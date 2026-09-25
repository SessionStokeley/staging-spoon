<#
.SYNOPSIS
    Detection and presentation of sources that disagree.
.DESCRIPTION
    When the installer says version 5.2, the registry says 5.1 and the
    installed executable says 5.2, the platform does not pick one quietly. It
    reports every observation with its source, names the one it would choose
    and why, and leaves the choice recorded as a decision rather than buried in
    an overwritten field.
#>

Set-StrictMode -Version Latest

function Get-FieldConflict {
    <#
    .SYNOPSIS
        Groups every observation recorded for a field by distinct value.
    .OUTPUTS
        Null when the sources agree; otherwise the competing values, the
        recommended one and the reason it is recommended.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path
    )

    $observations = @(Get-Fact -Store $Project.Evidence -Key $Path)
    if ($observations.Count -lt 2) { return $null }

    $groups = @{}
    foreach ($observation in $observations) {
        $key = if ($null -eq $observation.Value) { '<null>' } else { ($observation.Value -join ',') }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [PSCustomObject]@{
                Value     = $observation.Value
                Sources   = [System.Collections.Generic.List[string]]::new()
                Evidence  = [System.Collections.Generic.List[string]]::new()
                BestRank  = 0
            }
        }

        $group = $groups[$key]
        if ($observation.Source -notin $group.Sources) { $group.Sources.Add($observation.Source) }
        if ($observation.Evidence -and $observation.Evidence -notin $group.Evidence) {
            $group.Evidence.Add($observation.Evidence)
        }

        $rank = Get-FieldSourceRank -Source $observation.Source
        if ($rank -gt $group.BestRank) { $group.BestRank = $rank }
    }

    if ($groups.Count -lt 2) { return $null }

    $candidates = @(
        foreach ($key in $groups.Keys) {
            $group = $groups[$key]
            [PSCustomObject]@{
                Value       = $group.Value
                Display     = $key
                Sources     = @($group.Sources)
                Evidence    = @($group.Evidence)
                BestRank    = $group.BestRank
                SourceCount = $group.Sources.Count
            }
        }
    )

    # Corroboration breaks a tie: two independent sources agreeing beats one.
    $ranked = @($candidates | Sort-Object -Property @{ Expression = 'BestRank'; Descending = $true },
                                                    @{ Expression = 'SourceCount'; Descending = $true })

    $winner = $ranked[0]
    $runnerUp = $ranked[1]

    $reason = if ($winner.BestRank -gt $runnerUp.BestRank) {
        "$($winner.Sources -join ' and ') is trusted above $($runnerUp.Sources -join ' and ')"
    } elseif ($winner.SourceCount -gt $runnerUp.SourceCount) {
        "$($winner.SourceCount) independent sources agree on this value"
    } else {
        'No source outranks the others; this needs a decision'
    }

    $field = Get-ProjectField -Project $Project -Path $Path

    [PSCustomObject]@{
        Path             = $Path
        Candidates       = $ranked
        Recommended      = $winner
        Reason           = $reason
        IsDecidable      = $winner.BestRank -gt $runnerUp.BestRank -or $winner.SourceCount -gt $runnerUp.SourceCount
        CurrentValue     = if ($null -eq $field) { $null } else { $field.Value }
        ResolvedByUser   = $null -ne $field -and $field.ConfirmedByUser
    }
}

function Get-ProjectConflict {
    <#
    .SYNOPSIS
        Every unresolved disagreement in the project.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    $conflicts = foreach ($key in (Get-FactKey -Store $Project.Evidence)) {
        $conflict = Get-FieldConflict -Project $Project -Path $key
        if ($null -eq $conflict) { continue }
        if ($conflict.ResolvedByUser) { continue }
        $conflict
    }

    @($conflicts)
}

function Resolve-FieldConflict {
    <#
    .SYNOPSIS
        Settles a conflict with an explicit choice, recorded as a decision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Value,
        [string]$Rationale = '',
        [string]$DecidedBy = 'user'
    )

    $field = Get-ProjectField -Project $Project -Path $Path

    if ($null -eq $field) {
        Set-ProjectField -Project $Project -Path $Path -Value $Value -Source 'USER_SELECTED' `
            -Evidence 'Chosen while resolving a conflict' | Out-Null
    } else {
        Set-FieldOverride -Field $field -Value $Value -Reason $Rationale -Source 'USER_SELECTED' | Out-Null
    }

    Set-Decision -Store $Project.Evidence -Key "conflict:$Path" -Value $Value `
                 -Rationale $Rationale -DecidedBy $DecidedBy | Out-Null

    Get-ProjectField -Project $Project -Path $Path
}

function Compare-PreviousValue {
    <#
    .SYNOPSIS
        Presents a changed value against what a previous build used, so a
        version update never silently changes deployment behaviour.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$PreviousValue,
        [AllowNull()]$CurrentValue,
        [string]$PreviousSource = 'PREVIOUS_BUILD',
        [string]$CurrentSource = 'AUTO_DISCOVERED'
    )

    $changed = -not (Test-FieldValueMatch -Left $PreviousValue -Right $CurrentValue)

    [PSCustomObject]@{
        Path           = $Path
        Previous       = $PreviousValue
        Current        = $CurrentValue
        PreviousSource = $PreviousSource
        CurrentSource  = $CurrentSource
        HasChanged     = $changed
        Options        = if ($changed) { @('UseCurrent', 'KeepPrevious', 'InspectDifference') } else { @() }
    }
}
