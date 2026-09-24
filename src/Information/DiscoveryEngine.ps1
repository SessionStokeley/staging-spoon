<#
.SYNOPSIS
    Automatic discovery of everything the platform can work out for itself.
.DESCRIPTION
    Discovery runs before any prompt. Each discoverer reports what it found and
    the evidence for it, writes into the project state, and leaves fields it
    cannot resolve alone. A field only reaches the user after every discoverer
    that could produce it has been tried and failed.
#>

Set-StrictMode -Version Latest

# Tokens that identify a target architecture in a vendor's file name.
$script:ArchitectureTokens = [ordered]@{
    'arm64'   = 'ARM64'
    'aarch64' = 'ARM64'
    'amd64'   = 'x64'
    'x86_64'  = 'x64'
    'x64'     = 'x64'
    'win64'   = 'x64'
    '64bit'   = 'x64'
    'i386'    = 'x86'
    'i686'    = 'x86'
    'win32'   = 'x86'
    'x86'     = 'x86'
    '32bit'   = 'x86'
}

# Words vendors put in file names that are never part of the product name.
$script:FileNameNoiseWords = @(
    'setup', 'installer', 'install', 'standalone', 'enterprise', 'offline'
    'online', 'full', 'web', 'latest', 'final', 'release', 'package'
    'bundle', 'redist', 'redistributable', 'msi', 'exe', 'windows', 'win'
)

# Marker strings that identify the installer toolkit, which in turn gives the
# silent switches and the exit codes that mean success.
$script:InstallerFamilyMarkers = [ordered]@{
    'Inno Setup'    = 'InnoSetup'
    'Nullsoft'      = 'NSIS'
    'NullsoftInst'  = 'NSIS'
    'InstallShield' = 'InstallShield'
    'WixBundle'     = 'WiXBurn'
    'Burn.Elevated' = 'WiXBurn'
    'Squirrel'      = 'Squirrel'
}

$script:InstallerFamilyProfile = @{
    'MSI'           = @{ Silent = '/qn /norestart';                        ExitCodes = @(0, 1641, 3010) }
    'InnoSetup'     = @{ Silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; ExitCodes = @(0, 1641, 3010) }
    'NSIS'          = @{ Silent = '/S';                                    ExitCodes = @(0) }
    'InstallShield' = @{ Silent = '/s /v"/qn REBOOT=ReallySuppress"';      ExitCodes = @(0, 1641, 3010) }
    'WiXBurn'       = @{ Silent = '/quiet /norestart';                     ExitCodes = @(0, 1641, 3010) }
    'Squirrel'      = @{ Silent = '--silent';                              ExitCodes = @(0) }
}

function Get-VersionFromText {
    <#
    .SYNOPSIS
        Extracts the most plausible version number from a string.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    # A dotted version only: a bare number is usually a year or an architecture
    # token. The lookbehinds reject a fragment of a longer version (the "2.3" in
    # "1.2.3") while still allowing one that follows a separator dot, as in
    # "npp.8.6.2.Installer"; the lookahead allows a trailing file extension.
    $match = [regex]::Match($Text, '(?<!\d)(?<!\d\.)(\d+(?:\.\d+){1,3})(?!\d)')
    if ($match.Success) { return $match.Groups[1].Value }

    ''
}

function Get-ArchitectureFromText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $lower = $Text.ToLowerInvariant()

    foreach ($token in $script:ArchitectureTokens.Keys) {
        if ($lower -match "(?<![a-z0-9])$([regex]::Escape($token))(?![a-z0-9])") {
            return $script:ArchitectureTokens[$token]
        }
    }

    ''
}

function Get-ApplicationNameFromFileName {
    <#
    .SYNOPSIS
        Derives a product name from an installer file name.
    .DESCRIPTION
        Strips the version, the architecture token and the packaging noise
        words, then restores spacing. The result is a starting point offered to
        the user, not an authority: installer metadata outranks it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FileName)

    $stem = Get-CanonicalBaseName -Path $FileName
    if (-not $stem) { return '' }

    $version = Get-VersionFromText -Text $stem
    if ($version) { $stem = $stem.Replace($version, ' ') }

    foreach ($token in $script:ArchitectureTokens.Keys) {
        $stem = [regex]::Replace($stem, "(?<![a-z0-9])$([regex]::Escape($token))(?![a-z0-9])", ' ', 'IgnoreCase')
    }

    # Split camel case before separators are lost: GoogleChrome -> Google Chrome.
    $stem = [regex]::Replace($stem, '(?<=[a-z])(?=[A-Z])', ' ')
    $stem = $stem -replace '[._\-+]', ' '

    $words = @(
        foreach ($word in ($stem -split '\s+')) {
            if (-not $word) { continue }
            if ($word.ToLowerInvariant() -in $script:FileNameNoiseWords) { continue }
            $word
        }
    )

    ($words -join ' ').Trim()
}

