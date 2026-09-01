#Requires -Version 5.1
<#
.SYNOPSIS
    Intune detection script for Oracle JDK.
.DESCRIPTION
    Detects whether the JDK product is installed by checking the registry
    for a registered JDK version and verifying java.exe exists on disk.

    Per Intune convention: stdout output + exit 0 = detected.
    Exit 1 with no stdout = not detected.

    This script detects the PRODUCT installation only, not the environment
    configuration (JAVA_HOME/PATH). Environment configuration is handled
    by the install script and is not a detection criterion — otherwise a
    partial env-var failure would cause Intune to re-run the full MSI
    install in a loop.
#>

$ErrorActionPreference = 'SilentlyContinue'

# --- Strategy 1: Registry-based detection (preferred) ---
$registryPath = 'HKLM:\SOFTWARE\JavaSoft\JDK'
$javaHome = $null

if (Test-Path $registryPath) {
    $currentVersion = (Get-ItemProperty -Path $registryPath -Name 'CurrentVersion' -ErrorAction SilentlyContinue).CurrentVersion
    if ($currentVersion) {
        $versionKey = Join-Path $registryPath $currentVersion
        if (Test-Path $versionKey) {
            $javaHome = (Get-ItemProperty -Path $versionKey -Name 'JavaHome' -ErrorAction SilentlyContinue).JavaHome
        }
    }
}

# --- Strategy 2: Filesystem fallback ---
if (-not $javaHome -or -not (Test-Path $javaHome)) {
    $searchDirs = @(
        (Join-Path $env:ProgramFiles 'Java')
        (Join-Path ${env:ProgramFiles(x86)} 'Java')
    )
    foreach ($parentDir in $searchDirs) {
        if (-not $parentDir -or -not (Test-Path $parentDir)) { continue }
        $jdkDir = Get-ChildItem -Path $parentDir -Directory -Filter 'jdk-*' |
            Sort-Object {
                $vStr = $_.Name -replace '^jdk-', '' -replace '[_+].*', ''
                try { [version]$vStr } catch { [version]'0.0' }
            } |
            Select-Object -Last 1
        if ($jdkDir) {
            $javaHome = $jdkDir.FullName
            break
        }
    }
}

if (-not $javaHome) { exit 1 }

# Verify the executable exists on disk
$javaExe = Join-Path $javaHome 'bin\java.exe'
if (-not (Test-Path $javaExe)) { exit 1 }

Write-Output "JDK detected: $javaHome"
exit 0
