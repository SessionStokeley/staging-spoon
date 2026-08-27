#Requires -Version 5.1
<#
.SYNOPSIS
    Local testing framework for the Intune Win32 deployment package.
.DESCRIPTION
    Tests package validity, detection, requirements, and optionally performs
    live installation/uninstallation using the same engine as Install.ps1
    and Uninstall.ps1. Never modifies Configuration.psd1.

.PARAMETER Diagnostics
    Runs all non-destructive diagnostics: package validation, configuration
    schema, detection status, requirements, identity context, and installer
    file verification.

.PARAMETER ListInstallers
    Lists all files in the Files\ directory and shows which one is configured.

.PARAMETER Install
    Performs a live installation using the shared Invoke-Installation engine.
    Requires elevation. Prompts for confirmation unless -Force is specified.

.PARAMETER Uninstall
    Performs a live uninstallation using the shared Invoke-Uninstallation engine.
    Requires elevation. Prompts for confirmation unless -Force is specified.

.PARAMETER FullCycle
    Runs the full lifecycle: Install -> Detect -> Validate -> Uninstall -> Detect.
    Requires elevation. Prompts for confirmation unless -Force is specified.

.PARAMETER Force
    Bypasses confirmation prompts for Install, Uninstall, and FullCycle.

.PARAMETER RollbackOnFailure
    If installation fails, attempts to uninstall/rollback to the pre-install state.

.EXAMPLE
    .\Test-Local.ps1 -Diagnostics
    .\Test-Local.ps1 -ListInstallers
    .\Test-Local.ps1 -Install -Force
    .\Test-Local.ps1 -FullCycle -Force -RollbackOnFailure
#>

[CmdletBinding(DefaultParameterSetName = 'Diagnostics')]
param(
    [Parameter(ParameterSetName = 'Diagnostics')]
    [switch]$Diagnostics,

    [Parameter(ParameterSetName = 'ListInstallers')]
    [switch]$ListInstallers,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'FullCycle')]
    [switch]$FullCycle,

    [switch]$Force,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'FullCycle')]
    [switch]$RollbackOnFailure
)

$ErrorActionPreference = 'Stop'
$PackagePath = $PSScriptRoot
$script:Results = @()
$script:OverallSuccess = $true

# --- Output Helpers ---

function Write-Section {
    param([string]$Name)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Name" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-TestResult {
    param(
        [string]$Name,
        [ValidateSet('PASS','FAIL','INFO','WARN')]
        [string]$Status,
        [string]$Detail = ''
    )
    $color = switch ($Status) {
        'PASS' { 'Green'  }
        'FAIL' { 'Red'    }
        'INFO' { 'Cyan'   }
        'WARN' { 'Yellow' }
    }
    Write-Host "  [$Status] $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
    $script:Results += [PSCustomObject]@{ Test = $Name; Status = $Status; Detail = $Detail }
    if ($Status -eq 'FAIL') { $script:OverallSuccess = $false }
}

# --- Load Configuration ---

$configPath = Join-Path $PackagePath 'Configuration.psd1'
$Config = $null

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: Configuration.psd1 not found at $configPath" -ForegroundColor Red
    exit 1
}

try {
    $Config = Import-PowerShellDataFile -Path $configPath
}
catch {
    Write-Host "ERROR: Failed to parse Configuration.psd1: $_" -ForegroundColor Red
    exit 1
}

# --- Load Framework Modules ---

. (Join-Path $PackagePath 'Logging.ps1')
. (Join-Path $PackagePath 'Detection.ps1')
. (Join-Path $PackagePath 'Validation.ps1')
. (Join-Path $PackagePath 'Requirements.ps1')
. (Join-Path $PackagePath 'Helpers.ps1')

# --- Detect Identity ---

$isSystem  = Test-IsSystem
$isElevated = Test-IsElevated
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()

# --- Header ---

Write-Host ""
Write-Host "Intune Win32 Deployment Framework - Local Test Runner" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Yellow
Write-Host "  Package    : $PackagePath"
Write-Host "  App Name   : $($Config.Application.Name)"
Write-Host "  App Version: $($Config.Application.Version)"
Write-Host "  Identity   : $($identity.Name)"
Write-Host "  Is SYSTEM  : $isSystem"
Write-Host "  Is Elevated: $isElevated"
Write-Host "  Mode       : $($PSCmdlet.ParameterSetName)"
Write-Host ("=" * 70) -ForegroundColor Yellow

