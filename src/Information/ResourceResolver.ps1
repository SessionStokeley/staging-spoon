<#
.SYNOPSIS
    Resource references: files identified by more than their name.
.DESCRIPTION
    A file the platform depends on is stored as a reference carrying its
    project-relative path, name, size, hash and version metadata. That is what
    lets a project survive being moved, a file being relocated inside the
    project, or a resource being replaced by the same build from a different
    directory. When a reference cannot be resolved, recovery searches by
    decreasing certainty rather than failing outright.
#>

Set-StrictMode -Version Latest

$script:ResourceTypes = @(
    'installer'
    'script'
    'configuration'
    'transform'
    'license'
    'dependency'
    'capture'
    'package'
    'resource'
)

$script:ResourceExtensionMap = @{
    '.msi'       = 'installer'
    '.exe'       = 'installer'
    '.msix'      = 'installer'
    '.appx'      = 'installer'
    '.msixbundle'= 'installer'
    '.ps1'       = 'script'
    '.cmd'       = 'script'
    '.bat'       = 'script'
    '.vbs'       = 'script'
    '.mst'       = 'transform'
    '.msp'       = 'transform'
    '.json'      = 'configuration'
    '.xml'       = 'configuration'
    '.ini'       = 'configuration'
    '.config'    = 'configuration'
    '.rtf'       = 'license'
    '.txt'       = 'license'
    '.intunewin' = 'package'
}

function Get-ResourceTypeFromPath {
    <#
    .SYNOPSIS
        Classifies a dropped or selected file by extension.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $extension = Get-CanonicalExtension -Path $Path
    if (-not $extension) { return 'resource' }

    $key = $extension.ToLowerInvariant()
    if ($script:ResourceExtensionMap.ContainsKey($key)) { return $script:ResourceExtensionMap[$key] }

    'resource'
}

function Get-FileIdentity {
    <#
    .SYNOPSIS
        Everything needed to recognise a file again later.
    .PARAMETER SkipHash
        Skips the SHA-256 computation for large files when only the cheap
        attributes are wanted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$SkipHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cannot identify a file that does not exist: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $hash = if ($SkipHash) { '' } else { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

    $version   = ''
    $publisher = ''
    $product   = ''

    # Version metadata is a Windows concept; absent elsewhere and on data files.
    if ($item.Extension -in @('.exe', '.dll', '.msi')) {
        try {
            $info = $item.VersionInfo
            if ($info) {
                if ($info.FileVersion)   { $version   = $info.FileVersion.Trim() }
                if ($info.CompanyName)   { $publisher = $info.CompanyName.Trim() }
                if ($info.ProductName)   { $product   = $info.ProductName.Trim() }
            }
        } catch {
            # A file without a version resource is normal, not an error.
        }
    }

    [PSCustomObject]@{
        FileName     = $item.Name
        Extension    = $item.Extension
        Size         = $item.Length
        LastModified = $item.LastWriteTimeUtc.ToString('o')
        SHA256       = $hash
        Version      = $version
        Publisher    = $publisher
        ProductName  = $product
    }
}

function New-ResourceReference {
    <#
    .SYNOPSIS
        Creates a stored reference to a file the project depends on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateScript({ $_ -in $script:ResourceTypes })][string]$Type,
        [switch]$SkipHash
    )

    $storable = ConvertTo-StorablePath -Path $Path -ProjectRoot $ProjectRoot

    if (-not $PSBoundParameters.ContainsKey('Type')) {
        $Type = Get-ResourceTypeFromPath -Path $Path
    }

    $identity = if (Test-Path -LiteralPath $storable.Absolute -PathType Leaf) {
        Get-FileIdentity -Path $storable.Absolute -SkipHash:$SkipHash
    } else {
        [PSCustomObject]@{
            FileName     = Get-CanonicalLeaf -Path $storable.Absolute
            Extension    = Get-CanonicalExtension -Path $storable.Absolute
            Size         = 0
            LastModified = ''
            SHA256       = ''
            Version      = ''
            Publisher    = ''
            ProductName  = ''
        }
    }

    [PSCustomObject]@{
        Id           = $Id
        Type         = $Type
        StoredPath   = $storable.StoredPath
        IsExternal   = $storable.IsExternal
        FileName     = $identity.FileName
        Extension    = $identity.Extension
        Size         = $identity.Size
        LastModified = $identity.LastModified
        SHA256       = $identity.SHA256
        Version      = $identity.Version
        Publisher    = $identity.Publisher
        ProductName  = $identity.ProductName
        RegisteredAt = (Get-Date).ToString('o')
    }
}

