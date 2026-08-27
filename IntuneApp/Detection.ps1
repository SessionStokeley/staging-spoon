#Requires -Version 5.1
<#
.SYNOPSIS
    Reusable Intune detection script for Win32 applications.
.DESCRIPTION
    Detects application presence using the method configured in Configuration.psd1.
    Produces Intune-compatible output: writes to stdout and exits 0 if detected.
    This script does NOT depend on $PSScriptRoot or the current working directory
    when executed standalone by Intune for detection purposes.
#>

param(
    [string]$ConfigurationPath
)

function Find-Configuration {
    param([string]$Hint)

    if ($Hint -and (Test-Path $Hint)) { return $Hint }

    $candidates = @(
        (Join-Path $PSScriptRoot 'Configuration.psd1')
    )
    if ($MyInvocation.ScriptName) {
        $candidates += (Join-Path (Split-Path $MyInvocation.ScriptName -Parent) 'Configuration.psd1')
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Invoke-Detection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$DetectionConfig
    )

    switch ($DetectionConfig.Type) {
        'File'     { return Test-FileDetection -Config $DetectionConfig }
        'Registry' { return Test-RegistryDetection -Config $DetectionConfig }
        'MSI'      { return Test-MSIDetection -Config $DetectionConfig }
        'Service'  { return Test-ServiceDetection -Config $DetectionConfig }
        'Custom'   { return Test-CustomDetection -Config $DetectionConfig }
        default {
            return [PSCustomObject]@{ Detected = $false; Detail = "Unknown detection type: $($DetectionConfig.Type)" }
        }
    }
}

function Compare-VersionString {
    [CmdletBinding()]
    param(
        [version]$Actual,
        [version]$Required,
        [string]$Comparison = 'GreaterThanOrEqual'
    )

    switch ($Comparison) {
        'Equal'              { return $Actual -eq $Required }
        'GreaterThan'        { return $Actual -gt $Required }
        'GreaterThanOrEqual' { return $Actual -ge $Required }
        'LessThan'           { return $Actual -lt $Required }
        'LessThanOrEqual'    { return $Actual -le $Required }
        default              { return $Actual -ge $Required }
    }
}

function Test-FileDetection {
    [CmdletBinding()]
    param([hashtable]$Config)

    $filePath = if ($Config.FileName) {
        Join-Path $Config.Path $Config.FileName
    } else {
        $Config.Path
    }

    if (-not (Test-Path $filePath)) {
        return [PSCustomObject]@{ Detected = $false; Detail = "File not found: $filePath" }
    }

    if ($Config.MinimumVersion) {
        try {
            $fileVersion = (Get-Item $filePath).VersionInfo.FileVersion
            if (-not $fileVersion) {
                $fileVersion = (Get-Item $filePath).VersionInfo.ProductVersion
            }
            if ($fileVersion) {
                $fileVersion = $fileVersion -replace '[^0-9.]', ''
                $comparison = if ($Config.VersionComparison) { $Config.VersionComparison } else { 'GreaterThanOrEqual' }
                $versionMatch = Compare-VersionString -Actual ([version]$fileVersion) -Required ([version]$Config.MinimumVersion) -Comparison $comparison

                if (-not $versionMatch) {
                    return [PSCustomObject]@{
                        Detected = $false
                        Detail   = "File found but version $fileVersion does not satisfy $comparison $($Config.MinimumVersion)"
                    }
                }
                return [PSCustomObject]@{
                    Detected = $true
                    Detail   = "File found: $filePath (Version: $fileVersion, $comparison $($Config.MinimumVersion))"
                }
            }
        }
        catch {
            return [PSCustomObject]@{
                Detected = $false
                Detail   = "Failed to read version from $filePath : $_"
            }
        }
    }

    return [PSCustomObject]@{ Detected = $true; Detail = "File found: $filePath" }
}