# =========================================================================
# LIST INSTALLERS MODE
# =========================================================================
if ($ListInstallers) {
    Write-Section "Available Installer Files"

    $filesDir = Join-Path $PackagePath 'Files'
    $configuredFile = $Config.Installer.File

    Write-Host ""
    Write-Host "  Configured installer: $configuredFile" -ForegroundColor White
    Write-Host "  Expected path: $(Join-Path $filesDir $configuredFile)" -ForegroundColor White
    Write-Host ""

    if (Test-Path $filesDir) {
        $files = Get-ChildItem -Path $filesDir -File -Recurse
        if ($files.Count -eq 0) {
            Write-Host "  Files\ directory is empty." -ForegroundColor Yellow
        }
        else {
            Write-Host "  Files in package:" -ForegroundColor White
            foreach ($f in $files) {
                $relativePath = $f.FullName.Substring($filesDir.Length + 1)
                $sizeStr = if ($f.Length -ge 1MB) {
                    "$([math]::Round($f.Length / 1MB, 2)) MB"
                } else {
                    "$([math]::Round($f.Length / 1KB, 2)) KB"
                }
                $marker = if ($relativePath -eq $configuredFile) { ' <-- CONFIGURED' } else { '' }
                Write-Host "    $relativePath ($sizeStr)$marker" -ForegroundColor $(if ($marker) { 'Green' } else { 'Gray' })
            }
        }
    }
    else {
        Write-Host "  Files\ directory does not exist." -ForegroundColor Red
    }

    Write-Host ""
    exit 0
}

