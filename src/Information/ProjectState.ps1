<#
.SYNOPSIS
    The single source of truth for everything known about a package.
.DESCRIPTION
    One project state holds every field, resource reference, observed fact and
    recorded decision. Discovery, capture, script generation, packaging,
    validation and reporting all read from and write to this one object. No
    feature keeps its own copy of the application name or the installer path,
    which is what makes it impossible for two screens to disagree or to ask the
    same question twice.
#>

Set-StrictMode -Version Latest

$script:ProjectSchemaVersion = '1.0'
$script:ProjectDirectoryName = '.project'

function New-ProjectState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Name = ''
    )

    $canonicalRoot = ConvertTo-CanonicalPath -Path $Root

    if (-not $Name) { $Name = Split-Path -Path $canonicalRoot -Leaf }

    [PSCustomObject]@{
        SchemaVersion = $script:ProjectSchemaVersion
        Name          = $Name
        Root          = $canonicalRoot
        Fields        = @{}
        Resources     = @{}
        Evidence      = New-EvidenceStore
        Anchors       = @{ ProjectRoot = $canonicalRoot }
        CreatedAt     = (Get-Date).ToString('o')
        UpdatedAt     = (Get-Date).ToString('o')
    }
}

function Set-ProjectAnchor {
    <#
    .SYNOPSIS
        Registers a directory that relative paths can be resolved against.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )

    $Project.Anchors[$Name] = ConvertTo-CanonicalPath -Path $Path
    $Project.Anchors
}

function Get-ProjectAnchor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    $Project.Anchors
}

