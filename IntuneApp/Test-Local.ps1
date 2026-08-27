#Requires -Version 5.1
<#
.SYNOPSIS
    Local testing framework for the Intune Win32 deployment package.
.DESCRIPTION
    Simulates the Intune execution environment for local validation.
    Supports testing installation, detection, uninstallation, requirements,
    validation, and logging without deploying through Intune.

.PARAMETER Test
    The test to run. Valid values:
    All, Install, Uninstall, Detection, Requirements, Validation, Logging, Package

.PARAMETER EnableTestMode
    Temporarily enables Testing.AllowNonSystemExecution so scripts
    run under the current user context instead of requiring SYSTEM.

.EXAMPLE
    .\Test-Local.ps1 -Test All -EnableTestMode
    .\Test-Local.ps1 -Test Detection
    .\Test-Local.ps1 -Test Install -EnableTestMode
#>

[CmdletBinding()]
param(
    [ValidateSet('All','Install','Uninstall','Detection','Requirements','Validation','Logging','Package')]
    [string]$Test = 'All',

    [switch]$EnableTestMode
)

$ErrorActionPreference = 'Stop'
$PackagePath = $PSScriptRoot
$Results = @()

function Write-TestHeader {
    param([string]$Name)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  TEST: $Name" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $color = if ($Passed) { 'Green' } else { 'Red' }
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host "  [$status] $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
    $script:Results += [PSCustomObject]@{ Test = $Name; Passed = $Passed; Detail = $Detail }
}

# Detect execution context
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $identity.Name -eq 'NT AUTHORITY\SYSTEM'
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ""
Write-Host "Intune Win32 Deployment Framework - Local Test Runner" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Yellow
Write-Host "  Package Path : $PackagePath"
Write-Host "  Identity     : $($identity.Name)"
Write-Host "  Is SYSTEM    : $isSystem"
Write-Host "  Is Admin     : $isAdmin"
Write-Host "  Test Mode    : $EnableTestMode"
Write-Host "  Test         : $Test"
Write-Host ("=" * 70) -ForegroundColor Yellow

# Load configuration
$configPath = Join-Path $PackagePath 'Configuration.psd1'
$Config = $null
if (Test-Path $configPath) {
    try {
        $Config = Import-PowerShellDataFile -Path $configPath
        Write-Host "  App Name     : $($Config.Application.Name)" -ForegroundColor Green
        Write-Host "  App Version  : $($Config.Application.Version)" -ForegroundColor Green
        Write-Host "  Privileges   : InstallAsSystem=$($Config.Privileges.InstallAsSystem)" -ForegroundColor Green
    }
    catch {
        Write-Host "  ERROR: Failed to load Configuration.psd1: $_" -ForegroundColor Red
    }
}