# =========================================================================
# DIAGNOSTICS MODE (also the default when no switches are provided)
# =========================================================================
if ($Diagnostics -or $PSCmdlet.ParameterSetName -eq 'Diagnostics') {

    # Initialize logging for diagnostics
    $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }
    Initialize-Logging `
        -ApplicationName    $Config.Application.Name `
        -CompanyName        $Config.CompanyName `
        -ScriptName         'Test-Local' `
        -ApplicationVersion $Config.Application.Version `
        -LoggingConfig      $loggingConfig `
        -DebugLogging       $true

    # --- Identity Context ---
    Write-Section "Identity Context"

    if ($isSystem) {
        Write-TestResult -Name "Execution context" -Status 'PASS' `
            -Detail "Running as NT AUTHORITY\SYSTEM"
    }
    else {
        Write-TestResult -Name "Execution context" -Status 'INFO' `
            -Detail "Running as $($identity.Name) (not SYSTEM - expected for local testing)"
    }

    if ($isElevated) {
        Write-TestResult -Name "Elevation" -Status 'PASS' -Detail "Running elevated (Administrator)"
    }
    else {
        Write-TestResult -Name "Elevation" -Status 'INFO' `
            -Detail "Not elevated - installation tests require elevation"
    }

    $requireSystem = if ($Config.Privileges) { [bool]$Config.Privileges.InstallAsSystem } else { $true }
    Write-TestResult -Name "Privileges.InstallAsSystem" -Status 'INFO' `
        -Detail "Production requires SYSTEM: $requireSystem"

    $allowNonSystem = [bool]$Config.Testing.AllowNonSystemExecution
    Write-TestResult -Name "Testing.AllowNonSystemExecution" -Status 'INFO' `
        -Detail "Non-SYSTEM testing allowed: $allowNonSystem"

    # --- Package Files ---
    Write-Section "Package Validation"

    $requiredFiles = @(
        'Configuration.psd1', 'Install.ps1', 'Uninstall.ps1', 'Detection.ps1',
        'Validation.ps1', 'Logging.ps1', 'Requirements.ps1', 'Helpers.ps1'
    )

    foreach ($file in $requiredFiles) {
        $filePath = Join-Path $PackagePath $file
        if (Test-Path $filePath) {
            Write-TestResult -Name "File: $file" -Status 'PASS'
        }
        else {
            Write-TestResult -Name "File: $file" -Status 'FAIL' -Detail "Missing: $filePath"
        }
    }

    # Config structure
    Write-TestResult -Name "Application.Name" `
        -Status $(if ($Config.Application.Name) { 'PASS' } else { 'FAIL' }) `
        -Detail $Config.Application.Name

    Write-TestResult -Name "CompanyName" `
        -Status $(if ($Config.CompanyName) { 'PASS' } else { 'FAIL' }) `
        -Detail $Config.CompanyName

    Write-TestResult -Name "Installer section" `
        -Status $(if ($Config.Installer) { 'PASS' } else { 'FAIL' }) `
        -Detail $(if ($Config.Installer) { "Type: $($Config.Installer.Type)" } else { 'Missing' })

    Write-TestResult -Name "Detection section" `
        -Status $(if ($Config.Detection) { 'PASS' } else { 'FAIL' }) `
        -Detail $(if ($Config.Detection) { "Type: $($Config.Detection.Type)" } else { 'Missing' })

    Write-TestResult -Name "Privileges section" `
        -Status $(if ($Config.Privileges) { 'PASS' } else { 'WARN' }) `
        -Detail $(if ($Config.Privileges) { "InstallAsSystem=$($Config.Privileges.InstallAsSystem)" } else { 'Missing (defaults to InstallAsSystem=$true)' })

    # --- Installer File ---
    Write-Section "Installer File"

    if ($Config.Installer -and $Config.Installer.File) {
        $installerPath = Join-Path $PackagePath (Join-Path 'Files' $Config.Installer.File)

        if (Test-Path $installerPath) {
            $fileInfo = Get-Item $installerPath
            $sizeStr = "$([math]::Round($fileInfo.Length / 1MB, 2)) MB"
            Write-TestResult -Name "Installer file exists" -Status 'PASS' `
                -Detail "$($Config.Installer.File) ($sizeStr)"

            # SHA256 verification
            if ($Config.Installer.SHA256) {
                $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
                if ($actualHash -eq $Config.Installer.SHA256) {
                    Write-TestResult -Name "SHA256 integrity" -Status 'PASS' -Detail "Hash verified"
                }
                else {
                    Write-TestResult -Name "SHA256 integrity" -Status 'FAIL' `
                        -Detail "Expected: $($Config.Installer.SHA256) | Actual: $actualHash"
                }
            }
            else {
                Write-TestResult -Name "SHA256 integrity" -Status 'INFO' -Detail "No hash configured"
            }
        }
        else {
            Write-TestResult -Name "Installer file exists" -Status 'FAIL' `
                -Detail "Configured: $($Config.Installer.File) | Path: $installerPath"

            # Show available files
            $filesDir = Join-Path $PackagePath 'Files'
            if (Test-Path $filesDir) {
                $available = Get-ChildItem -Path $filesDir -File | Select-Object -ExpandProperty Name
                if ($available.Count -gt 0) {
                    Write-TestResult -Name "Available files in Files\" -Status 'INFO' `
                        -Detail ($available -join ', ')
                }
                else {
                    Write-TestResult -Name "Files\ directory" -Status 'INFO' -Detail "Empty"
                }
            }
            else {
                Write-TestResult -Name "Files\ directory" -Status 'WARN' -Detail "Directory does not exist"
            }
        }
    }
    else {
        Write-TestResult -Name "Installer file" -Status 'FAIL' -Detail "Installer.File not configured"
    }

    # --- Requirements ---
    Write-Section "Requirements"

    if ($Config.Requirements) {
        $reqResult = Test-Requirements -Configuration $Config
        Write-TestResult -Name "Requirements validation" `
            -Status $(if ($reqResult) { 'PASS' } else { 'FAIL' }) `
            -Detail $(if ($reqResult) { "All requirements met" } else { "Some requirements not met" })
    }
    else {
        Write-TestResult -Name "Requirements" -Status 'PASS' -Detail "No requirements configured"
    }

    # --- Detection ---
    Write-Section "Detection"

    if ($Config.Detection) {
        Write-TestResult -Name "Detection type" -Status 'INFO' `
            -Detail "$($Config.Detection.Type)"

        if ($Config.Detection.Type -eq 'File' -and $Config.Detection.Path) {
            $detPath = if ($Config.Detection.FileName) {
                Join-Path $Config.Detection.Path $Config.Detection.FileName
            } else { $Config.Detection.Path }
            Write-TestResult -Name "Detection target" -Status 'INFO' -Detail $detPath
        }

        $detResult = Invoke-Detection -DetectionConfig $Config.Detection
        if ($detResult.Detected) {
            Write-TestResult -Name "Application detected" -Status 'PASS' `
                -Detail $detResult.Detail
        }
        else {
            Write-TestResult -Name "Application detected" -Status 'INFO' `
                -Detail "Application not installed: $($detResult.Detail)"
        }
    }
    else {
        Write-TestResult -Name "Detection" -Status 'FAIL' -Detail "No detection configuration"
    }

    # --- Pre-Install Validation ---
    Write-Section "Pre-Install Validation"

    $testConfig = $Config.Clone()
    if (-not $testConfig.Testing) { $testConfig.Testing = @{} }
    $testConfig.Testing.AllowNonSystemExecution = $true

    $preVal = Test-PreInstallValidation -Configuration $testConfig -PackagePath $PackagePath
    if ($preVal.Passed) {
        Write-TestResult -Name "Pre-install validation" -Status 'PASS' -Detail "All checks passed"
    }
    else {
        foreach ($failure in $preVal.Failures) {
            Write-TestResult -Name "Pre-install validation" -Status 'FAIL' -Detail $failure
        }
    }

    # --- Logging ---
    Write-Section "Logging"

    try {
        $logDir = Get-LogDirectory
        $logFile = Get-LogFilePath
        Write-TestResult -Name "Log directory" -Status 'PASS' -Detail $logDir
        Write-TestResult -Name "Log file" -Status 'PASS' -Detail $logFile
    }
    catch {
        Write-TestResult -Name "Logging" -Status 'FAIL' -Detail $_.Exception.Message
    }

    # --- Return Codes ---
    Write-Section "Return Code Configuration"

    if ($Config.ReturnCodes) {
        Write-TestResult -Name "Success codes" -Status 'INFO' `
            -Detail ($Config.ReturnCodes.Success -join ', ')
        Write-TestResult -Name "Reboot codes" -Status 'INFO' `
            -Detail ($Config.ReturnCodes.SuccessWithReboot -join ', ')

        $testExit = Get-ExitCodeResult -ExitCode 0 -ReturnCodes $Config.ReturnCodes
        Write-TestResult -Name "Exit code 0 evaluation" `
            -Status $(if ($testExit.Success) { 'PASS' } else { 'WARN' }) `
            -Detail $testExit.Description

        $testReboot = Get-ExitCodeResult -ExitCode 3010 -ReturnCodes $Config.ReturnCodes
        Write-TestResult -Name "Exit code 3010 evaluation" `
            -Status $(if ($testReboot.Success) { 'PASS' } else { 'WARN' }) `
            -Detail "$($testReboot.Description) (RebootRequired: $($testReboot.RebootRequired))"
    }
    else {
        Write-TestResult -Name "ReturnCodes" -Status 'WARN' -Detail "Not configured"
    }
}

# =========================================================================
# INSTALL MODE
# =========================================================================
if ($Install -or $FullCycle) {
    Write-Section "Installation"

    # Require elevation
    if (-not $isElevated) {
        Write-TestResult -Name "Elevation check" -Status 'FAIL' `
            -Detail "Installation requires elevation. Run as Administrator."
        Write-Host ""
        Write-Host "  TIP: Right-click PowerShell -> Run as Administrator" -ForegroundColor Cyan
        Write-Host "  For SYSTEM: PsExec.exe -s -i powershell.exe -ExecutionPolicy Bypass -File `"$PackagePath\Test-Local.ps1`" -Install" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }

    # Initialize logging
    $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }
    Initialize-Logging `
        -ApplicationName    $Config.Application.Name `
        -CompanyName        $Config.CompanyName `
        -ScriptName         'Test-Local-Install' `
        -ApplicationVersion $Config.Application.Version `
        -LoggingConfig      $loggingConfig `
        -DebugLogging       $true

    # Pre-install summary
    $installerPath = Join-Path $PackagePath (Join-Path 'Files' $Config.Installer.File)
    $installerType = if ($Config.Installer.Type) { $Config.Installer.Type } else { 'EXE' }

    Write-Host ""
    Write-Host "  Installation Summary:" -ForegroundColor White
    Write-Host "    Application  : $($Config.Application.Name) $($Config.Application.Version)" -ForegroundColor Gray
    Write-Host "    Installer    : $($Config.Installer.File)" -ForegroundColor Gray
    Write-Host "    Type         : $installerType" -ForegroundColor Gray
    Write-Host "    Arguments    : $($Config.Installer.Arguments)" -ForegroundColor Gray
    Write-Host "    Identity     : $($identity.Name)" -ForegroundColor Gray
    Write-Host "    Elevated     : $isElevated" -ForegroundColor Gray
    Write-Host "    SYSTEM       : $isSystem" -ForegroundColor Gray
    Write-Host ""

    # Confirmation prompt
    $proceedInstall = $Force
    if (-not $Force) {
        Write-Host "  This will execute the installer on this machine." -ForegroundColor Yellow
        Write-Host "  Proceed? (Y/N): " -ForegroundColor Yellow -NoNewline
        $confirm = Read-Host
        if ($confirm -eq 'Y') {
            $proceedInstall = $true
        }
        else {
            Write-TestResult -Name "Installation" -Status 'INFO' -Detail "Cancelled by user"
        }
    }

    if ($proceedInstall) {
        # Validate installer file exists
        if (-not (Test-Path $installerPath)) {
            Write-TestResult -Name "Installer file" -Status 'FAIL' `
                -Detail "Not found: $installerPath"

            $filesDir = Join-Path $PackagePath 'Files'
            if (Test-Path $filesDir) {
                $available = Get-ChildItem -Path $filesDir -File | Select-Object -ExpandProperty Name
                if ($available.Count -gt 0) {
                    Write-TestResult -Name "Available files" -Status 'INFO' -Detail ($available -join ', ')
                }
            }
            $proceedInstall = $false
        }
    }

    if ($proceedInstall -and $Config.Installer.SHA256) {
        $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
        if ($actualHash -ne $Config.Installer.SHA256) {
            Write-TestResult -Name "SHA256 integrity" -Status 'FAIL' `
                -Detail "Expected: $($Config.Installer.SHA256) | Actual: $actualHash"
            $proceedInstall = $false
        }
        else {
            Write-TestResult -Name "SHA256 integrity" -Status 'PASS' -Detail "Hash verified"
        }
    }

    if ($proceedInstall) {
        # Pre-install detection state
        if ($Config.Detection) {
            $preDetection = Invoke-Detection -DetectionConfig $Config.Detection
            Write-TestResult -Name "Pre-install detection" -Status 'INFO' `
                -Detail $(if ($preDetection.Detected) { "Already installed: $($preDetection.Detail)" } else { "Not installed: $($preDetection.Detail)" })
        }

        # Stop configured processes
        if ($Config.ProcessesToStop -and $Config.ProcessesToStop.Count -gt 0) {
            Write-TestResult -Name "Stopping processes" -Status 'INFO' `
                -Detail ($Config.ProcessesToStop -join ', ')
            Stop-ConfiguredProcesses -ProcessNames $Config.ProcessesToStop
        }
        if ($Config.ServicesToStop -and $Config.ServicesToStop.Count -gt 0) {
            Write-TestResult -Name "Stopping services" -Status 'INFO' `
                -Detail ($Config.ServicesToStop -join ', ')
            Stop-ConfiguredServices -ServiceNames $Config.ServicesToStop
        }

        # Execute installation via shared engine
        Write-Host ""
        Write-Host "  Executing installer..." -ForegroundColor White
        $installStart = Get-Date

        try {
            $installExitCode = Invoke-Installation -InstallerConfig $Config.Installer -PackagePath $PackagePath
            $installEnd = Get-Date
            $installDuration = $installEnd - $installStart

            Write-Host ""
            Write-TestResult -Name "Installer exit code" -Status 'INFO' -Detail "$installExitCode"
            Write-TestResult -Name "Installer duration" -Status 'INFO' `
                -Detail "$([math]::Round($installDuration.TotalSeconds, 1)) seconds"

            # Evaluate exit code
            $exitResult = Get-ExitCodeResult -ExitCode $installExitCode -ReturnCodes $Config.ReturnCodes

            if ($exitResult.RebootRequired) {
                Write-TestResult -Name "Installation result" -Status 'PASS' `
                    -Detail "Success - REBOOT REQUIRED (exit code $installExitCode)"
            }
            elseif ($exitResult.Success) {
                Write-TestResult -Name "Installation result" -Status 'PASS' `
                    -Detail "Success (exit code $installExitCode)"
            }
            else {
                Write-TestResult -Name "Installation result" -Status 'FAIL' `
                    -Detail "Failed with exit code $installExitCode"

                if ($RollbackOnFailure -and $Config.Uninstaller) {
                    Write-Host ""
                    Write-Host "  Attempting rollback..." -ForegroundColor Yellow
                    try {
                        $rollbackCode = Invoke-Uninstallation -Config $Config -PackagePath $PackagePath
                        $rollbackResult = Get-ExitCodeResult -ExitCode $rollbackCode -ReturnCodes $Config.ReturnCodes
                        Write-TestResult -Name "Rollback" `
                            -Status $(if ($rollbackResult.Success) { 'PASS' } else { 'WARN' }) `
                            -Detail "Uninstaller exit code: $rollbackCode"
                    }
                    catch {
                        Write-TestResult -Name "Rollback" -Status 'FAIL' -Detail $_.Exception.Message
                    }
                }
            }

            # Post-install detection
            if ($exitResult.Success -and $Config.Detection) {
                Write-Host ""
                Start-Sleep -Seconds 2
                $postDetection = Invoke-Detection -DetectionConfig $Config.Detection
                if ($postDetection.Detected) {
                    Write-TestResult -Name "Post-install detection" -Status 'PASS' `
                        -Detail $postDetection.Detail
                }
                else {
                    Write-TestResult -Name "Post-install detection" -Status 'WARN' `
                        -Detail "Not detected after install: $($postDetection.Detail)"
                }

                # Post-install validation
                if ($Config.PostInstall.Validate) {
                    $postVal = Test-PostInstallValidation -Configuration $Config -InstallerExitCode $installExitCode
                    Write-TestResult -Name "Post-install validation" `
                        -Status $(if ($postVal.Passed) { 'PASS' } else { 'WARN' }) `
                        -Detail $(if ($postVal.Passed) { "All checks passed" } else { $postVal.Failures -join '; ' })
                }

                # Version check
                if ($Config.Application.Version -and $postDetection.Detail -match 'Version:\s*([\d.]+)') {
                    $detectedVersion = $Matches[1]
                    Write-TestResult -Name "Version verification" -Status 'INFO' `
                        -Detail "Configured: $($Config.Application.Version) | Detected: $detectedVersion"
                }
            }
        }
        catch {
            Write-TestResult -Name "Installation" -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
}

# =========================================================================
# UNINSTALL MODE
# =========================================================================
if ($Uninstall -or ($FullCycle -and $script:OverallSuccess)) {
    Write-Section "Uninstallation"

    # Require elevation
    $proceedUninstall = $true
    if (-not $isElevated) {
        Write-TestResult -Name "Elevation check" -Status 'FAIL' `
            -Detail "Uninstallation requires elevation. Run as Administrator."
        $proceedUninstall = $false
    }

    if ($proceedUninstall) {
        # Initialize logging if not already done
        if (-not $script:LogState -or -not $script:LogState.Initialized) {
            $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }
            Initialize-Logging `
                -ApplicationName    $Config.Application.Name `
                -CompanyName        $Config.CompanyName `
                -ScriptName         'Test-Local-Uninstall' `
                -ApplicationVersion $Config.Application.Version `
                -LoggingConfig      $loggingConfig `
                -DebugLogging       $true
        }

        # Pre-uninstall detection
        if ($Config.Detection) {
            $preUninstallDetection = Invoke-Detection -DetectionConfig $Config.Detection
            if ($preUninstallDetection.Detected) {
                Write-TestResult -Name "Pre-uninstall detection" -Status 'INFO' `
                    -Detail "Application installed: $($preUninstallDetection.Detail)"
            }
            else {
                Write-TestResult -Name "Pre-uninstall detection" -Status 'INFO' `
                    -Detail "Application not installed: $($preUninstallDetection.Detail)"
            }
        }

        # Confirmation prompt (skip in FullCycle since already confirmed)
        if (-not $Force -and -not $FullCycle) {
            Write-Host ""
            Write-Host "  This will execute the uninstaller on this machine." -ForegroundColor Yellow
            Write-Host "  Proceed? (Y/N): " -ForegroundColor Yellow -NoNewline
            $confirm = Read-Host
            if ($confirm -ne 'Y') { $proceedUninstall = $false }
        }
    }

    if ($proceedUninstall) {
        # Stop configured processes
        if ($Config.ProcessesToStop -and $Config.ProcessesToStop.Count -gt 0) {
            Stop-ConfiguredProcesses -ProcessNames $Config.ProcessesToStop
        }
        if ($Config.ServicesToStop -and $Config.ServicesToStop.Count -gt 0) {
            Stop-ConfiguredServices -ServiceNames $Config.ServicesToStop
        }

        Write-Host ""
        Write-Host "  Executing uninstaller..." -ForegroundColor White
        $uninstallStart = Get-Date

        try {
            $uninstallExitCode = Invoke-Uninstallation -Config $Config -PackagePath $PackagePath
            $uninstallEnd = Get-Date
            $uninstallDuration = $uninstallEnd - $uninstallStart

            Write-Host ""
            Write-TestResult -Name "Uninstaller exit code" -Status 'INFO' -Detail "$uninstallExitCode"
            Write-TestResult -Name "Uninstaller duration" -Status 'INFO' `
                -Detail "$([math]::Round($uninstallDuration.TotalSeconds, 1)) seconds"

            $exitResult = Get-ExitCodeResult -ExitCode $uninstallExitCode -ReturnCodes $Config.ReturnCodes

            if ($exitResult.RebootRequired) {
                Write-TestResult -Name "Uninstallation result" -Status 'PASS' `
                    -Detail "Success - REBOOT REQUIRED (exit code $uninstallExitCode)"
            }
            elseif ($exitResult.Success) {
                Write-TestResult -Name "Uninstallation result" -Status 'PASS' `
                    -Detail "Success (exit code $uninstallExitCode)"
            }
            else {
                Write-TestResult -Name "Uninstallation result" -Status 'FAIL' `
                    -Detail "Failed with exit code $uninstallExitCode"
            }

            # Post-uninstall detection
            if ($exitResult.Success -and $Config.Detection) {
                Start-Sleep -Seconds 2
                $postUninstallDetection = Invoke-Detection -DetectionConfig $Config.Detection
                if ($postUninstallDetection.Detected) {
                    Write-TestResult -Name "Post-uninstall detection" -Status 'WARN' `
                        -Detail "Still detected: $($postUninstallDetection.Detail)"
                }
                else {
                    Write-TestResult -Name "Post-uninstall detection" -Status 'PASS' `
                        -Detail "Application removed: $($postUninstallDetection.Detail)"
                }
            }
        }
        catch {
            Write-TestResult -Name "Uninstallation" -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
    else {
        Write-TestResult -Name "Uninstallation" -Status 'INFO' -Detail "Cancelled by user"
    }
}

# =========================================================================
# SUMMARY
# =========================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Yellow
Write-Host "  TEST SUMMARY" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Yellow

$passed = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$info   = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count
$warned = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$total  = $script:Results.Count

Write-Host ""
Write-Host "  Total: $total | Passed: $passed | Failed: $failed | Warnings: $warned | Info: $info" `
    -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "  Failed Tests:" -ForegroundColor Red
    $script:Results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
        Write-Host "    - $($_.Test): $($_.Detail)" -ForegroundColor Red
    }
    Write-Host ""
}

if ($warned -gt 0) {
    Write-Host "  Warnings:" -ForegroundColor Yellow
    $script:Results | Where-Object { $_.Status -eq 'WARN' } | ForEach-Object {
        Write-Host "    - $($_.Test): $($_.Detail)" -ForegroundColor Yellow
    }
    Write-Host ""
}

if (-not $isSystem -and -not $Install -and -not $Uninstall -and -not $FullCycle) {
    Write-Host "  TIP: For SYSTEM-context testing, run:" -ForegroundColor Cyan
    Write-Host "    PsExec.exe -s -i powershell.exe -ExecutionPolicy Bypass -File `"$PackagePath\Test-Local.ps1`" -Diagnostics" -ForegroundColor Gray
    Write-Host ""
}

exit $failed
