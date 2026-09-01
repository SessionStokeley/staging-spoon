#Requires -Version 5.1
<#
.SYNOPSIS
    Intune detection script. Supports MSI and EXE installed applications.
.DESCRIPTION
    Detects whether the application is installed using configurable methods:
    - Registry: checks uninstall registry for matching DisplayName
    - File: checks for a specific file on disk
    - Both: either method succeeding counts as detected

    Per Intune convention: stdout output + exit 0 = detected.
    Exit 1 with no stdout = not detected.

    This script detects the PRODUCT installation only, not environment
    configuration (JAVA_HOME/PATH), to prevent Intune retry loops.
#>

$ErrorActionPreference = 'SilentlyContinue'

# --- Configuration (inline for self-contained detection) ---
$ProductNamePattern = 'Java*JDK*'
$DetectionMethod    = 'Both'
$DetectionFilePath  = ''  # set to a specific file path for file-based detection

$UninstallRegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# JDK-specific: vendor registry and filesystem discovery
$JdkRegistryPath = 'HKLM:\SOFTWARE\JavaSoft\JDK'
$InstallParentDirs = @(
    (Join-Path $env:ProgramFiles 'Java')
    (Join-Path ${env:ProgramFiles(x86)} 'Java')
)

# --- Registry-based detection ---
$registryDetected = $false
$detectedProduct = $null

foreach ($regPath in $UninstallRegistryPaths) {
    $product = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $ProductNamePattern } |
        Select-Object -First 1
    if ($product) {
        $registryDetected = $true
        $detectedProduct = $product.DisplayName
        break
    }
}

# --- File-based detection (JDK-specific: find java.exe) ---
$fileDetected = $false
$detectedPath = $null

# Check explicit detection file path first
if ($DetectionFilePath -and (Test-Path $DetectionFilePath)) {
    $fileDetected = $true
    $detectedPath = $DetectionFilePath
}

# JDK-specific: registry path discovery
if (-not $fileDetected -and (Test-Path $JdkRegistryPath)) {
    $currentVersion = (Get-ItemProperty -Path $JdkRegistryPath -Name 'CurrentVersion' -ErrorAction SilentlyContinue).CurrentVersion
    if ($currentVersion) {
        $versionKey = Join-Path $JdkRegistryPath $currentVersion
        if (Test-Path $versionKey) {
            $javaHome = (Get-ItemProperty -Path $versionKey -Name 'JavaHome' -ErrorAction SilentlyContinue).JavaHome
            if ($javaHome) {
                $javaExe = Join-Path $javaHome 'bin\java.exe'
                if (Test-Path $javaExe) {
                    $fileDetected = $true
                    $detectedPath = $javaHome
                }
            }
        }
    }
}

# JDK-specific: filesystem fallback
if (-not $fileDetected) {
    foreach ($parentDir in $InstallParentDirs) {
        if (-not $parentDir -or -not (Test-Path $parentDir)) { continue }
        $jdkDir = Get-ChildItem -Path $parentDir -Directory -Filter 'jdk-*' |
            Sort-Object {
                $vStr = $_.Name -replace '^jdk-', '' -replace '[_+].*', ''
                try { [version]$vStr } catch { [version]'0.0' }
            } |
            Select-Object -Last 1
        if ($jdkDir) {
            $javaExe = Join-Path $jdkDir.FullName 'bin\java.exe'
            if (Test-Path $javaExe) {
                $fileDetected = $true
                $detectedPath = $jdkDir.FullName
                break
            }
        }
    }
}

# --- Evaluate detection result ---
$detected = $false
switch ($DetectionMethod) {
    'Registry' { $detected = $registryDetected }
    'File'     { $detected = $fileDetected }
    'Both'     { $detected = ($registryDetected -or $fileDetected) }
}

if ($detected) {
    $output = if ($detectedProduct) { $detectedProduct } elseif ($detectedPath) { "Detected: $detectedPath" } else { 'Detected' }
    Write-Output $output
    exit 0
}

exit 1
