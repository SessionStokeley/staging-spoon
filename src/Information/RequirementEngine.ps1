<#
.SYNOPSIS
    What the current operation needs, and how much of it is known.
.DESCRIPTION
    Readiness is computed per operation, not for the project as a whole. Only
    the fields an operation actually requires are considered, which is what
    keeps the user from being shown a form covering every field the platform
    can hold. Completeness is reported separately for required, recommended and
    optional information so a full set of cosmetic answers can never make a
    missing install command look like progress.
#>

Set-StrictMode -Version Latest

function Get-FieldReadiness {
    <#
    .SYNOPSIS
        Classifies one field against the project's current knowledge.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][PSCustomObject]$Definition,
        [switch]$IsRequired
    )

    $field  = Get-ProjectField -Project $Project -Path $Definition.Path
    $status = 'Missing'
    $value  = $null
    $source = ''
    $detail = ''

    if ($null -ne $field) {
        $value  = $field.Value
        $source = $field.Source

        $status = switch ($field.State) {
            'CONFLICT'       { 'Conflict' }
            'INVALID'        { 'Invalid' }
            'NOT_APPLICABLE' { 'NotApplicable' }
            'DISCOVERING'    { 'Missing' }
            default {
                if (Test-FieldResolved -Field $field) {
                    if ($field.ConfirmedByUser) { 'Confirmed' } else { 'Found' }
                } else {
                    'Missing'
                }
            }
        }

        if ($status -in @('Found', 'Confirmed')) { $detail = Format-FieldEvidence -Field $field }
    }

    # A field whose inputs are not yet known cannot be asked about usefully;
    # it is blocked rather than missing, and its prerequisite is what to ask.
    $blockedBy = @(
        foreach ($dependency in $Definition.DerivesFrom) {
            if (-not (Test-ProjectFieldKnown -Project $Project -Path $dependency)) { $dependency }
        }
    )

    [PSCustomObject]@{
        Path       = $Definition.Path
        Label      = $Definition.Label
        Group      = $Definition.Group
        Priority   = $Definition.Priority
        Rank       = $Definition.PriorityRank
        IsRequired = [bool]$IsRequired
        Status     = $status
        Value      = $value
        Source     = $source
        Detail     = $detail
        BlockedBy  = $blockedBy
        IsSatisfied = $status -in @('Found', 'Confirmed', 'NotApplicable')
    }
}

function Get-OperationReadiness {
    <#
    .SYNOPSIS
        Whether an operation can run, and what is missing if it cannot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Operation
    )

    $requirement = Get-OperationRequirement -Operation $Operation

    $required = @(
        foreach ($definition in $requirement.Required) {
            Get-FieldReadiness -Project $Project -Definition $definition -IsRequired
        }
    )

    $recommended = @(
        foreach ($definition in $requirement.Recommended) {
            Get-FieldReadiness -Project $Project -Definition $definition
        }
    )

    $satisfiedRequired    = @($required | Where-Object { $_.IsSatisfied })
    $satisfiedRecommended = @($recommended | Where-Object { $_.IsSatisfied })

    $blockers = @($required | Where-Object { -not $_.IsSatisfied } | Sort-Object Rank, Path)
    $warnings = @($recommended | Where-Object { -not $_.IsSatisfied } | Sort-Object Rank, Path)
    $conflicts = @(($required + $recommended) | Where-Object { $_.Status -eq 'Conflict' })

    $requiredPercent = if ($required.Count -eq 0) { 100 } else {
        [int][Math]::Round(($satisfiedRequired.Count / $required.Count) * 100)
    }

    [PSCustomObject]@{
        Operation            = $Operation
        CanProceed           = $blockers.Count -eq 0 -and $conflicts.Count -eq 0
        Required             = $required
        Recommended          = $recommended
        Blockers             = $blockers
        Warnings             = $warnings
        Conflicts            = $conflicts
        RequiredSatisfied    = $satisfiedRequired.Count
        RequiredTotal        = $required.Count
        RecommendedSatisfied = $satisfiedRecommended.Count
        RecommendedTotal     = $recommended.Count
        RequiredPercent      = $requiredPercent
    }
}

function Get-ProjectCompleteness {
    <#
    .SYNOPSIS
        Deployment readiness across the whole catalog, weighted so that
        required information dominates the headline number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string]$Operation = 'BuildPackage'
    )

    $readiness = Get-OperationReadiness -Project $Project -Operation $Operation
    $catalog   = Get-FieldCatalog

    $consideredPaths = @($readiness.Required.Path) + @($readiness.Recommended.Path)

    $optional = @(
        foreach ($definition in $catalog.Values) {
            if ($definition.Path -in $consideredPaths) { continue }
            Get-FieldReadiness -Project $Project -Definition $definition
        }
    )

    $optionalSatisfied = @($optional | Where-Object { $_.IsSatisfied })

    # Required information is the whole of readiness; recommended and optional
    # can raise a score only once nothing required is missing.
    $score = if ($readiness.RequiredTotal -eq 0) {
        100
    } elseif ($readiness.Blockers.Count -gt 0) {
        [int][Math]::Round(($readiness.RequiredSatisfied / $readiness.RequiredTotal) * 90)
    } else {
        $bonusTotal = $readiness.RecommendedTotal
        $bonus = if ($bonusTotal -eq 0) { 10 } else {
            [int][Math]::Round(($readiness.RecommendedSatisfied / $bonusTotal) * 10)
        }
        90 + $bonus
    }

    [PSCustomObject]@{
        Operation            = $Operation
        Readiness            = $score
        RequiredSatisfied    = $readiness.RequiredSatisfied
        RequiredTotal        = $readiness.RequiredTotal
        RecommendedSatisfied = $readiness.RecommendedSatisfied
        RecommendedTotal     = $readiness.RecommendedTotal
        OptionalSatisfied    = $optionalSatisfied.Count
        OptionalTotal        = $optional.Count
        BlockerCount         = $readiness.Blockers.Count
        WarningCount         = $readiness.Warnings.Count
        ConflictCount        = $readiness.Conflicts.Count
        CanProceed           = $readiness.CanProceed
    }
}

function Test-OperationReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Operation
    )

    (Get-OperationReadiness -Project $Project -Operation $Operation).CanProceed
}
