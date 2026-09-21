<#
.SYNOPSIS
    Machine state capture and delta generation.
.DESCRIPTION
    Captures state before and after installation so the build produces
    evidence of what actually changed rather than assuming the installer
    did what it claimed.
#>

Set-StrictMode -Version Latest

$script:UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-InstalledApplication {
    <#
    .SYNOPSIS
        Reads uninstall registration from both registry views.
    #>
    [CmdletBinding()]
    param()

    $applications = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($key in $script:UninstallKeys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }

        $view = if ($key -match 'WOW6432Node') { 'x86' } else { 'x64' }

        foreach ($item in (Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $properties -or -not $properties.PSObject.Properties.Name.Contains('DisplayName')) { continue }

            $applications.Add([PSCustomObject]@{
                DisplayName     = $properties.DisplayName
                DisplayVersion  = if ($properties.PSObject.Properties.Name -contains 'DisplayVersion') { $properties.DisplayVersion } else { $null }
                Publisher       = if ($properties.PSObject.Properties.Name -contains 'Publisher') { $properties.Publisher } else { $null }
                UninstallString = if ($properties.PSObject.Properties.Name -contains 'UninstallString') { $properties.UninstallString } else { $null }
                InstallLocation = if ($properties.PSObject.Properties.Name -contains 'InstallLocation') { $properties.InstallLocation } else { $null }
                ProductCode     = $item.PSChildName
                RegistryView    = $view
            })
        }
    }

    $applications.ToArray()
}

function Get-StateSnapshot {
    <#
    .SYNOPSIS
        Captures a point-in-time snapshot of machine state.
    .PARAMETER WatchPath
        Filesystem paths to enumerate. Enumeration is depth-limited to keep
        snapshots fast; pass the paths the package is expected to touch.
    #>
    [CmdletBinding()]
    param(
        [string[]]$WatchPath = @(
            "$env:ProgramFiles"
            "${env:ProgramFiles(x86)}"
            "$env:ProgramData"
        ),
        [string[]]$WatchRegistryKey = @(),
        [int]$Depth = 2
    )

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($path in ($WatchPath | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        Get-ChildItem -LiteralPath $path -Depth $Depth -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_.FullName) }
    }

    $registryValues = @{}
    foreach ($key in ($WatchRegistryKey | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue })) {
        $properties = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($properties) {
            foreach ($property in $properties.PSObject.Properties) {
                if ($property.Name -like 'PS*') { continue }
                $registryValues["$key\$($property.Name)"] = [string]$property.Value
            }
        }
    }

    $shortcutRoots = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
        "$env:Public\Desktop"
    )
    $shortcuts = [System.Collections.Generic.List[string]]::new()
    foreach ($root in ($shortcutRoots | Where-Object { Test-Path -LiteralPath $_ })) {
        Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
            ForEach-Object { $shortcuts.Add($_.FullName) }
    }

    [PSCustomObject]@{
        Timestamp            = (Get-Date).ToString('o')
        Applications         = @(Get-InstalledApplication)
        Files                = $files.ToArray()
        RegistryValues       = $registryValues
        Services             = @(Get-Service -ErrorAction SilentlyContinue |
                                 Select-Object Name, DisplayName, Status, StartType)
        ScheduledTasks       = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
                                 Select-Object TaskName, TaskPath, State)
        EnvironmentVariables = [Environment]::GetEnvironmentVariables('Machine')
        Path                 = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' |
                                 Where-Object { $_ })
        Shortcuts            = $shortcuts.ToArray()
    }
}

function Compare-StateSnapshot {
    <#
    .SYNOPSIS
        Produces the delta between two snapshots.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Before,
        [Parameter(Mandatory)][PSCustomObject]$After
    )

    $applicationsBefore = @($Before.Applications | ForEach-Object { "$($_.DisplayName)|$($_.DisplayVersion)|$($_.ProductCode)" })
    $applicationsAfter  = @($After.Applications  | ForEach-Object { "$($_.DisplayName)|$($_.DisplayVersion)|$($_.ProductCode)" })

    $servicesBefore = @($Before.Services | ForEach-Object { $_.Name })
    $servicesAfter  = @($After.Services  | ForEach-Object { $_.Name })

    $tasksBefore = @($Before.ScheduledTasks | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" })
    $tasksAfter  = @($After.ScheduledTasks  | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" })

    $registryKeysBefore = @($Before.RegistryValues.Keys)
    $registryKeysAfter  = @($After.RegistryValues.Keys)

    $changedRegistry = foreach ($key in ($registryKeysBefore | Where-Object { $_ -in $registryKeysAfter })) {
        if ($Before.RegistryValues[$key] -ne $After.RegistryValues[$key]) {
            [PSCustomObject]@{
                Key      = $key
                OldValue = $Before.RegistryValues[$key]
                NewValue = $After.RegistryValues[$key]
            }
        }
    }

    $environmentBefore = @($Before.EnvironmentVariables.Keys)
    $environmentAfter  = @($After.EnvironmentVariables.Keys)

    [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString('o')
        BeforeTimestamp = $Before.Timestamp
        AfterTimestamp  = $After.Timestamp
        Applications = [PSCustomObject]@{
            Added   = @($applicationsAfter  | Where-Object { $_ -notin $applicationsBefore })
            Removed = @($applicationsBefore | Where-Object { $_ -notin $applicationsAfter })
        }
        Files = [PSCustomObject]@{
            Added   = @($After.Files  | Where-Object { $_ -notin $Before.Files })
            Removed = @($Before.Files | Where-Object { $_ -notin $After.Files })
        }
        Registry = [PSCustomObject]@{
            Added   = @($registryKeysAfter  | Where-Object { $_ -notin $registryKeysBefore })
            Removed = @($registryKeysBefore | Where-Object { $_ -notin $registryKeysAfter })
            Changed = @($changedRegistry)
        }
        Services = [PSCustomObject]@{
            Added   = @($servicesAfter  | Where-Object { $_ -notin $servicesBefore })
            Removed = @($servicesBefore | Where-Object { $_ -notin $servicesAfter })
        }
        ScheduledTasks = [PSCustomObject]@{
            Added   = @($tasksAfter  | Where-Object { $_ -notin $tasksBefore })
            Removed = @($tasksBefore | Where-Object { $_ -notin $tasksAfter })
        }
        EnvironmentVariables = [PSCustomObject]@{
            Added   = @($environmentAfter  | Where-Object { $_ -notin $environmentBefore })
            Removed = @($environmentBefore | Where-Object { $_ -notin $environmentAfter })
        }
        Path = [PSCustomObject]@{
            Added   = @($After.Path  | Where-Object { $_ -notin $Before.Path })
            Removed = @($Before.Path | Where-Object { $_ -notin $After.Path })
        }
        Shortcuts = [PSCustomObject]@{
            Added   = @($After.Shortcuts  | Where-Object { $_ -notin $Before.Shortcuts })
            Removed = @($Before.Shortcuts | Where-Object { $_ -notin $After.Shortcuts })
        }
    }
}

function Save-InstallDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Delta,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $Delta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}

