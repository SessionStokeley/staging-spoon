<#
.SYNOPSIS
    Windows application integrations as owned, reversible package resources.
.DESCRIPTION
    Four integration kinds a package can establish, verify and remove:
    a PATH/environment entry, a desktop shortcut, a context-menu action, and a
    file association. Each is handled under one of three modes:

        DISABLED  the package does nothing with it.
        VALIDATE  the vendor installer owns it; the package only verifies it
                  exists and is correct, and never creates or removes it.
        MANAGE    the package creates it, records that it owns it, and removes
                  only what it recorded during uninstall.

    The decisions that make these safe - never removing a resource the package
    did not create, never adding a PATH entry twice, resolving where a resource
    lives under SYSTEM rather than assuming the calling user's profile - are
    pure functions tested on any platform. The raw operating-system calls (the
    COM shortcut, the registry, the machine PATH) are thin adapters guarded by
    Test-WindowsPlatform, because only Windows has them to call.

    This file is self-contained so it can be staged into a package and run on
    the target beside Install.ps1 and Uninstall.ps1.
#>

Set-StrictMode -Version Latest

# Platform probe, redefined only if the package staged this file without
# Platform.ps1 beside it. Test-WindowsPlatform from Platform.ps1 wins when both
# are present, because dot-sourcing order leaves the last definition in force.
if (-not (Get-Command -Name 'Test-WindowsPlatform' -ErrorAction SilentlyContinue)) {
    function Test-WindowsPlatform {
        $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
        if ($null -eq $variable) { return $true }
        [bool]$variable.Value
    }
}

$script:IntegrationModes = @('DISABLED', 'VALIDATE', 'MANAGE')
$script:IntegrationKinds = @('Path', 'Shortcut', 'ContextMenu', 'FileAssociation')

# --- PATH entry logic (pure) -------------------------------------------------

function Get-NormalizedPathEntry {
    <#
    .SYNOPSIS
        A PATH entry reduced to the form two entries are equal by.
    .DESCRIPTION
        Windows PATH matching is case-insensitive and indifferent to a trailing
        separator, so C:\App\bin, c:\app\bin and C:\App\bin\ are one entry. The
        comparison form is lower-cased with any trailing slashes removed;
        expandable references such as %ProgramFiles% are compared as written,
        since that is how they sit in the registry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Entry)

    $trimmed = $Entry.Trim()
    $trimmed = $trimmed.TrimEnd('\', '/')
    $trimmed.ToLowerInvariant()
}

function Split-PathValue {
    <#
    .SYNOPSIS
        Splits a PATH string into its entries, dropping the empty spans a
        trailing or doubled semicolon leaves behind.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PathValue)

    @($PathValue -split ';' | Where-Object { $_.Trim() })
}

function Add-PathContribution {
    <#
    .SYNOPSIS
        Adds an entry to a PATH value unless an equal one is already present.
    .DESCRIPTION
        Existing entries are preserved in their original order and spelling; the
        new entry is appended only when no existing entry normalises to the same
        thing. Returns the resulting value and whether it changed, so a caller
        can record ownership only when the entry was genuinely added.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PathValue,
        [Parameter(Mandatory)][string]$Entry
    )

    $existing = Split-PathValue -PathValue $PathValue
    $target   = Get-NormalizedPathEntry -Entry $Entry

    foreach ($item in $existing) {
        if ((Get-NormalizedPathEntry -Entry $item) -eq $target) {
            return [PSCustomObject]@{ Value = $PathValue; Added = $false; Entries = $existing }
        }
    }

    $result = @($existing) + $Entry
    [PSCustomObject]@{ Value = ($result -join ';'); Added = $true; Entries = $result }
}

function Remove-PathContribution {
    <#
    .SYNOPSIS
        Removes one entry from a PATH value, leaving every other entry as it was.
    .DESCRIPTION
        Only entries equal to the one named are dropped. An entry the package
        never added is never removed, because removal is driven by what
        ownership recorded, and this function only ever sees an owned entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PathValue,
        [Parameter(Mandatory)][string]$Entry
    )

    $target = Get-NormalizedPathEntry -Entry $Entry
    $kept   = @(Split-PathValue -PathValue $PathValue |
        Where-Object { (Get-NormalizedPathEntry -Entry $_) -ne $target })

    [PSCustomObject]@{
        Value   = ($kept -join ';')
        Removed = @(Split-PathValue -PathValue $PathValue).Count -ne $kept.Count
        Entries = $kept
    }
}

# --- PATH environment adapter (Windows edge, injectable for tests) ----------

function New-EnvironmentAccessor {
    <#
    .SYNOPSIS
        Reads and writes an environment variable at Machine or User scope.
    .DESCRIPTION
        The default accessor is the real Windows environment. Tests pass a
        hashtable-backed accessor instead, so the add/deduplicate/remove and
        preserve-others logic runs for real off Windows without touching the
        machine. Both honour the same contract: Get returns the current value,
        Set replaces it.
    #>
    [CmdletBinding()]
    param([hashtable]$Store)

    if ($PSBoundParameters.ContainsKey('Store')) {
        return [PSCustomObject]@{
            Get = { param($Name, $Scope) if ($Store.ContainsKey("$Scope`:$Name")) { [string]$Store["$Scope`:$Name"] } else { '' } }.GetNewClosure()
            Set = { param($Name, $Scope, $Value) $Store["$Scope`:$Name"] = $Value }.GetNewClosure()
        }
    }

    [PSCustomObject]@{
        Get = { param($Name, $Scope) [string][Environment]::GetEnvironmentVariable($Name, $Scope) }
        Set = { param($Name, $Scope, $Value) [Environment]::SetEnvironmentVariable($Name, $Value, $Scope) }
    }
}

