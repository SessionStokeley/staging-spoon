<#
.SYNOPSIS
    Inspects the installed application on the live system, not just its installer.
.DESCRIPTION
    The selection and parsing logic - which ARP entry is the application, which
    executable is the main one, which PATH entries and shortcuts and registry
    verbs belong to it - is kept separate from the functions that read the live
    machine (the uninstall registry, the machine PATH, .lnk files through COM,
    the file-class registry), which feed those selectors.
#>

Set-StrictMode -Version Latest

# --- Pure selection and parsing ---------------------------------------------

function Select-ArpApplication {
    <#
    .SYNOPSIS
        Chooses the uninstall-registry entry that is the named application.
    .DESCRIPTION
        Given the entries read from Add/Remove Programs and a name (a plain name
        or a wildcard), returns the best match: an exact name wins over a prefix,
        a prefix over a substring, and an entry with a real uninstall string
        over one without. Returns nothing rather than guessing when none match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$Name
    )

    $pattern = $Name
    $needle  = ($Name -replace '[\*\?]', '').Trim().ToLowerInvariant()

    $scored = foreach ($record in $Records) {
        if ($null -eq $record) { continue }
        $display = if ($record.PSObject.Properties.Name -contains 'DisplayName') { [string]$record.DisplayName } else { '' }
        if (-not $display) { continue }
        $lower = $display.ToLowerInvariant()

        $score = 0
        if ($lower -eq $needle) { $score = 100 }
        elseif ($display -like $pattern) { $score = 80 }
        elseif ($lower.StartsWith($needle)) { $score = 60 }
        elseif ($needle -and $lower.Contains($needle)) { $score = 40 }
        else { continue }

        $hasUninstall = ($record.PSObject.Properties.Name -contains 'UninstallString' -and $record.UninstallString) -or
                        ($record.PSObject.Properties.Name -contains 'QuietUninstallString' -and $record.QuietUninstallString)
        if ($hasUninstall) { $score += 5 }

        [PSCustomObject]@{ Record = $record; Score = $score }
    }

    $best = @($scored | Sort-Object -Property Score -Descending | Select-Object -First 1)
    if ($best.Count -eq 0) { return $null }
    $best[0].Record
}

function Get-MsiProductCode {
    <#
    .SYNOPSIS
        The MSI product code when an ARP key name is a GUID, else nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$KeyName)
    if ($KeyName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { return $KeyName }
    ''
}

function Resolve-MainExecutable {
    <#
    .SYNOPSIS
        Picks the application's main executable from the evidence available.
    .DESCRIPTION
        DisplayIcon in the ARP entry is the strongest signal - vendors point it
        at the launchable executable. Failing that, an executable whose name
        resembles the application, then one in a bin directory, then the only
        executable present. Returns the path and why it was chosen, or nothing.
    #>
    [CmdletBinding()]
    param(
        [string]$DisplayIcon = '',
        [string]$InstallLocation = '',
        [string]$ApplicationName = '',
        [AllowEmptyCollection()][string[]]$Executables = @()
    )

    if ($DisplayIcon) {
        # DisplayIcon may carry a ,index suffix; the path is before the comma.
        $iconPath = ($DisplayIcon -split ',')[0].Trim('"')
        if ($iconPath -match '\.exe$') {
            return [PSCustomObject]@{ Path = $iconPath; Reason = 'ARP DisplayIcon points at it'; Confidence = 'High' }
        }
    }

    $stem = ($ApplicationName -replace '[^\w]', '').ToLowerInvariant()
    if ($stem) {
        foreach ($exe in $Executables) {
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($exe).ToLowerInvariant() -replace '[^\w]', ''
            if ($leaf -and ($stem.Contains($leaf) -or $leaf.Contains($stem))) {
                return [PSCustomObject]@{ Path = $exe; Reason = 'executable name matches the application'; Confidence = 'Medium' }
            }
        }
    }

    $binExe = @($Executables | Where-Object { $_ -match '[\\/]bin[\\/]' })
    if ($binExe.Count -eq 1) {
        return [PSCustomObject]@{ Path = $binExe[0]; Reason = 'only executable under a bin directory'; Confidence = 'Medium' }
    }

    if (@($Executables).Count -eq 1) {
        return [PSCustomObject]@{ Path = $Executables[0]; Reason = 'only executable in the install location'; Confidence = 'Medium' }
    }

    $null
}

function Split-PathList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PathValue)
    @($PathValue -split ';' | Where-Object { $_.Trim() })
}

