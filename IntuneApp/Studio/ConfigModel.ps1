#Requires -Version 5.1
<#
    ConfigModel.ps1

    Canonical shape of a package configuration, plus round-tripping between a
    .psd1 on disk and the in-memory model the wizard and GUI both edit.

    Design notes:
      * The model is an ordered dictionary so generated files have a stable,
        readable key order.
      * Loading merges the file over the defaults, so a configuration written
        by an older Studio still opens, and keys the Studio does not know about
        are preserved rather than dropped.

    Headless: no UI dependencies.
#>

Set-StrictMode -Version Latest

# Sections the packaging engine reads today. Sections outside this list are
# recorded in the configuration but are not executed by the current engine;
# the validator surfaces that so nothing is silently implied.
$script:EngineExecutedSections = @(
    'ApplicationName', 'Publisher', 'Version', 'Architecture',
    'Installer', 'Uninstaller', 'Detection', 'SuccessExitCodes',
    'Logging', 'Environment', 'WindowsIntegration'
)

function Get-EngineExecutedSections { return $script:EngineExecutedSections }

function New-ConfigModel {
    <#
        .SYNOPSIS
        Returns a configuration model populated with safe defaults.

        Every optional feature defaults to disabled. The wizard turns things on
        only when the technician explicitly asks for them.
    #>
    param(
        [string]$ApplicationName = 'Example Application',
        [string]$Publisher = 'Example Vendor',
        [string]$Version = '1.0.0'
    )

    return [ordered]@{
        ApplicationName = $ApplicationName
        Publisher       = $Publisher
        Version         = $Version
        Architecture    = 'x64'          # x64, x86, or ARM64

        Installer = [ordered]@{
            Type          = 'EXE'        # EXE or MSI
            File          = ''
            # Used for local testing, and for deployment when ArgumentSource
            # is 'Configuration'. Kept either way, so a package always has a
            # reproducible local test.
            Arguments     = ''
            # Configuration - Arguments above is authoritative (the default)
            # Intune        - the Intune Program command supplies them
            # None          - the installer is launched with no arguments
            # They are never combined. See Helpers/InstallerArguments.ps1.
            ArgumentSource = 'Configuration'
            Context       = 'System'     # System or User
            UserInterface = 'Silent'     # Silent, BasicUI, or Interactive
            Restart       = 'Suppress'   # Suppress, Allow, or Prompt
        }

        Uninstaller = [ordered]@{
            Type        = 'EXE'
            File        = ''
            Arguments   = ''
            ProductCode = $null
        }

        Detection = [ordered]@{
            Type           = 'File'      # File, Registry, MSI, or Custom
            Path           = ''
            FileName       = ''
            MinimumVersion = $null
            # Custom detection. Script is inline PowerShell; ScriptFile is a
            # .ps1 shipped in the package. Both are plain .psd1 literals, so
            # Windows PowerShell 5.1 loads them - a script block literal does
            # not load there at all, and takes the whole file with it.
            Script         = ''
            ScriptFile     = ''
        }

        SuccessExitCodes = @(0, 3010)

        Logging = [ordered]@{
            Enabled = $true
            Path    = 'C:\ProgramData\Company\IntuneApps'
        }

        Environment = [ordered]@{
            Enabled = $false
            SystemPath = [ordered]@{
                Enabled           = $false
                Entries           = @()
                AddIfMissing      = $true
                RemoveOnUninstall = $true
            }
            UserPath = [ordered]@{
                Enabled           = $false
                Entries           = @()
                AddIfMissing      = $true
                RemoveOnUninstall = $true
            }
            Variables                     = @()
            BroadcastChange               = $true
            PreserveExistingPath          = $true
            PreserveExpandableVariables   = $true
            CaseInsensitivePathComparison = $true
        }

        # Applied by the packaging engine after the application installs.
        # Each feature is independently DISABLED, VALIDATE or MANAGE - see
        # Helpers/WindowsIntegration.ps1. Mode is blank by default so the
        # older Enabled flag keeps its meaning ($true means MANAGE).
        WindowsIntegration = [ordered]@{
            Enabled = $false
            StartMenuShortcut = [ordered]@{
                Mode              = ''       # DISABLED, VALIDATE, or MANAGE
                Enabled           = $false
                Required          = $false
                Name              = ''
                Target            = ''
                Arguments         = ''
                WorkingDirectory  = ''
                Icon              = ''
                Description       = ''
                Folder            = ''       # Subfolder under Programs
                Location          = 'AllUsers'      # AllUsers or CurrentUser
                RemoveOnUninstall = $true
            }
            DesktopShortcut = [ordered]@{
                Mode              = ''
                Enabled           = $false
                Required          = $false
                Name              = ''
                Target            = ''
                Arguments         = ''
                WorkingDirectory  = ''
                Icon              = ''
                Description       = ''
                Location          = 'PublicDesktop' # PublicDesktop or UserDesktop
                RemoveOnUninstall = $true
            }
            FileAssociations = [ordered]@{
                Mode              = ''
                Enabled           = $false
                Required          = $false
                Associations      = @()
                # Registering a handler does not take the extension over.
                # Windows makes the user confirm a default change anyway.
                SetAsDefault      = $false
                RemoveOnUninstall = $true
            }
            ContextMenu = [ordered]@{
                Mode              = ''
                Enabled           = $false
                Required          = $false
                Entries           = @()
                RemoveOnUninstall = $true
            }
            Services = [ordered]@{
                Mode              = ''
                Enabled           = $false
                Required          = $false
                Services          = @()
                RemoveOnUninstall = $true
            }
            ScheduledTasks = [ordered]@{
                Mode              = ''
                Enabled           = $false
                Required          = $false
                Tasks             = @()
                RemoveOnUninstall = $true
            }
            NotifyShell     = $true    # Tell Explorer that associations changed
            RestartExplorer = $false   # Never restart Explorer unless asked
        }

        Intune = [ordered]@{
            InstallBehavior    = 'System'
            InstallCommand     = 'powershell.exe -ExecutionPolicy Bypass -File Install.ps1'
            UninstallCommand   = 'powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1'
            DetectionScript    = 'Detection.ps1'
            RestartBehavior    = 'basedOnReturnCode'
        }
    }
}