function Test-PostInstallState {
    <#
    .SYNOPSIS
        Validates the application itself against declared expectations.
    .PARAMETER Expectation
        A hashtable describing what the package is required to produce. Only
        the keys present are checked, so a package declares only what it needs.
        Supported keys: File, FileVersion, UninstallDisplayName, Service,
        RunningService, RegistryKey, Shortcut, PathEntry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Expectation)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Add-Result {
        param([string]$Category, [string]$Target, [bool]$Passed, [string]$Detail = '')
        $results.Add([PSCustomObject]@{
            Category = $Category
            Target   = $Target
            Passed   = $Passed
            Detail   = $Detail
        })
    }

    foreach ($file in @($Expectation['File'])) {
        if (-not $file) { continue }
        $exists = Test-Path -LiteralPath $file -PathType Leaf
        Add-Result -Category 'File' -Target $file -Passed $exists -Detail $(if ($exists) { 'Present' } else { 'Missing' })
    }

    if ($Expectation.ContainsKey('FileVersion')) {
        foreach ($entry in $Expectation['FileVersion'].GetEnumerator()) {
            $path = $entry.Key
            $expectedVersion = $entry.Value
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $actual = (Get-Item -LiteralPath $path).VersionInfo.FileVersion
                $matches = $actual -eq $expectedVersion
                Add-Result -Category 'FileVersion' -Target $path -Passed $matches -Detail "Expected $expectedVersion, found $actual"
            } else {
                Add-Result -Category 'FileVersion' -Target $path -Passed $false -Detail 'File missing'
            }
        }
    }

    $installed = Get-InstalledApplication
    foreach ($name in @($Expectation['UninstallDisplayName'])) {
        if (-not $name) { continue }
        $found = @($installed | Where-Object { $_.DisplayName -like $name })
        Add-Result -Category 'UninstallRegistration' -Target $name -Passed ($found.Count -gt 0) `
                   -Detail $(if ($found.Count -gt 0) { "Found: $($found[0].DisplayName) $($found[0].DisplayVersion)" } else { 'Not registered' })
    }

    foreach ($serviceName in @($Expectation['Service'])) {
        if (-not $serviceName) { continue }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        Add-Result -Category 'Service' -Target $serviceName -Passed ($null -ne $service) `
                   -Detail $(if ($service) { "Status: $($service.Status)" } else { 'Not installed' })
    }

    foreach ($serviceName in @($Expectation['RunningService'])) {
        if (-not $serviceName) { continue }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $running = $service -and $service.Status -eq 'Running'
        Add-Result -Category 'RunningService' -Target $serviceName -Passed $running `
                   -Detail $(if ($service) { "Status: $($service.Status)" } else { 'Not installed' })
    }

    foreach ($key in @($Expectation['RegistryKey'])) {
        if (-not $key) { continue }
        $exists = Test-Path -LiteralPath $key -ErrorAction SilentlyContinue
        Add-Result -Category 'RegistryKey' -Target $key -Passed $exists -Detail $(if ($exists) { 'Present' } else { 'Missing' })
    }

    foreach ($shortcut in @($Expectation['Shortcut'])) {
        if (-not $shortcut) { continue }
        $exists = Test-Path -LiteralPath $shortcut -PathType Leaf
        Add-Result -Category 'Shortcut' -Target $shortcut -Passed $exists -Detail $(if ($exists) { 'Present' } else { 'Missing' })
    }

    $machinePath = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';')
    foreach ($entry in @($Expectation['PathEntry'])) {
        if (-not $entry) { continue }
        $present = $machinePath -contains $entry
        Add-Result -Category 'PathEntry' -Target $entry -Passed $present -Detail $(if ($present) { 'Present' } else { 'Missing from machine PATH' })
    }

    $all = $results.ToArray()
    [PSCustomObject]@{
        Passed  = @($all | Where-Object { -not $_.Passed }).Count -eq 0
        Results = $all
    }
}
