#Requires -Version 5.1
<#
    Install.ps1

    Stages, in order:

        1  Validate the configuration
        2  Validate the installer
        3  Detect any current installation
        4  Run the installer
        5  Check the installer exit code
        6  Confirm the application is present
        7  Configure environment variables
        8  Configure PATH
        9  Apply Windows integration
       10  Validate the application
       11  Validate the integrations
       12  Record ownership
       13  Report

    Nothing is created before stage 6 confirms the application actually
    installed, so a shortcut never points at an application that is not there.

    -TestMode performs stages 1 to 3, prints every change the remaining stages
    would make, and exits without touching the machine.

    Installer arguments
    -------------------
    Installer.ArgumentSource in Configuration.psd1 decides where the installer's
    arguments come from: 'Configuration' (the default, and what every older
    package means), 'Intune' (passed in here from the Program command), or
    'None'. Exactly one source is authoritative and they are never combined -
    see Helpers/InstallerArguments.ps1.

    Intune Program command, for ArgumentSource = 'Intune':

        powershell.exe -ExecutionPolicy Bypass -File Install.ps1 ^
            -InstallerArguments "/quiet /norestart"

    Use -InstallerArgumentsBase64 instead when the arguments contain quotes or
    end in a backslash, which the Windows command line cannot carry intact.
