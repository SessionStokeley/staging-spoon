<#
.SYNOPSIS
    Console rendering for the information layer.
.DESCRIPTION
    The engines produce prompt descriptors; this renders them. A descriptor
    already carries its question, its reason and the ways it can be answered,
    so a different front end can present the same prompts without
    reimplementing any of the logic that decided to ask them.
#>

Set-StrictMode -Version Latest

# Paths the user declined during the current session. Held here rather than in
# the project, because skipping means "not now" and must not read back later as
# a decision that was made.
$script:SkippedPath = @()

function Reset-PromptSession {
    [CmdletBinding()]
    param()
    $script:SkippedPath = @()
}

function Format-InformationValue {
    [CmdletBinding()]
    param([AllowNull()]$Value, [int]$MaximumLength = 68)

    if ($null -eq $Value) { return '<not set>' }

    $text = if ($Value -is [array]) {
        if ($Value.Count -eq 0) { '<empty>' } else { $Value -join ', ' }
    } elseif ($Value -is [bool]) {
        if ($Value) { 'Yes' } else { 'No' }
    } else {
        "$Value"
    }

    if ($text.Length -gt $MaximumLength) { return $text.Substring(0, $MaximumLength - 1) + '…' }
    $text
}

function Show-DiscoverySummary {
    <#
    .SYNOPSIS
        Reports what the platform worked out on its own, with the evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string[]]$Path = @()
    )

    $paths = if ($Path.Count -gt 0) { $Path } else { Get-ProjectFieldPath -Project $Project }

    Write-Host ''
    Write-Host 'Discovered automatically' -ForegroundColor Cyan

    $shown = 0

    foreach ($fieldPath in $paths) {
        $field = Get-ProjectField -Project $Project -Path $fieldPath
        if ($null -eq $field) { continue }
        if (-not (Test-FieldResolved -Field $field)) { continue }

        $definition = Get-FieldDefinition -Path $fieldPath
        $label = if ($null -eq $definition) { $fieldPath } else { $definition.Label }

        Write-Host ("  {0,-26} {1}" -f $label, (Format-InformationValue -Value $field.Value))
        Write-Host ("  {0,-26} {1}" -f '', (Format-FieldEvidence -Field $field)) -ForegroundColor DarkGray
        $shown++
    }

    if ($shown -eq 0) { Write-Host '  Nothing yet.' -ForegroundColor DarkGray }
    $shown
}