function Resolve-ResourceReference {
    <#
    .SYNOPSIS
        Finds the file a reference points at.
    .DESCRIPTION
        Tries the stored path first, then recovery strategies in decreasing
        order of certainty. Every outcome reports which strategy produced it so
        the user can see whether the platform is certain or guessing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Reference,
        [Parameter(Mandatory)][hashtable]$Anchors,
        [string[]]$SearchRoots = @()
    )

    $resolved = Resolve-ProjectPath -Path $Reference.StoredPath -Anchors $Anchors

    if ($resolved.Exists) {
        return [PSCustomObject]@{
            Found      = $true
            Path       = $resolved.Path
            Strategy   = 'StoredPath'
            Confidence = 'CONFIRMED'
            Candidates = @()
        }
    }

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @('ProjectRoot', 'SourceDirectory', 'InstallerDirectory', 'OutputDirectory')) {
        if ($Anchors.ContainsKey($key) -and $Anchors[$key]) { $roots.Add($Anchors[$key]) }
    }
    foreach ($root in $SearchRoots) {
        if ($root) { $roots.Add($root) }
    }

    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        $matches = @(Get-ChildItem -LiteralPath $root -Filter $Reference.FileName -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($match in $matches) {
            $candidates.Add([PSCustomObject]@{
                Path = $match.FullName
                Size = $match.Length
            })
        }
    }

    if ($candidates.Count -eq 0) {
        return [PSCustomObject]@{
            Found      = $false
            Path       = ''
            Strategy   = 'NotFound'
            Confidence = 'LOW'
            Candidates = @()
        }
    }

    # Name plus hash is an exact identity match: the same file, moved.
    if ($Reference.SHA256) {
        foreach ($candidate in $candidates) {
            if ($candidate.Size -ne $Reference.Size) { continue }
            $hash = (Get-FileHash -LiteralPath $candidate.Path -Algorithm SHA256).Hash
            if ($hash -eq $Reference.SHA256) {
                return [PSCustomObject]@{
                    Found      = $true
                    Path       = $candidate.Path
                    Strategy   = 'FileNameAndHash'
                    Confidence = 'CONFIRMED'
                    Candidates = @()
                }
            }
        }
    }

    # Name plus version and publisher is the same build from elsewhere.
    if ($Reference.Version) {
        $versionMatches = @(
            foreach ($candidate in $candidates) {
                $identity = Get-FileIdentity -Path $candidate.Path -SkipHash
                if ($identity.Version -eq $Reference.Version -and
                    ($null -eq $Reference.Publisher -or -not $Reference.Publisher -or $identity.Publisher -eq $Reference.Publisher)) {
                    $candidate.Path
                }
            }
        )

        if ($versionMatches.Count -eq 1) {
            return [PSCustomObject]@{
                Found      = $true
                Path       = $versionMatches[0]
                Strategy   = 'FileNameAndVersion'
                Confidence = 'HIGH'
                Candidates = @()
            }
        }
    }

    if ($candidates.Count -eq 1) {
        return [PSCustomObject]@{
            Found      = $true
            Path       = $candidates[0].Path
            Strategy   = 'FileNameOnly'
            Confidence = 'MEDIUM'
            Candidates = @()
        }
    }

    # Several plausible files and no way to choose: the user decides.
    [PSCustomObject]@{
        Found      = $false
        Path       = ''
        Strategy   = 'AmbiguousCandidates'
        Confidence = 'LOW'
        Candidates = @($candidates | ForEach-Object { $_.Path })
    }
}

function Test-ResourceCurrent {
    <#
    .SYNOPSIS
        Detects that a resolved file is no longer the file that was registered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Reference,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{ IsCurrent = $false; Reason = 'File no longer exists' }
    }

    if (-not $Reference.SHA256) {
        return [PSCustomObject]@{ IsCurrent = $true; Reason = 'No hash recorded to compare against' }
    }

    $identity = Get-FileIdentity -Path $Path

    if ($identity.SHA256 -eq $Reference.SHA256) {
        return [PSCustomObject]@{ IsCurrent = $true; Reason = 'Hash matches' }
    }

    [PSCustomObject]@{
        IsCurrent = $false
        Reason    = "File changed since it was registered (expected $($Reference.SHA256.Substring(0, 12)), found $($identity.SHA256.Substring(0, 12)))"
    }
}

function Find-CandidateResource {
    <#
    .SYNOPSIS
        Scans a directory for files the platform knows how to use, so the user
        picks from what is there instead of typing a path.
    .DESCRIPTION
        Ambiguity is surfaced, never resolved silently: when several installers
        are present, all of them are returned with the evidence needed to
        choose between them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Type = @('installer'),
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }

    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse -ErrorAction SilentlyContinue)

    $results = foreach ($file in $files) {
        $resourceType = Get-ResourceTypeFromPath -Path $file.FullName
        if ($resourceType -notin $Type) { continue }

        $identity = Get-FileIdentity -Path $file.FullName -SkipHash

        [PSCustomObject]@{
            Path        = $file.FullName
            FileName    = $identity.FileName
            Type        = $resourceType
            Size        = $identity.Size
            Version     = $identity.Version
            Publisher   = $identity.Publisher
            ProductName = $identity.ProductName
        }
    }

    @($results)
}
