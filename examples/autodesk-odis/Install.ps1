<#
.SYNOPSIS
    Deployment wrapper - install (Autodesk ODIS offline deployment).
.DESCRIPTION
    This is an ODIS-specific wrapper, not the generic template. An Autodesk
    deployment does not run from the folder it ships in: the offline image
    carries an absolute DeploymentImagePath baked into Collection.xml
    (C:\Program Files\Autodesk\image), and the product is laid down with
    symlinks into that image (Collection.xml: <Symlink>true</Symlink>). The
    image must therefore live at that fixed path, and must remain there after
    install for Revit to run.

    So this wrapper does two things the generic template cannot:
      1. Stage the packaged image\ folder to the DeploymentImagePath the
         deployment was authored for.
      2. Run Installer.exe -i deploy in true silent mode (-q), NOT the
         '--ui_mode basic' the generated .bat uses, which shows a UI and hangs
         under SYSTEM (session 0).

    It keeps the template's hard-won contracts:
      - All payload resolves from $PSScriptRoot, never the working directory.
      - The vendor exit code is preserved, never replaced with 0.
      - Each child process is run with no shell and waited on as a single
        process (never -Wait, which also waits on descendants a resident
        Autodesk helper keeps alive).
      - Resolving the log path cannot throw, so a failure still produces a log.

    The staged image is deliberately NOT removed after install: with symlink
    deployment the installed product references files inside it. Uninstall.ps1
    removes it once the product is gone.
#>

[CmdletBinding()]
param(
    # Accepted for parity with the generic install command shape; this wrapper
    # is self-contained and does not need them. Extra arguments are tolerated
    # and ignored rather than rejected, so a generated command still runs.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$IgnoredArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Package configuration ---------------------------------------------------
$PackageRoot = $PSScriptRoot

# The image folder that ships inside the package.
$ImageFolderName = 'image'

# Where the deployment expects its image. This MUST match Collection.xml's
# <DeploymentImagePath> and odisver.xml's <location>; the deploy command below
# points -o at Collection.xml inside it, and the product symlinks into it.
$DeploymentImagePath = 'C:\Program Files\Autodesk\image'

# From odisver.xml / the vendor .bat. The ODIS installer verifies this.
$InstallerVersion = '2.24.0.558'

# The silent deploy switches. -q is the real silent mode. --offline_mode keeps
# the installer from reaching the internet for payload it already has.
$DeployArguments = @(
    '-i', 'deploy'
    '--offline_mode'
    '-q'
    '-o', (Join-Path $DeploymentImagePath 'Collection.xml')
    '--installer_version', $InstallerVersion
)

$SuccessExitCodes = @(0)
$RebootExitCodes  = @(1641, 3010)

# Revit is large and the image copy is ~14 GB; give both stages room.
$StageTimeoutSeconds   = 3600    # copying the image to C:\Program Files\Autodesk\image
$InstallTimeoutSeconds = 7200    # the Autodesk deployment itself

# Resolving the log location must never throw: it runs before the try block, so
# a failure here would end the wrapper with exit 1 and no log at all.
$LogParent = if ($env:ProgramData) { $env:ProgramData } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$LogRoot = Join-Path $LogParent 'IntuneDeployment\Logs'
$LogFile = Join-Path $LogRoot ('Install-Revit2027.3-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

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

# --- Process execution -------------------------------------------------------
function Invoke-NativeProcess {
    <#
        Runs one process exactly as a command prompt would: no shell, no
        redirection, and a wait on this process alone. Returns the exit code.
        Waiting on the process object (not -Wait) avoids waiting on descendants
        an Autodesk updater/helper keeps resident.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$WorkingDirectory = $PackageRoot
    )

    $argumentLine = (
        $Arguments | ForEach-Object {
            if ([string]::IsNullOrEmpty($_)) { return }
            if ($_ -match '"') { $_ }
            elseif ($_ -match '\s') { '"' + $_ + '"' }
            else { $_ }
        }
    ) -join ' '

    Write-Log "Running: $FilePath $argumentLine"

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName         = $FilePath
    $startInfo.Arguments        = $argumentLine
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute  = $false

    $process = [System.Diagnostics.Process]::Start($startInfo)
    Write-Log "Process running as PID $($process.Id)"

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Log "Process did not exit within $TimeoutSeconds seconds" -Level ERROR
        try { $process.Kill() } catch { }
        return 1460
    }

    $process.ExitCode
}

# --- Execution ---------------------------------------------------------------
$exitCode = 1

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log "Package root: $PackageRoot"
    Write-Log "Running as: $($identity.Name) (System=$($identity.IsSystem), Interactive=$([Environment]::UserInteractive))"
    Write-Log "Process architecture: $(if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' })"

    $imageSource = Join-Path $PackageRoot $ImageFolderName
    if (-not (Test-Path -LiteralPath $imageSource -PathType Container)) {
        throw "Deployment image not found in package: $imageSource"
    }

    $sourceInstaller = Join-Path $imageSource 'Installer.exe'
    if (-not (Test-Path -LiteralPath $sourceInstaller -PathType Leaf)) {
        throw "Installer.exe not found in packaged image: $sourceInstaller"
    }

    # --- Stage the image to the path the deployment was authored for ---------
    # robocopy /E copies the tree without deleting anything already there, so a
    # re-run is idempotent and skips files that already match. Exit codes 0-7
    # are success for robocopy; 8 and above are genuine failures.
    Write-Log "Staging image to $DeploymentImagePath (this copies ~14 GB and can take a while)"
    if (-not (Test-Path -LiteralPath $DeploymentImagePath)) {
        New-Item -Path $DeploymentImagePath -ItemType Directory -Force | Out-Null
    }

    $roboArgs = @(
        $imageSource, $DeploymentImagePath,
        '/E', '/COPY:DAT', '/DCOPY:DAT',
        '/R:2', '/W:5',
        '/NFL', '/NDL', '/NP', '/NJH', '/NJS'
    )
    $roboExit = Invoke-NativeProcess -FilePath "$env:SystemRoot\System32\robocopy.exe" `
        -Arguments $roboArgs -TimeoutSeconds $StageTimeoutSeconds

    if ($roboExit -ge 8) {
        Write-Log "Image staging failed. robocopy exit code: $roboExit" -Level ERROR
        exit 1
    }
    Write-Log "Image staged (robocopy exit code $roboExit)"

    $stagedInstaller = Join-Path $DeploymentImagePath 'Installer.exe'
    if (-not (Test-Path -LiteralPath $stagedInstaller -PathType Leaf)) {
        throw "Installer.exe not present after staging: $stagedInstaller"
    }

    # --- Run the deployment silently -----------------------------------------
    $vendorExitCode = Invoke-NativeProcess -FilePath $stagedInstaller `
        -Arguments $DeployArguments -TimeoutSeconds $InstallTimeoutSeconds `
        -WorkingDirectory $DeploymentImagePath

    Write-Log "Installer process exited with code $vendorExitCode"

    $requiresReboot = $vendorExitCode -in $RebootExitCodes
    $isSuccess      = ($vendorExitCode -in $SuccessExitCodes) -or $requiresReboot

    if (-not $isSuccess) {
        Write-Log "Installation failed. Vendor exit code: $vendorExitCode" -Level ERROR
        exit $vendorExitCode
    }

    Write-Log "Installation succeeded with exit code $vendorExitCode"
    $exitCode = $vendorExitCode
} catch {
    Write-Log "Unhandled failure: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}

# Always terminate explicitly; never rely on implicit exit behaviour.
exit $exitCode