function Read-InformationPrompt {
    <#
    .SYNOPSIS
        Asks one question and returns the answer.
    .DESCRIPTION
        Reusing a value the platform already holds is always the first option,
        so the ordinary answer is a single keystroke rather than a typed path.
    .OUTPUTS
        A result carrying the answer and how it was supplied, or Skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Prompt,
        [switch]$NonInteractive
    )

    $choices = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($option in $Prompt.Options) {
        if ($option.Method -eq 'Choice' -and $null -eq $option.Value) { continue }
        if ($option.Method -in @('BrowseFile', 'BrowseFolder', 'FreeText', 'Redetect', 'DetectInstalledExecutables')) { continue }

        $choices.Add([PSCustomObject]@{
            Label  = "$($option.Label): $(Format-InformationValue -Value $option.Value)"
            Value  = $option.Value
            Method = $option.Method
        })
    }

    foreach ($choice in $Prompt.Choices) {
        if (@($choices | Where-Object { "$($_.Value)" -eq "$choice" }).Count -gt 0) { continue }
        $choices.Add([PSCustomObject]@{ Label = $choice; Value = $choice; Method = 'Choice' })
    }

    $allowsText = @($Prompt.Options | Where-Object {
        $_.Method -in @('FreeText', 'BrowseFile', 'BrowseFolder')
    }).Count -gt 0

    # Unattended runs take a value only when the platform already found one and
    # nothing has to be invented; anything else stays unanswered.
    if ($NonInteractive) {
        $reusable = @($choices | Where-Object { $_.Method -ne 'Choice' })
        if ($reusable.Count -ge 1) {
            return [PSCustomObject]@{
                Answered = $true; Value = $reusable[0].Value
                Method = $reusable[0].Method; Skipped = $false
            }
        }
        return [PSCustomObject]@{ Answered = $false; Value = $null; Method = ''; Skipped = $true }
    }

    $marker = if ($Prompt.IsRequired) { 'required' } else { 'optional' }

    Write-Host ''
    Write-Host ("  {0}  [{1}]" -f $Prompt.Label, $marker) -ForegroundColor White
    Write-Host ("    Why: {0}" -f $Prompt.Why) -ForegroundColor DarkGray

    if ($Prompt.PSObject.Properties.Name -contains 'Explanation' -and $Prompt.Explanation) {
        Write-Host ("    {0}" -f $Prompt.Explanation) -ForegroundColor DarkGray
    }

    if ($Prompt.PSObject.Properties.Name -contains 'Observed' -and @($Prompt.Observed).Count -gt 0) {
        Write-Host '    Observed during capture:' -ForegroundColor DarkGray
        foreach ($item in @($Prompt.Observed)) {
            Write-Host ("      {0}" -f (Format-InformationValue -Value $item)) -ForegroundColor DarkGray
        }
    }

    if ($null -ne $Prompt.Conflict) {
        Write-Host '    Sources disagree:' -ForegroundColor Yellow
        foreach ($candidate in $Prompt.Conflict.Candidates) {
            Write-Host ("      {0}  ({1})" -f (Format-InformationValue -Value $candidate.Value),
                                              ($candidate.Sources -join ', ')) -ForegroundColor Yellow
        }
        Write-Host ("    Recommended: {0}" -f $Prompt.Conflict.Reason) -ForegroundColor Yellow
    }

    Write-Host ''
    for ($index = 0; $index -lt $choices.Count; $index++) {
        Write-Host ("    [{0}] {1}" -f ($index + 1), $choices[$index].Label)
    }

    if ($allowsText) { Write-Host '    [t] Enter a value' }
    Write-Host '    [s] Skip for now'

    # Read-Host returns an empty string forever once its input is exhausted, so
    # an unbounded retry loop spins rather than ending when stdin is redirected
    # or closed. Give up after a few and treat it as a skip.
    $attemptsRemaining = 5

    while ($attemptsRemaining -gt 0) {
        $attemptsRemaining--
        $answer = Read-Host '    Choose'

        if ($answer -eq 's') {
            return [PSCustomObject]@{ Answered = $false; Value = $null; Method = ''; Skipped = $true }
        }

        if ($answer -eq 't' -and $allowsText) {
            $text = Read-Host '    Value'
            if ($text) {
                return [PSCustomObject]@{ Answered = $true; Value = $text; Method = 'FreeText'; Skipped = $false }
            }
            continue
        }

        $selection = 0
        if ([int]::TryParse($answer, [ref]$selection) -and $selection -ge 1 -and $selection -le $choices.Count) {
            $choice = $choices[$selection - 1]
            return [PSCustomObject]@{
                Answered = $true; Value = $choice.Value
                Method = $choice.Method; Skipped = $false
            }
        }

        if ($attemptsRemaining -gt 0) {
            Write-Host '    Not one of the options.' -ForegroundColor Red
        }
    }

    Write-Host '    No usable answer; skipping.' -ForegroundColor Yellow
    [PSCustomObject]@{ Answered = $false; Value = $null; Method = ''; Skipped = $true }
}

function Invoke-InformationPromptSession {
    <#
    .SYNOPSIS
        Works through everything an operation still needs, one group at a time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$IncludeRecommended,
        [switch]$NonInteractive
    )

    Reset-PromptSession

    $answered = 0
    $skipped  = 0

    # Capture policy first: those questions carry concrete observed evidence.
    $capturePrompts = @(Get-CaptureDecisionPrompt -Project $Project)

    if ($capturePrompts.Count -gt 0) {
        Write-Host ''
        Write-Host 'Decisions raised by the installation capture' -ForegroundColor Cyan

        foreach ($prompt in $capturePrompts) {
            $result = Read-InformationPrompt -Prompt $prompt -NonInteractive:$NonInteractive
            if (-not $result.Answered) { $skipped++; continue }

            Resolve-InformationPrompt -Project $Project -Path $prompt.Path -Value $result.Value `
                                      -Method $result.Method | Out-Null
            $answered++
        }
    }

    # Re-read between groups: answering one question can resolve another by
    # derivation, and a resolved field is never asked about.
    while ($true) {
        $groups = @(Get-PromptGroup -Project $Project -Operation $Operation -IncludeRecommended:$IncludeRecommended)
        $outstanding = @($groups | ForEach-Object { $_.Prompts } | Where-Object { $_.Path -notin $script:SkippedPath })

        if ($outstanding.Count -eq 0) { break }

        $group = @($groups | Where-Object {
            @($_.Prompts | Where-Object { $_.Path -notin $script:SkippedPath }).Count -gt 0
        })[0]

        Write-Host ''
        Write-Host ("{0}" -f $group.Group) -ForegroundColor Cyan

        foreach ($prompt in $group.Prompts) {
            if ($prompt.Path -in $script:SkippedPath) { continue }

            $result = Read-InformationPrompt -Prompt $prompt -NonInteractive:$NonInteractive

            if (-not $result.Answered) {
                $script:SkippedPath += $prompt.Path
                $skipped++
                continue
            }

            Resolve-InformationPrompt -Project $Project -Path $prompt.Path -Value $result.Value `
                                      -Method $result.Method | Out-Null
            $answered++
        }
    }

    [PSCustomObject]@{ Answered = $answered; Skipped = $skipped }
}