function Get-InstallerFamily {
    <#
    .SYNOPSIS
        Identifies the toolkit that produced an installer, by its markers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ScanBytes = 4MB
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }

    if ((Get-CanonicalExtension -Path $Path).ToLowerInvariant() -eq '.msi') { return 'MSI' }

    try {
        # Paths reaching here are in canonical forward-slash form; resolve them
        # to the native provider path the raw file APIs expect.
        $nativePath = (Resolve-Path -LiteralPath $Path).ProviderPath

        $stream = [System.IO.File]::OpenRead($nativePath)
        try {
            $length = [Math]::Min($ScanBytes, $stream.Length)
            $buffer = [byte[]]::new($length)
            $read   = $stream.Read($buffer, 0, $length)
        } finally {
            $stream.Dispose()
        }

        if ($read -le 0) { return '' }

        # Installer toolkits leave ASCII markers; scanning as Latin-1 keeps
        # byte offsets aligned and avoids UTF-8 decode failures on binaries.
        $text = (Get-Latin1Encoding).GetString($buffer, 0, $read)

        foreach ($marker in $script:InstallerFamilyMarkers.Keys) {
            if ($text.Contains($marker)) { return $script:InstallerFamilyMarkers[$marker] }
        }
    } catch {
        # An unreadable installer means an unknown family, not a failed build,
        # but the reason is worth having when discovery comes back empty.
        Write-Verbose "Could not scan installer for toolkit markers: $_"
        return ''
    }

    ''
}

function Get-InstallerFamilyProfile {
    <#
    .SYNOPSIS
        The silent switches and success exit codes for a known toolkit.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Family)

    if ($Family -and $script:InstallerFamilyProfile.ContainsKey($Family)) {
        $profileData = $script:InstallerFamilyProfile[$Family]
        return [PSCustomObject]@{
            Family    = $Family
            Silent    = $profileData.Silent
            ExitCodes = $profileData.ExitCodes
        }
    }

    $null
}

function Get-MsiProperty {
    <#
    .SYNOPSIS
        Reads the MSI property table. Windows only; returns nothing elsewhere.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $properties = @{}

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $properties }

    $installer = $null
    $database  = $null
    $view      = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database  = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))

        $view = $database.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $database, @('SELECT `Property`, `Value` FROM `Property`'))

        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null

        while ($true) {
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($null -eq $record) { break }

            $name  = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
            $value = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(2))
            if ($name) { $properties[$name] = $value }
        }
    } catch {
        Write-Verbose "MSI property table unreadable: $_"
    } finally {
        foreach ($comObject in @($view, $database, $installer)) {
            if ($null -ne $comObject) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) | Out-Null
            }
        }
    }

    $properties
}

function Find-InstalledApplication {
    <#
    .SYNOPSIS
        Reads Add/Remove Programs from both registry views.
    #>
    [CmdletBinding()]
    param([string]$NameLike = '*')

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $results = foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $properties) { continue }

            $names = $properties.PSObject.Properties.Name
            if ('DisplayName' -notin $names) { continue }
            if (-not $properties.DisplayName) { continue }
            if ($properties.DisplayName -notlike $NameLike) { continue }

            $getValue = {
                param($propertyName)
                if ($propertyName -in $names) { $properties.$propertyName } else { '' }
            }

            [PSCustomObject]@{
                DisplayName     = $properties.DisplayName
                DisplayVersion  = & $getValue 'DisplayVersion'
                Publisher       = & $getValue 'Publisher'
                InstallLocation = & $getValue 'InstallLocation'
                UninstallString = & $getValue 'UninstallString'
                ProductCode     = $key.PSChildName
                RegistryView    = if ($root -match 'WOW6432Node') { 'x86' } else { 'x64' }
                RegistryPath    = $key.PSPath
            }
        }
    }

    @($results)
}