function New-ContextMenuEntry {
    <#
        Target is FILE, FOLDER, DIRECTORY or ALL_FILES. Verb should be
        application-specific (Company.Application.Open) so that uninstall
        removes this package's key and nothing else.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Verb,
        [ValidateSet('FILE', 'FOLDER', 'DIRECTORY', 'ALL_FILES')][string]$Target = 'FILE',
        [string[]]$Extensions = @(),
        [string]$Executable = '',
        [string]$Arguments = '"%1"',
        [string]$Icon = ''
    )
    return [ordered]@{
        Name       = $Name
        Verb       = $Verb
        Target     = $Target
        Extensions = @($Extensions)
        Executable = $Executable
        Arguments  = $Arguments
        Icon       = $Icon
    }
}

function New-FileAssociationEntry {
    param(
        [Parameter(Mandatory)][string]$Extension,
        [string]$ProgId = '',
        [string]$Description = '',
        [string]$OpenCommand = '',
        [string]$IconPath = ''
    )
    $ext = $Extension.Trim()
    if ($ext -and -not $ext.StartsWith('.')) { $ext = ".$ext" }
    return [ordered]@{
        Extension   = $ext
        ProgId      = $ProgId
        Description = $Description
        OpenCommand = $OpenCommand
        IconPath    = $IconPath
    }
}

function New-EnvironmentVariableEntry {
    <#
        Mode decides how the value meets an existing variable:
          Append / Prepend  add to its ';'-separated list, keeping what is there
          Set               replace the whole value (single-value variables)
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('Machine', 'User')][string]$Scope = 'Machine',
        [ValidateSet('Set', 'Append', 'Prepend')][string]$Mode = 'Set',
        [bool]$Expandable = $false,
        [bool]$RemoveOnUninstall = $true
    )
    return [ordered]@{
        Name              = $Name
        Value             = $Value
        Scope             = $Scope
        Mode              = $Mode
        Expandable        = $Expandable
        RemoveOnUninstall = $RemoveOnUninstall
    }
}

