#Requires -Version 5.1
<#
.SYNOPSIS
    Local validation and testing script for the Intune deployment package.
.DESCRIPTION
    Validates configuration, runs syntax checks on all scripts, and optionally
    executes the full install/detect/uninstall lifecycle for local testing.
    Does not require Intune.
.PARAMETER RunInstall
    Execute the real installer for a full lifecycle test.
.PARAMETER RunUninstall
    Execute uninstall after install test.
.EXAMPLE
    .\Test-Package.ps1
    Runs configuration and syntax validation only.
.EXAMPLE
    .\Test-Package.ps1 -RunInstall -RunUninstall
    Runs the full install, detect, uninstall, detect lifecycle.
#>

[CmdletBinding()]
param(
    [switch]$RunInstall,
    [switch]$RunUninstall
)

$ErrorActionPreference = 'Stop'

$script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:ErrorCount = 0
$script:WarnCount = 0

function Add-TestResult {
    param(
        [string]$Name,
        [ValidateSet('PASS','FAIL','WARN','SKIP')][string]$Status,
        [string]$Detail = ''
    )
    $script:TestResults.Add([PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    })
    switch ($Status) {
        'FAIL' { $script:ErrorCount++; Write-Host "[FAIL] $Name" -ForegroundColor Red }
        'WARN' { $script:WarnCount++; Write-Host "[WARN] $Name" -ForegroundColor Yellow }
        'PASS' { Write-Host "[PASS] $Name" -ForegroundColor Green }
        'SKIP' { Write-Host "[SKIP] $Name" -ForegroundColor DarkGray }
    }
    if ($Detail) { Write-Host "       $Detail" }
}

Write-Host "`n=== Intune Package Validation ===`n"

# --- Syntax Validation ---
$scripts = @('Config.ps1', 'Helpers.ps1', 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1')
foreach ($script in $scripts) {
    $path = Join-Path $PSScriptRoot $script
    if (-not (Test-Path $path)) {
        Add-TestResult "$script syntax" 'FAIL' "File not found: $path"
        continue
    }
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        Add-TestResult "$script syntax" 'FAIL' ($errors | ForEach-Object { $_.Message }) -join '; '
    } else {
        Add-TestResult "$script syntax" 'PASS'
    }
}

# --- Load Configuration ---
try {
    . (Join-Path $PSScriptRoot 'Config.ps1')
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    Add-TestResult 'Config/Helpers load' 'PASS'
} catch {
    Add-TestResult 'Config/Helpers load' 'FAIL' $_.Exception.Message
    Write-Host "`n=== Cannot continue without valid configuration ===`n"
    exit 1
}

# --- Configuration Validation ---
Write-Host ''
$configValid = Test-PackageConfiguration -PackageRoot $PSScriptRoot -ValidateInstallerExists:$RunInstall
if ($configValid) {
    Add-TestResult 'Installer type validation' 'PASS' "Type: $($AppConfig.InstallerType)"
} else {
    Add-TestResult 'Installer type validation' 'FAIL'
}

# File extension match
$ext = [System.IO.Path]::GetExtension($AppConfig.InstallerFileName).ToLower()
$expectedExt = if ($AppConfig.InstallerType -eq 'MSI') { '.msi' } else { '.exe' }
if ($ext -eq $expectedExt) {
    Add-TestResult 'Installer file extension' 'PASS' "$($AppConfig.InstallerFileName) matches $($AppConfig.InstallerType)"
} else {
    Add-TestResult 'Installer file extension' 'FAIL' "Expected $expectedExt, got $ext"
}

# Installer file existence
$installerPath = Join-Path $PSScriptRoot $AppConfig.InstallerFileName
if (Test-Path $installerPath) {
    Add-TestResult 'Installer file exists' 'PASS' $installerPath
} else {
    if ($RunInstall) {
        Add-TestResult 'Installer file exists' 'FAIL' "Not found: $installerPath"
    } else {
        Add-TestResult 'Installer file exists' 'WARN' "Not found (skipping — use -RunInstall to require): $installerPath"
    }
}

# Detection method
Add-TestResult 'Detection method' 'PASS' $AppConfig.DetectionMethod