#>
param(
    # Dry run. Validates, resolves paths, and prints the planned changes.
    [switch]$TestMode,

    # Installer arguments supplied by the caller, for ArgumentSource = 'Intune'.
    [string]$InstallerArguments = '',

    # The same string, base64-encoded, for arguments the Windows command line
    # cannot carry as a quoted parameter.
    [string]$InstallerArgumentsBase64 = '',

    # Overrides Installer.ArgumentSource for this run. Test-Local.ps1 uses it
    # so a package configured for Intune can still be tested locally.
    [ValidateSet('', 'Configuration', 'Intune', 'None')]
    [string]$ArgumentSource = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Load shared helpers
$helpersDir = Join-Path $ScriptDir 'Helpers'
foreach ($helper in @('ConfigLoader.ps1', 'InstallerArguments.ps1', 'Environment.ps1', 'WindowsIntegration.ps1')) {
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
    # ---------------------------------------------- 1. Validate configuration
    $Config = Get-PackageConfiguration -PackageRoot $ScriptDir
    $appName = $Config.ApplicationName

    if (-not $appName) { throw 'Configuration.psd1 has no ApplicationName.' }
    if (-not $Config.Installer) { throw 'Configuration.psd1 has no Installer section.' }
    if (-not $Config.Installer.Type) { throw 'Configuration.psd1 has no Installer.Type.' }

    # Logging setup
    $logFile = $null
    if ($Config.Logging.Enabled) {
        $logDir = Join-Path $Config.Logging.Path $appName
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        $logFile = Join-Path $logDir 'Install.log'
    }

    $modeLabel = if ($TestMode) { ' (dry run)' } else { '' }
    Write-Log "=== Install started for $appName$modeLabel ===" $logFile
    Write-Log "Running as: $(Get-CurrentIdentityName)" $logFile

    if ($TestMode) {
        Write-Host ''
        Write-Host "Dry run for $appName. Nothing will be changed."
        Write-Host ''
    }

    if (-not (Test-SystemAccount)) {
        if ($env:INTUNE_LOCAL_TEST -or $TestMode) {
            Write-Log 'Local test mode: skipping SYSTEM check.' $logFile
        }
        else {
            Write-Log 'WARNING: Not running as SYSTEM. Production deployments must run as SYSTEM.' $logFile
            Write-Warning 'Not running as SYSTEM. Use Test-Local.ps1 for local testing.'
        }
    }

    # -------------------------------------------------- 2. Validate installer
    $filesDir = Join-Path $ScriptDir 'Files'
    $installerPath = Join-Path $filesDir $Config.Installer.File
    if (-not (Test-Path $installerPath)) {
        $available = if (Test-Path $filesDir) { (Get-ChildItem $filesDir -File | Select-Object -ExpandProperty Name) -join ', ' } else { '(Files directory missing)' }
        if (-not $available) { $available = '(empty)' }
        Write-Log "ERROR: Installer not found: $($Config.Installer.File). Files directory contains: $available" $logFile
        Write-Error "Installer not found: $($Config.Installer.File). Files directory contains: $available"
        exit 1
    }
    Write-Log "Installer: $installerPath" $logFile

    # ------------------------------------------ 3. Detect current installation
    $alreadyInstalled = Invoke-Detection -Config $Config
    Write-Log "Pre-install detection: application present = $alreadyInstalled" $logFile

    $installerType = $Config.Installer.Type.ToUpper()

    if ($installerType -notin @('MSI', 'EXE', 'BAT')) {
        Write-Log "ERROR: Unknown installer type: $installerType" $logFile
        Write-Error "Unknown installer type: $installerType"
        exit 1
    }

    # Exactly one argument source wins, and a disagreement between the
    # configuration and what was passed is refused rather than guessed at.
    $argumentResult = Resolve-InstallerArguments -Config $Config `
        -Override $ArgumentSource `
        -IntuneArguments $InstallerArguments `
        -IntuneArgumentsBase64 $InstallerArgumentsBase64 `
        -IntuneArgumentsProvided ($PSBoundParameters.ContainsKey('InstallerArguments') -or
                                  $PSBoundParameters.ContainsKey('InstallerArgumentsBase64'))

    foreach ($warning in @($argumentResult.Warnings)) {
        Write-Log "NOTE: $warning" $logFile
    }

    # Everything downstream uses this one command line, so a dry run prints
    # what will actually run rather than a second rendering of it.
    $commandLine = New-InstallerCommandLine -Type $installerType `
        -InstallerPath $installerPath `
        -Arguments $argumentResult.Arguments `
        -DisplayArguments $argumentResult.Display

    Write-Log "Installer type   : $installerType" $logFile
    Write-Log "Installer path   : $installerPath" $logFile
    Write-Log "Argument source  : $($argumentResult.Source)" $logFile
    Write-Log "Effective args   : $($argumentResult.Display)" $logFile

    # ------------------------------------------------------ Dry run stops here
    if ($TestMode) {
        Write-Host "Installer type   : $installerType"
        Write-Host "Installer path   : $installerPath"
        Write-Host "Argument source  : $($argumentResult.Source)"
        Write-Host "Effective args   : $($argumentResult.Display)"
        Write-Host ''
        Write-Plan "Would run: $($commandLine.Display)" $logFile

        if ($Config.Environment -and $Config.Environment.Enabled) {
            Install-EnvironmentConfig -Config $Config -LogFile $logFile -DryRun | Out-Null
        }
        else {
            Write-Plan 'Environment and PATH: nothing configured.' $logFile
        }

        if ($Config.WindowsIntegration -and $Config.WindowsIntegration.Enabled) {
            Install-WindowsIntegration -Config $Config -LogFile $logFile -DryRun | Out-Null
        }
        else {
            Write-Plan 'Windows integration: nothing configured.' $logFile
        }

        Write-Host ''
        Write-Host 'Dry run complete. No changes were made.'
        Write-Log 'Dry run complete. No changes were made.' $logFile
        exit 0
    }

    # ------------------------------------------------------ 4. Run the installer
    Write-Log "Executing: $($commandLine.Display)" $logFile
    $process = Start-InstallerProcess -CommandLine $commandLine

    # ----------------------------------------------------- 5. Check exit code
    $exitCode = $process.ExitCode
    Write-Log "Exit code: $exitCode" $logFile

    $successCodes = $Config.SuccessExitCodes
    if (-not $successCodes) { $successCodes = @(0, 3010) }

    if ($exitCode -notin $successCodes) {
        Write-Log "ERROR: Installer failed with exit code $exitCode" $logFile
        exit 1
    }

    # ---------------------------------------- 6. Confirm the application is in
    Write-Log 'Running post-install detection...' $logFile
    $detected = Invoke-Detection -Config $Config
    if (-not $detected) {
        Write-Log 'ERROR: Detection failed after installation. Application not detected.' $logFile
        exit 1
    }
    Write-Log 'Detection result : Application detected.' $logFile

    # ----------------------------------------- 7 & 8. Environment and PATH
    if ($Config.Environment -and $Config.Environment.Enabled) {
        Write-Log 'Configuring environment...' $logFile
        $envSuccess = Install-EnvironmentConfig -Config $Config -LogFile $logFile
        if (-not $envSuccess) {
            Write-Log 'WARNING: Environment configuration had failures. Application is installed.' $logFile
        }
    }

    # -------------------------------------------- 9. Apply Windows integration
    # Only reached once detection has confirmed the application is present.
    $integrationRequiredFailed = $false
    if ($Config.WindowsIntegration -and $Config.WindowsIntegration.Enabled) {
        Write-Log 'Applying Windows integration...' $logFile
        $integration = Install-WindowsIntegration -Config $Config -LogFile $logFile
        $integrationRequiredFailed = $integration.RequiredFailed

        if (-not $integration.Success) {
            foreach ($finding in @($integration.Findings)) {
                Write-Warning "Windows integration: $finding"
            }
        }
    }

    # ------------------------------ 10 & 11. Validate application and integrations
    if ($Config.WindowsIntegration -and $Config.WindowsIntegration.Enabled) {
        $check = Test-WindowsIntegrationState -Config $Config -LogFile $logFile
        Write-Log "Integration validation: success = $($check.Success)" $logFile
        foreach ($finding in @($check.Findings)) {
            Write-Log "  $finding" $logFile
        }
    }

    # ------------------------------------------------------------ 13. Report
    # A Required integration that could not be created fails the install: the
    # configuration said the application is not usable without it.
    if ($integrationRequiredFailed) {
        Write-Log 'ERROR: A Windows integration marked Required could not be created.' $logFile
        Write-Error 'A Windows integration marked Required could not be created. See the install log.'
        exit 1
    }

    Write-Log 'Install SUCCESS.' $logFile
    if ($exitCode -eq 3010) { exit 3010 }
    exit 0
}
catch {
    if ($logFile) { Write-Log "ERROR: $($_.Exception.Message)" $logFile }
    Write-Error $_.Exception.Message
    exit 1
}
