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

# Resolving the log location must never be able to throw: it runs before the
# try block, so a failure here would end the wrapper with exit 1 and no log at
# all - indistinguishable from an uninstaller that failed.
$LogParent = if ($env:ProgramData) { $env:ProgramData } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$LogRoot = Join-Path $LogParent 'IntuneDeployment\Logs'
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

    # Remove only the integrations this package recorded owning. Driven by the
    # saved ownership state, so a vendor-created (VALIDATE) association, and any
    # PATH entry or key the package did not add, is left untouched. Runs first
    # and independently of the vendor uninstall, so it happens even when the app
    # is already gone.
    $removeIntegrations = Join-Path $PackageRoot 'Remove-Integrations.ps1'
    if (Test-Path -LiteralPath $removeIntegrations -PathType Leaf) {
        Write-Log "Removing package-owned Windows integrations"
        & $removeIntegrations 2>&1 | ForEach-Object { Write-Log $_ }
    }

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

    $argumentLine = (
        $arguments | ForEach-Object {
            if ($_ -match '\s' -and -not ($_.StartsWith('"') -and $_.EndsWith('"'))) { '"' + $_ + '"' } else { $_ }
        }
    ) -join ' '

    Write-Log "Starting uninstaller: $filePath $argumentLine"

    # Run exactly as a command prompt would, and wait for this process only.
    #
    # Start-Process -Wait is deliberately not used: on Windows it waits for the
    # process AND ITS DESCENDANTS. Nor is there a wait on msiexec by name -
    # msiexec also runs as the long-lived Windows Installer service, so a
    # machine-wide name match never goes quiet and the wait runs to its
    # deadline on every uninstall.
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName        = $filePath
    $startInfo.Arguments       = $argumentLine
    $startInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($startInfo)
    Write-Log "Uninstaller running as PID $($process.Id)"

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Log "Uninstaller did not exit within $TimeoutSeconds seconds" -Level ERROR
        try { $process.Kill() } catch { }
        exit 1460
    }

    $vendorExitCode = $process.ExitCode
    Write-Log "Uninstaller exited with code $vendorExitCode"

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
