<#
.SYNOPSIS
    Path normalization and resolution against project-relative anchors.
.DESCRIPTION
    Paths reach the platform in whatever shape the user or the operating system
    produced: forward slashes, trailing separators, relative fragments,
    environment tokens. They are normalized to one canonical representation
    before they are stored, and stored relative to the project root whenever
    they live inside the project, so a project keeps working after it is moved.
#>

Set-StrictMode -Version Latest

# Anchors a stored path can be resolved against, in the order they are tried.
$script:PathAnchors = @(
    'ProjectRoot'
    'SourceDirectory'
    'InstallerDirectory'
    'CaptureDirectory'
    'DeploymentDirectory'
    'OutputDirectory'
    'PreviousBuildDirectory'
)

function ConvertTo-CanonicalPath {
    <#
    .SYNOPSIS
        Reduces a path to one canonical internal form, using forward slashes.
    .DESCRIPTION
        Expands environment tokens, unifies separators, collapses . and ..
        segments and strips a trailing separator. The path does not need to
        exist - this is string normalization, not disk access.

        The canonical separator is "/" on every platform. A single stored form
        means a path reads the same in the project file, the report, the log
        and the console, and never acquires the doubled backslashes that a
        Windows path picks up the moment it is serialised to JSON. Windows
        accepts forward slashes in its filesystem APIs, and anything that needs
        the native form asks for it through ConvertTo-NativePath.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
    $expanded = $expanded -replace '\\', '/'

    $isUnc = $expanded.StartsWith('//')

    # Collapse repeated separators without destroying a UNC prefix.
    $collapsed = $expanded -replace '/{2,}', '/'
    if ($isUnc) { $collapsed = '/' + $collapsed }

    $hasDriveOrUnc = $isUnc -or $collapsed -match '^[A-Za-z]:'
    $segments = [System.Collections.Generic.List[string]]::new()

    foreach ($segment in $collapsed.Split('/')) {
        if ($segment -eq '.') { continue }

        if ($segment -eq '..') {
            # Only collapse when there is a real segment to remove; a leading
            # .. in a relative path is meaningful and must survive.
            $last = if ($segments.Count -gt 0) { $segments[$segments.Count - 1] } else { $null }
            if ($segments.Count -gt 0 -and $last -ne '..' -and $last -ne '') {
                $segments.RemoveAt($segments.Count - 1)
                continue
            }
        }

        $segments.Add($segment)
    }

    $result = $segments -join '/'

    if ($isUnc) { $result = '//' + $result.TrimStart('/') }

    # A drive root keeps its separator: C: alone is a drive-relative path.
    if ($result -match '^[A-Za-z]:$') { return $result + '/' }

    if ($result.Length -gt 3 -or -not $hasDriveOrUnc) {
        $result = $result.TrimEnd('/')
    }

    $result
}

