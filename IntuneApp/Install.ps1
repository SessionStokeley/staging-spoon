#Requires -Version 5.1
<#
.SYNOPSIS
    Generic Intune Win32 application installer.
.DESCRIPTION
    Configuration-driven installation script for any Windows application.
    All application-specific settings are read from Configuration.psd1.
    Designed to run as NT AUTHORITY\SYSTEM via the Intune Management Extension.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:ExitCode = 1

try {
    # Resolve package root relative to this script, not CWD
    $PackagePath = $PSScriptRoot

    # Load framework modules
    . (Join-Path $PackagePath 'Logging.ps1')
    . (Join-Path $PackagePath 'Detection.ps1')
    . (Join-Path $PackagePath 'Validation.ps1')
    . (Join-Path $PackagePath 'Requirements.ps1')

    # Load configuration
    $configPath = Join-Path $PackagePath 'Configuration.psd1'
    if (-not (Test-Path $configPath)) {
        Write-Error "Configuration.psd1 not found at $configPath"
        exit 1
    }
    $Config = Import-PowerShellDataFile -Path $configPath

    # Initialize logging with configurable settings
    $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }
    $debugLogging = [bool]$Config.Testing.EnableDebugLogging

    Initialize-Logging `
        -ApplicationName    $Config.ApplicationName `
        -CompanyName        $Config.CompanyName `
        -ScriptName         'Install' `
        -ApplicationVersion $Config.ApplicationVersion `
        -LoggingConfig      $loggingConfig `
        -DebugLogging       $debugLogging

    Write-Log -Message "Package path: $PackagePath" -Level 'Info'
    Write-Log -Message "Install scope: $($Config.InstallScope)" -Level 'Info'

    # Validate execution context
    $allowNonSystem = [bool]$Config.Testing.AllowNonSystemExecution
    $requireSystem = if ($Config.Execution) { $Config.Execution.RequireSystem } else { $true }

    if ($requireSystem -and -not (Test-SystemContext -AllowNonSystem $allowNonSystem)) {
        $script:ExitCode = 1
        Write-DeploymentSummary -Action 'Install' -ExitCode $script:ExitCode -ErrorDetail 'Not running as SYSTEM'
        exit $script:ExitCode
    }

    # Pre-install validation (unless skipped for testing)
    if (-not $Config.Testing.SkipValidation) {
        Write-Log -Message "Running pre-install validation..." -Level 'Info'
        $preValidation = Test-PreInstallValidation -Configuration $Config -PackagePath $PackagePath
        if (-not $preValidation.Passed) {
            $failureDetail = $preValidation.Failures -join '; '
            Write-Log -Message "Pre-install validation failed: $failureDetail" -Level 'Error'
            $script:ExitCode = 1
            Write-DeploymentSummary -Action 'Install' -ExitCode $script:ExitCode `
                -ValidationResult 'FAILED' -ErrorDetail $failureDetail
            exit $script:ExitCode
        }
    }

    # Validate requirements (unless skipped for testing)
    if (-not $Config.Testing.SkipRequirementChecks) {
        Write-Log -Message "Validating requirements..." -Level 'Info'
        $reqResult = Test-Requirements -Configuration $Config
        if (-not $reqResult) {
            Write-Log -Message "Requirements not met." -Level 'Error'
            $script:ExitCode = 1
            Write-DeploymentSummary -Action 'Install' -ExitCode $script:ExitCode `
                -ValidationResult 'FAILED' -ErrorDetail 'System requirements not met'
            exit $script:ExitCode
        }
    }

    # Check if already installed (unless skipped for testing)
    if (-not $Config.Testing.SkipDetection) {
        Write-Log -Message "Checking if application is already installed..." -Level 'Info'
        if ($Config.Detection) {
            $existingDetection = Invoke-Detection -DetectionConfig $Config.Detection
            if ($existingDetection.Detected) {
                Write-Log -Message "Application already installed: $($existingDetection.Detail)" -Level 'Info'

                # Check upgrade awareness
                if ($Config.Upgrade -and -not $Config.Upgrade.RemovePreviousVersion) {
                    Write-Log -Message "Application detected and RemovePreviousVersion is false. Reporting success." -Level 'Info'
                    $script:ExitCode = 0
                    Write-DeploymentSummary -Action 'Install' -ExitCode $script:ExitCode `
                        -DetectionResult 'Already Installed' -ValidationResult 'PASS'
                    exit $script:ExitCode
                }

                Write-Log -Message "Upgrade mode: proceeding with installation over existing version." -Level 'Info'
            }
        }
    }

    # Log upgrade context
    if ($Config.Upgrade) {
        Write-Log -Message "Upgrade config: RemovePreviousVersion=$($Config.Upgrade.RemovePreviousVersion), AllowDowngrade=$($Config.Upgrade.AllowDowngrade)" -Level 'Info'
        if ($Config.Upgrade.PreviousVersions -and $Config.Upgrade.PreviousVersions.Count -gt 0) {
            Write-Log -Message "Previous versions tracked: $($Config.Upgrade.PreviousVersions -join ', ')" -Level 'Info'
        }
    }

    # Set environment variables if configured
    if ($Config.Environment -and $Config.Environment.Variables) {
        foreach ($key in $Config.Environment.Variables.Keys) {
            $value = $Config.Environment.Variables[$key]
            Write-Log -Message "Setting environment variable: $key" -Level 'Debug'
            [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }

    # Stop configured processes and services
    $pm = $Config.ProcessManagement
    if ($pm -and $pm.Enabled) {
        if ($pm.Processes -and $pm.Processes.Count -gt 0) {
            Write-Log -Message "Stopping configured processes..." -Level 'Info'
            Stop-ConfiguredProcesses -ProcessNames $pm.Processes `
                -Force ([bool]$pm.ForceStop) `
                -TimeoutSeconds ($pm.GracefulStopTimeoutSeconds)
        }
        if ($pm.Services -and $pm.Services.Count -gt 0) {
            Write-Log -Message "Stopping configured services..." -Level 'Info'
            Stop-ConfiguredServices -ServiceNames $pm.Services
        }
    }

    # Build installer command
    $installerConfig = $Config.Installer
    $installerDir = $installerConfig.WorkingDirectory
    if (-not $installerDir) { $installerDir = 'Files' }

    $installerFile = Join-Path $PackagePath (Join-Path $installerDir $installerConfig.File)
    $installerType = if ($installerConfig.Type) { $installerConfig.Type } else { 'EXE' }
    $timeoutSeconds = if ($installerConfig.TimeoutSeconds) { $installerConfig.TimeoutSeconds } else { 3600 }

    Write-Log -Message "Installer type: $installerType" -Level 'Info'
    Write-Log -Message "Installer file: $installerFile" -Level 'Info'
    Write-Log -Message "Installer arguments: $($installerConfig.Arguments)" -Level 'Info'

    # Verify installer hash if configured
    if ($installerConfig.SHA256) {
        Write-Log -Message "Verifying installer integrity..." -Level 'Info'
        $actualHash = (Get-FileHash -Path $installerFile -Algorithm SHA256).Hash
        if ($actualHash -ne $installerConfig.SHA256) {
            $errorMsg = "Installer integrity validation failed. Expected SHA256: $($installerConfig.SHA256) | Actual: $actualHash"
            Write-Log -Message $errorMsg -Level 'Error'
            $script:ExitCode = 1
            Write-DeploymentSummary -Action 'Install' -ExitCode $script:ExitCode `
                -ValidationResult 'FAILED' -ErrorDetail $errorMsg
            exit $script:ExitCode
        }
        Write-Log -Message "Installer integrity verified (SHA256 match)." -Level 'Info'
    }

    # Execute installer
    $installExitCode = 0
    switch ($installerType.ToUpper()) {
        'MSI' {
            $msiArgs = @('/i', "`"$installerFile`"")
            if ($installerConfig.InstallArguments) {
                $msiArgs += $installerConfig.InstallArguments -split ' '
            }
            else {
                $msiArgs += @('/qn', '/norestart')
            }

            Write-Log -Message "Executing: msiexec.exe $($msiArgs -join ' ')" -Level 'Info'
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $installExitCode = $process.ExitCode
        }

        'MSIX' {
            Write-Log -Message "Executing MSIX: Add-AppxPackage -Path `"$installerFile`"" -Level 'Info'
            try {
                Add-AppxPackage -Path $installerFile -ErrorAction Stop
                $installExitCode = 0
            }
            catch {
                Write-Log -Message "MSIX installation failed: $_" -Level 'Error'
                $installExitCode = 1
            }
        }

        'PS1' {
            Write-Log -Message "Executing PowerShell installer: $installerFile" -Level 'Info'
            try {
                & $installerFile
                $installExitCode = $LASTEXITCODE
                if ($null -eq $installExitCode) { $installExitCode = 0 }
            }
            catch {
                Write-Log -Message "PowerShell installer failed: $_" -Level 'Error'
                $installExitCode = 1
            }
        }

        { $_ -in 'CMD', 'BAT' } {
            Write-Log -Message "Executing: cmd.exe /c `"$installerFile`" $($installerConfig.Arguments)" -Level 'Info'
            $process = Start-Process -FilePath 'cmd.exe' `
                -ArgumentList "/c `"$installerFile`" $($installerConfig.Arguments)" `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $installExitCode = $process.ExitCode
        }

        default {
            # EXE and other types
            $startParams = @{
                FilePath     = $installerFile
                Wait         = $true
                PassThru     = $true
                NoNewWindow  = $true
                ErrorAction  = 'Stop'
            }
            if ($installerConfig.Arguments) {
                $startParams.ArgumentList = $installerConfig.Arguments
            }

            Write-Log -Message "Executing: $installerFile $($installerConfig.Arguments)" -Level 'Info'
            $process = Start-Process @startParams
            $installExitCode = $process.ExitCode
        }
    }

    Write-Log -Message "Installer exit code: $installExitCode" -Level 'Info'

    # Evaluate exit code
    $returnCodes = $Config.ReturnCodes
    $isSuccess = $installExitCode -in $returnCodes.Success
    $isReboot  = $installExitCode -in $returnCodes.SuccessWithReboot

    if ($isReboot) {
        Write-Log -Message "Installation succeeded. Reboot required (exit code $installExitCode)." -Level 'Warning'
        $script:ExitCode = $installExitCode
    }
    elseif ($isSuccess) {
        Write-Log -Message "Installation succeeded." -Level 'Info'
        $script:ExitCode = 0
    }
    else {
        Write-Log -Message "Installation FAILED with exit code $installExitCode." -Level 'Error'
        $script:ExitCode = $installExitCode
        Write-DeploymentSummary -Action 'Install' -ExitCode $script:ExitCode `
            -DetectionResult 'N/A' -ValidationResult 'FAILED' `
            -ErrorDetail "Installer returned exit code $installExitCode"
        exit $script:ExitCode
    }

    # Post-install validation
    if (-not $Config.Testing.SkipValidation) {
        Write-Log -Message "Running post-install validation..." -Level 'Info'
        $postValidation = Test-PostInstallValidation -Configuration $Config -InstallerExitCode $installExitCode
        $validationResult = if ($postValidation.Passed) { 'PASS' } else { 'FAIL' }

        if (-not $postValidation.Passed) {
            Write-Log -Message "Post-install validation failed but installer reported success." -Level 'Warning'
        }
    }
    else {
        $validationResult = 'SKIPPED'
    }

    # Run detection
    $detectionResult = 'N/A'
    if ($Config.Detection -and -not $Config.Testing.SkipDetection) {
        Write-Log -Message "Running post-install detection..." -Level 'Info'
        $detection = Invoke-Detection -DetectionConfig $Config.Detection
        $detectionResult = if ($detection.Detected) { "Detected: $($detection.Detail)" } else { "NOT detected: $($detection.Detail)" }
        Write-Log -Message "Detection result: $detectionResult" -Level 'Info'
    }

    # Write deployment summary
    Write-DeploymentSummary -Action 'Install' -ExitCode $script:ExitCode `
        -DetectionResult $detectionResult -ValidationResult $validationResult

    exit $script:ExitCode
}
catch {
    $errorMessage = "Unhandled exception: $($_.Exception.Message)"

    try {
        Write-Log -Message $errorMessage -Level 'Error'
        Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level 'Error'
        Write-DeploymentSummary -Action 'Install' -ExitCode 1 `
            -ErrorDetail $errorMessage
    }
    catch {
        $fallbackLog = Join-Path $env:ProgramData "IntuneApp_Install_Error.log"
        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $errorMessage" | Out-File -FilePath $fallbackLog -Append
    }

    exit 1
}

# --- Helper Functions ---

function Stop-ConfiguredProcesses {
    [CmdletBinding()]
    param(
        [string[]]$ProcessNames,
        [bool]$Force = $false,
        [int]$TimeoutSeconds = 30
    )

    foreach ($procName in $ProcessNames) {
        $processes = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if (-not $processes) {
            Write-Log -Message "Process '$procName' not running." -Level 'Info'
            continue
        }

        Write-Log -Message "Requesting graceful close for process '$procName' ($($processes.Count) instance(s))..." -Level 'Info'
        foreach ($proc in $processes) {
            try {
                $proc.CloseMainWindow() | Out-Null
            }
            catch {
                Write-Log -Message "Failed to send close to $procName (PID $($proc.Id)): $_" -Level 'Warning'
            }
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $remaining = Get-Process -Name $procName -ErrorAction SilentlyContinue
            if (-not $remaining) { break }
            Start-Sleep -Milliseconds 500
        }

        $remaining = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($remaining -and $Force) {
            Write-Log -Message "Force-stopping process '$procName'..." -Level 'Warning'
            $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        elseif ($remaining) {
            Write-Log -Message "Process '$procName' still running after graceful timeout. Force not enabled." -Level 'Warning'
        }
        else {
            Write-Log -Message "Process '$procName' stopped successfully." -Level 'Info'
        }
    }
}

function Stop-ConfiguredServices {
    [CmdletBinding()]
    param([string[]]$ServiceNames)

    foreach ($svcName in $ServiceNames) {
        $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Log -Message "Service '$svcName' not found." -Level 'Info'
            continue
        }

        if ($service.Status -eq 'Stopped') {
            Write-Log -Message "Service '$svcName' already stopped." -Level 'Info'
            continue
        }

        Write-Log -Message "Stopping service '$svcName'..." -Level 'Info'
        try {
            Stop-Service -Name $svcName -Force -ErrorAction Stop
            Write-Log -Message "Service '$svcName' stopped." -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to stop service '$svcName': $_" -Level 'Warning'
        }
    }
}
