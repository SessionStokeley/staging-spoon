<#
.SYNOPSIS
    Deployment wrapper template - install.
.DESCRIPTION
    Self-contained by design: this script ships inside the .intunewin and
    must not depend on anything outside the package directory.

    Contracts this template implements:
      - All payload resolves from $PSScriptRoot, never the working directory.
      - The vendor exit code is preserved, never replaced with 0.
      - Installer failure propagates upward so Intune reports failure.
      - Child processes are awaited before success is declared.
#>

[CmdletBinding()]
param(
    [ValidateSet('Preserve', 'Translate')]
    [string]$RebootStrategy = 'Preserve'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Package configuration ---------------------------------------------------
$PackageRoot  = $PSScriptRoot
$InstallerName = 'Setup.exe'
$InstallerArguments = @('/S', '/v/qn')

$SuccessExitCodes = @(0)
$RebootExitCodes  = @(1641, 3010)
$TimeoutSeconds   = 1800
$SettleSeconds    = 10

# Waiting for installer children is a courtesy, not a completion condition, so
# it gets its own short budget. Tying it to $TimeoutSeconds means a process
# that never exits blocks the deployment for the full installer timeout.
$ChildWaitSeconds = 120

# Names that may be a continuation of this installation. Matching on name alone
# is not enough: msiexec.exe also runs as the long-lived Windows Installer
# service, so a machine-wide name match never goes quiet and the wait below
# would run to its deadline on every install.
$ChildProcessNames = @('msiexec', 'setup', 'install', 'installer')

$LogRoot = Join-Path $env:ProgramData 'IntuneDeployment\Logs'
$LogFile = Join-Path $LogRoot ('Install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# --- Logging -----------------------------------------------------------------
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
    } catch {
        # Logging must never mask the installation result.
    }
}

# --- Execution ---------------------------------------------------------------
$exitCode = 1

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log "Package root: $PackageRoot"
    Write-Log "Running as: $($identity.Name) (System=$($identity.IsSystem), Interactive=$([Environment]::UserInteractive))"
    Write-Log "Process architecture: $(if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' })"

    $installerPath = Join-Path $PackageRoot $InstallerName
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Installer not found in package: $installerPath"
    }

    # Anything matching by name that is already running belongs to the machine,
    # not to this installation, and must never be waited on.
    $preexistingIds = @(
        foreach ($name in $ChildProcessNames) {
            Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }
        }
    )

    if ($preexistingIds.Count -gt 0) {
        Write-Log "Ignoring $($preexistingIds.Count) pre-existing installer-named process(es)"
    }

    $installStartedAt = Get-Date
    Write-Log "Starting installer: $installerPath $($InstallerArguments -join ' ')"

    $process = Start-Process -FilePath $installerPath `
                             -ArgumentList $InstallerArguments `
                             -WorkingDirectory $PackageRoot `
                             -PassThru `
                             -Wait `
                             -NoNewWindow

    $vendorExitCode = $process.ExitCode
    Write-Log "Installer process exited with code $vendorExitCode"

    # A bootstrapper may hand off to the real installer and exit, so the first
    # process exiting does not always mean installation finished. Only
    # processes this installation actually started are waited on, and only for
    # $ChildWaitSeconds: a handover that has not finished by then is reported
    # and the deployment continues, because some installers deliberately leave
    # a helper or updater running.
    $childDeadline = (Get-Date).AddSeconds($ChildWaitSeconds)

    do {
        $active = @(
            foreach ($name in $ChildProcessNames) {
                foreach ($candidate in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                    if ($candidate.Id -eq $process.Id) { continue }
                    if ($candidate.Id -in $preexistingIds) { continue }
                    if ($candidate.HasExited) { continue }

                    # A process older than this installation cannot be part of
                    # it. StartTime is unreadable for some processes even when
                    # elevated; those are judged by the baseline alone.
                    $startedAt = $null
                    try { $startedAt = $candidate.StartTime } catch { }
                    if ($null -ne $startedAt -and $startedAt -lt $installStartedAt) { continue }

                    $candidate
                }
            }
        )

        if ($active.Count -eq 0) { break }
        Write-Log "Waiting for installer child processes: $(($active | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ')"
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $childDeadline)

    if ((Get-Date) -ge $childDeadline) {
        Write-Log "Child processes still running after ${ChildWaitSeconds}s; continuing without waiting further" -Level WARN
    }

    if ($SettleSeconds -gt 0) {
        Write-Log "Allowing $SettleSeconds seconds for asynchronous components to settle"
        Start-Sleep -Seconds $SettleSeconds
    }

    # Map the vendor code onto the wrapper's exit code. Meaningful codes are
    # preserved; only an explicit strategy may translate a reboot code.
    $requiresReboot = $vendorExitCode -in $RebootExitCodes
    $isSuccess      = $vendorExitCode -in $SuccessExitCodes -or $requiresReboot

    if (-not $isSuccess) {
        Write-Log "Installation failed. Vendor exit code: $vendorExitCode" -Level ERROR
        exit $vendorExitCode
    }

    if ($requiresReboot -and $RebootStrategy -eq 'Translate') {
        Write-Log "Installation succeeded; reboot code $vendorExitCode translated to 0 per RebootStrategy"
        $exitCode = 0
    } else {
        Write-Log "Installation succeeded with exit code $vendorExitCode"
        $exitCode = $vendorExitCode
    }
} catch {
    Write-Log "Unhandled failure: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}

# Always terminate explicitly; never rely on implicit exit behaviour.
exit $exitCode
