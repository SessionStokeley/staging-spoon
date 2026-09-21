#Requires -Version 5.1

<#
    PackageConfig.ps1

    The package configuration: its shape, its defaults, and reading and writing
    it.

    The configuration is the single authoritative source of installer
    arguments. Intune's command line only launches the wrapper, so nothing is
    passed in from the Program command and there is nowhere for a second set of
    arguments to come from.

    Flat on purpose. Every key a technician edits is at the top level or one
    level down, so the file reads as a description of the package rather than a
    schema to navigate.
#>

$script:BuilderName = 'Intune Package Builder'

# Stamped into generated packages, so a package records which builder produced
# it. A fix shipped in the template only reaches packages generated afterwards,
# and this is how you tell which those are.
$script:BuilderVersion = '1.0.0'

$script:InstallerTypes  = @('EXE', 'MSI', 'BAT')
$script:Architectures   = @('x64', 'x86', 'ARM64', 'Any')
$script:PathScopes      = @('Machine', 'User')
$script:ShortcutPlaces  = @('Desktop', 'StartMenu')
$script:ContextTargets  = @('File', 'Folder', 'Directory', 'AllFiles')
$script:DetectionTypes  = @('File', 'Folder', 'Registry', 'MSI')
$script:VersionOperators = @('Equals', 'GreaterThan', 'GreaterThanOrEqual')
$script:RebootBehaviors = @('Suppress', 'Allow', 'Prompt')

function Get-BuilderName    { return $script:BuilderName }
function Get-BuilderVersion { return $script:BuilderVersion }

function Get-InstallerTypes   { return $script:InstallerTypes }
function Get-Architectures    { return $script:Architectures }
function Get-DetectionTypes   { return $script:DetectionTypes }
function Get-ContextTargets   { return $script:ContextTargets }
function Get-ShortcutPlaces   { return $script:ShortcutPlaces }
function Get-VersionOperators { return $script:VersionOperators }
function Get-RebootBehaviors  { return $script:RebootBehaviors }

function New-PackageConfig {
    <#
        .SYNOPSIS
        A configuration populated with safe defaults.

        Everything optional starts off. The builder turns things on only when
        the technician asks, or when Installation Capture proposes a change and
        it is approved.
    #>
    param(
        [string]$ApplicationName = 'Example Application',
        [string]$Publisher = 'Example Publisher',
        [string]$Version = '1.0.0'
    )

    return [ordered]@{
        ApplicationName = $ApplicationName
        Publisher       = $Publisher
        Version         = $Version
        Description     = ''
        Architecture    = 'x64'

        # EXE  launched directly
        # MSI  msiexec.exe /i "<file>" <arguments>
        # BAT  cmd.exe /c call "<file>" <arguments>, from its own directory
        InstallerType = 'EXE'
        InstallerFile = ''

        # The authoritative installer arguments. Supply the application's real
        # silent switches; they are never guessed at or modified.
        InstallArguments   = ''
        UninstallArguments = ''

        # MSI only. Uninstall uses msiexec /x <ProductCode>.
        ProductCode = $null

        # Where the application lands. Used as the default for detection and
        # for shortcut targets, and recorded for review.
        InstallPath = ''

        SuccessExitCodes = @(0, 3010)
        RebootBehavior   = 'Suppress'

        Path = [ordered]@{
            Enabled = $false
            Scope   = 'Machine'
            Value   = ''
        }

        FileAssociations = @()
        ContextMenus     = @()
        Shortcuts        = @()

        Detection = [ordered]@{
            Type              = 'File'
            Path              = ''
            Version           = ''
            VersionComparison = 'GreaterThanOrEqual'
        }

        Logging = [ordered]@{
            Enabled = $true
            Path    = 'C:\ProgramData\IntunePackageBuilder\Logs'
        }

        Builder = [ordered]@{
            Name    = $script:BuilderName
            Version = $script:BuilderVersion
        }
    }
}

function New-FileAssociation {
    <#
        SetAsDefault is off by default. Registering a handler adds the
        application under "Open with"; taking the extension over is a
        user-visible change, and Windows manages default associations through
        its own mechanism rather than the registry key alone.
    #>
    param(
        [Parameter(Mandatory)][string]$Extension,
        [string]$Description = '',
        [Parameter(Mandatory)][string]$Executable,
        [string]$Icon = '',
        [string]$ProgId = '',
        [bool]$SetAsDefault = $false
    )

    $normalized = $Extension.Trim()
    if ($normalized -and -not $normalized.StartsWith('.')) { $normalized = ".$normalized" }

    return [ordered]@{
        Extension    = $normalized
        Description  = $Description
        Executable   = $Executable
        Icon         = $Icon
        ProgId       = $ProgId
        SetAsDefault = $SetAsDefault
    }
}