function ConvertTo-NativePath {
    <#
    .SYNOPSIS
        The execution boundary: canonical form in, the host's own form out.
    .DESCRIPTION
        Called immediately before a path is handed to something that wants the
        platform's native spelling - an external process argument, a generated
        command, a message a Windows administrator will read as a Windows path.
        It is not called anywhere else, because converting paths at arbitrary
        points is how a codebase ends up with two representations and no rule
        about which is which.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $canonical = ConvertTo-CanonicalPath -Path $Path

    # On a non-Windows host the canonical form is already native.
    if (-not (Test-WindowsPlatform)) { return $canonical }

    $native = $canonical -replace '/', '\'
    if ($native -match '^[A-Za-z]:$') { return $native + '\' }

    $native
}

function Split-CanonicalPath {
    <#
    .SYNOPSIS
        The parent directory of a canonical path.
    .DESCRIPTION
        System.IO.Path honours only the running platform's separator, so it
        silently returns nothing for a path spelled the other way. Canonical
        paths use forward slashes on every platform, so splitting them has to
        be done here rather than by the framework.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $canonical = ConvertTo-CanonicalPath -Path $Path
    if (-not $canonical) { return '' }

    $isUnc = $canonical.StartsWith('//')
    $body  = if ($isUnc) { $canonical.Substring(2) } else { $canonical }

    $index = $body.LastIndexOf('/')
    if ($index -lt 0) { return '' }

    $parent = $body.Substring(0, $index)

    # A drive root keeps its separator; //server/share has no parent.
    if (-not $isUnc -and $parent -match '^[A-Za-z]:$') { return $parent + '/' }
    if ($isUnc) {
        if ($parent.IndexOf('/') -lt 0) { return '' }
        return '//' + $parent
    }

    $parent
}

function Get-CanonicalLeaf {
    <#
    .SYNOPSIS
        The final component of a canonical path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $canonical = ConvertTo-CanonicalPath -Path $Path
    if (-not $canonical) { return '' }

    $trimmed = $canonical.TrimEnd('/')
    if (-not $trimmed) { return '' }

    $index = $trimmed.LastIndexOf('/')
    if ($index -lt 0) { return $trimmed }

    $trimmed.Substring($index + 1)
}

function Get-CanonicalExtension {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $leaf = Get-CanonicalLeaf -Path $Path
    if (-not $leaf) { return '' }

    $index = $leaf.LastIndexOf('.')
    if ($index -le 0) { return '' }

    $leaf.Substring($index)
}

function Get-CanonicalBaseName {
    <#
    .SYNOPSIS
        The final component of a canonical path without its extension.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $leaf = Get-CanonicalLeaf -Path $Path
    if (-not $leaf) { return '' }

    $index = $leaf.LastIndexOf('.')
    if ($index -le 0) { return $leaf }

    $leaf.Substring(0, $index)
}

function Test-AbsolutePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    # Accepts either spelling: the value may arrive native from the OS or
    # canonical from storage.
    $normalized = $Path -replace '\\', '/'
    $normalized.StartsWith('//') -or $normalized -match '^[A-Za-z]:/'
}

function ConvertTo-RelativePath {
    <#
    .SYNOPSIS
        Expresses a path relative to a base directory, or returns empty when the
        path lies outside that base.
    .DESCRIPTION
        Only paths inside the base are made relative. A path outside stays
        absolute and is stored as an external reference, because rewriting it
        with .. segments would break as soon as either end moved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BasePath
    )

    $canonicalPath = ConvertTo-CanonicalPath -Path $Path
    $canonicalBase = ConvertTo-CanonicalPath -Path $BasePath

    if (-not $canonicalPath -or -not $canonicalBase) { return '' }

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not $canonicalPath.StartsWith($canonicalBase, $comparison)) { return '' }
    if ($canonicalPath.Length -eq $canonicalBase.Length) { return '' }

    $remainder = $canonicalPath.Substring($canonicalBase.Length)
    if (-not $remainder.StartsWith('/')) { return '' }

    $remainder.TrimStart('/')
}

function Resolve-ProjectPath {
    <#
    .SYNOPSIS
        Turns a stored path back into a usable absolute path.
    .DESCRIPTION
        An absolute stored path is returned as-is. A relative one is resolved
        against each anchor in turn, and the first anchor that produces an
        existing file or directory wins. When nothing exists, the ProjectRoot
        interpretation is returned so callers can report a precise miss.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][hashtable]$Anchors,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [PSCustomObject]@{ Path = ''; Exists = $false; Anchor = $null }
    }

    if (Test-AbsolutePath -Path $Path) {
        $canonical = ConvertTo-CanonicalPath -Path $Path
        return [PSCustomObject]@{
            Path   = $canonical
            Exists = (Test-Path -LiteralPath (ConvertTo-NativePath -Path $canonical))
            Anchor = 'Absolute'
        }
    }

    $fallback = $null

    foreach ($anchor in $script:PathAnchors) {
        if (-not $Anchors.ContainsKey($anchor)) { continue }
        $base = $Anchors[$anchor]
        if ([string]::IsNullOrWhiteSpace($base)) { continue }

        $candidate = ConvertTo-CanonicalPath -Path (Join-Path $base $Path)

        if (Test-Path -LiteralPath (ConvertTo-NativePath -Path $candidate)) {
            return [PSCustomObject]@{ Path = $candidate; Exists = $true; Anchor = $anchor }
        }

        if ($null -eq $fallback) {
            $fallback = [PSCustomObject]@{ Path = $candidate; Exists = $false; Anchor = $anchor }
        }
    }

    if ($null -eq $fallback) {
        $fallback = [PSCustomObject]@{
            Path   = ConvertTo-CanonicalPath -Path $Path
            Exists = $false
            Anchor = $null
        }
    }

    if ($MustExist -and -not $fallback.Exists) {
        throw "Path could not be resolved against any project anchor: $Path"
    }

    $fallback
}

