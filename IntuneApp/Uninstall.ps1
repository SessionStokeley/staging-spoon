#Requires -Version 5.1
<#
.SYNOPSIS
    Generic Intune Win32 application uninstaller.
.DESCRIPTION
    Configuration-driven uninstallation script supporting Executable, MSI,
    Registry-discovered, and Custom uninstall mechanisms.
    Designed to run as NT AUTHORITY\SYSTEM via the Intune Management Extension.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:ExitCode = 1

try {
    $PackagePath = $PSScriptRoot

    # Load framework modules
    . (Join-Path $PackagePath 'Logging.ps1')
    . (Join-Path $PackagePath 'Detection.ps1')
    . (Join-Path $PackagePath 'Validation.ps1')
    . (Join-Path $PackagePath 'Requirements.ps1')
    . (Join-Path $PackagePath 'Helpers.ps1')

    # Load configuration
    $configPath = Join-Path $PackagePath 'Configuration.psd1'
    if (-not (Test-Path $configPath)) {
        Write-Error "Configuration.psd1 not found at $configPath"
        exit 1
    }
    $Config = Import-PowerShellDataFile -Path $configPath

    # Resolve application metadata
    $appName    = $Config.Application.Name
    $appVersion = $Config.Application.Version

    # Initialize logging
    $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }
    $debugLogging  = [bool]$Config.Testing.EnableDebugLogging

    Initialize-Logging `
        -ApplicationName    $appName `
        -CompanyName        $Config.CompanyName `
        -ScriptName         'Uninstall' `
        -ApplicationVersion $appVersion `
        -LoggingConfig      $loggingConfig `
        -DebugLogging       $debugLogging

    Write-Log -Message "Package path: $PackagePath" -Level 'Info'

    # Validate execution context based on Privileges
    $allowNonSystem = [bool]$Config.Testing.AllowNonSystemExecution
    $privileges     = $Config.Privileges
    $requireSystem  = if ($privileges) { [bool]$privileges.InstallAsSystem } else { $true }

    if ($requireSystem -and -not (Test-SystemContext -AllowNonSystem $allowNonSystem)) {
        $script:ExitCode = 1
        Write-DeploymentSummary -Action 'Uninstall' -ExitCode $script:ExitCode -ErrorDetail 'Not running as SYSTEM'
        exit $script:ExitCode
    }

    # Check if application is present
    if (-not $Config.Testing.SkipDetection) {
        Write-Log -Message "Checking if application is installed..." -Level 'Info'
        if ($Config.Detection) {
            $detection = Invoke-Detection -DetectionConfig $Config.Detection
            if (-not $detection.Detected) {
                Write-Log -Message "Application not detected. Nothing to uninstall: $($detection.Detail)" -Level 'Info'
                $script:ExitCode = 0
                Write-DeploymentSummary -Action 'Uninstall' -ExitCode $script:ExitCode `
                    -DetectionResult 'Not Installed' -ValidationResult 'PASS'
                exit $script:ExitCode
            }
            Write-Log -Message "Application detected: $($detection.Detail)" -Level 'Info'
        }
    }

    # Stop configured processes and services
    if ($Config.ProcessesToStop -and $Config.ProcessesToStop.Count -gt 0) {
        Write-Log -Message "Stopping configured processes..." -Level 'Info'
        Stop-ConfiguredProcesses -ProcessNames $Config.ProcessesToStop
    }
    if ($Config.ServicesToStop -and $Config.ServicesToStop.Count -gt 0) {
        Write-Log -Message "Stopping configured services..." -Level 'Info'
        Stop-ConfiguredServices -ServiceNames $Config.ServicesToStop
    }

    # Execute uninstall
    $uninstallerConfig = $Config.Uninstaller
    $uninstallType     = if ($uninstallerConfig.Type) { $uninstallerConfig.Type } else { 'Executable' }
    $timeoutSeconds    = if ($uninstallerConfig.TimeoutSeconds) { $uninstallerConfig.TimeoutSeconds } else { 3600 }
    $uninstallExitCode = 0

    Write-Log -Message "Uninstall type: $uninstallType" -Level 'Info'

    switch ($uninstallType) {
        'MSI' {
            $productCode = $uninstallerConfig.ProductCode
            if (-not $productCode) {
                if ($Config.Detection.Type -eq 'MSI' -and $Config.Detection.ProductCode) {
                    $productCode = $Config.Detection.ProductCode
                }
            }
            if (-not $productCode) {
                throw "MSI uninstall requires ProductCode in Uninstaller or Detection configuration."
            }

            $msiArgs = @('/x', $productCode)
            if ($uninstallerConfig.Arguments) {
                $msiArgs += $uninstallerConfig.Arguments -split ' '
            }
            else {
                $msiArgs += @('/qn', '/norestart')
            }

            Write-Log -Message "Executing: msiexec.exe $($msiArgs -join ' ')" -Level 'Info'
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $uninstallExitCode = $process.ExitCode
        }

        'Registry' {
            $uninstallExitCode = Invoke-RegistryUninstall -Config $Config
        }

        'Custom' {
            $customCmd  = $uninstallerConfig.Command
            $customArgs = $uninstallerConfig.Arguments
            if (-not $customCmd) {
                throw "Custom uninstall requires Command in Uninstaller configuration."
            }

            Write-Log -Message "Executing custom: $customCmd $customArgs" -Level 'Info'
            $startParams = @{
                FilePath    = $customCmd
                Wait        = $true
                PassThru    = $true
                NoNewWindow = $true
                ErrorAction = 'Stop'
            }
            if ($customArgs) { $startParams.ArgumentList = $customArgs }

            $process = Start-Process @startParams
            $uninstallExitCode = $process.ExitCode
        }

        default {
            $uninstallFile = $uninstallerConfig.File
            $uninstallArgs = $uninstallerConfig.Arguments

            if (-not $uninstallFile) {
                throw "Executable uninstall requires File in Uninstaller configuration."
            }

            if (-not [System.IO.Path]::IsPathRooted($uninstallFile)) {
                $candidatePaths = @(
                    (Join-Path $PackagePath (Join-Path 'Files' $uninstallFile))
                    (Join-Path $PackagePath $uninstallFile)
                )
                $resolvedPath = $candidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($resolvedPath) {
                    $uninstallFile = $resolvedPath
                }
            }

            Write-Log -Message "Executing: $uninstallFile $uninstallArgs" -Level 'Info'
            $startParams = @{
                FilePath    = $uninstallFile
                Wait        = $true
                PassThru    = $true
                NoNewWindow = $true
                ErrorAction = 'Stop'
            }
            if ($uninstallArgs) { $startParams.ArgumentList = $uninstallArgs }

            $process = Start-Process @startParams
            $uninstallExitCode = $process.ExitCode
        }
    }

    Write-Log -Message "Uninstaller exit code: $uninstallExitCode" -Level 'Info'

    # Evaluate exit code
    $returnCodes = $Config.ReturnCodes
    $isSuccess = $uninstallExitCode -in $returnCodes.Success
    $isReboot  = $uninstallExitCode -in $returnCodes.SuccessWithReboot

    if ($isReboot) {
        Write-Log -Message "Uninstall succeeded. Reboot required (exit code $uninstallExitCode)." -Level 'Warning'
        $script:ExitCode = $uninstallExitCode
    }
    elseif ($isSuccess) {
        Write-Log -Message "Uninstall succeeded." -Level 'Info'
        $script:ExitCode = 0
    }
    else {
        Write-Log -Message "Uninstall FAILED with exit code $uninstallExitCode." -Level 'Error'
        $script:ExitCode = $uninstallExitCode
        Write-DeploymentSummary -Action 'Uninstall' -ExitCode $script:ExitCode `
            -ErrorDetail "Uninstaller returned exit code $uninstallExitCode"
        exit $script:ExitCode
    }

    # =====================================================================
    # POST-UNINSTALL CLEANUP
    # =====================================================================

    # Remove Machine PATH entries
    if ($Config.Environment -and $Config.Environment.AddToMachinePath -and $Config.Environment.AddToMachinePath.Count -gt 0) {
        Write-Log -Message "Removing Machine PATH entries..." -Level 'Info'
        Remove-PathEntries -Entries $Config.Environment.AddToMachinePath
    }

    # Remove persistent environment variables
    if ($Config.Environment -and $Config.Environment.Variables -and $Config.Environment.Variables.Count -gt 0) {
        Write-Log -Message "Removing persistent environment variables..." -Level 'Info'
        Remove-PersistentEnvironmentVariables -Variables $Config.Environment.Variables
    }

    # Remove framework-managed file associations
    $faConfig = $Config.FileAssociations
    if ($faConfig -and $faConfig.Mode -eq 'Framework' -and $faConfig.Associations -and $faConfig.Associations.Count -gt 0) {
        Write-Log -Message "Removing framework-managed file associations..." -Level 'Info'
        Remove-FileAssociations -Associations $faConfig.Associations -ApplicationName $appName
    }

    # Reverse registry additions (entries added during install are removed during uninstall)
    if ($Config.Registry -and $Config.Registry.Add -and $Config.Registry.Add.Count -gt 0) {
        Write-Log -Message "Removing registry entries added during install..." -Level 'Info'
        Remove-RegistryEntries -Entries $Config.Registry.Add
    }

    # Remove shortcuts created during install
    if ($Config.Shortcuts -and $Config.Shortcuts.Create -and $Config.Shortcuts.Create.Count -gt 0) {
        Write-Log -Message "Removing shortcuts..." -Level 'Info'
        Remove-ApplicationShortcuts -Shortcuts $Config.Shortcuts.Create
    }

    # Remove UserExperience shortcuts
    if ($Config.UserExperience -and ($Config.UserExperience.CreateStartMenuShortcut -or $Config.UserExperience.CreateDesktopShortcut)) {
        Write-Log -Message "Removing user experience shortcuts..." -Level 'Info'
        Remove-UserExperienceShortcuts -ApplicationName $appName
    }

    # Post-uninstall detection
    $detectionResult = 'N/A'
    if ($Config.Detection -and -not $Config.Testing.SkipDetection) {
        Write-Log -Message "Running post-uninstall detection..." -Level 'Info'
        Start-Sleep -Seconds 2
        $postDetection = Invoke-Detection -DetectionConfig $Config.Detection
        if ($postDetection.Detected) {
            $detectionResult = "Still detected: $($postDetection.Detail)"
            Write-Log -Message "WARNING: Application still detected after uninstall." -Level 'Warning'
        }
        else {
            $detectionResult = "Removed: $($postDetection.Detail)"
            Write-Log -Message "Application successfully removed." -Level 'Info'
        }
    }

    Write-DeploymentSummary -Action 'Uninstall' -ExitCode $script:ExitCode `
        -DetectionResult $detectionResult -ValidationResult 'PASS'

    exit $script:ExitCode
}
catch {
    $errorMessage = "Unhandled exception: $($_.Exception.Message)"

    try {
        Write-Log -Message $errorMessage -Level 'Error'
        Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level 'Error'
        Write-DeploymentSummary -Action 'Uninstall' -ExitCode 1 `
            -ErrorDetail $errorMessage
    }
    catch {
        $fallbackLog = Join-Path $env:ProgramData "IntuneApp_Uninstall_Error.log"
        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $errorMessage" | Out-File -FilePath $fallbackLog -Append
    }

    exit 1
}

