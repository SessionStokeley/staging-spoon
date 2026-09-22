<#
.SYNOPSIS
    Validates package.json and source folder before building an Intune package.
.DESCRIPTION
    Checks that:
    - package.json exists and has required fields
    - All source files (installer, scripts) exist
    - Configuration values are reasonable
    - Paths in PostInstallExpectation are absolute
    - No obvious configuration errors
.EXAMPLE
    .\src\Build\Evaluate-Package.ps1 -ConfigPath .\package.json -SourcePath .\source
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$SourcePath,
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'

$script:errors = @()
$script:warnings = @()

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $icon = if ($Passed) { '[ok]' } else { '[!!]' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host "  $icon $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "    $Detail" -ForegroundColor Gray }
}

function Add-Error {
    param([string]$Message)
    $script:errors += $Message
    Write-Host "  [!!] ERROR: $Message" -ForegroundColor Red
}

function Add-Warning {
    param([string]$Message)
    $script:warnings += $Message
    Write-Host "  [ ! ] WARNING: $Message" -ForegroundColor Yellow
}

Write-Host "`n=== Intune Package Evaluator ===" -ForegroundColor Cyan

# Check config file exists
Write-Host "`nConfiguration"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Add-Error "Config file not found: $ConfigPath"
    exit 1
}

# Read and parse config
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Check "Config file is valid JSON" $true
} catch {
    Add-Error "Config file is not valid JSON: $_"
    exit 1
}

# Check required fields
Write-Host "`nRequired fields"
$requiredFields = @(
    'ApplicationName', 'ApplicationVersion', 'PackageVersion', 'InstallerType',
    'SourceInstaller', 'InstallCommand', 'UninstallCommand', 'DetectionMethod',
    'DetectionScript', 'InstallBehavior', 'Architecture', 'ExpectedExitCodes',
    'RebootBehavior'
)

$allPresent = $true
foreach ($field in $requiredFields) {
    $hasField = $null -ne $config.$field -and $config.$field -ne ''
    Write-Check "  $field" $hasField
    if (-not $hasField) { $allPresent = $false }
}

if (-not $allPresent) {
    Add-Error "Missing required fields in config"
    exit 1
}

# Check ApplicationVersion format
Write-Host "`nVersion format"
if ($config.ApplicationVersion -match '^\d+\.\d+(\.\d+)?$') {
    Write-Check "ApplicationVersion format" $true $config.ApplicationVersion
} else {
    Add-Warning "ApplicationVersion should be semantic (e.g., 1.0.0): $($config.ApplicationVersion)"
}

if ($config.PackageVersion -match '^\d+\.\d+(\.\d+)?$') {
    Write-Check "PackageVersion format" $true $config.PackageVersion
} else {
    Add-Warning "PackageVersion should be semantic (e.g., 1.0.0): $($config.PackageVersion)"
}

# Check source folder
Write-Host "`nSource folder ($SourcePath)"
if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    Add-Error "Source folder not found: $SourcePath"
    exit 1
}
Write-Check "Source folder exists" $true

# Check installer exists
$installerPath = Join-Path $SourcePath $config.SourceInstaller
if (-not (Test-Path -LiteralPath $installerPath)) {
    Add-Error "Installer not found: $($config.SourceInstaller) in $SourcePath"
    exit 1
}
$installerSize = (Get-Item -LiteralPath $installerPath).Length / 1MB
Write-Check "Installer file exists" $true "$($config.SourceInstaller) ($([Math]::Round($installerSize, 2)) MB)"

# Check scripts
$scripts = @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1')
foreach ($script in $scripts) {
    $scriptPath = Join-Path $SourcePath $script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Add-Error "$script not found in source folder"
    } else {
        Write-Check "$script exists" $true
    }
}

# Check detection script in config matches actual file
if ($config.DetectionScript -ne 'Detection.ps1') {
    Add-Warning "DetectionScript is '$($config.DetectionScript)' but template expects 'Detection.ps1'"
}

# Check commands
Write-Host "`nCommands"
if ($config.InstallCommand -match 'Install\.ps1') {
    Write-Check "InstallCommand references Install.ps1" $true
} else {
    Add-Warning "InstallCommand doesn't reference Install.ps1: $($config.InstallCommand)"
}

if ($config.UninstallCommand -match 'Uninstall\.ps1') {
    Write-Check "UninstallCommand references Uninstall.ps1" $true
} else {
    Add-Warning "UninstallCommand doesn't reference Uninstall.ps1: $($config.UninstallCommand)"
}

