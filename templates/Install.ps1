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
      - The installer is run exactly as a command prompt would run it: no
        shell, no redirection, and a wait on the installer process alone.

    What this template deliberately does NOT do: wait for descendants of the
    installer. Leaving a helper or updater resident is normal behaviour, not an
    unfinished installation, and waiting for one that never exits stalls the
    deployment. The installer's own exit code is what says it finished.
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

# Resolving the log location must never be able to throw: it runs before the
# try block, so a failure here would end the wrapper with exit 1 and no log at
# all - indistinguishable from an installer that failed.
$LogParent = if ($env:ProgramData) { $env:ProgramData } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$LogRoot = Join-Path $LogParent 'IntuneDeployment\Logs'
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

    # Arguments are joined into one string and quoted only where a value
    # contains whitespace, so the installer receives exactly what it would from
    # a command prompt.
    $argumentLine = (
        $InstallerArguments | ForEach-Object {
            if ($_ -match '\s' -and -not ($_.StartsWith('"') -and $_.EndsWith('"'))) { '"' + $_ + '"' } else { $_ }
        }
    ) -join ' '

    Write-Log "Starting installer: $installerPath $argumentLine"

    # Run exactly as a command prompt would: no shell, no redirection, no
    # window games, and a wait on this process only.
    #
    # Start-Process -Wait is deliberately not used. On Windows it waits for the
    # process AND ITS DESCENDANTS, so an installer that leaves a helper or
    # updater resident - which is normal, and not a failure - never lets the
    # wait return. Waiting on the process object waits for the installer alone,
    # which is the thing whose exit code means the installation finished.
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName         = $installerPath
    $startInfo.Arguments        = $argumentLine
    $startInfo.WorkingDirectory = $PackageRoot
    $startInfo.UseShellExecute  = $false

    $process = [System.Diagnostics.Process]::Start($startInfo)
    Write-Log "Installer running as PID $($process.Id)"

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Log "Installer did not exit within $TimeoutSeconds seconds" -Level ERROR
        try { $process.Kill() } catch { }
        exit 1460
    }

    $vendorExitCode = $process.ExitCode
    Write-Log "Installer process exited with code $vendorExitCode"

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
