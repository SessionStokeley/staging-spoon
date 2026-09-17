#Requires -Version 5.1
<#
    Uninstall.ps1

    Stages, in order:

        1  Detect the application
        2  Run the uninstaller
        3  Remove package-owned Windows integrations
        4  Remove package-owned PATH entries
        5  Remove package-owned environment variables
        6  Validate the cleanup
        7  Report

    Every removal is driven by the ownership recorded at install time. A
    shortcut, registry key, service or task that this package did not create is
    never removed, and a feature left in VALIDATE mode recorded nothing, so the
    installer's own integrations survive.

    -TestMode prints what would be removed and exits without changing anything.
#>
param(
    # Dry run. Prints the planned removals without performing them.
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Load shared helpers
$helpersDir = Join-Path $ScriptDir 'Helpers'
foreach ($helper in @('ConfigLoader.ps1', 'Environment.ps1', 'WindowsIntegration.ps1')) {
    $helperPath = Join-Path $helpersDir $helper
    if (Test-Path $helperPath) { . $helperPath }
}

# --- Helpers ---

function Write-Log {
    param([string]$Message, [string]$LogFile)
    if (-not $LogFile) { return }
    $entry = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $entry | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Write-Plan {
    param([string]$Message, [string]$LogFile)
    Write-Host "[DRY-RUN] $Message"
    Write-Log "[DRY-RUN] $Message" $LogFile
}

function Get-CurrentIdentityName {
    # Never allowed to abort the run. The identity is diagnostic, and the
    # Windows principal API throws outright on non-Windows, which would stop a
    # dry run before it printed anything.
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { return '(identity unavailable on this platform)' }
}

function Test-SystemAccount {
    return ((Get-CurrentIdentityName) -eq 'NT AUTHORITY\SYSTEM')
}

function Invoke-Detection {
    param([hashtable]$Config)
    $detectionScript = Join-Path $ScriptDir 'Detection.ps1'
    $result = & $detectionScript
    return ($LASTEXITCODE -eq 0)
}

# --- Main ---

try {
    $Config = Get-PackageConfiguration -PackageRoot $ScriptDir
    $appName = $Config.ApplicationName

    # Logging setup
    $logFile = $null
    if ($Config.Logging.Enabled) {
        $logDir = Join-Path $Config.Logging.Path $appName
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        $logFile = Join-Path $logDir 'Uninstall.log'
    }

    $modeLabel = if ($TestMode) { ' (dry run)' } else { '' }
    Write-Log "=== Uninstall started for $appName$modeLabel ===" $logFile
    Write-Log "Running as: $(Get-CurrentIdentityName)" $logFile

    if (-not (Test-SystemAccount)) {
        if ($env:INTUNE_LOCAL_TEST -or $TestMode) {
            Write-Log 'Local test mode: skipping SYSTEM check.' $logFile
        }
        else {
            Write-Log 'WARNING: Not running as SYSTEM. Production deployments must run as SYSTEM.' $logFile
            Write-Warning 'Not running as SYSTEM. Use Test-Local.ps1 for local testing.'
        }
    }

    # ------------------------------------------------- 1. Detect application
    $presentBefore = Invoke-Detection -Config $Config
    Write-Log "Pre-uninstall detection: application present = $presentBefore" $logFile

    if (-not $Config.Uninstaller -or -not $Config.Uninstaller.Type) {
        throw 'Configuration.psd1 has no Uninstaller.Type.'
    }
    $uninstallType = $Config.Uninstaller.Type.ToUpper()

    if ($uninstallType -notin @('MSI', 'EXE')) {
        Write-Log "ERROR: Unknown uninstaller type: $uninstallType" $logFile
        Write-Error "Unknown uninstaller type: $uninstallType"
        exit 1
    }

    # Resolve what the uninstaller will be, so a dry run can name it.
    $uninstallCommand = ''
    if ($uninstallType -eq 'MSI') {
        $productCode = $Config.Uninstaller.ProductCode
        if (-not $productCode) {
            Write-Log 'ERROR: MSI uninstall requires ProductCode in configuration.' $logFile
            Write-Error 'MSI uninstall requires ProductCode in configuration.'
            exit 1
        }
        $msiArgs = "/x $productCode /qn /norestart"
        $uninstallCommand = "msiexec.exe $msiArgs"
    }
    else {
        $uninstallFile = $Config.Uninstaller.File
        $uninstallArgs = $Config.Uninstaller.Arguments

        if (-not $uninstallFile) {
            Write-Log 'ERROR: EXE uninstall requires File in configuration.' $logFile
            Write-Error 'EXE uninstall requires File in configuration.'
            exit 1
        }

        # Absolute paths are supported, for uninstallers discovered in the
        # registry rather than shipped in the package.
        if ([System.IO.Path]::IsPathRooted($uninstallFile)) {
            $uninstallPath = $uninstallFile
        }
        else {
            $uninstallPath = Join-Path (Join-Path $ScriptDir 'Files') $uninstallFile
        }

        if (-not (Test-Path $uninstallPath)) {
            Write-Log "ERROR: Uninstaller not found: $uninstallPath" $logFile
            Write-Error "Uninstaller not found: $uninstallPath"
            exit 1
        }
        $uninstallCommand = "$uninstallPath $uninstallArgs"
    }

    # ------------------------------------------------------ Dry run stops here
    if ($TestMode) {
        Write-Host ''
        Write-Host "Dry run for $appName. Nothing will be changed."
        Write-Host ''
        Write-Plan "Would run: $uninstallCommand" $logFile

        if ($Config.WindowsIntegration -and $Config.WindowsIntegration.Enabled) {
            Uninstall-WindowsIntegration -Config $Config -LogFile $logFile -DryRun | Out-Null
        }
        if ($Config.Environment -and $Config.Environment.Enabled) {
            Uninstall-EnvironmentConfig -Config $Config -LogFile $logFile -DryRun | Out-Null
        }

        Write-Host ''
        Write-Host 'Dry run complete. No changes were made.'
        Write-Log 'Dry run complete. No changes were made.' $logFile
        exit 0
    }

    # ---------------------------------------------------- 2. Run uninstaller
    if ($uninstallType -eq 'MSI') {
        Write-Log "Executing: msiexec.exe $msiArgs" $logFile
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    }
    else {
        Write-Log "Executing: $uninstallPath $uninstallArgs" $logFile
        $process = Start-Process -FilePath $uninstallPath -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
    }

    $exitCode = $process.ExitCode
    Write-Log "Exit code: $exitCode" $logFile

    $successCodes = $Config.SuccessExitCodes
    if (-not $successCodes) { $successCodes = @(0, 3010) }

    if ($exitCode -notin $successCodes) {
        Write-Log "ERROR: Uninstaller failed with exit code $exitCode" $logFile
        exit 1
    }

    # --------------------------------- 3. Remove package-owned integrations
    if ($Config.WindowsIntegration -and $Config.WindowsIntegration.Enabled) {
        Write-Log 'Removing package-owned Windows integrations...' $logFile
        $integration = Uninstall-WindowsIntegration -Config $Config -LogFile $logFile
        if (-not $integration.Success) {
            Write-Log 'WARNING: Windows integration cleanup had failures.' $logFile
        }
    }

    # ------------------------------------- 4 & 5. PATH and environment variables
    if ($Config.Environment -and $Config.Environment.Enabled) {
        Write-Log 'Cleaning up environment configuration...' $logFile
        $envSuccess = Uninstall-EnvironmentConfig -Config $Config -LogFile $logFile
        if (-not $envSuccess) {
            Write-Log 'WARNING: Environment cleanup had failures.' $logFile
        }
    }

    # ----------------------------------------------------- 6. Validate cleanup
    Write-Log 'Running post-uninstall detection...' $logFile
    $detected = Invoke-Detection -Config $Config

    # ------------------------------------------------------------- 7. Report
    if (-not $detected) {
        Write-Log 'Detection: Application no longer detected. Uninstall SUCCESS.' $logFile
        if ($exitCode -eq 3010) { exit 3010 }
        exit 0
    }
    else {
        Write-Log 'ERROR: Application still detected after uninstall.' $logFile
        exit 1
    }
}
catch {
    if ($logFile) { Write-Log "ERROR: $($_.Exception.Message)" $logFile }
    Write-Error $_.Exception.Message
    exit 1
}