function New-ServiceEntry {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DisplayName = '',
        [ValidateSet('Automatic', 'Manual', 'Disabled', 'Unchanged')]
        [string]$StartupType = 'Unchanged',
        [bool]$Keep = $true
    )
    return [ordered]@{
        Name        = $Name
        DisplayName = $DisplayName
        StartupType = $StartupType
        Keep        = $Keep
    }
}

function New-ScheduledTaskEntry {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = '\',
        [bool]$Keep = $true
    )
    return [ordered]@{
        Name = $Name
        Path = $Path
        Keep = $Keep
    }
}

# Canonical key orders for the repeating element shapes that live inside
# arrays. Import-PowerShellDataFile hands those back as unordered hashtables,
# so without this a re-save would reshuffle their keys and produce noisy diffs.
# The leading commas are required: without them PowerShell flattens nested
# array literals into one long list of strings.
$script:CanonicalKeyOrders = @(
    , @('Name', 'Value', 'Scope', 'Mode', 'Expandable', 'RemoveOnUninstall')  # env variable
    , @('Extension', 'ProgId', 'Description', 'OpenCommand', 'IconPath')    # file association
    , @('Name', 'DisplayName', 'StartupType', 'Keep')                       # service
    , @('Name', 'Path', 'Keep')                                             # scheduled task
    , @('Name', 'Verb', 'Target', 'Extensions', 'Executable', 'Arguments', 'Icon')  # context menu
    , @('Extension', 'ProgId', 'Description', 'Executable', 'Arguments', 'Icon')    # association (split form)
    , @('Name', 'DisplayName', 'Description', 'Executable', 'Arguments',
        'StartupType', 'StartAfterInstall', 'RemoveOnUninstall')                    # managed service
    , @('Name', 'Path', 'Executable', 'Arguments', 'Trigger', 'RunAsUser',
        'RunLevel', 'RunWhetherLoggedOnOrNot', 'RemoveOnUninstall')                 # managed task
)

function Get-CanonicalKeyOrder {
    <#
        Returns the preferred key order for a dictionary whose key set matches
        a known element shape, otherwise $null.
    #>
    param([Parameter(Mandatory)]$Dictionary)

    $keys = @($Dictionary.Keys | ForEach-Object { [string]$_ })

    foreach ($template in $script:CanonicalKeyOrders) {
        if ($keys.Count -ne $template.Count) { continue }
        $missing = @($keys | Where-Object { $template -notcontains $_ })
        if ($missing.Count -eq 0) { return $template }
    }
    return $null
}

function ConvertTo-OrderedModel {
    <#
        Recursively converts hashtables (as returned by
        Import-PowerShellDataFile) into ordered dictionaries so that
        re-serialization produces stable output.

        Ordered input keeps its order. Unordered input is placed in canonical
        order when its shape is recognised, and alphabetical order otherwise,
        so repeated save cycles are byte-stable.
    #>
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}

        $keyOrder = if ($InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
            @($InputObject.Keys)                       # author order already correct
        }
        else {
            $canonical = Get-CanonicalKeyOrder -Dictionary $InputObject
            if ($canonical) { $canonical } else { @($InputObject.Keys | Sort-Object) }
        }

        foreach ($key in $keyOrder) {
            $result[[string]$key] = ConvertTo-OrderedModel $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) { $items += , (ConvertTo-OrderedModel $item) }
        return , $items
    }

    return $InputObject
}