function Resolve-EnvironmentScope {
    <#
    .SYNOPSIS
        Turns a requested scope into the .NET target and reports SYSTEM reach.
    .DESCRIPTION
        Under SYSTEM a User-scope change lands in the SYSTEM account's own
        environment, not any signed-in user's, so a package that asks for a User
        PATH entry from SYSTEM is told the change will not reach the intended
        users rather than being allowed to claim it did.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$RequestedScope,
        [bool]$RunningAsSystem
    )

    $reachesIntendedUsers = -not ($RequestedScope -eq 'User' -and $RunningAsSystem)

    [PSCustomObject]@{
        Scope                = $RequestedScope
        ReachesIntendedUsers = $reachesIntendedUsers
        Limitation           = if ($reachesIntendedUsers) { '' } else {
            'A User-scope PATH change made from SYSTEM lands in the SYSTEM profile, not the signed-in user. Use Machine scope for a device-wide deployment.'
        }
    }
}

# --- Registry payload logic (pure) ------------------------------------------

function Resolve-ClassesRoot {
    <#
    .SYNOPSIS
        The registry root that carries file classes for the running context.
    .DESCRIPTION
        HKLM\SOFTWARE\Classes is machine-wide and visible to every user, which
        is what an Intune SYSTEM deployment needs. HKCU\SOFTWARE\Classes is
        per-user and, written from SYSTEM, reaches only the SYSTEM profile. A
        machine request always resolves to HKLM; a user request resolves to
        HKCU but reports that it will not reach other users when run as SYSTEM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope,
        [bool]$RunningAsSystem
    )

    if ($Scope -eq 'Machine') {
        return [PSCustomObject]@{
            Root = 'HKLM:\SOFTWARE\Classes'; ReachesIntendedUsers = $true; Limitation = ''
        }
    }

    [PSCustomObject]@{
        Root                 = 'HKCU:\SOFTWARE\Classes'
        ReachesIntendedUsers = -not $RunningAsSystem
        Limitation           = if ($RunningAsSystem) {
            'A per-user (HKCU) class written from SYSTEM reaches only the SYSTEM profile. Use Machine scope to reach signed-in users.'
        } else { '' }
    }
}

function Get-ContextMenuPlan {
    <#
    .SYNOPSIS
        The registry keys and values a context-menu action needs, as data.
    .DESCRIPTION
        Produced without touching the registry so the plan can be asserted on
        any platform and applied unchanged on Windows. The shell verb lives
        under a shell\<verb> subkey of the target's class, with a command
        subkey; the command embeds the selected item as the argument the target
        expects, "%1" by default. The class the verb attaches to depends on the
        target: a file extension, the Directory class, its Background class, or
        the all-files "*" class.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('File', 'Folder', 'Directory', 'AllFiles')][string]$Target,
        [Parameter(Mandatory)][string]$Verb,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Executable,
        [string]$Arguments = '"%1"',
        [string[]]$Extensions = @(),
        [string]$Icon = ''
    )

    # The class each target scope hangs its verb from.
    $classes = switch ($Target) {
        'File'      { @($Extensions | ForEach-Object { $_ }) }
        'AllFiles'  { @('*') }
        'Folder'    { @('Directory') }
        'Directory' { @('Directory\Background') }
    }

    if ($Target -eq 'File' -and $classes.Count -eq 0) {
        throw "A file context-menu action needs at least one extension to attach to."
    }

    $command = ('"{0}" {1}' -f $Executable, $Arguments).TrimEnd()

    $keys = [System.Collections.Generic.List[object]]::new()
    foreach ($class in $classes) {
        $verbKey = "$Root\$class\shell\$Verb"
        $entry = [ordered]@{
            VerbKey     = $verbKey
            CommandKey  = "$verbKey\command"
            DisplayName = $DisplayName
            Command     = $command
            Icon        = $Icon
        }
        $keys.Add([PSCustomObject]$entry)
    }

    [PSCustomObject]@{
        Target  = $Target
        Verb    = $Verb
        Command = $command
        Keys    = $keys.ToArray()
    }
}

function Get-FileAssociationPlan {
    <#
    .SYNOPSIS
        The ProgID and extension keys a file association needs, as data.
    .DESCRIPTION
        An association is a ProgID that describes how to open a class of file,
        plus an extension key that points at that ProgID. Kept as a plan so it
        can be asserted and applied identically. The open command embeds the
        selected file as "%1" unless the caller specifies otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][string]$ProgId,
        [Parameter(Mandatory)][string]$Executable,
        [string]$FriendlyName = '',
        [string]$Arguments = '"%1"',
        [string]$Icon = ''
    )

    $ext = if ($Extension.StartsWith('.')) { $Extension } else { ".$Extension" }
    $command = ('"{0}" {1}' -f $Executable, $Arguments).TrimEnd()

    [PSCustomObject]@{
        Extension       = $ext
        ProgId          = $ProgId
        Command         = $command
        ExtensionKey    = "$Root\$ext"
        ProgIdKey       = "$Root\$ProgId"
        ProgIdCommandKey= "$Root\$ProgId\shell\open\command"
        ProgIdIconKey   = "$Root\$ProgId\DefaultIcon"
        FriendlyName    = $FriendlyName
        Icon            = $Icon
    }
}