# --- Uninstall-specific Helper ---

function Invoke-RegistryUninstall {
    [CmdletBinding()]
    param([hashtable]$Config)

    $displayName = $Config.Uninstaller.DisplayName
    if (-not $displayName) { $displayName = $Config.Application.Name }

    $searchPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entry = $null
    foreach ($path in $searchPaths) {
        $entry = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$displayName*" } |
            Select-Object -First 1
        if ($entry) { break }
    }

    if (-not $entry) {
        Write-Log -Message "No registry uninstall entry found for '$displayName'." -Level 'Warning'
        return 0
    }

    $uninstallString = $entry.QuietUninstallString
    if (-not $uninstallString) {
        $uninstallString = $entry.UninstallString
    }

    if (-not $uninstallString) {
        Write-Log -Message "No UninstallString found in registry for '$displayName'." -Level 'Error'
        return 1
    }

    Write-Log -Message "Found registry uninstall entry: $($entry.DisplayName) $($entry.DisplayVersion)" -Level 'Info'
    Write-Log -Message "Uninstall string: $uninstallString" -Level 'Info'

    $uninstallString = $uninstallString.Trim('"')

    if ($uninstallString -match 'msiexec' -or $uninstallString -match '/[Ii]') {
        $guidMatch = [regex]::Match($uninstallString, '\{[0-9A-Fa-f\-]+\}')
        if ($guidMatch.Success) {
            $msiArgs = @('/x', $guidMatch.Value, '/qn', '/norestart')
            Write-Log -Message "Executing: msiexec.exe $($msiArgs -join ' ')" -Level 'Info'
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            return $process.ExitCode
        }
    }

    $silentFlags = $Config.Uninstaller.Arguments
    if (-not $silentFlags) { $silentFlags = '/quiet /norestart' }

    if ($uninstallString -match '^"?(.+\.exe)"?\s*(.*)$') {
        $exePath      = $Matches[1]
        $existingArgs = $Matches[2]
        $allArgs      = "$existingArgs $silentFlags".Trim()

        Write-Log -Message "Executing: $exePath $allArgs" -Level 'Info'
        $process = Start-Process -FilePath $exePath -ArgumentList $allArgs `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop
        return $process.ExitCode
    }

    Write-Log -Message "Unable to parse uninstall string: $uninstallString" -Level 'Error'
    return 1
}