function Merge-ConfigModel {
    <#
        .SYNOPSIS
        Overlays a loaded configuration onto the default model.

        Keys present in the default but missing from the file take the default
        value. Keys present in the file but unknown to the default are kept, so
        hand-written additions survive a Studio round-trip.
    #>
    param(
        # Both sides may legitimately be $null (e.g. Detection.MinimumVersion),
        # so neither can be a mandatory non-null parameter.
        [AllowNull()]$Default,
        [AllowNull()]$Loaded
    )

    if ($null -eq $Loaded) { return $Default }

    if ($Default -is [System.Collections.IDictionary] -and
        $Loaded -is [System.Collections.IDictionary]) {

        $result = [ordered]@{}

        # Defaults first, so canonical ordering wins.
        foreach ($key in $Default.Keys) {
            if ($Loaded.Contains($key)) {
                $result[$key] = Merge-ConfigModel -Default $Default[$key] -Loaded $Loaded[$key]
            }
            else {
                $result[$key] = $Default[$key]
            }
        }

        # Then anything the file had that the schema does not know about.
        foreach ($key in $Loaded.Keys) {
            if (-not $result.Contains($key)) {
                $result[$key] = ConvertTo-OrderedModel $Loaded[$key]
            }
        }

        return $result
    }

    # Scalars and arrays: the file wins outright.
    return ConvertTo-OrderedModel $Loaded
}

function Import-ConfigModel {
    <#
        .SYNOPSIS
        Loads a .psd1 from disk and reconstructs the editable model.

        .DESCRIPTION
        This is what makes "Open Existing Configuration" work: the file is
        parsed, merged over the schema defaults, and returned in a shape the
        wizard and GUI screens can bind to.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    $loaded = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop

    $default = New-ConfigModel
    $model = Merge-ConfigModel -Default $default -Loaded $loaded

    return $model
}

function Copy-ConfigModel {
    param([Parameter(Mandatory)]$Model)
    return ConvertTo-OrderedModel $Model
}

# --- Installation profiles -------------------------------------------------
#
# A starting point, not a constraint. Applying a profile turns sections on;
# everything it does not mention is left exactly as it was, so a profile can
# be applied to a part-built configuration without undoing anything.

$script:ConfigurationProfiles = [ordered]@{
    Minimal  = @('Installer', 'Detection')
    Standard = @('Installer', 'Detection', 'DesktopShortcut', 'StartMenuShortcut')
    Full     = @('Installer', 'Detection', 'DesktopShortcut', 'StartMenuShortcut',
                 'ContextMenu', 'FileAssociations', 'Path', 'EnvironmentVariables')
}

function Get-ConfigurationProfileNames {
    return @($script:ConfigurationProfiles.Keys)
}

function Get-ConfigurationProfileFeatures {
    param([Parameter(Mandatory)][string]$Name)
    $key = @($script:ConfigurationProfiles.Keys | Where-Object { $_ -eq $Name })
    if ($key.Count -eq 0) {
        throw "Unknown profile '$Name'. Available: $((Get-ConfigurationProfileNames) -join ', ')."
    }
    return @($script:ConfigurationProfiles[$key[0]])
}

function Set-ConfigurationProfile {
    <#
        .SYNOPSIS
        Turns on the sections a named profile covers.

        .DESCRIPTION
        Shortcuts, context menus and associations are switched to MANAGE,
        because a profile is an explicit request for the framework to create
        them. Nothing is populated with invented values: the technician still
        supplies names and targets, and validation reports whatever is missing.

        Returns the same model, mutated in place.
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Name
    )

    $features = Get-ConfigurationProfileFeatures -Name $Name
    $wi = $Model.WindowsIntegration

    $integrationFeatures = @('DesktopShortcut', 'StartMenuShortcut', 'ContextMenu', 'FileAssociations')
    $wantsIntegration = @($integrationFeatures | Where-Object { $features -contains $_ })

    if ($wantsIntegration.Count -gt 0) {
        $wi.Enabled = $true
        foreach ($feature in $wantsIntegration) {
            $wi[$feature].Mode = 'MANAGE'
            $wi[$feature].Enabled = $true
        }
    }

    if ($features -contains 'Path' -or $features -contains 'EnvironmentVariables') {
        $Model.Environment.Enabled = $true
        if ($features -contains 'Path') {
            $Model.Environment.SystemPath.Enabled = $true
        }
    }

    return $Model
}