function Show-InformationReview {
    <#
    .SYNOPSIS
        The consolidated review before a build.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Review)

    Write-Host ''
    Write-Host '════ Deployment review ════' -ForegroundColor Cyan

    foreach ($entry in $Review.Summary.GetEnumerator()) {
        Write-Host ("  {0,-26} {1}" -f $entry.Key, (Format-InformationValue -Value $entry.Value.Value))
    }

    if ($Review.Observed.Count -gt 0) {
        Write-Host ''
        Write-Host '  Observed installation changes' -ForegroundColor Cyan
        foreach ($entry in $Review.Observed.GetEnumerator()) {
            $decision = if ($entry.Value.Decision -is [bool]) {
                if ($entry.Value.Decision) { 'apply' } else { 'do not apply' }
            } else {
                $entry.Value.Decision
            }

            Write-Host ("  {0,-26} {1}" -f $entry.Key, (Format-InformationValue -Value $entry.Value.Observed))
            Write-Host ("  {0,-26} decision: {1}" -f '', $decision) -ForegroundColor DarkGray
        }
    }

    if ($Review.Conflicts.Count -gt 0) {
        Write-Host ''
        Write-Host '  Conflicts' -ForegroundColor Yellow
        foreach ($conflict in $Review.Conflicts) {
            Write-Host ("  {0,-26} {1}" -f $conflict.Path,
                        (($conflict.Candidates | ForEach-Object { Format-InformationValue -Value $_.Value }) -join ' vs ')) -ForegroundColor Yellow
        }
    }

    if ($Review.Outstanding.Count -gt 0) {
        Write-Host ''
        Write-Host '  Outstanding' -ForegroundColor Yellow
        foreach ($item in $Review.Outstanding) {
            $marker = if ($item.IsRequired) { 'required' } else { 'recommended' }
            Write-Host ("  {0,-26} {1} ({2})" -f $item.Label, $item.Status, $marker) -ForegroundColor Yellow
        }
    }

    $completeness = $Review.Completeness

    Write-Host ''
    Write-Host ("  Readiness      {0}%" -f $completeness.Readiness)
    Write-Host ("  Required       {0} / {1}" -f $completeness.RequiredSatisfied, $completeness.RequiredTotal)
    Write-Host ("  Recommended    {0} / {1}" -f $completeness.RecommendedSatisfied, $completeness.RecommendedTotal)
    Write-Host ("  Blockers       {0}" -f $completeness.BlockerCount)
    Write-Host ("  Conflicts      {0}" -f $completeness.ConflictCount)

    Write-Host ''
    if ($Review.IsReady) {
        Write-Host '  READY TO BUILD' -ForegroundColor Green
    } else {
        Write-Host '  NOT READY - resolve the items above' -ForegroundColor Red
    }

    $Review.IsReady
}

function Show-InformationInventory {
    <#
    .SYNOPSIS
        Everything the project knows, with source and confidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [switch]$IncludeUnknown
    )

    $rows = @(Get-InformationInventory -Project $Project -IncludeUnknown:$IncludeUnknown)

    Write-Host ''
    Write-Host '════ Project information ════' -ForegroundColor Cyan
    Write-Host ("  {0,-26} {1,-34} {2,-19} {3}" -f 'Field', 'Value', 'Source', 'Status')

    foreach ($row in $rows) {
        Write-Host ("  {0,-26} {1,-34} {2,-19} {3}" -f
            $row.Field,
            (Format-InformationValue -Value $row.Value -MaximumLength 33),
            $row.Source,
            $row.Status)
    }

    $rows.Count
}
