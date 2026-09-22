<#
.SYNOPSIS
    Field values with provenance: source, confidence, state and audit trail.
.DESCRIPTION
    Every piece of information the platform knows is a field value. A field
    value is never a bare string - it carries where it came from, how much the
    platform trusts it, whether a user confirmed it, and the history of every
    change. Downstream code decides what to do with a value by reading its
    state, not by guessing from emptiness.
#>

Set-StrictMode -Version Latest

# Ordered by precedence. A value from a higher-ranked source wins a conflict
# against a lower-ranked one, unless the lower one was confirmed by a user.
$script:FieldSources = [ordered]@{
    USER_ENTERED       = 100
    USER_SELECTED      = 95
    CAPTURED           = 90
    INSTALLED_SYSTEM   = 80
    INSTALLER_METADATA = 75
    REGISTRY           = 70
    FILESYSTEM         = 65
    INTUNE_METADATA    = 60
    PREVIOUS_BUILD     = 55
    PROJECT            = 50
    CONFIGURATION      = 45
    DERIVED            = 40
    AUTO_DISCOVERED    = 35
}

$script:FieldStates = @(
    'UNKNOWN'         # nothing known, not yet looked for
    'DISCOVERING'     # discovery in progress
    'FOUND'           # discovered, not confirmed by a user
    'CONFIRMED'       # user confirmed, or supplied directly
    'USER_REQUIRED'   # discovery exhausted, only a user can supply it
    'OPTIONAL'        # not needed to proceed
    'NOT_APPLICABLE'  # cannot apply to this package
    'CONFLICT'        # sources disagree
    'INVALID'         # present but failed validation
)

$script:FieldConfidence = [ordered]@{
    CONFIRMED = 100   # a user said so, or the value was observed directly
    HIGH      = 75
    MEDIUM    = 50
    LOW       = 25
}

# What the platform trusts a source to produce without a user saying so.
$script:SourceDefaultConfidence = @{
    USER_ENTERED       = 'CONFIRMED'
    USER_SELECTED      = 'CONFIRMED'
    CAPTURED           = 'CONFIRMED'
    INSTALLED_SYSTEM   = 'HIGH'
    INSTALLER_METADATA = 'HIGH'
    REGISTRY           = 'HIGH'
    FILESYSTEM         = 'HIGH'
    INTUNE_METADATA    = 'MEDIUM'
    PREVIOUS_BUILD     = 'MEDIUM'
    PROJECT            = 'MEDIUM'
    CONFIGURATION      = 'MEDIUM'
    DERIVED            = 'MEDIUM'
    AUTO_DISCOVERED    = 'LOW'
}

function Get-FieldSourceName {
    [CmdletBinding()]
    param()
    @($script:FieldSources.Keys)
}

function Get-FieldStateName {
    [CmdletBinding()]
    param()
    $script:FieldStates
}

function Get-FieldSourceRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source)

    if ($script:FieldSources.Contains($Source)) { return $script:FieldSources[$Source] }
    0
}

function Get-FieldConfidenceRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Confidence)

    if ($script:FieldConfidence.Contains($Confidence)) { return $script:FieldConfidence[$Confidence] }
    0
}

function New-FieldValue {
    <#
    .SYNOPSIS
        Creates a field value carrying its own provenance.
    .PARAMETER Evidence
        What the platform saw. Free text, shown to the user when they ask why a
        value is what it is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()]$Value,
        [Parameter(Mandatory)][ValidateScript({ $_ -in (Get-FieldSourceName) })][string]$Source,
        [ValidateScript({ $_ -in $script:FieldStates })][string]$State,
        [ValidateScript({ $_ -in $script:FieldConfidence.Keys })][string]$Confidence,
        [string]$Evidence = ''
    )

    if (-not $PSBoundParameters.ContainsKey('Confidence')) {
        $Confidence = $script:SourceDefaultConfidence[$Source]
    }

    if (-not $PSBoundParameters.ContainsKey('State')) {
        $State = if ($Confidence -eq 'CONFIRMED') { 'CONFIRMED' } else { 'FOUND' }
    }

    $timestamp = (Get-Date).ToString('o')

    [PSCustomObject]@{
        Path            = $Path
        Value           = $Value
        Source          = $Source
        Confidence      = $Confidence
        State           = $State
        Evidence        = $Evidence
        ConfirmedByUser = $Confidence -eq 'CONFIRMED' -and $Source -in @('USER_ENTERED', 'USER_SELECTED')
        UpdatedAt       = $timestamp
        OriginalValue   = $null
        OriginalSource  = $null
        OverrideReason  = ''
        History         = @(
            [PSCustomObject]@{
                Timestamp = $timestamp
                Value     = $Value
                Source    = $Source
                State     = $State
                Note      = 'initial'
            }
        )
    }
}