# --- Ownership state ---------------------------------------------------------

function Get-IntegrationStatePath {
    <#
    .SYNOPSIS
        Where a package records what integrations it owns.
    .DESCRIPTION
        Under ProgramData, keyed by a sanitised application name, so uninstall
        on the same machine finds exactly what install recorded and nothing
        from another package. Falls back to TEMP only when ProgramData is
        unavailable, so resolving the path never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationKey,
        [string]$Root = ''
    )

    if (-not $Root) {
        $parent = if ($env:ProgramData) { $env:ProgramData } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $Root = Join-Path $parent 'IntuneDeployment\State'
    }

    $safe = ($ApplicationKey -replace '[^\w.-]', '_')
    Join-Path (Join-Path $Root $safe) 'integration-state.json'
}

function New-IntegrationState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApplicationKey)

    [PSCustomObject]@{
        ApplicationKey = $ApplicationKey
        RecordedAt     = (Get-Date).ToString('o')
        PathEntries    = @()   # @{ Scope; Entry }
        EnvVars        = @()   # @{ Scope; Name }
        Shortcuts      = @()   # full .lnk paths
        RegistryKeys   = @()   # full key paths created
    }
}

function Save-IntegrationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-IntegrationState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

# --- Shortcut adapter (Windows edge) ----------------------------------------

function Resolve-DesktopLocation {
    <#
    .SYNOPSIS
        The desktop folder a shortcut should be created in for the context.
    .DESCRIPTION
        A machine-wide deployment - the Intune norm - belongs on the Public
        desktop, which every user sees, not the calling account's personal
        desktop (under SYSTEM that is the service profile no one opens). An
        explicit location is honoured as given.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Public', 'User', 'Custom')][string]$Location = 'Public',
        [string]$CustomPath = '',
        [bool]$RunningAsSystem
    )

    switch ($Location) {
        'Custom' {
            if (-not $CustomPath) { throw "A custom shortcut location needs a path." }
            [PSCustomObject]@{ Directory = $CustomPath; ReachesIntendedUsers = $true; Limitation = '' }
        }
        'User' {
            # Built by string join, not Join-Path: these are Windows target
            # paths and Join-Path rejects the C: drive when this runs on Linux.
            $dir = if ($env:USERPROFILE) { ($env:USERPROFILE.TrimEnd('\', '/') + '\Desktop') } else { '' }
            [PSCustomObject]@{
                Directory            = $dir
                ReachesIntendedUsers = -not $RunningAsSystem
                Limitation           = if ($RunningAsSystem) {
                    "The user desktop under SYSTEM is the service profile, which no signed-in user sees. Use the Public desktop for a device-wide shortcut."
                } else { '' }
            }
        }
        default {
            $public = if ($env:PUBLIC) { $env:PUBLIC } else { 'C:\Users\Public' }
            [PSCustomObject]@{ Directory = ($public.TrimEnd('\', '/') + '\Desktop'); ReachesIntendedUsers = $true; Limitation = '' }
        }
    }
}

function Set-Shortcut {
    <#
    .SYNOPSIS
        Creates or overwrites a .lnk with the given target and options.
    .DESCRIPTION
        Uses the WScript.Shell COM object, which exists only on Windows; the
        caller guards with Test-WindowsPlatform. Returns the shortcut path so
        ownership can record it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = ''
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $TargetPath
        if ($Arguments)        { $shortcut.Arguments = $Arguments }
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
        if ($IconLocation)     { $shortcut.IconLocation = $IconLocation }
        $shortcut.Save()
    } finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    }

    $Path
}

function Read-Shortcut {
    <#
    .SYNOPSIS
        Reads back a .lnk so its target and options can be verified.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        [PSCustomObject]@{
            Path             = $Path
            TargetPath       = $shortcut.TargetPath
            Arguments        = $shortcut.Arguments
            WorkingDirectory = $shortcut.WorkingDirectory
            IconLocation     = $shortcut.IconLocation
        }
    } finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    }
}

# --- Configuration normalisation --------------------------------------------

function ConvertTo-IntegrationConfig {
    <#
    .SYNOPSIS
        Normalises the package's integrations block into validated definitions.
    .DESCRIPTION
        Accepts the object deserialised from package.json's "Integrations" and
        returns one definition per integration with its mode and kind resolved
        and its required fields checked. An unknown mode or kind, or a MANAGE
        definition missing what it needs to be created, is a hard error here
        rather than a surprise at apply time. DISABLED definitions are kept but
        marked, so a report can show they were considered and skipped.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Integrations)

    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Integrations) { return $result.ToArray() }

    foreach ($kindName in $script:IntegrationKinds) {
        if ($Integrations.PSObject.Properties.Name -notcontains $kindName) { continue }

        foreach ($raw in @($Integrations.$kindName)) {
            if ($null -eq $raw) { continue }

            $mode = if ($raw.PSObject.Properties.Name -contains 'Mode' -and $raw.Mode) { [string]$raw.Mode } else { 'MANAGE' }
            if ($mode -notin $script:IntegrationModes) {
                throw "Integration '$kindName' has mode '$mode'; expected one of $($script:IntegrationModes -join ', ')."
            }

            $definition = [ordered]@{
                Kind = $kindName
                Mode = $mode
                Id   = if ($raw.PSObject.Properties.Name -contains 'Id' -and $raw.Id) { [string]$raw.Id } else { "$kindName-$($result.Count + 1)" }
            }
            foreach ($property in $raw.PSObject.Properties) {
                if ($property.Name -in @('Mode', 'Id')) { continue }
                $definition[$property.Name] = $property.Value
            }

            $object = [PSCustomObject]$definition
            if ($mode -ne 'DISABLED') { Assert-IntegrationDefinition -Definition $object }
            $result.Add($object)
        }
    }

    $result.ToArray()
}