# =========================================================================
# PACKAGE VALIDATION TEST
# =========================================================================
if ($Test -in 'All', 'Package') {
    Write-TestHeader "Package Validation"

    $requiredFiles = @(
        'Configuration.psd1'
        'Install.ps1'
        'Uninstall.ps1'
        'Detection.ps1'
        'Validation.ps1'
        'Logging.ps1'
        'Requirements.ps1'
        'Helpers.ps1'
    )

    foreach ($file in $requiredFiles) {
        $filePath = Join-Path $PackagePath $file
        $exists = Test-Path $filePath
        Write-TestResult -Name "File exists: $file" -Passed $exists `
            -Detail $(if ($exists) { "Found at $filePath" } else { "Missing: $filePath" })
    }

    if ($Config) {
        Write-TestResult -Name "Configuration has Application.Name" `
            -Passed ([bool]$Config.Application.Name) `
            -Detail $Config.Application.Name

        Write-TestResult -Name "Configuration has CompanyName" `
            -Passed ([bool]$Config.CompanyName) `
            -Detail $Config.CompanyName

        Write-TestResult -Name "Configuration has Installer section" `
            -Passed ([bool]$Config.Installer) `
            -Detail $(if ($Config.Installer) { "Type: $($Config.Installer.Type)" } else { "Missing" })

        Write-TestResult -Name "Configuration has Detection section" `
            -Passed ([bool]$Config.Detection) `
            -Detail $(if ($Config.Detection) { "Type: $($Config.Detection.Type)" } else { "Missing" })

        Write-TestResult -Name "Configuration has Privileges section" `
            -Passed ([bool]$Config.Privileges) `
            -Detail $(if ($Config.Privileges) { "InstallAsSystem: $($Config.Privileges.InstallAsSystem), RequireElevation: $($Config.Privileges.RequireElevation)" } else { "Missing (defaults to InstallAsSystem=true)" })

        # MSI validation
        if ($Config.Installer.Type -eq 'MSI') {
            Write-TestResult -Name "MSI has ProductCode" `
                -Passed ([bool]$Config.Installer.ProductCode) `
                -Detail $(if ($Config.Installer.ProductCode) { $Config.Installer.ProductCode } else { "Missing - required for MSI" })
        }

        # Installer file check
        if ($Config.Installer -and $Config.Installer.File) {
            $installerPath = Join-Path $PackagePath (Join-Path 'Files' $Config.Installer.File)
            $installerExists = Test-Path $installerPath
            Write-TestResult -Name "Installer file exists" -Passed $installerExists `
                -Detail $(if ($installerExists) { $installerPath } else { "Not found: $installerPath" })

            # Hash validation
            if ($installerExists -and $Config.Installer.SHA256) {
                $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
                $hashMatch = $actualHash -eq $Config.Installer.SHA256
                Write-TestResult -Name "Installer SHA256 integrity" -Passed $hashMatch `
                    -Detail $(if ($hashMatch) { "Hash verified" } else { "Expected: $($Config.Installer.SHA256) | Actual: $actualHash" })
            }
        }

        # Architecture validation
        if ($Config.Requirements.Architecture) {
            $arch = $Config.Requirements.Architecture
            $isArray = $arch -is [array]
            Write-TestResult -Name "Architecture is array format" -Passed $isArray `
                -Detail $(if ($isArray) { "Values: $($arch -join ', ')" } else { "Should be @('x64') not '$arch'" })
        }

        # FileAssociations validation
        if ($Config.FileAssociations) {
            $validModes = @('Installer', 'Framework', 'None')
            $modeValid = $Config.FileAssociations.Mode -in $validModes
            Write-TestResult -Name "FileAssociations.Mode is valid" -Passed $modeValid `
                -Detail "Mode: $($Config.FileAssociations.Mode)"

            if ($Config.FileAssociations.Mode -eq 'Framework' -and $Config.FileAssociations.Associations) {
                Write-TestResult -Name "Framework associations configured" -Passed ($Config.FileAssociations.Associations.Count -gt 0) `
                    -Detail "$($Config.FileAssociations.Associations.Count) extension(s)"
            }
        }

        # Environment PATH entries
        if ($Config.Environment -and $Config.Environment.AddToMachinePath -and $Config.Environment.AddToMachinePath.Count -gt 0) {
            Write-TestResult -Name "AddToMachinePath configured" -Passed $true `
                -Detail "$($Config.Environment.AddToMachinePath.Count) entries: $($Config.Environment.AddToMachinePath -join ', ')"
        }

        # Environment variables
        if ($Config.Environment -and $Config.Environment.Variables -and $Config.Environment.Variables.Count -gt 0) {
            Write-TestResult -Name "Environment variables configured" -Passed $true `
                -Detail "$($Config.Environment.Variables.Count) variable(s)"
        }

        # ProcessesToStop
        if ($Config.ProcessesToStop -and $Config.ProcessesToStop.Count -gt 0) {
            Write-TestResult -Name "ProcessesToStop configured" -Passed $true `
                -Detail "$($Config.ProcessesToStop.Count) process(es): $($Config.ProcessesToStop -join ', ')"
        }

        # ServicesToStop
        if ($Config.ServicesToStop -and $Config.ServicesToStop.Count -gt 0) {
            Write-TestResult -Name "ServicesToStop configured" -Passed $true `
                -Detail "$($Config.ServicesToStop.Count) service(s): $($Config.ServicesToStop -join ', ')"
        }

        # Registry
        if ($Config.Registry) {
            if ($Config.Registry.Add -and $Config.Registry.Add.Count -gt 0) {
                Write-TestResult -Name "Registry.Add configured" -Passed $true `
                    -Detail "$($Config.Registry.Add.Count) entries"
            }
            if ($Config.Registry.Remove -and $Config.Registry.Remove.Count -gt 0) {
                Write-TestResult -Name "Registry.Remove configured" -Passed $true `
                    -Detail "$($Config.Registry.Remove.Count) entries"
            }
        }

        # Shortcuts
        if ($Config.Shortcuts -and $Config.Shortcuts.Create -and $Config.Shortcuts.Create.Count -gt 0) {
            Write-TestResult -Name "Shortcuts.Create configured" -Passed $true `
                -Detail "$($Config.Shortcuts.Create.Count) shortcuts"
        }

        # PostInstall
        if ($Config.PostInstall) {
            Write-TestResult -Name "PostInstall configured" -Passed $true `
                -Detail "Validate: $($Config.PostInstall.Validate), Actions: $($Config.PostInstall.Actions.Count)"
        }

        # UserExperience
        if ($Config.UserExperience) {
            Write-TestResult -Name "UserExperience configured" -Passed $true `
                -Detail "StartMenu: $($Config.UserExperience.CreateStartMenuShortcut), Desktop: $($Config.UserExperience.CreateDesktopShortcut)"
        }
    }
}

# =========================================================================
# LOGGING TEST
# =========================================================================
if ($Test -in 'All', 'Logging') {
    Write-TestHeader "Logging"

    try {
        . (Join-Path $PackagePath 'Logging.ps1')

        $testCompany = if ($Config.CompanyName) { $Config.CompanyName } else { 'TestCompany' }
        $testApp = if ($Config.Application.Name) { $Config.Application.Name } else { 'TestApp' }
        $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }

        Initialize-Logging -ApplicationName $testApp -CompanyName $testCompany `
            -ScriptName 'Test-Local' -ApplicationVersion '1.0.0' -LoggingConfig $loggingConfig

        $logDir = Get-LogDirectory
        $logFile = Get-LogFilePath

        Write-TestResult -Name "Logging initialized" -Passed $true -Detail "Log dir: $logDir"

        Write-Log -Message "Test log entry - Info" -Level 'Info'
        Write-Log -Message "Test log entry - Warning" -Level 'Warning'

        $logExists = Test-Path $logFile
        Write-TestResult -Name "Log file created" -Passed $logExists -Detail $logFile

        if ($logExists) {
            $content = Get-Content $logFile -Tail 5
            $hasEntries = $content.Count -gt 0
            Write-TestResult -Name "Log entries written" -Passed $hasEntries `
                -Detail "Last entry: $($content[-1])"
        }

        Write-DeploymentSummary -Action 'Test' -ExitCode 0 `
            -DetectionResult 'Test' -ValidationResult 'Test'

        $summaryFile = Join-Path $logDir 'DeploymentSummary.log'
        Write-TestResult -Name "Deployment summary written" -Passed (Test-Path $summaryFile) `
            -Detail $summaryFile
    }
    catch {
        Write-TestResult -Name "Logging" -Passed $false -Detail $_.Exception.Message
    }
}

# =========================================================================
# REQUIREMENTS TEST
# =========================================================================
if ($Test -in 'All', 'Requirements') {
    Write-TestHeader "Requirements"

    try {
        . (Join-Path $PackagePath 'Logging.ps1')
        . (Join-Path $PackagePath 'Requirements.ps1')

        if (-not $script:LogState.Initialized) {
            $testCompany = if ($Config.CompanyName) { $Config.CompanyName } else { 'TestCompany' }
            $testApp = if ($Config.Application.Name) { $Config.Application.Name } else { 'TestApp' }
            $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }
            Initialize-Logging -ApplicationName $testApp -CompanyName $testCompany `
                -ScriptName 'Test-Requirements' -ApplicationVersion '1.0.0' -LoggingConfig $loggingConfig
        }

        if ($Config -and $Config.Requirements) {
            $reqResult = Test-Requirements -Configuration $Config
            Write-TestResult -Name "Requirements validation" -Passed $reqResult `
                -Detail $(if ($reqResult) { "All requirements met" } else { "Some requirements not met" })
        }
        else {
            Write-TestResult -Name "Requirements validation" -Passed $true `
                -Detail "No requirements configured"
        }
    }
    catch {
        Write-TestResult -Name "Requirements" -Passed $false -Detail $_.Exception.Message
    }
}