function New-UnknownFieldValue {
    <#
    .SYNOPSIS
        Creates a placeholder for information the platform has looked for and
        not found. UNKNOWN is a real state - it is never silently read as "no".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Evidence = 'No source produced a value'
    )

    [PSCustomObject]@{
        Path            = $Path
        Value           = $null
        Source          = 'AUTO_DISCOVERED'
        Confidence      = 'LOW'
        State           = 'UNKNOWN'
        Evidence        = $Evidence
        ConfirmedByUser = $false
        UpdatedAt       = (Get-Date).ToString('o')
        OriginalValue   = $null
        OriginalSource  = $null
        OverrideReason  = ''
        History         = @()
    }
}

function Add-FieldHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Field,
        [Parameter(Mandatory)][string]$Note
    )

    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        Value     = $Field.Value
        Source    = $Field.Source
        State     = $Field.State
        Note      = $Note
    }

    $Field.History = @($Field.History) + $entry
    $Field
}

function Set-FieldConfirmed {
    <#
    .SYNOPSIS
        Records that a user accepted a discovered value. The source is kept so
        the report can still say where the value came from.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Field)

    $Field.Confidence      = 'CONFIRMED'
    $Field.State           = 'CONFIRMED'
    $Field.ConfirmedByUser = $true
    $Field.UpdatedAt       = (Get-Date).ToString('o')

    Add-FieldHistory -Field $Field -Note 'confirmed by user'
}

function Set-FieldOverride {
    <#
    .SYNOPSIS
        Replaces a value with one the user supplied, preserving what was
        discovered. The discovered value is never lost - it stays available as
        evidence and as the target of a reset.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Field,
        [AllowNull()][AllowEmptyString()]$Value,
        [string]$Reason = '',
        [ValidateScript({ $_ -in (Get-FieldSourceName) })][string]$Source = 'USER_ENTERED'
    )

    if ($null -eq $Field.OriginalValue -and $Field.State -notin @('UNKNOWN', 'USER_REQUIRED')) {
        $Field.OriginalValue  = $Field.Value
        $Field.OriginalSource = $Field.Source
    }

    $Field.Value           = $Value
    $Field.Source          = $Source
    $Field.Confidence      = 'CONFIRMED'
    $Field.State           = 'CONFIRMED'
    $Field.ConfirmedByUser = $true
    $Field.OverrideReason  = $Reason
    $Field.UpdatedAt       = (Get-Date).ToString('o')

    $note = if ($Reason) { "overridden by user: $Reason" } else { 'overridden by user' }
    Add-FieldHistory -Field $Field -Note $note
}

function Reset-FieldToDiscovered {
    <#
    .SYNOPSIS
        Restores the automatically discovered value after an override.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Field)

    if ($null -eq $Field.OriginalSource) {
        return $Field
    }

    $Field.Value           = $Field.OriginalValue
    $Field.Source          = $Field.OriginalSource
    $Field.Confidence      = $script:SourceDefaultConfidence[$Field.OriginalSource]
    $Field.State           = 'FOUND'
    $Field.ConfirmedByUser = $false
    $Field.OriginalValue   = $null
    $Field.OriginalSource  = $null
    $Field.OverrideReason  = ''
    $Field.UpdatedAt       = (Get-Date).ToString('o')

    Add-FieldHistory -Field $Field -Note 'reset to discovered value'
}

function Test-FieldResolved {
    <#
    .SYNOPSIS
        True when a field carries a usable value. UNKNOWN, USER_REQUIRED,
        CONFLICT and INVALID are all unresolved.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Field)

    if ($null -eq $Field) { return $false }
    if ($Field.State -notin @('FOUND', 'CONFIRMED', 'NOT_APPLICABLE', 'OPTIONAL')) { return $false }
    if ($Field.State -in @('NOT_APPLICABLE', 'OPTIONAL') -and $null -eq $Field.Value) { return $true }

    -not (Test-FieldValueEmpty -Value $Field.Value)
}

function Test-FieldValueEmpty {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [array]) { return $Value.Count -eq 0 }
    $false
}

function Format-FieldEvidence {
    <#
    .SYNOPSIS
        One-line human explanation of where a value came from, for the
        "why are you asking / where did this come from" surfaces.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Field)

    $sourceText = switch ($Field.Source) {
        'USER_ENTERED'       { 'Entered by you' }
        'USER_SELECTED'      { 'Selected by you' }
        'CAPTURED'           { 'Observed during installation capture' }
        'INSTALLED_SYSTEM'   { 'Read from the installed application' }
        'INSTALLER_METADATA' { 'Read from installer metadata' }
        'REGISTRY'           { 'Read from the registry' }
        'FILESYSTEM'         { 'Found on disk' }
        'INTUNE_METADATA'    { 'Read from Intune metadata' }
        'PREVIOUS_BUILD'     { 'Carried forward from a previous build' }
        'PROJECT'            { 'Stored in this project' }
        'CONFIGURATION'      { 'Read from configuration' }
        'DERIVED'            { 'Derived from another known value' }
        default              { 'Discovered automatically' }
    }

    if ($Field.Evidence) { "$sourceText - $($Field.Evidence)" } else { $sourceText }
}