function Select-PathEntriesUnder {
    <#
    .SYNOPSIS
        The PATH entries that live under the application's install location.
    .DESCRIPTION
        A live diff proves the installer added an entry; this identifies which
        current PATH entries belong to the application by directory containment,
        case-insensitively. Returns each with the scope it was found in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PathValue,
        [Parameter(Mandatory)][string]$InstallLocation,
        [string]$Scope = 'Machine'
    )

    if (-not $InstallLocation) { return @() }
    $root = $InstallLocation.TrimEnd('\', '/').ToLowerInvariant()

    @(Split-PathList -PathValue $PathValue | Where-Object {
        $e = $_.Trim().TrimEnd('\', '/').ToLowerInvariant()
        $e -eq $root -or $e.StartsWith($root + '\') -or $e.StartsWith($root + '/')
    } | ForEach-Object {
        [PSCustomObject]@{ Entry = $_.Trim(); Scope = $Scope }
    })
}

function Select-ArtifactsForApp {
    <#
    .SYNOPSIS
        Keeps the shortcuts, verbs or associations whose target is the app.
    .DESCRIPTION
        One matcher for every kind of integration artifact. Each observed item
        carries a target path or command; an item is the application's when that
        target is the main executable, sits under the install location, or names
        the application. Nothing matches on name alone unless asked, so an
        unrelated handler is never captured as the package's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [string]$Executable = '',
        [string]$InstallLocation = '',
        [string]$ApplicationName = ''
    )

    $exe   = $Executable.ToLowerInvariant()
    $exeLeaf = if ($Executable) { (Split-Path -Leaf $Executable).ToLowerInvariant() } else { '' }
    $root  = if ($InstallLocation) { $InstallLocation.TrimEnd('\', '/').ToLowerInvariant() } else { '' }
    $name  = $ApplicationName.ToLowerInvariant()

    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }
        $target = ''
        foreach ($prop in @('Target', 'Command', 'Executable')) {
            if ($item.PSObject.Properties.Name -contains $prop -and $item.$prop) { $target = ([string]$item.$prop).ToLowerInvariant(); break }
        }
        if (-not $target) { continue }

        $reasons = [System.Collections.Generic.List[string]]::new()
        if ($exe -and $target.Contains($exe)) { $reasons.Add('target is the main executable') }
        elseif ($exeLeaf -and $target.Contains($exeLeaf)) { $reasons.Add('target runs the executable by name') }
        if ($root -and $target.Contains($root)) { $reasons.Add('target is under the install location') }
        if ($name -and $target.Contains($name)) { $reasons.Add('target names the application') }

        if ($reasons.Count -gt 0) {
            $enriched = $item.PSObject.Copy()
            Add-Member -InputObject $enriched -NotePropertyName 'Evidence' -NotePropertyValue $reasons.ToArray() -Force
            $kept.Add($enriched)
        }
    }
    $kept.ToArray()
}

function Test-RequiresElevation {
    <#
    .SYNOPSIS
        Whether an installer or its command suggests it needs elevation.
    #>
    [CmdletBinding()]
    param([string]$InstallLocation = '', [string]$UninstallString = '')

    # Installing under a machine-wide location is the strongest ordinary signal
    # that the installer wrote where only an administrator can.
    $machineRoots = @('c:\program files', 'c:\programdata', 'c:\windows')
    $loc = $InstallLocation.ToLowerInvariant()
    foreach ($rootPath in $machineRoots) {
        if ($loc.StartsWith($rootPath)) {
            return [PSCustomObject]@{ RequiresElevation = $true; Reason = "installs under $rootPath, which needs administrator rights" }
        }
    }
    [PSCustomObject]@{ RequiresElevation = $false; Reason = 'installs outside machine-wide locations; may run per-user' }
}

# --- Windows live adapters (Windows only) -----------------------------------

function Read-UninstallRegistry {
    <#
    .SYNOPSIS
        Reads the Add/Remove Programs entries from all three hives.
    #>
    [CmdletBinding()]
    param()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        foreach ($item in (Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or $p.PSObject.Properties.Name -notcontains 'DisplayName') { continue }
            $records.Add([PSCustomObject]@{
                KeyName              = $item.PSChildName
                Hive                 = $key
                DisplayName          = $p.DisplayName
                Publisher            = $(if ($p.PSObject.Properties.Name -contains 'Publisher') { $p.Publisher } else { '' })
                DisplayVersion       = $(if ($p.PSObject.Properties.Name -contains 'DisplayVersion') { $p.DisplayVersion } else { '' })
                InstallLocation      = $(if ($p.PSObject.Properties.Name -contains 'InstallLocation') { $p.InstallLocation } else { '' })
                DisplayIcon          = $(if ($p.PSObject.Properties.Name -contains 'DisplayIcon') { $p.DisplayIcon } else { '' })
                UninstallString      = $(if ($p.PSObject.Properties.Name -contains 'UninstallString') { $p.UninstallString } else { '' })
                QuietUninstallString = $(if ($p.PSObject.Properties.Name -contains 'QuietUninstallString') { $p.QuietUninstallString } else { '' })
                WindowsInstaller     = $(if ($p.PSObject.Properties.Name -contains 'WindowsInstaller') { [bool]$p.WindowsInstaller } else { $false })
            })
        }
    }
    $records.ToArray()
}

function Read-PathValue {
    [CmdletBinding()]
    param([ValidateSet('Machine', 'User')][string]$Scope = 'Machine')
    [string][Environment]::GetEnvironmentVariable('Path', $Scope)
}

function Read-ExecutablesUnder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallLocation, [int]$Depth = 3)
    if (-not $InstallLocation -or -not (Test-Path -LiteralPath $InstallLocation)) { return @() }
    @(Get-ChildItem -LiteralPath $InstallLocation -Recurse -Depth $Depth -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
}

function Read-ShortcutTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $s = $shell.CreateShortcut($Path)
        [PSCustomObject]@{
            Path = $Path; Name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            Target = $s.TargetPath; Arguments = $s.Arguments
            WorkingDirectory = $s.WorkingDirectory; Icon = $s.IconLocation
        }
    } finally { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
}

function Read-ShortcutsIn {
    <#
    .SYNOPSIS
        Reads every .lnk in a folder, tagged machine-wide or per-user.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder, [string]$Location = 'Unknown', [bool]$MachineWide = $false)
    if (-not (Test-Path -LiteralPath $Folder)) { return @() }
    @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sc = Read-ShortcutTarget -Path $_.FullName
        if ($sc) {
            Add-Member -InputObject $sc -NotePropertyName 'Location' -NotePropertyValue $Location -Force
            Add-Member -InputObject $sc -NotePropertyName 'MachineWide' -NotePropertyValue $MachineWide -Force
            $sc
        }
    })
}