function New-ContextMenu {
    <#
        Verb is what makes removal safe: uninstall deletes this package's own
        key and nothing else. One is derived from the name when not supplied,
        but a vendor-prefixed verb is far less likely to collide.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [ValidateSet('File', 'Folder', 'Directory', 'AllFiles')][string]$AppliesTo = 'File',
        [string[]]$Extensions = @(),
        [string]$Icon = '',
        [string]$Verb = ''
    )

    $resolvedVerb = $Verb
    if (-not $resolvedVerb) {
        $resolvedVerb = 'IntunePackageBuilder.' + ($Name -replace '[^A-Za-z0-9]', '')
    }

    return [ordered]@{
        Name       = $Name
        Verb       = $resolvedVerb
        Command    = $Command
        AppliesTo  = $AppliesTo
        Extensions = @($Extensions)
        Icon       = $Icon
    }
}

function New-Shortcut {
    <#
        Intune runs as SYSTEM, where "the current user" is the system profile
        and not any real person. Desktop therefore means the Public Desktop and
        StartMenu means the all-users Start Menu - those are the locations that
        produce a shortcut every user can actually see.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [ValidateSet('Desktop', 'StartMenu')][string]$Location = 'Desktop',
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$Icon = '',
        [string]$Folder = ''
    )

    return [ordered]@{
        Name             = $Name
        Target           = $Target
        Location         = $Location
        Arguments        = $Arguments
        WorkingDirectory = $WorkingDirectory
        Icon             = $Icon
        Folder           = $Folder
    }
}

function Get-ConfigComments {
    <#
        Comments emitted into the generated Configuration.psd1. They explain
        the decisions a technician has to make, not the syntax.
    #>
    return @{
        'InstallerType' = @'
EXE  launched directly
MSI  msiexec.exe /i "<file>" <arguments>
BAT  cmd.exe /c call "<file>" <arguments>, from its own directory
'@
        'InstallArguments' = @'
The application's real silent switches. This is the only place installer
arguments are defined - Intune's command line only launches the wrapper.
'@
        'ProductCode' = 'MSI only. Uninstall runs msiexec /x with this.'
        'SuccessExitCodes' = '3010 means success with a reboot pending.'
        'Path' = @'
Machine PATH is the normal choice for an Intune System deployment. User PATH
from SYSTEM only reaches the system profile, which no real user sees.
'@
        'FileAssociations' = @'
Registering a handler offers the application under "Open with". SetAsDefault
additionally takes the extension over, and records the previous handler so
uninstall can put it back.
'@
        'ContextMenus' = @'
Verb must be application-specific: it is what lets uninstall remove this
package's key and nothing else.
'@
        'Shortcuts' = 'Desktop is the Public Desktop; StartMenu is the all-users Start Menu.'
        'Detection' = 'What Intune checks to decide the application is installed.'
    }
}

function Import-PackageConfig {
    <#
        Loads a configuration and merges it over the defaults, so a file
        written by an older builder still opens and keys the builder does not
        know about are preserved rather than dropped.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Strict
    )

    $loaded = Import-Psd1 -Path $Path -Strict:$Strict
    return (Merge-PackageConfig -Default (New-PackageConfig) -Loaded $loaded)
}

function Merge-PackageConfig {
    param([AllowNull()]$Default, [AllowNull()]$Loaded)

    if ($null -eq $Loaded) { return $Default }

    if ($Default -is [System.Collections.IDictionary] -and $Loaded -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Default.Keys) {
            if ($Loaded.Contains($key)) {
                $result[$key] = Merge-PackageConfig -Default $Default[$key] -Loaded $Loaded[$key]
            }
            else { $result[$key] = $Default[$key] }
        }
        foreach ($key in $Loaded.Keys) {
            if (-not $result.Contains($key)) { $result[$key] = $Loaded[$key] }
        }
        return $result
    }

    # The comma is load-bearing. 'return $Loaded' unrolls a collection, so a
    # list holding exactly one entry - one shortcut, one association - comes
    # back as the bare entry instead of a list. Indexing it then yields $null
    # and the caller reads a property off nothing.
    if ($null -ne $Loaded -and $Loaded -isnot [string] -and
        $Loaded -is [System.Collections.IEnumerable]) {
        return , $Loaded
    }

    return $Loaded
}

function Export-PackageConfig {
    <#
        Writes the configuration as readable .psd1.

        UTF8 without a BOM: Windows PowerShell 5.1 reads a BOM-less UTF8 .psd1
        correctly, and a BOM shows up as stray characters in diffs.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path,
        [switch]$NoComments
    )

    $comments = @{}
    if (-not $NoComments) { $comments = Get-ConfigComments }

    $header = @"
# $($script:BuilderName) package configuration
# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
#
# Install.ps1, Uninstall.ps1 and Detection.ps1 read this file at runtime.
# Intune's command line only launches the wrapper:
#
#   powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install.ps1

"@

    $text = $header + (ConvertTo-Psd1Text -InputObject $Config -Comments $comments) + [Environment]::NewLine

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}
