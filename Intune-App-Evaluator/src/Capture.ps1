<#
.SYNOPSIS
    Before/after capture of Windows state, and attribution of the diff to an app.
.DESCRIPTION
    Capturing the machine, installing, capturing again and diffing gives far
    better evidence than reading an installer: what actually changed is what the
    application needs. The snapshot reader is Windows-only; the diff and the
    attribution of changes to the application are pure and tested anywhere.
#>

Set-StrictMode -Version Latest

function New-SystemStateSnapshot {
    <#
    .SYNOPSIS
        A point-in-time picture of the integration-relevant Windows state.
    .DESCRIPTION
        On Windows it reads the live machine through the inspector adapters. Off
        Windows it returns an empty snapshot, so a caller can still construct and
        diff snapshots supplied from fixtures.
    #>
    [CmdletBinding()]
    param()

    $snapshot = [PSCustomObject]@{
        TakenAt      = (Get-Date).ToString('o')
        Applications = @()
        MachinePath  = ''
        UserPath     = ''
        Shortcuts    = @()
    }

    if (-not (Test-WindowsPlatform)) { return $snapshot }

    $snapshot.Applications = @(Read-UninstallRegistry)
    $snapshot.MachinePath  = Read-PathValue -Scope 'Machine'
    $snapshot.UserPath     = Read-PathValue -Scope 'User'

    $folders = @(
        @{ Folder = (Join-Path $env:PUBLIC 'Desktop');                                          Location = 'PublicDesktop'; Machine = $true }
        @{ Folder = (Join-Path $env:USERPROFILE 'Desktop');                                     Location = 'UserDesktop';   Machine = $false }
        @{ Folder = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs');       Location = 'CommonStartMenu'; Machine = $true }
        @{ Folder = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs');           Location = 'UserStartMenu'; Machine = $false }
    )
    $shortcuts = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $folders) {
        if ($f.Folder -and (Test-Path -LiteralPath $f.Folder)) {
            foreach ($sc in (Read-ShortcutsIn -Folder $f.Folder -Location $f.Location -MachineWide $f.Machine)) { $shortcuts.Add($sc) }
        }
    }
    $snapshot.Shortcuts = $shortcuts.ToArray()
    $snapshot
}

function Compare-SystemStateSnapshot {
    <#
    .SYNOPSIS
        What appeared between two snapshots, by category.
    .DESCRIPTION
        Pure: a caller diffs a real before/after or two fixtures identically.
        Applications are keyed by their registry key, PATH by entry, shortcuts
        by their .lnk path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Before,
        [Parameter(Mandatory)][PSCustomObject]$After
    )

    $beforeApps = @{}
    foreach ($a in @($Before.Applications)) { if ($a.PSObject.Properties.Name -contains 'KeyName') { $beforeApps[$a.KeyName] = $true } }
    $addedApps = @(@($After.Applications) | Where-Object { $_.PSObject.Properties.Name -contains 'KeyName' -and -not $beforeApps.ContainsKey($_.KeyName) })

    $addedMachinePath = @(Compare-PathValues -Before $Before.MachinePath -After $After.MachinePath | ForEach-Object { [PSCustomObject]@{ Entry = $_; Scope = 'Machine' } })
    $addedUserPath    = @(Compare-PathValues -Before $Before.UserPath    -After $After.UserPath    | ForEach-Object { [PSCustomObject]@{ Entry = $_; Scope = 'User' } })

    $beforeLinks = @{}
    foreach ($s in @($Before.Shortcuts)) { if ($s.PSObject.Properties.Name -contains 'Path') { $beforeLinks[$s.Path.ToLowerInvariant()] = $true } }
    $addedShortcuts = @(@($After.Shortcuts) | Where-Object { $_.PSObject.Properties.Name -contains 'Path' -and -not $beforeLinks.ContainsKey($_.Path.ToLowerInvariant()) })

    [PSCustomObject]@{
        AddedApplications = $addedApps
        AddedPathEntries  = @($addedMachinePath + $addedUserPath)
        AddedShortcuts    = $addedShortcuts
    }
}

function Compare-PathValues {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Before, [AllowEmptyString()][string]$After)
    $beforeSet = @{}
    foreach ($e in @(($Before -split ';') | Where-Object { $_.Trim() })) { $beforeSet[$e.Trim().TrimEnd('\','/').ToLowerInvariant()] = $true }
    @(($After -split ';') | Where-Object { $_.Trim() } | Where-Object {
        -not $beforeSet.ContainsKey($_.Trim().TrimEnd('\','/').ToLowerInvariant())
    } | ForEach-Object { $_.Trim() })
}

function Select-ApplicationChanges {
    <#
    .SYNOPSIS
        Narrows a capture diff to the changes that belong to the application.
    .DESCRIPTION
        The added PATH entries under the install location, and the added
        shortcuts whose target is the application, are the ones to carry into
        the package; other software installed in the same window is left out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Diff,
        [string]$Executable = '',
        [string]$InstallLocation = '',
        [string]$ApplicationName = ''
    )

    $pathEntries = @()
    if ($InstallLocation) {
        $pathEntries = @($Diff.AddedPathEntries | Where-Object {
            $e = $_.Entry.TrimEnd('\','/').ToLowerInvariant()
            $root = $InstallLocation.TrimEnd('\','/').ToLowerInvariant()
            $e -eq $root -or $e.StartsWith($root + '\') -or $e.StartsWith($root + '/')
        })
    }

    $shortcuts = @(Select-ArtifactsForApp -Items $Diff.AddedShortcuts -Executable $Executable -InstallLocation $InstallLocation -ApplicationName $ApplicationName)

    [PSCustomObject]@{
        PathEntries = $pathEntries
        Shortcuts   = $shortcuts
    }
}
