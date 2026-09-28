<#
.SYNOPSIS
    Facts and decisions, stored separately and never merged.
.DESCRIPTION
    A fact is something the platform observed: the installer added a directory
    to the machine PATH. A decision is what the deployment chooses to do about
    it: do not reproduce that PATH change. Overwriting the fact with the
    decision would destroy the only record of what the installer actually does,
    so the two are stored in separate collections and both survive into the
    build evidence.
#>

Set-StrictMode -Version Latest

function New-EvidenceStore {
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        Facts     = @{}
        Decisions = @{}
        Audit     = [System.Collections.Generic.List[PSCustomObject]]::new()
    }
}

function Add-Fact {
    <#
    .SYNOPSIS
        Records something the platform observed.
    .DESCRIPTION
        Facts accumulate. Observing the same key twice from different sources
        keeps both observations, because disagreement between them is itself
        information the conflict resolver needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Source,
        [string]$Evidence = ''
    )

    $observation = [PSCustomObject]@{
        Value      = $Value
        Source     = $Source
        Evidence   = $Evidence
        ObservedAt = (Get-Date).ToString('o')
    }

    if (-not $Store.Facts.ContainsKey($Key)) {
        $Store.Facts[$Key] = @()
    }

    $Store.Facts[$Key] = @($Store.Facts[$Key]) + $observation

    Add-AuditEntry -Store $Store -Category 'Fact' -Key $Key `
                   -Detail "Observed by $Source" -Value $Value

    $observation
}

function Get-Fact {
    <#
    .SYNOPSIS
        All observations recorded for a key, newest last.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $Store.Facts.ContainsKey($Key)) { return @() }
    @($Store.Facts[$Key])
}

function Get-FactKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Store)

    @($Store.Facts.Keys | Sort-Object)
}

function Set-Decision {
    <#
    .SYNOPSIS
        Records a deployment policy choice about an observed fact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Value,
        [string]$Rationale = '',
        [string]$DecidedBy = 'user'
    )

    $previous = if ($Store.Decisions.ContainsKey($Key)) { $Store.Decisions[$Key].Value } else { $null }

    $Store.Decisions[$Key] = [PSCustomObject]@{
        Value     = $Value
        Rationale = $Rationale
        DecidedBy = $DecidedBy
        DecidedAt = (Get-Date).ToString('o')
    }

    $detail = if ($null -ne $previous -and $previous -ne $Value) {
        "Changed from '$previous' to '$Value' by $DecidedBy"
    } else {
        "Decided by $DecidedBy"
    }

    Add-AuditEntry -Store $Store -Category 'Decision' -Key $Key -Detail $detail -Value $Value

    $Store.Decisions[$Key]
}

function Get-Decision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $Store.Decisions.ContainsKey($Key)) { return $null }
    $Store.Decisions[$Key]
}

function Test-DecisionRecorded {
    <#
    .SYNOPSIS
        True when a decision has been made, which is how the prompt engine
        knows not to ask the same question again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [Parameter(Mandatory)][string]$Key
    )

    $Store.Decisions.ContainsKey($Key)
}

function Clear-Decision {
    <#
    .SYNOPSIS
        Forgets a decision so the platform asks about it again. Used when the
        evidence underneath it changed or the user explicitly resets it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [Parameter(Mandatory)][string]$Key,
        [string]$Reason = 'reset by user'
    )

    if (-not $Store.Decisions.ContainsKey($Key)) { return $false }

    $Store.Decisions.Remove($Key)
    Add-AuditEntry -Store $Store -Category 'Decision' -Key $Key -Detail "Cleared: $Reason" -Value $null
    $true
}

function Add-AuditEntry {
    <#
    .SYNOPSIS
        Appends to the trail that makes a build reproducible after the fact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [Parameter(Mandatory)][ValidateSet('Fact', 'Decision', 'Field', 'Resource', 'Conflict', 'Operation')][string]$Category,
        [Parameter(Mandatory)][string]$Key,
        [string]$Detail = '',
        [AllowNull()]$Value
    )

    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        Category  = $Category
        Key       = $Key
        Detail    = $Detail
        Value     = $Value
    }

    $Store.Audit.Add($entry)
    $entry
}

function Get-AuditTrail {
    <#
    .SYNOPSIS
        The audit trail, optionally narrowed to one key or category.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Store,
        [string]$Key,
        [string]$Category
    )

    $entries = @($Store.Audit)

    if ($PSBoundParameters.ContainsKey('Key')) {
        $entries = @($entries | Where-Object { $_.Key -eq $Key })
    }

    if ($PSBoundParameters.ContainsKey('Category')) {
        $entries = @($entries | Where-Object { $_.Category -eq $Category })
    }

    $entries
}

function ConvertTo-SerializableEvidence {
    <#
    .SYNOPSIS
        Flattens the store for JSON persistence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Store)

    $facts = [ordered]@{}
    foreach ($key in ($Store.Facts.Keys | Sort-Object)) { $facts[$key] = @($Store.Facts[$key]) }

    $decisions = [ordered]@{}
    foreach ($key in ($Store.Decisions.Keys | Sort-Object)) { $decisions[$key] = $Store.Decisions[$key] }

    [PSCustomObject]@{
        Facts     = $facts
        Decisions = $decisions
        Audit     = @($Store.Audit)
    }
}

function ConvertFrom-SerializableEvidence {
    <#
    .SYNOPSIS
        Rebuilds a store from persisted JSON.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Data)

    $store = New-EvidenceStore

    if ($Data.PSObject.Properties.Name -contains 'Facts' -and $Data.Facts) {
        foreach ($property in $Data.Facts.PSObject.Properties) {
            $store.Facts[$property.Name] = @($property.Value)
        }
    }

    if ($Data.PSObject.Properties.Name -contains 'Decisions' -and $Data.Decisions) {
        foreach ($property in $Data.Decisions.PSObject.Properties) {
            $store.Decisions[$property.Name] = $property.Value
        }
    }

    if ($Data.PSObject.Properties.Name -contains 'Audit' -and $Data.Audit) {
        foreach ($entry in @($Data.Audit)) { $store.Audit.Add($entry) }
    }

    $store
}
