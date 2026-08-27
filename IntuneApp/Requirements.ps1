#Requires -Version 5.1
<#
.SYNOPSIS
    Generic requirement validation for Intune Win32 deployments.
.DESCRIPTION
    Validates system requirements defined in Configuration.psd1 before installation.
    Returns $true if all requirements are met, $false otherwise.
    Architecture is validated as an array of accepted values.
#>

function Test-Requirements {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration
    )

    $requirements = $Configuration.Requirements
    if (-not $requirements) {
        Write-Log -Message "No requirements configured; skipping validation." -Level 'Info'
        return $true
    }

    $allMet = $true
    $results = @()

    # Windows version
    if ($requirements.MinimumWindowsVersion) {
        $result = Test-WindowsVersion -MinimumVersion $requirements.MinimumWindowsVersion
        $results += $result
        if (-not $result.Met) { $allMet = $false }
    }

    # Windows edition
    if ($requirements.WindowsEdition) {
        $result = Test-WindowsEdition -RequiredEdition $requirements.WindowsEdition
        $results += $result
        if (-not $result.Met) { $allMet = $false }
    }

    # Architecture (array support)
    if ($requirements.Architecture) {
        $result = Test-Architecture -AcceptedArchitectures $requirements.Architecture
        $results += $result
        if (-not $result.Met) { $allMet = $false }
    }

    # Disk space
    if ($requirements.MinimumDiskSpaceGB) {
        $result = Test-DiskSpace -MinimumGB $requirements.MinimumDiskSpaceGB
        $results += $result
        if (-not $result.Met) { $allMet = $false }
    }

    # RAM
    if ($requirements.MinimumRAMGB) {
        $result = Test-RAM -MinimumGB $requirements.MinimumRAMGB
        $results += $result
        if (-not $result.Met) { $allMet = $false }
    }

    # CPU architecture
    if ($requirements.CPUArchitecture) {
        $result = Test-CPUArchitecture -RequiredArchitecture $requirements.CPUArchitecture
        $results += $result
        if (-not $result.Met) { $allMet = $false }
    }

    # Device type
    if ($requirements.DeviceType) {
        $result = Test-DeviceType -RequiredType $requirements.DeviceType
        $results += $result
        if (-not $result.Met) { $allMet = $false }
    }

    # Custom requirements
    if ($requirements.CustomRequirements) {
        foreach ($customReq in $requirements.CustomRequirements) {
            $result = Test-CustomRequirement -ScriptBlockString $customReq
            $results += $result
            if (-not $result.Met) { $allMet = $false }
        }
    }

    foreach ($r in $results) {
        $level = if ($r.Met) { 'Info' } else { 'Error' }
        Write-Log -Message "Requirement [$($r.Name)]: $($r.Detail)" -Level $level
    }

    return $allMet
}

function Test-WindowsVersion {
    [CmdletBinding()]
    param([string]$MinimumVersion)

    $currentVersion = [System.Environment]::OSVersion.Version
    $requiredVersion = [version]$MinimumVersion

    $met = $currentVersion -ge $requiredVersion
    return [PSCustomObject]@{
        Name   = 'Windows Version'
        Met    = $met
        Detail = "Required: >= $MinimumVersion | Current: $currentVersion | $(if($met){'PASS'}else{'FAIL'})"
    }
}

function Test-WindowsEdition {
    [CmdletBinding()]
    param([string]$RequiredEdition)

    $currentEdition = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
    $met = $currentEdition -like "*$RequiredEdition*"
    return [PSCustomObject]@{
        Name   = 'Windows Edition'
        Met    = $met
        Detail = "Required: $RequiredEdition | Current: $currentEdition | $(if($met){'PASS'}else{'FAIL'})"
    }
}

function Test-Architecture {
    [CmdletBinding()]
    param($AcceptedArchitectures)

    # Normalize to array
    if ($AcceptedArchitectures -is [string]) {
        $AcceptedArchitectures = @($AcceptedArchitectures)
    }

    $currentArch = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }

    $met = $currentArch -in $AcceptedArchitectures
    # x64 systems can run x86 applications
    if (-not $met -and $currentArch -eq 'x64' -and 'x86' -in $AcceptedArchitectures) {
        $met = $true
    }

    return [PSCustomObject]@{
        Name   = 'Architecture'
        Met    = $met
        Detail = "Accepted: $($AcceptedArchitectures -join ', ') | Current: $currentArch | $(if($met){'PASS'}else{'FAIL'})"
    }
}

function Test-DiskSpace {
    [CmdletBinding()]
    param([double]$MinimumGB)

    $systemDrive = $env:SystemDrive
    if (-not $systemDrive) { $systemDrive = 'C:' }
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'"
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    $met = $freeGB -ge $MinimumGB
    return [PSCustomObject]@{
        Name   = 'Disk Space'
        Met    = $met
        Detail = "Required: >= ${MinimumGB}GB | Available: ${freeGB}GB | $(if($met){'PASS'}else{'FAIL'})"
    }
}

function Test-RAM {
    [CmdletBinding()]
    param([double]$MinimumGB)

    $totalRAM = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
    $met = $totalRAM -ge $MinimumGB
    return [PSCustomObject]@{
        Name   = 'RAM'
        Met    = $met
        Detail = "Required: >= ${MinimumGB}GB | Installed: ${totalRAM}GB | $(if($met){'PASS'}else{'FAIL'})"
    }
}

function Test-CPUArchitecture {
    [CmdletBinding()]
    param([string]$RequiredArchitecture)

    $cpu = (Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).Architecture
    $archMap = @{ 0 = 'x86'; 5 = 'ARM'; 9 = 'AMD64'; 12 = 'ARM64' }
    $currentArch = if ($archMap.ContainsKey($cpu)) { $archMap[$cpu] } else { "Unknown ($cpu)" }
    $met = $currentArch -eq $RequiredArchitecture
    return [PSCustomObject]@{
        Name   = 'CPU Architecture'
        Met    = $met
        Detail = "Required: $RequiredArchitecture | Current: $currentArch | $(if($met){'PASS'}else{'FAIL'})"
    }
}

function Test-DeviceType {
    [CmdletBinding()]
    param([string]$RequiredType)

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem

    $isWorkstation = $cs.DomainRole -le 1 -or $cs.DomainRole -eq 3
    $isServer = $cs.DomainRole -ge 4

    $met = switch ($RequiredType) {
        'Workstation' { $isWorkstation }
        'Server'      { $isServer }
        'Laptop'      { $cs.PCSystemType -eq 2 }
        'Desktop'     { $cs.PCSystemType -eq 1 }
        default       { $true }
    }

    return [PSCustomObject]@{
        Name   = 'Device Type'
        Met    = $met
        Detail = "Required: $RequiredType | SystemType: $($cs.PCSystemType) DomainRole: $($cs.DomainRole) | $(if($met){'PASS'}else{'FAIL'})"
    }
}

function Test-CustomRequirement {
    [CmdletBinding()]
    param([string]$ScriptBlockString)

    try {
        $sb = [scriptblock]::Create($ScriptBlockString)
        $result = & $sb
        $met = [bool]$result
    }
    catch {
        $met = $false
        Write-Log -Message "Custom requirement evaluation failed: $_" -Level 'Error'
    }

    return [PSCustomObject]@{
        Name   = 'Custom Requirement'
        Met    = $met
        Detail = "Script: $ScriptBlockString | $(if($met){'PASS'}else{'FAIL'})"
    }
}