function Test-RegistryDetection {
    [CmdletBinding()]
    param([hashtable]$Config)

    $searchPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    if ($Config.RegistryPath) {
        if ($Config.ValueName) {
            try {
                $value = Get-ItemProperty -Path $Config.RegistryPath -Name $Config.ValueName -ErrorAction Stop
                $currentValue = $value.$($Config.ValueName)

                if ($Config.MinimumVersion -and $currentValue) {
                    $cleanVersion = $currentValue -replace '[^0-9.]', ''
                    if ($cleanVersion) {
                        $comparison = if ($Config.VersionComparison) { $Config.VersionComparison } else { 'GreaterThanOrEqual' }
                        $versionMatch = Compare-VersionString -Actual ([version]$cleanVersion) -Required ([version]$Config.MinimumVersion) -Comparison $comparison
                        if ($versionMatch) {
                            return [PSCustomObject]@{ Detected = $true; Detail = "Registry key found: $($Config.RegistryPath) Value: $currentValue ($comparison $($Config.MinimumVersion))" }
                        }
                        return [PSCustomObject]@{ Detected = $false; Detail = "Registry version $currentValue does not satisfy $comparison $($Config.MinimumVersion)" }
                    }
                }
                return [PSCustomObject]@{ Detected = $true; Detail = "Registry key found: $($Config.RegistryPath) Value: $currentValue" }
            }
            catch {
                return [PSCustomObject]@{ Detected = $false; Detail = "Registry key not found: $($Config.RegistryPath)\$($Config.ValueName)" }
            }
        }

        if (Test-Path $Config.RegistryPath) {
            return [PSCustomObject]@{ Detected = $true; Detail = "Registry path exists: $($Config.RegistryPath)" }
        }
        return [PSCustomObject]@{ Detected = $false; Detail = "Registry path not found: $($Config.RegistryPath)" }
    }

    if ($Config.DisplayName) {
        foreach ($path in $searchPaths) {
            $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*$($Config.DisplayName)*" }
            if ($entries) {
                $entry = $entries | Select-Object -First 1
                return [PSCustomObject]@{ Detected = $true; Detail = "Found in registry: $($entry.DisplayName) $($entry.DisplayVersion)" }
            }
        }
        return [PSCustomObject]@{ Detected = $false; Detail = "Not found in registry: $($Config.DisplayName)" }
    }

    return [PSCustomObject]@{ Detected = $false; Detail = "Registry detection requires RegistryPath or DisplayName" }
}

function Test-MSIDetection {
    [CmdletBinding()]
    param([hashtable]$Config)

    if (-not $Config.ProductCode) {
        return [PSCustomObject]@{ Detected = $false; Detail = "MSI detection requires ProductCode" }
    }

    $productCode = $Config.ProductCode
    $searchPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
    )

    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            $entry = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            return [PSCustomObject]@{
                Detected = $true
                Detail   = "MSI product found: $productCode ($($entry.DisplayName) $($entry.DisplayVersion))"
            }
        }
    }

    return [PSCustomObject]@{ Detected = $false; Detail = "MSI product not found: $productCode" }
}

function Test-ServiceDetection {
    [CmdletBinding()]
    param([hashtable]$Config)

    if (-not $Config.ServiceName) {
        return [PSCustomObject]@{ Detected = $false; Detail = "Service detection requires ServiceName" }
    }

    $service = Get-Service -Name $Config.ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        return [PSCustomObject]@{ Detected = $true; Detail = "Service found: $($Config.ServiceName) (Status: $($service.Status))" }
    }

    return [PSCustomObject]@{ Detected = $false; Detail = "Service not found: $($Config.ServiceName)" }
}

function Test-CustomDetection {
    [CmdletBinding()]
    param([hashtable]$Config)

    if (-not $Config.CustomScript) {
        return [PSCustomObject]@{ Detected = $false; Detail = "Custom detection requires CustomScript" }
    }

    try {
        $sb = [scriptblock]::Create($Config.CustomScript)
        $result = & $sb
        $detected = [bool]$result
        return [PSCustomObject]@{ Detected = $detected; Detail = "Custom detection result: $detected" }
    }
    catch {
        return [PSCustomObject]@{ Detected = $false; Detail = "Custom detection failed: $_" }
    }
}

# --- Main execution when run standalone by Intune ---
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    $configPath = Find-Configuration -Hint $ConfigurationPath

    if (-not $configPath -or -not (Test-Path $configPath)) {
        Write-Output "Detection FAILED: Configuration.psd1 not found."
        exit 1
    }

    try {
        $config = Import-PowerShellDataFile -Path $configPath
    }
    catch {
        Write-Output "Detection FAILED: Unable to parse Configuration.psd1 - $_"
        exit 1
    }

    if (-not $config.Detection) {
        Write-Output "Detection FAILED: No Detection section in Configuration.psd1"
        exit 1
    }

    $result = Invoke-Detection -DetectionConfig $config.Detection

    if ($result.Detected) {
        Write-Output "Detected: $($result.Detail)"
        exit 0
    }
    else {
        exit 1
    }
}