# =========================================================================
# DETECTION TEST
# =========================================================================
if ($Test -in 'All', 'Detection') {
    Write-TestHeader "Detection"

    try {
        . (Join-Path $PackagePath 'Detection.ps1')

        if ($Config -and $Config.Detection) {
            $detResult = Invoke-Detection -DetectionConfig $Config.Detection
            Write-TestResult -Name "Detection ($($Config.Detection.Type))" `
                -Passed $detResult.Detected -Detail $detResult.Detail

            if ($Config.Detection.VersionComparison) {
                Write-TestResult -Name "Version comparison mode" -Passed $true `
                    -Detail $Config.Detection.VersionComparison
            }
        }
        else {
            Write-TestResult -Name "Detection" -Passed $false `
                -Detail "No detection configuration found"
        }
    }
    catch {
        Write-TestResult -Name "Detection" -Passed $false -Detail $_.Exception.Message
    }
}

# =========================================================================
# VALIDATION TEST
# =========================================================================
if ($Test -in 'All', 'Validation') {
    Write-TestHeader "Validation"

    try {
        . (Join-Path $PackagePath 'Logging.ps1')
        . (Join-Path $PackagePath 'Detection.ps1')
        . (Join-Path $PackagePath 'Validation.ps1')

        if (-not $script:LogState.Initialized) {
            $testCompany = if ($Config.CompanyName) { $Config.CompanyName } else { 'TestCompany' }
            $testApp = if ($Config.Application.Name) { $Config.Application.Name } else { 'TestApp' }
            $loggingConfig = if ($Config.Logging) { $Config.Logging } else { @{} }
            Initialize-Logging -ApplicationName $testApp -CompanyName $testCompany `
                -ScriptName 'Test-Validation' -ApplicationVersion '1.0.0' -LoggingConfig $loggingConfig
        }

        # SYSTEM context test
        $sysResult = Test-SystemContext -AllowNonSystem $EnableTestMode.IsPresent
        Write-TestResult -Name "SYSTEM context check" -Passed $sysResult `
            -Detail "Identity: $($identity.Name), AllowNonSystem: $($EnableTestMode.IsPresent)"

        # Pre-install validation
        if ($Config) {
            $testConfig = $Config.Clone()
            if ($EnableTestMode) {
                if (-not $testConfig.Testing) { $testConfig.Testing = @{} }
                $testConfig.Testing.AllowNonSystemExecution = $true
            }

            $preVal = Test-PreInstallValidation -Configuration $testConfig -PackagePath $PackagePath
            Write-TestResult -Name "Pre-install validation" -Passed $preVal.Passed `
                -Detail $(if ($preVal.Passed) { "All checks passed" } else { $preVal.Failures -join '; ' })
        }
    }
    catch {
        Write-TestResult -Name "Validation" -Passed $false -Detail $_.Exception.Message
    }
}