function Set-ProjectField {
    <#
    .SYNOPSIS
        Records a value for a field, arbitrating against whatever is already
        known.
    .DESCRIPTION
        A value the user confirmed is never silently replaced by a discovered
        one. A discovered value is replaced only by a source the platform
        trusts more. Equal-ranked sources that disagree produce a CONFLICT
        state rather than a silent winner, and every observation is recorded as
        a fact regardless of which one wins.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()]$Value,
        [Parameter(Mandatory)][string]$Source,
        [string]$Evidence = '',
        [ValidateScript({ $_ -in (Get-FieldStateName) })][string]$State,
        [switch]$Force
    )

    Add-Fact -Store $Project.Evidence -Key $Path -Value $Value -Source $Source -Evidence $Evidence | Out-Null

    $incomingArgs = @{
        Path     = $Path
        Value    = $Value
        Source   = $Source
        Evidence = $Evidence
    }
    if ($PSBoundParameters.ContainsKey('State')) { $incomingArgs['State'] = $State }

    $incoming = New-FieldValue @incomingArgs

    if (-not $Project.Fields.ContainsKey($Path)) {
        $Project.Fields[$Path] = $incoming
        $Project.UpdatedAt = (Get-Date).ToString('o')
        return $incoming
    }

    $existing = $Project.Fields[$Path]

    if ($Force) {
        $existing.Value      = $Value
        $existing.Source     = $Source
        $existing.Confidence = $incoming.Confidence
        $existing.State      = $incoming.State
        $existing.Evidence   = $Evidence
        $existing.UpdatedAt  = (Get-Date).ToString('o')
        Add-FieldHistory -Field $existing -Note "forced by $Source" | Out-Null
        $Project.UpdatedAt = (Get-Date).ToString('o')
        return $existing
    }

    $sameValue = Test-FieldValueMatch -Left $existing.Value -Right $Value

    if ($sameValue) {
        # Independent agreement raises confidence without changing the value.
        if ((Get-FieldSourceRank -Source $Source) -gt (Get-FieldSourceRank -Source $existing.Source)) {
            $existing.Source     = $Source
            $existing.Confidence = $incoming.Confidence
            $existing.Evidence   = $Evidence
            if ($existing.State -eq 'UNKNOWN') { $existing.State = $incoming.State }
            $existing.UpdatedAt  = (Get-Date).ToString('o')
            Add-FieldHistory -Field $existing -Note "corroborated by $Source" | Out-Null
        }
        $Project.UpdatedAt = (Get-Date).ToString('o')
        return $existing
    }

    if ($existing.ConfirmedByUser) {
        # The user already settled this. Keep their value; the disagreement is
        # preserved as a fact and surfaces in the conflict report.
        Add-AuditEntry -Store $Project.Evidence -Category 'Conflict' -Key $Path `
                       -Detail "$Source reported '$Value' but the user-confirmed value was kept" `
                       -Value $existing.Value | Out-Null
        $Project.UpdatedAt = (Get-Date).ToString('o')
        return $existing
    }

    $incomingRank = Get-FieldSourceRank -Source $Source
    $existingRank = Get-FieldSourceRank -Source $existing.Source

    if ($incomingRank -gt $existingRank) {
        $existing.Value      = $Value
        $existing.Source     = $Source
        $existing.Confidence = $incoming.Confidence
        $existing.State      = $incoming.State
        $existing.Evidence   = $Evidence
        $existing.UpdatedAt  = (Get-Date).ToString('o')
        Add-FieldHistory -Field $existing -Note "replaced by higher-trust source $Source" | Out-Null
        $Project.UpdatedAt = (Get-Date).ToString('o')
        return $existing
    }

    if ($incomingRank -eq $existingRank) {
        $existing.State     = 'CONFLICT'
        $existing.UpdatedAt = (Get-Date).ToString('o')
        Add-FieldHistory -Field $existing -Note "conflicting value '$Value' from $Source" | Out-Null
        Add-AuditEntry -Store $Project.Evidence -Category 'Conflict' -Key $Path `
                       -Detail "$Source and $($existing.Source) disagree" -Value $Value | Out-Null
        $Project.UpdatedAt = (Get-Date).ToString('o')
        return $existing
    }

    # Lower-trust source loses, but the observation is kept as evidence.
    $Project.UpdatedAt = (Get-Date).ToString('o')
    $existing
}

function Test-FieldValueMatch {
    [CmdletBinding()]
    param([AllowNull()]$Left, [AllowNull()]$Right)

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }

    if ($Left -is [array] -or $Right -is [array]) {
        $leftItems  = @($Left)
        $rightItems = @($Right)
        if ($leftItems.Count -ne $rightItems.Count) { return $false }
        for ($index = 0; $index -lt $leftItems.Count; $index++) {
            if ("$($leftItems[$index])" -ne "$($rightItems[$index])") { return $false }
        }
        return $true
    }

    if ($Left -is [string] -and $Right -is [string]) {
        return $Left.Trim() -eq $Right.Trim()
    }

    "$Left" -eq "$Right"
}

function Get-ProjectField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not $Project.Fields.ContainsKey($Path)) { return $null }
    $Project.Fields[$Path]
}

function Get-ProjectFieldValue {
    <#
    .SYNOPSIS
        The plain value of a field, or a default when it is not resolved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Default = $null
    )

    $field = Get-ProjectField -Project $Project -Path $Path
    if (-not (Test-FieldResolved -Field $field)) { return $Default }
    $field.Value
}

function Test-ProjectFieldKnown {
    <#
    .SYNOPSIS
        True when the platform already has a usable answer, which is the test
        that stops a question being asked twice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path
    )

    Test-FieldResolved -Field (Get-ProjectField -Project $Project -Path $Path)
}

function Get-ProjectFieldPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    @($Project.Fields.Keys | Sort-Object)
}

function Register-ProjectResource {
    <#
    .SYNOPSIS
        Stores a resource reference and publishes the fields that derive from
        it, so selecting an installer populates its path, name, size and hash
        at once rather than asking for each separately.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Path,
        [string]$Type,
        [string]$Source = 'USER_SELECTED'
    )

    $referenceArgs = @{
        Id          = $Id
        Path        = $Path
        ProjectRoot = $Project.Root
    }
    if ($PSBoundParameters.ContainsKey('Type')) { $referenceArgs['Type'] = $Type }

    $reference = New-ResourceReference @referenceArgs
    $Project.Resources[$Id] = $reference

    Add-AuditEntry -Store $Project.Evidence -Category 'Resource' -Key $Id `
                   -Detail "Registered $($reference.Type) from $Source" -Value $reference.StoredPath | Out-Null

    $Project.UpdatedAt = (Get-Date).ToString('o')
    $reference
}