function Invoke-InstallerDiscovery {
    <#
    .SYNOPSIS
        Populates everything derivable from a selected installer.
    .DESCRIPTION
        This is the step that makes selecting an installer enough: the name,
        version, publisher, architecture, type, size, hash and silent switches
        all follow from it, each recorded with the source that produced it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$InstallerPath
    )

    $found = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Installer not found: $InstallerPath"
    }

    $identity = Get-FileIdentity -Path $InstallerPath
    $fileName = $identity.FileName

    Set-ProjectField -Project $Project -Path 'installer.fileName' -Value $fileName `
        -Source 'DERIVED' -Evidence 'File name of the selected installer' | Out-Null
    Set-ProjectField -Project $Project -Path 'installer.size' -Value $identity.Size `
        -Source 'DERIVED' -Evidence 'File size on disk' | Out-Null
    Set-ProjectField -Project $Project -Path 'installer.hash' -Value $identity.SHA256 `
        -Source 'DERIVED' -Evidence 'SHA-256 of the selected installer' | Out-Null
    $found.Add('installer.fileName')

    $extension = $identity.Extension.ToLowerInvariant()
    $installerType = switch ($extension) {
        '.msi'  { 'MSI' }
        '.exe'  { 'EXE' }
        '.msix' { 'MSIX' }
        '.appx' { 'APPX' }
        '.ps1'  { 'Script' }
        default { '' }
    }

    if ($installerType) {
        Set-ProjectField -Project $Project -Path 'installer.type' -Value $installerType `
            -Source 'DERIVED' -Evidence "Derived from the $extension extension" | Out-Null
        $found.Add('installer.type')
    }

    # Version resource metadata, where the binary carries it.
    if ($identity.ProductName) {
        Set-ProjectField -Project $Project -Path 'application.name' -Value $identity.ProductName `
            -Source 'INSTALLER_METADATA' -Evidence 'ProductName in the installer version resource' | Out-Null
        $found.Add('application.name')
    }
    if ($identity.Publisher) {
        Set-ProjectField -Project $Project -Path 'application.publisher' -Value $identity.Publisher `
            -Source 'INSTALLER_METADATA' -Evidence 'CompanyName in the installer version resource' | Out-Null
        $found.Add('application.publisher')
    }
    if ($identity.Version) {
        $version = Get-VersionFromText -Text $identity.Version
        if ($version) {
            Set-ProjectField -Project $Project -Path 'application.version' -Value $version `
                -Source 'INSTALLER_METADATA' -Evidence 'FileVersion in the installer version resource' | Out-Null
            $found.Add('application.version')
        }
    }

    # MSI property table outranks a version resource when both are present.
    if ($installerType -eq 'MSI') {
        $properties = Get-MsiProperty -Path $InstallerPath

        $msiFields = @(
            @{ Property = 'ProductName';    Field = 'application.name' }
            @{ Property = 'ProductVersion'; Field = 'application.version' }
            @{ Property = 'Manufacturer';   Field = 'application.publisher' }
            @{ Property = 'ProductCode';    Field = 'installer.productCode' }
            @{ Property = 'UpgradeCode';    Field = 'installer.upgradeCode' }
        )

        foreach ($entry in $msiFields) {
            if (-not $properties.ContainsKey($entry.Property)) { continue }
            $value = $properties[$entry.Property]
            if (-not $value) { continue }

            Set-ProjectField -Project $Project -Path $entry.Field -Value $value `
                -Source 'INSTALLER_METADATA' -Evidence "$($entry.Property) in the MSI property table" | Out-Null
            $found.Add($entry.Field)
        }
    }

    # File-name derivation fills what the metadata left empty.
    if (-not (Test-ProjectFieldKnown -Project $Project -Path 'application.name')) {
        $derivedName = Get-ApplicationNameFromFileName -FileName $fileName
        if ($derivedName) {
            Set-ProjectField -Project $Project -Path 'application.name' -Value $derivedName `
                -Source 'DERIVED' -Evidence "Derived from the installer file name '$fileName'" | Out-Null
            $found.Add('application.name')
        }
    }

    if (-not (Test-ProjectFieldKnown -Project $Project -Path 'application.version')) {
        $derivedVersion = Get-VersionFromText -Text $fileName
        if ($derivedVersion) {
            Set-ProjectField -Project $Project -Path 'application.version' -Value $derivedVersion `
                -Source 'DERIVED' -Evidence "Derived from the installer file name '$fileName'" | Out-Null
            $found.Add('application.version')
        }
    }

    $architecture = Get-ArchitectureFromText -Text $fileName
    if ($architecture) {
        Set-ProjectField -Project $Project -Path 'application.architecture' -Value $architecture `
            -Source 'DERIVED' -Evidence "Derived from the installer file name '$fileName'" | Out-Null
        $found.Add('application.architecture')
    }

    # The installer toolkit gives silent switches and success exit codes.
    $family = Get-InstallerFamily -Path $InstallerPath
    if ($family) {
        Add-Fact -Store $Project.Evidence -Key 'installer.family' -Value $family `
            -Source 'INSTALLER_METADATA' -Evidence 'Toolkit marker found in the installer binary' | Out-Null

        $familyProfile = Get-InstallerFamilyProfile -Family $family
        if ($null -ne $familyProfile) {
            Set-ProjectField -Project $Project -Path 'installer.silentArguments' -Value $familyProfile.Silent `
                -Source 'DERIVED' -Evidence "Standard silent switches for $family" | Out-Null
            Set-ProjectField -Project $Project -Path 'deployment.expectedExitCodes' -Value $familyProfile.ExitCodes `
                -Source 'DERIVED' -Evidence "Success exit codes for $family" | Out-Null
            $found.Add('installer.silentArguments')
            $found.Add('deployment.expectedExitCodes')
        }
    }

    [PSCustomObject]@{
        InstallerPath = $InstallerPath
        Family        = $family
        FieldsFound   = @($found | Select-Object -Unique)
    }
}