# Check InstallBehavior
if ($config.InstallBehavior -in @('System', 'User')) {
    Write-Check "InstallBehavior is valid" $true $config.InstallBehavior
} else {
    Add-Warning "InstallBehavior should be 'System' or 'User', not '$($config.InstallBehavior)'"
}

# Check Architecture
if ($config.Architecture -in @('x64', 'x86')) {
    Write-Check "Architecture is valid" $true $config.Architecture
} else {
    Add-Warning "Architecture should be 'x64' or 'x86', not '$($config.Architecture)'"
}

# Check RebootBehavior
if ($config.RebootBehavior -in @('BasedOnReturnCode', 'NoAction', 'ForceReboot')) {
    Write-Check "RebootBehavior is valid" $true $config.RebootBehavior
} else {
    Add-Warning "RebootBehavior should be 'BasedOnReturnCode', 'NoAction', or 'ForceReboot'"
}

# Check ExpectedExitCodes
Write-Host "`nExit codes"
if ($config.ExpectedExitCodes -is [array] -and $config.ExpectedExitCodes.Count -gt 0) {
    Write-Check "ExpectedExitCodes is set" $true ($config.ExpectedExitCodes -join ', ')
    if ($config.ExpectedExitCodes -notcontains 0) {
        Add-Warning "ExpectedExitCodes should typically include 0 (success)"
    }
    if ($config.RebootBehavior -eq 'BasedOnReturnCode' -and -not (
        $config.ExpectedExitCodes -contains 1641 -or $config.ExpectedExitCodes -contains 3010)) {
        Add-Warning "With BasedOnReturnCode, consider including 1641 or 3010 (reboot codes)"
    }
} else {
    Add-Error "ExpectedExitCodes must be a non-empty array"
}

# Check PostInstallExpectation
Write-Host "`nPost-install validation"
$hasExpectation = $null -ne $config.PostInstallExpectation -and (
    $config.PostInstallExpectation.File.Count -gt 0 -or
    $config.PostInstallExpectation.RegistryKey.Count -gt 0 -or
    $config.PostInstallExpectation.UninstallDisplayName.Count -gt 0
)

if ($hasExpectation) {
    Write-Check "PostInstallExpectation is configured" $true

    # Check File paths are absolute
    if ($config.PostInstallExpectation.File.Count -gt 0) {
        $invalidFiles = @($config.PostInstallExpectation.File | Where-Object { -not $_.StartsWith('C:\') -and -not $_.StartsWith('C:/') })
        if ($invalidFiles.Count -gt 0) {
            Add-Error "File paths must be absolute (start with C:\): $($invalidFiles -join ', ')"
        } else {
            Write-Check "  File paths are absolute" $true "$($config.PostInstallExpectation.File.Count) files"
        }
    }

    # Check registry paths
    if ($config.PostInstallExpectation.RegistryKey.Count -gt 0) {
        $invalidReg = @($config.PostInstallExpectation.RegistryKey | Where-Object { -not $_.StartsWith('HKLM:\') -and -not $_.StartsWith('HKCU:\') })
        if ($invalidReg.Count -gt 0) {
            Add-Error "Registry paths must start with HKLM:\ or HKCU:\: $($invalidReg -join ', ')"
        } else {
            Write-Check "  Registry keys are valid" $true "$($config.PostInstallExpectation.RegistryKey.Count) keys"
        }
    }

    # UninstallDisplayName
    if ($config.PostInstallExpectation.UninstallDisplayName.Count -gt 0) {
        Write-Check "  Uninstall display name patterns" $true "$($config.PostInstallExpectation.UninstallDisplayName.Count) patterns"
    }
} else {
    Add-Warning "PostInstallExpectation is empty or missing - installation won't be validated for completeness"
}

# Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan

if ($script:errors.Count -eq 0) {
    Write-Host "Configuration is ready for build" -ForegroundColor Green
    Write-Host "`nNext steps:"
    Write-Host "  1. Verify all source scripts have been edited with app-specific values"
    Write-Host "  2. Test installation manually: .\source\Install.ps1"
    Write-Host "  3. Run the build with elevated PowerShell:"
    Write-Host "     .\src\Build\Build-IntunePackage.ps1 -SourcePath .\source -ConfigPath .\package.json -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe -SystemContext"

    if ($script:warnings.Count -gt 0) {
        Write-Host "`nAddress warnings before production deployment" -ForegroundColor Yellow
    }

    exit 0
} else {
    Write-Host "Configuration has errors" -ForegroundColor Red
    Write-Host "`nFix the above errors and run again."
    exit 1
}