function ConvertTo-StorablePath {
    <#
    .SYNOPSIS
        Prepares a path for storage: project-relative when it lives inside the
        project, absolute and marked external when it does not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $canonical = ConvertTo-CanonicalPath -Path $Path
    $relative  = ConvertTo-RelativePath -Path $canonical -BasePath $ProjectRoot

    if ($relative) {
        [PSCustomObject]@{
            StoredPath = $relative
            IsExternal = $false
            Absolute   = $canonical
        }
    } else {
        [PSCustomObject]@{
            StoredPath = $canonical
            IsExternal = $true
            Absolute   = $canonical
        }
    }
}

function Test-PathCharacterValid {
    <#
    .SYNOPSIS
        Rejects paths Windows cannot represent, before they reach a build.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $problems = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $problems.Add('Path is empty')
    } else {
        # Drive colons are legal; any other colon is not.
        $withoutDrive = $Path -replace '^[A-Za-z]:', ''
        if ($withoutDrive.Contains(':')) {
            $problems.Add('Path contains a colon outside the drive specifier')
        }

        foreach ($char in @('<', '>', '"', '|', '?', '*')) {
            if ($Path.Contains($char)) {
                $problems.Add("Path contains an invalid character: $char")
            }
        }

        if ($Path -match '[\x00-\x1F]') {
            $problems.Add('Path contains a control character')
        }

        $reserved = @('CON', 'PRN', 'AUX', 'NUL') +
                    (1..9 | ForEach-Object { "COM$_" }) +
                    (1..9 | ForEach-Object { "LPT$_" })

        foreach ($segment in ($Path -replace '\\', '/').Split('/')) {
            if (-not $segment) { continue }
            $stem = $segment.Split('.')[0]
            if ($stem.ToUpperInvariant() -in $reserved) {
                $problems.Add("Path contains the reserved name: $stem")
            }
        }
    }

    [PSCustomObject]@{
        IsValid  = $problems.Count -eq 0
        Problems = $problems.ToArray()
    }
}

function Get-KnownWindowsLocation {
    <#
    .SYNOPSIS
        Well-known locations discovery searches when looking for an installed
        application. Returned as a name/path map so callers can report which
        location produced a hit.
    #>
    [CmdletBinding()]
    param()

    $locations = [ordered]@{}

    $candidates = [ordered]@{
        ProgramFiles      = 'ProgramFiles'
        ProgramFilesX86   = 'ProgramFiles(x86)'
        ProgramData       = 'ProgramData'
        SystemRoot        = 'SystemRoot'
        LocalAppData      = 'LOCALAPPDATA'
        RoamingAppData    = 'APPDATA'
        PublicDesktop     = 'PUBLIC'
    }

    foreach ($entry in $candidates.GetEnumerator()) {
        $value = [System.Environment]::GetEnvironmentVariable($entry.Value)
        if ($value) { $locations[$entry.Key] = ConvertTo-CanonicalPath -Path $value }
    }

    $locations
}