function Assert-IntegrationDefinition {
    <#
    .SYNOPSIS
        Fails a definition that could not be created or verified as written.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Definition)

    $required = switch ($Definition.Kind) {
        'Path'            { @('Entry') }
        'Shortcut'        { @('Name', 'Target') }
        'ContextMenu'     { @('Verb', 'DisplayName', 'Executable', 'Target') }
        'FileAssociation' { @('Extension', 'ProgId', 'Executable') }
    }

    $missing = @($required | Where-Object {
        $Definition.PSObject.Properties.Name -notcontains $_ -or -not $Definition.$_
    })
    if ($missing.Count -gt 0) {
        throw "$($Definition.Kind) integration '$($Definition.Id)' is missing: $($missing -join ', ')."
    }

    if ($Definition.Kind -eq 'ContextMenu' -and $Definition.Target -notin @('File', 'Folder', 'Directory', 'AllFiles')) {
        throw "ContextMenu integration '$($Definition.Id)' has target '$($Definition.Target)'; expected File, Folder, Directory or AllFiles."
    }
    if ($Definition.Kind -eq 'ContextMenu' -and $Definition.Target -eq 'File') {
        $extensions = @(if ($Definition.PSObject.Properties.Name -contains 'Extensions') { $Definition.Extensions } else { @() })
        if ($extensions.Count -eq 0) {
            throw "ContextMenu integration '$($Definition.Id)' targets File but names no extensions."
        }
    }
}

function Get-IntegrationScopeValue {
    param([PSCustomObject]$Definition, [string]$Default = 'Machine')
    if ($Definition.PSObject.Properties.Name -contains 'Scope' -and $Definition.Scope) { [string]$Definition.Scope } else { $Default }
}

# --- PATH orchestration (pure, tested cross-platform) -----------------------

function Invoke-PathIntegration {
    <#
    .SYNOPSIS
        Applies, verifies or removes one PATH/environment integration.
    .DESCRIPTION
        The whole PATH contract in one place: add without duplicating, verify by
        presence, remove only what was added, and never disturb another entry.
        It runs through an environment accessor, so the real logic is exercised
        without a Windows machine when a test supplies its own store.
    .OUTPUTS
        A result carrying Success, a human reason, and (for Apply) whether the
        entry was newly added so ownership records only genuine additions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Apply', 'Validate', 'Remove')][string]$Action,
        [Parameter(Mandatory)][PSCustomObject]$Definition,
        [Parameter(Mandatory)][PSCustomObject]$Accessor,
        [bool]$RunningAsSystem,
        [PSCustomObject]$State
    )

    $scope = Get-IntegrationScopeValue -Definition $Definition -Default 'Machine'
    $entry = [string]$Definition.Entry
    $resolved = Resolve-EnvironmentScope -RequestedScope $scope -RunningAsSystem $RunningAsSystem
    $current  = & $Accessor.Get 'Path' $scope

    if ($Action -eq 'Validate') {
        $present = $false
        foreach ($item in (Split-PathValue -PathValue $current)) {
            if ((Get-NormalizedPathEntry -Entry $item) -eq (Get-NormalizedPathEntry -Entry $entry)) { $present = $true; break }
        }
        return [PSCustomObject]@{
            Success = $present
            Reason  = if ($present) { "PATH ($scope) contains $entry" } else { "PATH ($scope) does not contain $entry" }
        }
    }

    if ($Action -eq 'Apply') {
        if (-not $resolved.ReachesIntendedUsers) {
            return [PSCustomObject]@{ Success = $false; Added = $false; Reason = $resolved.Limitation }
        }
        $add = Add-PathContribution -PathValue $current -Entry $entry
        if ($add.Added) { & $Accessor.Set 'Path' $scope $add.Value }
        if ($null -ne $State -and $add.Added) {
            $State.PathEntries = @($State.PathEntries) + [PSCustomObject]@{ Scope = $scope; Entry = $entry }
        }
        return [PSCustomObject]@{
            Success = $true
            Added   = $add.Added
            Reason  = if ($add.Added) { "Added $entry to PATH ($scope)" } else { "PATH ($scope) already contained $entry; left unchanged" }
        }
    }

    # Remove
    $remove = Remove-PathContribution -PathValue $current -Entry $entry
    if ($remove.Removed) { & $Accessor.Set 'Path' $scope $remove.Value }
    [PSCustomObject]@{
        Success = $true
        Removed = $remove.Removed
        Reason  = if ($remove.Removed) { "Removed $entry from PATH ($scope)" } else { "PATH ($scope) did not contain $entry; nothing removed" }
    }
}

# --- Shortcut orchestration --------------------------------------------------

