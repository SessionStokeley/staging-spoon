<#
.SYNOPSIS
    Deployment wrapper template - uninstall.
.DESCRIPTION
    Self-contained by design: this script ships inside the .intunewin.
    Resolves the uninstall command from the machine's uninstall registration
    rather than assuming a path that may differ by version.
#>

[CmdletBinding()]
param(
    [ValidateSet('Preserve', 'Translate')]
    [string]$RebootStrategy = 'Preserve'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Package configuration ---------------------------------------------------
$PackageRoot   = $PSScriptRoot
$DisplayName   = 'Vendor Application'
$ProductCode   = ''          # Set for MSI packages, e.g. '{GUID}'
$FallbackArguments = @('/S')

$SuccessExitCodes = @(0, 1605)   # 1605: already absent
$RebootExitCodes  = @(1641, 3010)
$TimeoutSeconds   = 1800

$LogRoot = Join-Path $env:ProgramData 'IntuneDeployment\Logs'
$LogFile = Join-Path $LogRoot ('Uninstall-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    try {
        if (-not (Test-Path -LiteralPath $LogRoot)) {
            New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Get-UninstallRegistration {
    param([Parameter(Mandatory)][string]$Name)

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }

        foreach ($item in (Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $properties) { continue }
            if ($properties.PSObject.Properties.Name -notcontains 'DisplayName') { continue }
            if ($properties.DisplayName -notlike $Name) { continue }

            return [PSCustomObject]@{
                DisplayName     = $properties.DisplayName
                ProductCode     = $item.PSChildName
                UninstallString = if ($properties.PSObject.Properties.Name -contains 'UninstallString') { $properties.UninstallString } else { $null }
            }
        }
    }

    $null
}

$exitCode = 1

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log "Package root: $PackageRoot"
    Write-Log "Running as: $($identity.Name) (System=$($identity.IsSystem))"

    $filePath = $null
    $arguments = @()

    if ($ProductCode) {
        $filePath  = "$env:SystemRoot\System32\msiexec.exe"
        $arguments = @('/x', $ProductCode, '/qn', '/norestart')
        Write-Log "Uninstalling by product code: $ProductCode"
    } else {
        $registration = Get-UninstallRegistration -Name $DisplayName

        if (-not $registration) {
            # Nothing to remove is a successful uninstall, not a failure.
            Write-Log "No uninstall registration found for '$DisplayName'; treating as already uninstalled"
            exit 0
        }

        Write-Log "Found registration: $($registration.DisplayName) ($($registration.ProductCode))"

        if ($registration.ProductCode -match '^\{[0-9A-Fa-f-]{36}\}$') {
            $filePath  = "$env:SystemRoot\System32\msiexec.exe"
            $arguments = @('/x', $registration.ProductCode, '/qn', '/norestart')
        } elseif ($registration.UninstallString) {
            # Split a quoted executable from its trailing arguments.
            if ($registration.UninstallString -match '^"([^"]+)"\s*(.*)$') {
                $filePath  = $Matches[1]
                $arguments = @($Matches[2] -split '\s+' | Where-Object { $_ }) + $FallbackArguments
            } else {
                $filePath  = $registration.UninstallString
                $arguments = $FallbackArguments
            }
        } else {
            throw "Uninstall registration for '$DisplayName' has no usable uninstall string"
        }
    }

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Uninstaller not found: $filePath"
    }

    Write-Log "Starting uninstaller: $filePath $($arguments -join ' ')"

    $process = Start-Process -FilePath $filePath `
                             -ArgumentList $arguments `
                             -PassThru `
                             -Wait `
                             -NoNewWindow

    $vendorExitCode = $process.ExitCode
    Write-Log "Uninstaller exited with code $vendorExitCode"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $active = @(Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -ne $process.Id -and -not $_.HasExited })
        if ($active.Count -eq 0) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $requiresReboot = $vendorExitCode -in $RebootExitCodes
    $isSuccess      = $vendorExitCode -in $SuccessExitCodes -or $requiresReboot

    if (-not $isSuccess) {
        Write-Log "Uninstallation failed. Vendor exit code: $vendorExitCode" -Level ERROR
        exit $vendorExitCode
    }

    if ($requiresReboot -and $RebootStrategy -eq 'Translate') {
        Write-Log "Uninstallation succeeded; reboot code $vendorExitCode translated to 0"
        $exitCode = 0
    } else {
        Write-Log "Uninstallation succeeded with exit code $vendorExitCode"
        $exitCode = $vendorExitCode
    }
} catch {
    Write-Log "Unhandled failure: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}

exit $exitCode
