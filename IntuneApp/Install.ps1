#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- Helpers ---

function Write-Log {
    param([string]$Message, [string]$LogFile)
    if (-not $LogFile) { return }
    $entry = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $entry | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Test-SystemAccount {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    return ($identity -eq 'NT AUTHORITY\SYSTEM')
}

function Invoke-Detection {
    param([hashtable]$Config)
    $detectionScript = Join-Path $ScriptDir 'Detection.ps1'
    $result = & $detectionScript
    return ($LASTEXITCODE -eq 0)
}

# --- Main ---

try {
    $Config = Import-PowerShellDataFile (Join-Path $ScriptDir 'Configuration.psd1')
    $appName = $Config.ApplicationName

    # Logging setup
    $logFile = $null
    if ($Config.Logging.Enabled) {
        $logDir = Join-Path $Config.Logging.Path $appName
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        $logFile = Join-Path $logDir 'Install.log'
    }

    Write-Log "=== Install started for $appName ===" $logFile
    Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" $logFile

    # Verify SYSTEM (warn but don't block for local testing)
    if (-not (Test-SystemAccount)) {
        Write-Log "WARNING: Not running as SYSTEM. Production deployments must run as SYSTEM." $logFile
    }

    # Locate installer
    $installerPath = Join-Path (Join-Path $ScriptDir 'Files') $Config.Installer.File
    if (-not (Test-Path $installerPath)) {
        Write-Log "ERROR: Installer not found: $installerPath" $logFile
        Write-Error "Installer not found: $installerPath"
        exit 1
    }
    Write-Log "Installer: $installerPath" $logFile

    # Execute installer
    $installerType = $Config.Installer.Type.ToUpper()
    $arguments = $Config.Installer.Arguments

    if ($installerType -eq 'MSI') {
        $msiArgs = "/i `"$installerPath`" $arguments"
        Write-Log "Executing: msiexec.exe $msiArgs" $logFile
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    }
    elseif ($installerType -eq 'EXE') {
        Write-Log "Executing: $installerPath $arguments" $logFile
        $process = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    }
    else {
        Write-Log "ERROR: Unknown installer type: $installerType" $logFile
        Write-Error "Unknown installer type: $installerType"
        exit 1
    }

    $exitCode = $process.ExitCode
    Write-Log "Exit code: $exitCode" $logFile

    # Check exit code
    $successCodes = $Config.SuccessExitCodes
    if (-not $successCodes) { $successCodes = @(0, 3010) }

    if ($exitCode -notin $successCodes) {
        Write-Log "ERROR: Installer failed with exit code $exitCode" $logFile
        exit 1
    }

    # Run detection to confirm installation
    Write-Log "Running post-install detection..." $logFile
    $detected = Invoke-Detection -Config $Config
    if ($detected) {
        Write-Log "Detection: Application detected. Install SUCCESS." $logFile
        if ($exitCode -eq 3010) { exit 3010 }
        exit 0
    }
    else {
        Write-Log "ERROR: Detection failed after installation. Application not detected." $logFile
        exit 1
    }
}
catch {
    if ($logFile) { Write-Log "ERROR: $($_.Exception.Message)" $logFile }
    Write-Error $_.Exception.Message
    exit 1
}