function Get-ProjectResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Id
    )

    if (-not $Project.Resources.ContainsKey($Id)) { return $null }
    $Project.Resources[$Id]
}

function Resolve-ProjectResourcePath {
    <#
    .SYNOPSIS
        Turns a registered resource back into a usable absolute path, running
        recovery when the stored location no longer holds the file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Id,
        [string[]]$SearchRoots = @()
    )

    $reference = Get-ProjectResource -Project $Project -Id $Id
    if ($null -eq $reference) {
        return [PSCustomObject]@{
            Found = $false; Path = ''; Strategy = 'NotRegistered'
            Confidence = 'LOW'; Candidates = @()
        }
    }

    Resolve-ResourceReference -Reference $reference -Anchors $Project.Anchors -SearchRoots $SearchRoots
}

function Get-ProjectDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    Join-Path $Project.Root $script:ProjectDirectoryName
}

function Save-ProjectState {
    <#
    .SYNOPSIS
        Persists the project to .project/, keeping facts, decisions and the
        field store in separate files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string]$Path
    )

    if (-not $PSBoundParameters.ContainsKey('Path')) {
        $Path = Get-ProjectDirectory -Project $Project
    }

    foreach ($directory in @($Path, (Join-Path $Path 'captures'), (Join-Path $Path 'builds'))) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
    }

    $fields = [ordered]@{}
    foreach ($key in ($Project.Fields.Keys | Sort-Object)) { $fields[$key] = $Project.Fields[$key] }

    $resources = [ordered]@{}
    foreach ($key in ($Project.Resources.Keys | Sort-Object)) { $resources[$key] = $Project.Resources[$key] }

    $anchors = [ordered]@{}
    foreach ($key in ($Project.Anchors.Keys | Sort-Object)) {
        # Anchors outside the project are machine-specific; store them relative
        # where possible so the project survives being moved.
        $value = $Project.Anchors[$key]
        $relative = ConvertTo-RelativePath -Path $value -BasePath $Project.Root
        $anchors[$key] = if ($key -eq 'ProjectRoot') { '' } elseif ($relative) { $relative } else { $value }
    }

    $document = [PSCustomObject]@{
        SchemaVersion = $Project.SchemaVersion
        Name          = $Project.Name
        Anchors       = $anchors
        Fields        = $fields
        Resources     = $resources
        CreatedAt     = $Project.CreatedAt
        UpdatedAt     = (Get-Date).ToString('o')
    }

    $evidence = ConvertTo-SerializableEvidence -Store $Project.Evidence

    $document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Path 'project.json') -Encoding UTF8
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Path 'evidence.json') -Encoding UTF8

    [PSCustomObject]@{ Facts = $evidence.Facts } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Path 'facts.json') -Encoding UTF8

    [PSCustomObject]@{ Decisions = $evidence.Decisions } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Path 'decisions.json') -Encoding UTF8

    $Path
}