function Invoke-InstalledApplicationDiscovery {
    <#
    .SYNOPSIS
        Recovers deployment information from an application already present on
        the reference machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string]$NameLike = ''
    )

    if (-not $NameLike) {
        $name = Get-ProjectFieldValue -Project $Project -Path 'application.name' -Default ''
        if (-not $name) {
            return [PSCustomObject]@{ Matched = @(); FieldsFound = @() }
        }
        $NameLike = "$name*"
    }

    $matched = @(Find-InstalledApplication -NameLike $NameLike)
    $found   = [System.Collections.Generic.List[string]]::new()

    if ($matched.Count -eq 0) {
        return [PSCustomObject]@{ Matched = @(); FieldsFound = @() }
    }

    # Several matches means the platform cannot tell which is the product; the
    # observations are kept as facts and the user is asked to choose.
    if ($matched.Count -gt 1) {
        foreach ($entry in $matched) {
            Add-Fact -Store $Project.Evidence -Key 'installedApplication.candidate' -Value $entry.DisplayName `
                -Source 'INSTALLED_SYSTEM' -Evidence "$($entry.DisplayName) $($entry.DisplayVersion) ($($entry.RegistryView))" | Out-Null
        }
        return [PSCustomObject]@{ Matched = $matched; FieldsFound = @() }
    }

    $application = $matched[0]

    $mappings = @(
        @{ Value = $application.DisplayName;     Field = 'installation.uninstallDisplayName'; Evidence = 'DisplayName in the uninstall registry' }
        @{ Value = $application.DisplayVersion;  Field = 'application.version';               Evidence = 'DisplayVersion in the uninstall registry' }
        @{ Value = $application.Publisher;       Field = 'application.publisher';             Evidence = 'Publisher in the uninstall registry' }
        @{ Value = $application.InstallLocation; Field = 'installation.installLocation';      Evidence = 'InstallLocation in the uninstall registry' }
        @{ Value = $application.UninstallString; Field = 'installation.uninstallString';      Evidence = 'UninstallString in the uninstall registry' }
    )

    foreach ($mapping in $mappings) {
        if (-not $mapping.Value) { continue }
        Set-ProjectField -Project $Project -Path $mapping.Field -Value $mapping.Value `
            -Source 'INSTALLED_SYSTEM' -Evidence $mapping.Evidence | Out-Null
        $found.Add($mapping.Field)
    }

    if ($application.ProductCode -match '^\{[0-9A-Fa-f-]+\}$') {
        Set-ProjectField -Project $Project -Path 'installer.productCode' -Value $application.ProductCode `
            -Source 'INSTALLED_SYSTEM' -Evidence 'Registry key name in the uninstall registry' | Out-Null
        $found.Add('installer.productCode')
    }

    [PSCustomObject]@{
        Matched     = $matched
        FieldsFound = @($found | Select-Object -Unique)
    }
}

function Find-ProjectInstaller {
    <#
    .SYNOPSIS
        Scans the project for installers, without choosing between them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string]$SubPath = ''
    )

    $root = if ($SubPath) { Join-Path $Project.Root $SubPath } else { $Project.Root }
    @(Find-CandidateResource -Path $root -Type @('installer') -Recurse)
}

function Find-PackagingTool {
    <#
    .SYNOPSIS
        Locates IntuneWinAppUtil.exe rather than asking for its path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    $searchRoots = [System.Collections.Generic.List[string]]::new()
    $searchRoots.Add($Project.Root)

    foreach ($key in @('ProgramFiles', 'ProgramFilesX86', 'LocalAppData')) {
        $locations = Get-KnownWindowsLocation
        if ($locations.Contains($key)) { $searchRoots.Add($locations[$key]) }
    }

    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        $match = Get-ChildItem -LiteralPath $root -Filter 'IntuneWinAppUtil.exe' `
                               -File -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1

        if ($match) {
            Set-ProjectField -Project $Project -Path 'package.intuneWinAppUtilPath' -Value $match.FullName `
                -Source 'FILESYSTEM' -Evidence "Found under $root" | Out-Null
            return $match.FullName
        }
    }

    ''
}
