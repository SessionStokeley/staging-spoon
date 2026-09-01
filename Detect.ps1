#Requires -Version 5.1
<#
.SYNOPSIS
    Intune detection script for Oracle JDK.
.DESCRIPTION
    Exits 0 with stdout output if JDK is detected (installed, JAVA_HOME set, bin in PATH).
    Exits 1 with no stdout if not detected.
    Per Intune convention: stdout output + exit 0 = detected.
#>

$ErrorActionPreference = 'SilentlyContinue'

# Inline the registry/filesystem discovery to keep the detection script self-contained
# (Intune detection scripts run independently of the install package)

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

if (-not $javaHome -or -not (Test-Path $javaHome)) {
    $parentDir = Join-Path $env:ProgramFiles 'Java'
    if (Test-Path $parentDir) {
        $jdkDir = Get-ChildItem -Path $parentDir -Directory -Filter 'jdk-*' |
            Sort-Object { [version]($_.Name -replace '^jdk-', '' -replace '[^0-9.]', '') } -ErrorAction SilentlyContinue |
            Select-Object -Last 1
        if ($jdkDir) {
            $javaHome = $jdkDir.FullName
        }
    }
}

if (-not $javaHome) { exit 1 }

$javaExe = Join-Path $javaHome 'bin\java.exe'
if (-not (Test-Path $javaExe)) { exit 1 }

$envJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
if (-not $envJavaHome) { exit 1 }

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$javaBin = (Join-Path $javaHome 'bin').TrimEnd('\', '/')
$pathEntries = $machinePath -split ';' | ForEach-Object { $_.TrimEnd('\', '/').Trim() }

if ($pathEntries -inotcontains $javaBin) { exit 1 }

Write-Output "JDK detected: $javaHome"
exit 0
