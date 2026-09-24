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

    The installer name and its silent arguments are NOT written into this file.
    They are passed in as parameters by the generated install command, so
    package.json is the single source of both. -InstallerName is the file to
    run; the silent switches follow as ordinary arguments and are collected by
    -InstallerArguments, which keeps each switch a separate value.
#>

[CmdletBinding()]
param(
    [string]$InstallerName = '',

    # Position 0 makes this the one positional parameter, so the silent switches
    # that follow -InstallerName collect here even when another parameter (such
    # as -RebootStrategy) is also present. Without an explicit position a bare
    # switch like /S would bind to whichever parameter came first.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InstallerArguments = @(),

    [ValidateSet('Preserve', 'Translate')]
    [string]$RebootStrategy = 'Preserve'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Package configuration ---------------------------------------------------
$PackageRoot = $PSScriptRoot

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

    # The name is supplied by the generated command, not hard-coded here. An
    # empty value means the package was generated before the wrapper took
    # parameters; regenerate package.json rather than guess which file to run.
    if (-not $InstallerName) {
        throw "No installer name was passed to Install.ps1. Regenerate the package with New-PackageProject.ps1 so the install command carries -InstallerName."
    }

    $installerPath = Join-Path $PackageRoot $InstallerName
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Installer not found in package: $installerPath"
    }

    # Joined into the single string the process boundary takes. A value the
    # author already quoted is emitted as written, so the quotes land where the
    # installer expects them; a value that merely contains a space, and carries
    # no quotes of its own, is wrapped whole. This is the last layer, so the
    # string is the installer's own command-line syntax, not PowerShell's.
    $argumentLine = (
        $InstallerArguments | ForEach-Object {
            if ([string]::IsNullOrEmpty($_)) { return }
            if ($_ -match '"') { $_ }
            elseif ($_ -match '\s') { '"' + $_ + '"' }
            else { $_ }
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