function Invoke-ShortcutIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Apply', 'Validate', 'Remove')][string]$Action,
        [Parameter(Mandatory)][PSCustomObject]$Definition,
        [bool]$RunningAsSystem,
        [PSCustomObject]$State
    )

    $location = if ($Definition.PSObject.Properties.Name -contains 'Location' -and $Definition.Location) { [string]$Definition.Location } else { 'Public' }
    $custom   = if ($Definition.PSObject.Properties.Name -contains 'LocationPath') { [string]$Definition.LocationPath } else { '' }
    $resolved = Resolve-DesktopLocation -Location $location -CustomPath $custom -RunningAsSystem $RunningAsSystem
    # String join, not Join-Path: the desktop directory is a Windows path that
    # Join-Path would reject for its C: drive when this is exercised on Linux.
    $linkPath = ($resolved.Directory.TrimEnd('\', '/') + '\' + $Definition.Name + '.lnk')

    if (-not (Test-WindowsPlatform)) {
        return [PSCustomObject]@{ Success = $false; Skipped = $true; Reason = 'Shortcut operations require Windows'; Path = $linkPath }
    }

    switch ($Action) {
        'Apply' {
            if (-not $resolved.ReachesIntendedUsers) {
                return [PSCustomObject]@{ Success = $false; Reason = $resolved.Limitation; Path = $linkPath }
            }
            Set-Shortcut -Path $linkPath -TargetPath ([string]$Definition.Target) `
                -Arguments $(if ($Definition.PSObject.Properties.Name -contains 'Arguments') { [string]$Definition.Arguments } else { '' }) `
                -WorkingDirectory $(if ($Definition.PSObject.Properties.Name -contains 'WorkingDirectory') { [string]$Definition.WorkingDirectory } else { '' }) `
                -IconLocation $(if ($Definition.PSObject.Properties.Name -contains 'Icon') { [string]$Definition.Icon } else { '' }) | Out-Null
            if ($null -ne $State) { $State.Shortcuts = @($State.Shortcuts) + $linkPath }
            [PSCustomObject]@{ Success = $true; Reason = "Created shortcut $linkPath"; Path = $linkPath }
        }
        'Validate' {
            $shortcut = Read-Shortcut -Path $linkPath
            if ($null -eq $shortcut) {
                return [PSCustomObject]@{ Success = $false; Reason = "Shortcut not found: $linkPath"; Path = $linkPath }
            }
            $problems = [System.Collections.Generic.List[string]]::new()
            if ($shortcut.TargetPath -ne [string]$Definition.Target) {
                $problems.Add("target is '$($shortcut.TargetPath)', expected '$($Definition.Target)'")
            }
            if ($Definition.PSObject.Properties.Name -contains 'Arguments' -and $Definition.Arguments -and $shortcut.Arguments -ne [string]$Definition.Arguments) {
                $problems.Add("arguments are '$($shortcut.Arguments)', expected '$($Definition.Arguments)'")
            }
            if ($Definition.PSObject.Properties.Name -contains 'WorkingDirectory' -and $Definition.WorkingDirectory -and $shortcut.WorkingDirectory -ne [string]$Definition.WorkingDirectory) {
                $problems.Add("working directory is '$($shortcut.WorkingDirectory)', expected '$($Definition.WorkingDirectory)'")
            }
            [PSCustomObject]@{
                Success = $problems.Count -eq 0
                Reason  = if ($problems.Count -eq 0) { "Shortcut $linkPath is correct" } else { "Shortcut ${linkPath}: $($problems -join '; ')" }
                Path    = $linkPath
            }
        }
        'Remove' {
            # Removal is driven by ownership state, so this only ever removes a
            # link the package recorded. The caller passes owned paths.
            if (Test-Path -LiteralPath $linkPath) {
                Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
                [PSCustomObject]@{ Success = $true; Reason = "Removed shortcut $linkPath"; Path = $linkPath }
            } else {
                [PSCustomObject]@{ Success = $true; Reason = "Shortcut already absent: $linkPath"; Path = $linkPath }
            }
        }
    }
}

# --- Registry orchestration (context menu + file association) ---------------

function New-RegistryKeyValues {
    <#
    .SYNOPSIS
        Writes a key and its named values, recording the key root as owned.
    .DESCRIPTION
        Only the roots the package creates are recorded, and removal deletes
        only those roots, so a verb added under an existing class never takes
        the class with it. Windows only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Values = @{},
        [PSCustomObject]$State,
        [string]$OwnedRoot = ''
    )

    if (-not (Test-Path -LiteralPath $Key)) {
        New-Item -Path $Key -Force | Out-Null
    }
    foreach ($name in $Values.Keys) {
        Set-ItemProperty -LiteralPath $Key -Name $name -Value $Values[$name]
    }
    if ($null -ne $State -and $OwnedRoot -and (@($State.RegistryKeys) -notcontains $OwnedRoot)) {
        $State.RegistryKeys = @($State.RegistryKeys) + $OwnedRoot
    }
}

function Invoke-ContextMenuIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Apply', 'Validate', 'Remove')][string]$Action,
        [Parameter(Mandatory)][PSCustomObject]$Definition,
        [bool]$RunningAsSystem,
        [PSCustomObject]$State
    )

    $scope    = Get-IntegrationScopeValue -Definition $Definition -Default 'Machine'
    $classes  = Resolve-ClassesRoot -Scope $scope -RunningAsSystem $RunningAsSystem
    $plan = Get-ContextMenuPlan -Root $classes.Root -Target ([string]$Definition.Target) `
        -Verb ([string]$Definition.Verb) -DisplayName ([string]$Definition.DisplayName) `
        -Executable ([string]$Definition.Executable) `
        -Arguments $(if ($Definition.PSObject.Properties.Name -contains 'Arguments' -and $Definition.Arguments) { [string]$Definition.Arguments } else { '"%1"' }) `
        -Extensions @(if ($Definition.PSObject.Properties.Name -contains 'Extensions') { $Definition.Extensions } else { @() }) `
        -Icon $(if ($Definition.PSObject.Properties.Name -contains 'Icon') { [string]$Definition.Icon } else { '' })

    if (-not (Test-WindowsPlatform)) {
        return [PSCustomObject]@{ Success = $false; Skipped = $true; Reason = 'Registry operations require Windows'; Plan = $plan }
    }
    if ($Action -ne 'Validate' -and -not $classes.ReachesIntendedUsers) {
        return [PSCustomObject]@{ Success = $false; Reason = $classes.Limitation; Plan = $plan }
    }

    switch ($Action) {
        'Apply' {
            foreach ($key in $plan.Keys) {
                New-RegistryKeyValues -Key $key.VerbKey -Values @{ '(default)' = $key.DisplayName } -State $State -OwnedRoot $key.VerbKey
                if ($key.Icon) { Set-ItemProperty -LiteralPath $key.VerbKey -Name 'Icon' -Value $key.Icon }
                New-RegistryKeyValues -Key $key.CommandKey -Values @{ '(default)' = $key.Command }
            }
            [PSCustomObject]@{ Success = $true; Reason = "Created context menu '$($Definition.DisplayName)' ($($plan.Keys.Count) class(es))"; Plan = $plan }
        }
        'Validate' {
            $problems = [System.Collections.Generic.List[string]]::new()
            foreach ($key in $plan.Keys) {
                if (-not (Test-Path -LiteralPath $key.VerbKey)) { $problems.Add("missing key $($key.VerbKey)"); continue }
                $name = (Get-ItemProperty -LiteralPath $key.VerbKey -ErrorAction SilentlyContinue).'(default)'
                if ($name -ne $key.DisplayName) { $problems.Add("display name at $($key.VerbKey) is '$name', expected '$($key.DisplayName)'") }
                if (-not (Test-Path -LiteralPath $key.CommandKey)) { $problems.Add("missing command key $($key.CommandKey)"); continue }
                $command = (Get-ItemProperty -LiteralPath $key.CommandKey -ErrorAction SilentlyContinue).'(default)'
                if ($command -ne $key.Command) { $problems.Add("command is '$command', expected '$($key.Command)'") }
            }
            [PSCustomObject]@{
                Success = $problems.Count -eq 0
                Reason  = if ($problems.Count -eq 0) { "Context menu '$($Definition.DisplayName)' is correct" } else { ($problems -join '; ') }
                Plan    = $plan
            }
        }
        'Remove' {
            foreach ($key in $plan.Keys) {
                if (Test-Path -LiteralPath $key.VerbKey) { Remove-Item -LiteralPath $key.VerbKey -Recurse -Force -ErrorAction SilentlyContinue }
            }
            [PSCustomObject]@{ Success = $true; Reason = "Removed context menu '$($Definition.DisplayName)'"; Plan = $plan }
        }
    }
}

function Invoke-FileAssociationIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Apply', 'Validate', 'Remove')][string]$Action,
        [Parameter(Mandatory)][PSCustomObject]$Definition,
        [bool]$RunningAsSystem,
        [PSCustomObject]$State
    )

    $scope   = Get-IntegrationScopeValue -Definition $Definition -Default 'Machine'
    $classes = Resolve-ClassesRoot -Scope $scope -RunningAsSystem $RunningAsSystem
    $plan = Get-FileAssociationPlan -Root $classes.Root -Extension ([string]$Definition.Extension) `
        -ProgId ([string]$Definition.ProgId) -Executable ([string]$Definition.Executable) `
        -FriendlyName $(if ($Definition.PSObject.Properties.Name -contains 'FriendlyName') { [string]$Definition.FriendlyName } else { '' }) `
        -Arguments $(if ($Definition.PSObject.Properties.Name -contains 'Arguments' -and $Definition.Arguments) { [string]$Definition.Arguments } else { '"%1"' }) `
        -Icon $(if ($Definition.PSObject.Properties.Name -contains 'Icon') { [string]$Definition.Icon } else { '' })

    if (-not (Test-WindowsPlatform)) {
        return [PSCustomObject]@{ Success = $false; Skipped = $true; Reason = 'Registry operations require Windows'; Plan = $plan }
    }
    if ($Action -ne 'Validate' -and -not $classes.ReachesIntendedUsers) {
        return [PSCustomObject]@{ Success = $false; Reason = $classes.Limitation; Plan = $plan }
    }

    switch ($Action) {
        'Apply' {
            New-RegistryKeyValues -Key $plan.ProgIdKey -Values $(if ($plan.FriendlyName) { @{ '(default)' = $plan.FriendlyName } } else { @{} }) -State $State -OwnedRoot $plan.ProgIdKey
            New-RegistryKeyValues -Key $plan.ProgIdCommandKey -Values @{ '(default)' = $plan.Command }
            if ($plan.Icon) { New-RegistryKeyValues -Key $plan.ProgIdIconKey -Values @{ '(default)' = $plan.Icon } }
            # The extension key points at the ProgID. It may pre-exist (another
            # app's association); record it as owned only when we create it, so
            # uninstall does not strip an extension we merely pointed.
            $extExisted = Test-Path -LiteralPath $plan.ExtensionKey
            New-RegistryKeyValues -Key $plan.ExtensionKey -Values @{ '(default)' = $plan.ProgId } `
                -State $State -OwnedRoot $(if ($extExisted) { '' } else { $plan.ExtensionKey })
            [PSCustomObject]@{ Success = $true; Reason = "Associated $($plan.Extension) with $($plan.ProgId)"; Plan = $plan }
        }
        'Validate' {
            $problems = [System.Collections.Generic.List[string]]::new()
            if (-not (Test-Path -LiteralPath $plan.ExtensionKey)) {
                $problems.Add("extension $($plan.Extension) is not registered")
            } else {
                $progId = (Get-ItemProperty -LiteralPath $plan.ExtensionKey -ErrorAction SilentlyContinue).'(default)'
                if ($progId -ne $plan.ProgId) { $problems.Add("$($plan.Extension) points at '$progId', expected '$($plan.ProgId)'") }
            }
            if (-not (Test-Path -LiteralPath $plan.ProgIdCommandKey)) {
                $problems.Add("ProgID $($plan.ProgId) has no open command")
            } else {
                $command = (Get-ItemProperty -LiteralPath $plan.ProgIdCommandKey -ErrorAction SilentlyContinue).'(default)'
                if ($command -ne $plan.Command) { $problems.Add("open command is '$command', expected '$($plan.Command)'") }
            }
            [PSCustomObject]@{
                Success = $problems.Count -eq 0
                Reason  = if ($problems.Count -eq 0) { "$($plan.Extension) -> $($plan.ProgId) is correct" } else { ($problems -join '; ') }
                Plan    = $plan
            }
        }
        'Remove' {
            # Only roots ownership recorded are removed; the caller passes them.
            [PSCustomObject]@{ Success = $true; Reason = "File association removal is driven by recorded ownership"; Plan = $plan }
        }
    }
}

# --- Top-level dispatch ------------------------------------------------------

function Invoke-IntegrationSet {
    <#
    .SYNOPSIS
        Applies or validates a whole set of integrations by mode.
    .DESCRIPTION
        Phase 'Apply' (run after install): a MANAGE integration is created and
        its resources recorded as owned; a VALIDATE integration is only checked,
        because the vendor installer owns it and the package must not duplicate
        or alter it; a DISABLED integration is skipped. Phase 'Validate' (the
        post-install check) verifies both MANAGE and VALIDATE integrations
        against the real machine state without changing anything.
    .OUTPUTS
        One result per integration, so a caller can report every outcome and
        fail on any that did not succeed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Apply', 'Validate')][string]$Phase,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Definitions,
        [bool]$RunningAsSystem,
        [PSCustomObject]$State,
        [PSCustomObject]$Accessor
    )

    if ($null -eq $Accessor) { $Accessor = New-EnvironmentAccessor }
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($definition in $Definitions) {
        if ($definition.Mode -eq 'DISABLED') {
            $results.Add((New-IntegrationResult -Definition $definition -Action 'Skip' -Success $true -Reason 'Mode is DISABLED'))
            continue
        }

        $action = if ($Phase -eq 'Apply' -and $definition.Mode -eq 'MANAGE') { 'Apply' } else { 'Validate' }

        $outcome = switch ($definition.Kind) {
            'Path'            { Invoke-PathIntegration            -Action $action -Definition $definition -Accessor $Accessor -RunningAsSystem $RunningAsSystem -State $State }
            'Shortcut'        { Invoke-ShortcutIntegration        -Action $action -Definition $definition -RunningAsSystem $RunningAsSystem -State $State }
            'ContextMenu'     { Invoke-ContextMenuIntegration     -Action $action -Definition $definition -RunningAsSystem $RunningAsSystem -State $State }
            'FileAssociation' { Invoke-FileAssociationIntegration -Action $action -Definition $definition -RunningAsSystem $RunningAsSystem -State $State }
        }

        $results.Add((New-IntegrationResult -Definition $definition -Action $action `
            -Success ([bool]$outcome.Success) -Reason $outcome.Reason `
            -Skipped $(if ($outcome.PSObject.Properties.Name -contains 'Skipped') { [bool]$outcome.Skipped } else { $false })))
    }

    $results.ToArray()
}

function New-IntegrationResult {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Definition,
        [Parameter(Mandatory)][string]$Action,
        [bool]$Success,
        [string]$Reason = '',
        [bool]$Skipped = $false
    )
    [PSCustomObject]@{
        Id      = $Definition.Id
        Kind    = $Definition.Kind
        Mode    = $Definition.Mode
        Action  = $Action
        Success = $Success
        Skipped = $Skipped
        Reason  = $Reason
    }
}

function Remove-OwnedIntegrations {
    <#
    .SYNOPSIS
        Removes exactly the resources ownership recorded, and nothing else.
    .DESCRIPTION
        Driven entirely by the saved state, never by the current configuration,
        so a VALIDATE integration (never recorded) is never touched, an entry
        the package did not add is never removed, and an unrelated PATH entry or
        registry key is left alone. PATH removal runs through the accessor, so
        preserve-others is exercised on any platform; shortcut and registry
        removal are Windows-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$State,
        [PSCustomObject]$Accessor,
        [bool]$RunningAsSystem
    )

    if ($null -eq $Accessor) { $Accessor = New-EnvironmentAccessor }
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($owned in @($State.PathEntries)) {
        $current = & $Accessor.Get 'Path' $owned.Scope
        $removal = Remove-PathContribution -PathValue $current -Entry $owned.Entry
        if ($removal.Removed) { & $Accessor.Set 'Path' $owned.Scope $removal.Value }
        $results.Add([PSCustomObject]@{ Kind = 'Path'; Resource = "$($owned.Scope):$($owned.Entry)"; Removed = $removal.Removed })
    }

    foreach ($owned in @($State.EnvVars)) {
        & $Accessor.Set $owned.Name $owned.Scope ''
        $results.Add([PSCustomObject]@{ Kind = 'EnvVar'; Resource = "$($owned.Scope):$($owned.Name)"; Removed = $true })
    }

    # A shortcut is a recorded file path; deleting exactly that path works on
    # any platform, so the remove-owned / preserve-others behaviour is not
    # Windows-gated.
    foreach ($link in @($State.Shortcuts)) {
        $existed = Test-Path -LiteralPath $link
        if ($existed) { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
        $results.Add([PSCustomObject]@{ Kind = 'Shortcut'; Resource = $link; Removed = $existed })
    }

    # Registry keys can only be removed on Windows; elsewhere the recorded keys
    # are reported as skipped rather than silently treated as removed.
    if (Test-WindowsPlatform) {
        foreach ($key in @($State.RegistryKeys)) {
            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
            $results.Add([PSCustomObject]@{ Kind = 'Registry'; Resource = $key; Removed = $true })
        }
    } else {
        foreach ($key in @($State.RegistryKeys)) {
            $results.Add([PSCustomObject]@{ Kind = 'Registry'; Resource = $key; Removed = $false; Skipped = $true })
        }
    }

    $results.ToArray()
}

# --- Capture: identify app-relevant integrations (pure) ---------------------

function Select-ApplicationAssociations {
    <#
    .SYNOPSIS
        Keeps only the observed associations that belong to this application.
    .DESCRIPTION
        Capture is not a registry snapshot. Given associations observed on the
        machine (each an extension, ProgID and open command) and what is known
        about the application - its executable, name, ProgID hints, configured
        extensions, install directory, publisher - this returns only the
        associations whose command or ProgID actually references the
        application, so an unrelated handler is never captured as though the
        package owned it.
    .PARAMETER Observed
        Objects with at least Extension, ProgId and Command.
    .PARAMETER Executable
        The application executable; an association whose command contains it is
        relevant. Matched on the file name too, so a differing install root
        still matches.
    .PARAMETER ApplicationName / Publisher
        Substrings that, when they appear in a ProgID or command, mark the
        association as this application's.
    .PARAMETER ProgIdHints / Extensions / InstallDirectory
        Further evidence: a ProgID that matches a hint, an extension the package
        configured, or a command that runs from the install directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Observed,
        [string]$Executable = '',
        [string]$ApplicationName = '',
        [string]$Publisher = '',
        [string[]]$ProgIdHints = @(),
        [string[]]$Extensions = @(),
        [string]$InstallDirectory = ''
    )

    $exeLeaf = if ($Executable) { Split-Path -Leaf $Executable } else { '' }
    $wanted  = @($Extensions | ForEach-Object { if ($_.StartsWith('.')) { $_.ToLowerInvariant() } else { ".$_".ToLowerInvariant() } })

    $relevant = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Observed) {
        if ($null -eq $item) { continue }
        $command = if ($item.PSObject.Properties.Name -contains 'Command') { [string]$item.Command } else { '' }
        $progId  = if ($item.PSObject.Properties.Name -contains 'ProgId')  { [string]$item.ProgId }  else { '' }
        $ext     = if ($item.PSObject.Properties.Name -contains 'Extension') { ([string]$item.Extension).ToLowerInvariant() } else { '' }

        $reasons = [System.Collections.Generic.List[string]]::new()
        if ($Executable -and $command -and $command.ToLowerInvariant().Contains($Executable.ToLowerInvariant())) { $reasons.Add('command runs the executable') }
        elseif ($exeLeaf -and $command -and $command.ToLowerInvariant().Contains($exeLeaf.ToLowerInvariant())) { $reasons.Add('command runs the executable by name') }
        if ($InstallDirectory -and $command -and $command.ToLowerInvariant().Contains($InstallDirectory.ToLowerInvariant())) { $reasons.Add('command runs from the install directory') }
        if ($ApplicationName -and ($progId + ' ' + $command).ToLowerInvariant().Contains($ApplicationName.ToLowerInvariant())) { $reasons.Add('names the application') }
        if ($Publisher -and ($progId + ' ' + $command).ToLowerInvariant().Contains($Publisher.ToLowerInvariant())) { $reasons.Add('names the publisher') }
        foreach ($hint in $ProgIdHints) { if ($hint -and $progId -and $progId.ToLowerInvariant().Contains($hint.ToLowerInvariant())) { $reasons.Add("ProgID matches hint '$hint'"); break } }
        if ($wanted.Count -gt 0 -and $ext -and $wanted -contains $ext) { $reasons.Add('extension is configured for the package') }

        if ($reasons.Count -gt 0) {
            $relevant.Add([PSCustomObject]@{
                Extension = $item.Extension
                ProgId    = $progId
                Command   = $command
                Evidence  = $reasons.ToArray()
            })
        }
    }

    $relevant.ToArray()
}
