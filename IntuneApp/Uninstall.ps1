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
        $logFile = Join-Path $logDir 'Uninstall.log'
    }

    Write-Log "=== Uninstall started for $appName ===" $logFile
    Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" $logFile

    if (-not (Test-SystemAccount)) {
        if ($env:INTUNE_LOCAL_TEST) {
            Write-Log "Local test mode: skipping SYSTEM check." $logFile
        }
        else {
            Write-Log "WARNING: Not running as SYSTEM. Production deployments must run as SYSTEM." $logFile
            Write-Warning "Not running as SYSTEM. Use Test-Local.ps1 for local testing."
        }
    }

    $uninstallType = $Config.Uninstaller.Type.ToUpper()

    if ($uninstallType -eq 'MSI') {
        $productCode = $Config.Uninstaller.ProductCode
        if (-not $productCode) {
            Write-Log "ERROR: MSI uninstall requires ProductCode in configuration." $logFile
            Write-Error "MSI uninstall requires ProductCode in configuration."
            exit 1
        }
        $msiArgs = "/x $productCode /qn /norestart"
        Write-Log "Executing: msiexec.exe $msiArgs" $logFile
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    }
    elseif ($uninstallType -eq 'EXE') {
        $uninstallFile = $Config.Uninstaller.File
        $uninstallArgs = $Config.Uninstaller.Arguments

        if (-not $uninstallFile) {
            Write-Log "ERROR: EXE uninstall requires File in configuration." $logFile
            Write-Error "EXE uninstall requires File in configuration."
            exit 1
        }

        # Check if it's an absolute path or relative to the package
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

        Write-Log "Executing: $uninstallPath $uninstallArgs" $logFile
        $process = Start-Process -FilePath $uninstallPath -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
    }
    else {
        Write-Log "ERROR: Unknown uninstaller type: $uninstallType" $logFile
        Write-Error "Unknown uninstaller type: $uninstallType"
        exit 1
    }

    $exitCode = $process.ExitCode
    Write-Log "Exit code: $exitCode" $logFile

    $successCodes = $Config.SuccessExitCodes
    if (-not $successCodes) { $successCodes = @(0, 3010) }

    if ($exitCode -notin $successCodes) {
        Write-Log "ERROR: Uninstaller failed with exit code $exitCode" $logFile
        exit 1
    }

    # Verify removal via detection
    Write-Log "Running post-uninstall detection..." $logFile
    $detected = Invoke-Detection -Config $Config
    if (-not $detected) {
        Write-Log "Detection: Application no longer detected. Uninstall SUCCESS." $logFile
        if ($exitCode -eq 3010) { exit 3010 }
        exit 0
    }
    else {
        Write-Log "ERROR: Application still detected after uninstall." $logFile
        exit 1
    }
}
catch {
    if ($logFile) { Write-Log "ERROR: $($_.Exception.Message)" $logFile }
    Write-Error $_.Exception.Message
    exit 1
}
