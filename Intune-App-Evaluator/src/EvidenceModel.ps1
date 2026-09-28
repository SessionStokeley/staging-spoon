<#
.SYNOPSIS
    A discovered value that carries where it came from and how far to trust it.
.DESCRIPTION
    The evaluator never presents an inferred value as though it were verified.
    Every field it produces records its source, a confidence, whether it was
    verified against the live system, and whether a person has overridden it -
    so a report can separate what was observed from what was guessed, and a
    reviewer can see the evidence before exporting.

    A field's status is derived, never set by hand:

        Confirmed             a person accepted or edited the value.
        Detected              observed on the live system, or strong direct
                              evidence for it.
        Inferred              derived from metadata or a heuristic, not seen.
        RequiresConfirmation  low confidence, or a value whose being wrong is
                              costly (a silent switch, SYSTEM compatibility),
                              or a required value that is still missing.
#>

Set-StrictMode -Version Latest

$script:ConfidenceLevels = @('High', 'Medium', 'Low')

# Where a value came from, ordered so a stronger source is preferred when the
# same field is learned more than once. Observation of the running system beats
# anything read out of a file or inferred.
$script:EvidenceSources = [ordered]@{
    UserOverride       = 100   # a person typed or accepted it
    LiveCapture        = 90    # seen in a before/after install diff
    InstalledSystem    = 80    # read from the installed application on this machine
    UninstallRegistry  = 75    # the app's ARP registration
    MsiDatabase        = 70    # the MSI's own tables
    InstallerMetadata  = 50    # version info / signature on the installer file
    ToolkitHeuristic   = 40    # inferred from the installer toolkit (NSIS, Inno, ...)
    Default            = 10    # a fallback with no evidence
}

function Get-EvidenceSourceRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source)
    if ($script:EvidenceSources.Contains($Source)) { return [int]$script:EvidenceSources[$Source] }
    0
}

function New-EvaluatedField {
    <#
    .SYNOPSIS
        Builds a discovered field with its evidence attached.
    .PARAMETER Verified
        True only when the value was confirmed against the live system - a file
        that exists, a registry value read back, a PATH entry actually present.
        Never true for a value merely read from an installer or inferred.
    .PARAMETER RequiresConfirmation
        Marks a value that must be reviewed before it is trusted even at high
        confidence, such as a silent switch guessed from the installer toolkit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Value = $null,
        [Parameter(Mandatory)][string]$Source,
        [ValidateSet('High', 'Medium', 'Low')][string]$Confidence = 'Medium',
        [bool]$Verified = $false,
        [string]$Evidence = '',
        [bool]$RequiresConfirmation = $false,
        [string]$Group = 'General'
    )

    [PSCustomObject]@{
        Path                 = $Path
        Value                = $Value
        Source               = $Source
        SourceRank           = Get-EvidenceSourceRank -Source $Source
        Confidence           = $Confidence
        Verified             = $Verified
        RequiresConfirmation = $RequiresConfirmation
        UserOverride         = $false
        Group                = $Group
        Evidence             = @(if ($Evidence) { $Evidence } else { @() })
        RecordedAt           = (Get-Date).ToString('o')
    }
}

function Get-FieldStatus {
    <#
    .SYNOPSIS
        The review status a field belongs in, derived from its evidence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Field)

    if ($Field.UserOverride) { return 'Confirmed' }

    $hasValue = -not ($null -eq $Field.Value -or ($Field.Value -is [string] -and [string]::IsNullOrWhiteSpace($Field.Value)))
    if (-not $hasValue) { return 'RequiresConfirmation' }

    if ($Field.RequiresConfirmation) { return 'RequiresConfirmation' }
    if ($Field.Verified) { return 'Detected' }
    if ($Field.Confidence -eq 'Low') { return 'RequiresConfirmation' }

    # Not verified, but strong: observed on the system counts as detected;
    # anything derived from metadata or a heuristic is inferred.
    $observed = $Field.SourceRank -ge (Get-EvidenceSourceRank -Source 'MsiDatabase')
    if ($Field.Confidence -eq 'High' -and $observed) { return 'Detected' }
    'Inferred'
}

function New-EvaluationResult {
    <#
    .SYNOPSIS
        A collector for the fields an evaluation discovers.
    .DESCRIPTION
        Adding a field for a path that already has one keeps whichever has the
        stronger source, so a value seen in a live capture is not overwritten by
        a later guess, and a guess never clobbers an observation.
    #>
    [CmdletBinding()]
    param([string]$ApplicationName = '')

    [PSCustomObject]@{
        ApplicationName = $ApplicationName
        Fields          = [ordered]@{}
        Notes           = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-EvaluatedField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [Parameter(Mandatory)][PSCustomObject]$Field
    )

    $existing = if ($Result.Fields.Contains($Field.Path)) { $Result.Fields[$Field.Path] } else { $null }
    if ($null -ne $existing -and $existing.SourceRank -gt $Field.SourceRank -and -not $Field.UserOverride) {
        # Keep the stronger evidence, but remember the weaker one saw something.
        $existing.Evidence = @($existing.Evidence) + @($Field.Evidence | Where-Object { $_ })
        return $existing
    }

    $Result.Fields[$Field.Path] = $Field
    $Field
}

function Set-FieldOverride {
    <#
    .SYNOPSIS
        Records a reviewer's value for a field, marking it confirmed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Value
    )

    $field = if ($Result.Fields.Contains($Path)) { $Result.Fields[$Path] } else {
        $new = New-EvaluatedField -Path $Path -Value $null -Source 'UserOverride'
        $Result.Fields[$Path] = $new
        $new
    }

    $field.Value        = $Value
    $field.Source       = 'UserOverride'
    $field.SourceRank   = Get-EvidenceSourceRank -Source 'UserOverride'
    $field.Confidence   = 'High'
    $field.Verified     = $true
    $field.UserOverride = $true
    $field.RequiresConfirmation = $false
    $field.Evidence     = @($field.Evidence) + 'Set by reviewer'
    $field
}

function Get-EvaluationSummaryCounts {
    <#
    .SYNOPSIS
        How many fields are detected, inferred, or need confirmation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    $counts = [ordered]@{ Detected = 0; Inferred = 0; RequiresConfirmation = 0; Confirmed = 0 }
    foreach ($field in $Result.Fields.Values) {
        $status = Get-FieldStatus -Field $field
        $counts[$status] = [int]$counts[$status] + 1
    }
    [PSCustomObject]$counts
}
