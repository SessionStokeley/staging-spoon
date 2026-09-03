#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Uninstall', 'Detection', 'Validate')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Result {
    param([string]$Label, [bool]$Pass)
    $status = if ($Pass) { "PASS" } else { "FAIL" }
    $color = if ($Pass) { "Green" } else { "Red" }
    Write-Host ("{0,-30} {1}" -f "${Label}:", $status) -ForegroundColor $color
}

# Validate package structure and configuration
function Test-Package {
    $Config = Import-PowerShellDataFile (Join-Path $ScriptDir 'Configuration.psd1')
    $allPass = $true

    Write-Banner "Package Validation"
    Write-Host "Application: $($Config.ApplicationName)"
    Write-Host ""

    # Required files
    $requiredFiles = @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1', 'Configuration.psd1')
    foreach ($file in $requiredFiles) {
        $exists = Test-Path (Join-Path $ScriptDir $file)
        Write-Result "File: $file" $exists
        if (-not $exists) { $allPass = $false }
    }

    # Installer file
    $installerPath = Join-Path (Join-Path $ScriptDir 'Files') $Config.Installer.File
    $installerExists = Test-Path $installerPath
    Write-Result "Installer: $($Config.Installer.File)" $installerExists
    if (-not $installerExists) { $allPass = $false }

    # Configuration checks
    $hasName = [bool]$Config.ApplicationName
    Write-Result "ApplicationName" $hasName
    if (-not $hasName) { $allPass = $false }

    $hasInstallerType = [bool]$Config.Installer.Type
    Write-Result "Installer.Type" $hasInstallerType
    if (-not $hasInstallerType) { $allPass = $false }

    $hasDetectionType = [bool]$Config.Detection.Type
    Write-Result "Detection.Type" $hasDetectionType
    if (-not $hasDetectionType) { $allPass = $false }

    # Script syntax validation
    foreach ($file in $requiredFiles | Where-Object { $_ -like '*.ps1' }) {
        $path = Join-Path $ScriptDir $file
        if (Test-Path $path) {
            $errors = $null
            [System.Management.Automation.PSParser]::Tokenize((Get-Content $path -Raw), [ref]$errors) | Out-Null
            $syntaxOk = ($errors.Count -eq 0)
            Write-Result "Syntax: $file" $syntaxOk
            if (-not $syntaxOk) { $allPass = $false }
        }
    }

    Write-Host ""
    $overallColor = if ($allPass) { "Green" } else { "Red" }
    $overallResult = if ($allPass) { "VALIDATION PASSED" } else { "VALIDATION FAILED" }
    Write-Host "RESULT: $overallResult" -ForegroundColor $overallColor
    Write-Host "========================================" -ForegroundColor Cyan
}

# --- Main ---

$Config = Import-PowerShellDataFile (Join-Path $ScriptDir 'Configuration.psd1')

switch ($Mode) {
    'Validate' {
        Test-Package
    }

    'Install' {
        Write-Banner "Intune Application Test — Install"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host "Mode: Install"
        Write-Host ""

        $script = Join-Path $ScriptDir 'Install.ps1'
        & $script
        $installExit = $LASTEXITCODE

        Write-Host ""
        $success = ($installExit -in @(0, 3010))
        Write-Result "Exit Code" $success
        Write-Host "  Exit Code Value: $installExit"

        $overallColor = if ($success) { "Green" } else { "Red" }
        $overallResult = if ($success) { "SUCCESS" } else { "FAILURE" }
        Write-Host ""
        Write-Host "RESULT: $overallResult" -ForegroundColor $overallColor
        Write-Host "========================================" -ForegroundColor Cyan
    }

    'Uninstall' {
        Write-Banner "Intune Application Test — Uninstall"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host "Mode: Uninstall"
        Write-Host ""

        $script = Join-Path $ScriptDir 'Uninstall.ps1'
        & $script
        $uninstallExit = $LASTEXITCODE

        Write-Host ""
        $success = ($uninstallExit -in @(0, 3010))
        Write-Result "Exit Code" $success
        Write-Host "  Exit Code Value: $uninstallExit"

        $overallColor = if ($success) { "Green" } else { "Red" }
        $overallResult = if ($success) { "SUCCESS" } else { "FAILURE" }
        Write-Host ""
        Write-Host "RESULT: $overallResult" -ForegroundColor $overallColor
        Write-Host "========================================" -ForegroundColor Cyan
    }

    'Detection' {
        Write-Banner "Intune Application Test — Detection"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host "Mode: Detection"
        Write-Host ""

        $script = Join-Path $ScriptDir 'Detection.ps1'
        & $script
        $detectionExit = $LASTEXITCODE

        $detected = ($detectionExit -eq 0)
        Write-Result "Detection" $detected
        $status = if ($detected) { "Installed" } else { "Not Installed" }
        Write-Host "  Status: $status"

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
    }
}
