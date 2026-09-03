#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

try {
    $Config = Import-PowerShellDataFile (Join-Path $ScriptDir 'Configuration.psd1')
    $detection = $Config.Detection
    $detectionType = $detection.Type.ToUpper()

    # --- File Detection ---
    if ($detectionType -eq 'FILE') {
        $fullPath = Join-Path $detection.Path $detection.FileName
        if (-not (Test-Path $fullPath)) {
            exit 1
        }

        if ($detection.MinimumVersion) {
            $fileVersion = (Get-Item $fullPath).VersionInfo.FileVersion
            if (-not $fileVersion) {
                exit 1
            }
            if ([version]$fileVersion -lt [version]$detection.MinimumVersion) {
                exit 1
            }
        }

        Write-Output "Detected: $fullPath"
        exit 0
    }

    # --- Registry Detection ---
    elseif ($detectionType -eq 'REGISTRY') {
        $regPath = $detection.RegistryPath
        if (-not (Test-Path $regPath)) {
            exit 1
        }

        if ($detection.ValueName) {
            $regValue = Get-ItemProperty -Path $regPath -Name $detection.ValueName -ErrorAction SilentlyContinue
            if (-not $regValue) {
                exit 1
            }

            if ($detection.ExpectedValue) {
                $actual = $regValue.($detection.ValueName)
                if ($actual -ne $detection.ExpectedValue) {
                    exit 1
                }
            }
        }

        Write-Output "Detected via registry: $regPath"
        exit 0
    }

    # --- MSI Detection ---
    elseif ($detectionType -eq 'MSI') {
        $productCode = $detection.ProductCode
        if (-not $productCode) {
            exit 1
        }

        $uninstallPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
        )

        $found = $false
        foreach ($path in $uninstallPaths) {
            if (Test-Path $path) {
                $found = $true
                break
            }
        }

        if ($found) {
            Write-Output "Detected MSI: $productCode"
            exit 0
        }
        else {
            exit 1
        }
    }

    # --- Custom Detection ---
    elseif ($detectionType -eq 'CUSTOM') {
        if ($detection.ScriptBlock) {
            $result = & $detection.ScriptBlock
            if ($result) {
                Write-Output "Detected via custom check"
                exit 0
            }
            else {
                exit 1
            }
        }
        else {
            exit 1
        }
    }

    else {
        Write-Error "Unknown detection type: $detectionType"
        exit 1
    }
}
catch {
    exit 1
}