# --- Lifecycle Tests (require -RunInstall) ---
Write-Host ''
if ($RunInstall) {
    Write-Host '--- Install Test ---'

    # Pre-install detection
    Initialize-Logging
    $preDetected = Test-ProductDetected
    Add-TestResult 'Pre-install detection' $(if ($preDetected) { 'WARN' } else { 'PASS' }) `
        $(if ($preDetected) { 'Product already detected before install' } else { 'Product not detected (expected)' })

    # Run installer
    try {
        $exitCode = Invoke-Installer -PackageRoot $PSScriptRoot
        if ($exitCode -in $AppConfig.SuccessExitCodes) {
            Add-TestResult 'Installation execution' 'PASS' "Exit code: $exitCode"
        } else {
            Add-TestResult 'Installation execution' 'FAIL' "Exit code: $exitCode"
        }
    } catch {
        Add-TestResult 'Installation execution' 'FAIL' $_.Exception.Message
    }

    # Post-install detection
    $postDetected = Test-ProductDetected
    if ($postDetected) {
        Add-TestResult 'Post-install detection' 'PASS'
    } else {
        Add-TestResult 'Post-install detection' 'FAIL' 'Product not detected after install'
    }

    # Post-install environment configuration
    if ($AppConfig.ConfigureEnvironment) {
        $installPath = Get-InstalledJdkPath
        if ($installPath) {
            Add-TestResult 'Install path discovery' 'PASS' $installPath

            $binDir = Join-Path $installPath $AppConfig.PathSubdirectory
            Set-MachineEnvVar -Name 'JAVA_HOME' -Value $installPath
            Update-MachinePath -NewEntry $binDir

            $envValid = Test-EnvironmentConfiguration -ExpectedJavaHome $installPath -ExpectedBinDir $binDir
            Add-TestResult 'Environment validation' $(if ($envValid) { 'PASS' } else { 'FAIL' })

            # Idempotency: run PATH update again, verify no duplicates
            Update-MachinePath -NewEntry $binDir
            $machinePath = Get-MachinePathRaw
            $matchCount = ($machinePath -split ';' | Where-Object {
                (Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($_))) -ieq (Resolve-NormalizedPath $binDir)
            }).Count
            if ($matchCount -le 1) {
                Add-TestResult 'Idempotency (no duplicates)' 'PASS' "PATH entry count: $matchCount"
            } else {
                Add-TestResult 'Idempotency (no duplicates)' 'FAIL' "Duplicate PATH entries: $matchCount"
            }
        } else {
            Add-TestResult 'Install path discovery' 'FAIL' 'Could not determine installation path'
        }
    }

    # --- Uninstall Test ---
    Write-Host ''
    if ($RunUninstall) {
        Write-Host '--- Uninstall Test ---'

        try {
            $exitCode = Invoke-Uninstaller -PackageRoot $PSScriptRoot
            $allowedCodes = $AppConfig.SuccessExitCodes + @(1605)
            if ($exitCode -in $allowedCodes -or $exitCode -eq -1) {
                Add-TestResult 'Uninstall execution' 'PASS' "Exit code: $exitCode"
            } else {
                Add-TestResult 'Uninstall execution' 'FAIL' "Exit code: $exitCode"
            }
        } catch {
            Add-TestResult 'Uninstall execution' 'FAIL' $_.Exception.Message
        }

        # Environment cleanup
        if ($AppConfig.ConfigureEnvironment) {
            Set-MachineEnvVar -Name 'JAVA_HOME' -Value ''
            Remove-ManagedPathEntries
        }

        # Post-uninstall detection
        $postUninstallDetected = Test-ProductDetected
        if (-not $postUninstallDetected) {
            Add-TestResult 'Post-uninstall detection' 'PASS' 'Product no longer detected'
        } else {
            Add-TestResult 'Post-uninstall detection' 'FAIL' 'Product still detected after uninstall'
        }
    } else {
        Add-TestResult 'Uninstall test' 'SKIP' 'Use -RunUninstall to include'
    }
} else {
    Add-TestResult 'Install test' 'SKIP' 'Use -RunInstall to execute'
    Add-TestResult 'Uninstall test' 'SKIP' 'Use -RunUninstall to execute'
}

# --- Summary ---
Write-Host "`n=== Validation Summary ==="
Write-Host "Total:    $($script:TestResults.Count)"
Write-Host "Passed:   $(($script:TestResults | Where-Object Status -eq 'PASS').Count)" -ForegroundColor Green
Write-Host "Failed:   $($script:ErrorCount)" -ForegroundColor $(if ($script:ErrorCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Warnings: $($script:WarnCount)" -ForegroundColor $(if ($script:WarnCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "Skipped:  $(($script:TestResults | Where-Object Status -eq 'SKIP').Count)" -ForegroundColor DarkGray

if ($script:ErrorCount -gt 0) {
    Write-Host "`nRESULT: FAIL" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nRESULT: PASS" -ForegroundColor Green
    exit 0
}
