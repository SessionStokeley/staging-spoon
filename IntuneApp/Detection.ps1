#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

try {
    $Config = Import-PowerShellDataFile (Join-Path $ScriptDir 'Configuration.psd1')

    # Name the actual problem: without these guards a missing section surfaces
    # as "you cannot call a method on a null-valued expression", which tells
    # whoever reads the agent log nothing.
    $detection = $Config.Detection
    if (-not $detection) {
        throw 'Configuration.psd1 has no Detection section.'
    }
    if (-not $detection.Type) {
        throw 'Configuration.psd1 has a Detection section but no Detection.Type.'
    }

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
            Write-Error "Custom detection is configured but Detection.ScriptBlock is missing."
            exit 1
        }
    }

    else {
        Write-Error "Unknown detection type: $detectionType"
        exit 1
    }
}
catch {
    # Intune's contract is binary: exit 0 means detected, anything else means
    # not detected. A broken configuration must therefore still exit non-zero,
    # but it must not do so silently - otherwise it is indistinguishable from
    # "not installed" and Intune reinstalls in a loop with nothing to diagnose.
    #
    # The reason goes to stderr, which Intune captures and which can never be
    # mistaken for the stdout that signals a successful detection.
    #
    # Written directly rather than through Write-Error: that wraps the text in
    # a multi-line diagnostic block, which is hard to read in an agent log.
    [Console]::Error.WriteLine("Detection could not run: $($_.Exception.Message)")
    exit 1
}