function Update-ProjectPathFormat {
    <#
    .SYNOPSIS
        Brings a project's stored paths into the canonical format.
    .DESCRIPTION
        A project written before the canonical separator changed still holds
        native paths, and nobody should have to repair one by hand. Only values
        the field catalog declares to be a Path or a Directory are touched:
        rewriting separators in arbitrary strings would corrupt registry keys,
        command lines, URLs and regular expressions, all of which legitimately
        contain backslashes.
    .OUTPUTS
        The field and resource paths that were rewritten.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    $rewritten = [System.Collections.Generic.List[string]]::new()

    foreach ($path in @($Project.Fields.Keys)) {
        $definition = Get-FieldDefinition -Path $path
        if ($null -eq $definition) { continue }
        if ($definition.Type -notin @('Path', 'Directory')) { continue }

        $field = $Project.Fields[$path]
        if ($null -eq $field -or $field.Value -isnot [string]) { continue }
        if ([string]::IsNullOrWhiteSpace($field.Value)) { continue }

        $canonical = ConvertTo-CanonicalPath -Path $field.Value
        if ($canonical -ne $field.Value) {
            $field.Value = $canonical
            $rewritten.Add($path)
        }
    }

    foreach ($id in @($Project.Resources.Keys)) {
        $reference = $Project.Resources[$id]
        if ($null -eq $reference) { continue }
        if ($reference.PSObject.Properties.Name -notcontains 'StoredPath') { continue }
        if ([string]::IsNullOrWhiteSpace($reference.StoredPath)) { continue }

        $canonical = ConvertTo-CanonicalPath -Path $reference.StoredPath
        if ($canonical -ne $reference.StoredPath) {
            $reference.StoredPath = $canonical
            $rewritten.Add("resource:$id")
        }
    }

    if ($rewritten.Count -gt 0) {
        Add-AuditEntry -Store $Project.Evidence -Category 'Operation' -Key 'NormalizePaths' `
                       -Detail "Rewrote $($rewritten.Count) stored path(s) into canonical form" -Value $null | Out-Null
    }

    @($rewritten)
}

function Import-ProjectState {
    <#
    .SYNOPSIS
        Loads a project, re-anchoring it to wherever it now lives.
    .DESCRIPTION
        The root is taken from the location the project was found at, not from
        the file, so moving a project directory does not break its stored
        relative paths.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $canonicalRoot = ConvertTo-CanonicalPath -Path $Root
    $directory     = Join-Path $canonicalRoot $script:ProjectDirectoryName
    $projectFile   = Join-Path $directory 'project.json'

    if (-not (Test-Path -LiteralPath $projectFile)) {
        throw "No project found at: $canonicalRoot"
    }

    $data    = Get-Content -LiteralPath $projectFile -Raw | ConvertFrom-Json
    $project = New-ProjectState -Root $canonicalRoot -Name $data.Name

    $project.SchemaVersion = $data.SchemaVersion
    $project.CreatedAt     = $data.CreatedAt

    if ($data.PSObject.Properties.Name -contains 'Anchors' -and $data.Anchors) {
        foreach ($property in $data.Anchors.PSObject.Properties) {
            if ($property.Name -eq 'ProjectRoot') { continue }
            $value = $property.Value
            if (-not $value) { continue }

            $project.Anchors[$property.Name] = if (Test-AbsolutePath -Path $value) {
                ConvertTo-CanonicalPath -Path $value
            } else {
                ConvertTo-CanonicalPath -Path (Join-Path $canonicalRoot $value)
            }
        }
    }

    if ($data.PSObject.Properties.Name -contains 'Fields' -and $data.Fields) {
        foreach ($property in $data.Fields.PSObject.Properties) {
            $project.Fields[$property.Name] = $property.Value
        }
    }

    if ($data.PSObject.Properties.Name -contains 'Resources' -and $data.Resources) {
        foreach ($property in $data.Resources.PSObject.Properties) {
            $project.Resources[$property.Name] = $property.Value
        }
    }

    Update-ProjectPathFormat -Project $project | Out-Null

    $evidenceFile = Join-Path $directory 'evidence.json'
    if (Test-Path -LiteralPath $evidenceFile) {
        $evidenceData = Get-Content -LiteralPath $evidenceFile -Raw | ConvertFrom-Json
        $project.Evidence = ConvertFrom-SerializableEvidence -Data $evidenceData
    }

    $project
}

function Test-ProjectExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    Test-Path -LiteralPath (Join-Path (ConvertTo-CanonicalPath -Path $Root) "$script:ProjectDirectoryName/project.json")
}