# =========================================================================
# INSTALL TEST
# =========================================================================
if ($Test -eq 'Install') {
    Write-TestHeader "Installation (LIVE)"

    if (-not $isSystem -and -not $EnableTestMode) {
        Write-Host "  WARNING: Not running as SYSTEM. Use -EnableTestMode to allow." -ForegroundColor Yellow
        Write-Host "  For SYSTEM testing, use: PsExec.exe -s powershell.exe -File `"$PackagePath\Test-Local.ps1`" -Test Install" -ForegroundColor Yellow
        Write-TestResult -Name "Install" -Passed $false -Detail "Not running as SYSTEM and test mode not enabled"
    }
    else {
        Write-Host "  This will execute the actual installer. Proceed? (Y/N): " -ForegroundColor Yellow -NoNewline
        $confirm = Read-Host
        if ($confirm -eq 'Y') {
            if ($EnableTestMode -and $Config) {
                $envFile = Join-Path $PackagePath 'Configuration.psd1'
                $originalContent = Get-Content $envFile -Raw
                try {
                    $content = $originalContent -replace 'AllowNonSystemExecution\s*=\s*\$false', 'AllowNonSystemExecution = $true'
                    Set-Content -Path $envFile -Value $content
                    & (Join-Path $PackagePath 'Install.ps1')
                    $installResult = $LASTEXITCODE
                    Write-TestResult -Name "Installation" -Passed ($installResult -eq 0) `
                        -Detail "Exit code: $installResult"
                }
                finally {
                    Set-Content -Path $envFile -Value $originalContent
                }
            }
            else {
                & (Join-Path $PackagePath 'Install.ps1')
                $installResult = $LASTEXITCODE
                Write-TestResult -Name "Installation" -Passed ($installResult -eq 0) `
                    -Detail "Exit code: $installResult"
            }
        }
        else {
            Write-TestResult -Name "Installation" -Passed $false -Detail "Skipped by user"
        }
    }
}

# =========================================================================
# UNINSTALL TEST
# =========================================================================
if ($Test -eq 'Uninstall') {
    Write-TestHeader "Uninstallation (LIVE)"

    if (-not $isSystem -and -not $EnableTestMode) {
        Write-Host "  WARNING: Not running as SYSTEM. Use -EnableTestMode to allow." -ForegroundColor Yellow
        Write-TestResult -Name "Uninstall" -Passed $false -Detail "Not running as SYSTEM and test mode not enabled"
    }
    else {
        Write-Host "  This will execute the actual uninstaller. Proceed? (Y/N): " -ForegroundColor Yellow -NoNewline
        $confirm = Read-Host
        if ($confirm -eq 'Y') {
            if ($EnableTestMode -and $Config) {
                $envFile = Join-Path $PackagePath 'Configuration.psd1'
                $originalContent = Get-Content $envFile -Raw
                try {
                    $content = $originalContent -replace 'AllowNonSystemExecution\s*=\s*\$false', 'AllowNonSystemExecution = $true'
                    Set-Content -Path $envFile -Value $content
                    & (Join-Path $PackagePath 'Uninstall.ps1')
                    $uninstallResult = $LASTEXITCODE
                    Write-TestResult -Name "Uninstallation" -Passed ($uninstallResult -eq 0) `
                        -Detail "Exit code: $uninstallResult"
                }
                finally {
                    Set-Content -Path $envFile -Value $originalContent
                }
            }
            else {
                & (Join-Path $PackagePath 'Uninstall.ps1')
                $uninstallResult = $LASTEXITCODE
                Write-TestResult -Name "Uninstallation" -Passed ($uninstallResult -eq 0) `
                    -Detail "Exit code: $uninstallResult"
            }
        }
        else {
            Write-TestResult -Name "Uninstallation" -Passed $false -Detail "Skipped by user"
        }
    }
}

# =========================================================================
# SUMMARY
# =========================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Yellow
Write-Host "  TEST SUMMARY" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Yellow

$passed = ($Results | Where-Object { $_.Passed }).Count
$failed = ($Results | Where-Object { -not $_.Passed }).Count
$total  = $Results.Count

Write-Host "  Total: $total | Passed: $passed | Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "  Failed Tests:" -ForegroundColor Red
    $Results | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "    - $($_.Test): $($_.Detail)" -ForegroundColor Red
    }
    Write-Host ""
}

if (-not $isSystem) {
    Write-Host "  TIP: For SYSTEM-context testing, run:" -ForegroundColor Cyan
    Write-Host "    PsExec.exe -s -i powershell.exe -ExecutionPolicy Bypass -File `"$PackagePath\Test-Local.ps1`" -Test All" -ForegroundColor Gray
    Write-Host ""
}
