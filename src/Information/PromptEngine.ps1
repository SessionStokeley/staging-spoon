<#
.SYNOPSIS
    Generation of the questions that are actually worth asking.
.DESCRIPTION
    A prompt is produced only for a field that the current operation needs, that
    discovery could not resolve, and that the user has not already answered.
    Every prompt carries why it is being asked, what the platform already found,
    and the ways the answer can be supplied - so the answer is normally a click
    on a value the platform already holds rather than something typed by hand.
#>

Set-StrictMode -Version Latest

# Which recorded source satisfies which offered action.
$script:InputMethodSource = @{
    UseCaptured          = @('CAPTURED')
    UseInstalled         = @('INSTALLED_SYSTEM', 'REGISTRY')
    UseInstallerMetadata = @('INSTALLER_METADATA')
    UsePreviousBuild     = @('PREVIOUS_BUILD')
    UseDetected          = @('DERIVED', 'AUTO_DISCOVERED', 'FILESYSTEM', 'INSTALLER_METADATA', 'CAPTURED', 'INSTALLED_SYSTEM', 'REGISTRY')
}

$script:InputMethodLabel = @{
    UseDetected                = 'Use Detected Value'
    UseCaptured                = 'Use Captured Value'
    UseInstalled               = 'Use Installed Application'
    UsePreviousBuild           = 'Use Previous Project Value'
    UseInstallerMetadata       = 'Use Installer Value'
    BrowseFile                 = 'Select File'
    BrowseFolder               = 'Select Folder'
    DetectInstalledExecutables = 'Detect Installed Executables'
    Choice                     = 'Choose'
    FreeText                   = 'Enter Manually'
    Redetect                   = 'Re-detect'
}

function Test-PromptNeeded {
    <#
    .SYNOPSIS
        Whether a field still warrants a question.
    .DESCRIPTION
        This is the guard that stops the same question being asked twice. A
        field is not asked about when it is resolved, when a decision has
        already been recorded for it, or when the values it derives from are
        themselves still unknown - in that last case the prerequisite is asked
        instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path
    )

    $field = Get-ProjectField -Project $Project -Path $Path

    if ($null -ne $field -and $field.State -eq 'CONFLICT') { return $true }
    if (Test-FieldResolved -Field $field) { return $false }
    if (Test-DecisionRecorded -Store $Project.Evidence -Key $Path) { return $false }

    $definition = Get-FieldDefinition -Path $Path
    if ($null -ne $definition) {
        foreach ($dependency in $definition.DerivesFrom) {
            if (-not (Test-ProjectFieldKnown -Project $Project -Path $dependency)) { return $false }
        }
    }

    $true
}

function Get-PromptOption {
    <#
    .SYNOPSIS
        The ways this particular answer can be supplied right now.
    .DESCRIPTION
        An action that reuses a value is offered only when a value from a
        matching source actually exists, so the user is never shown a
        "Use Captured Value" button with nothing behind it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][PSCustomObject]$Definition
    )

    $observations = @(Get-Fact -Store $Project.Evidence -Key $Definition.Path)
    $options = [System.Collections.Generic.List[PSCustomObject]]::new()
    $offered = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($method in $Definition.InputMethods) {
        if (-not $script:InputMethodSource.ContainsKey($method)) { continue }

        $acceptable = $script:InputMethodSource[$method]
        $match = $observations |
                 Where-Object { $_.Source -in $acceptable -and -not (Test-FieldValueEmpty -Value $_.Value) } |
                 Select-Object -Last 1

        if ($null -eq $match) { continue }

        $key = "$method|$($match.Value -join ',')"
        if (-not $offered.Add($key)) { continue }

        $options.Add([PSCustomObject]@{
            Method   = $method
            Label    = $script:InputMethodLabel[$method]
            Value    = $match.Value
            Source   = $match.Source
            Evidence = $match.Evidence
        })
    }

    foreach ($method in $Definition.InputMethods) {
        if ($script:InputMethodSource.ContainsKey($method)) { continue }

        $option = [PSCustomObject]@{
            Method   = $method
            Label    = $script:InputMethodLabel[$method]
            Value    = $null
            Source   = ''
            Evidence = ''
        }

        if ($method -eq 'Choice') {
            $option | Add-Member -NotePropertyName 'Choices' -NotePropertyValue $Definition.Choices
        }

        $options.Add($option)
    }

    @($options)
}

function Get-PromptExplanation {
    <#
    .SYNOPSIS
        Why the platform is asking, in terms of what it already tried.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][PSCustomObject]$Definition
    )

    $field = Get-ProjectField -Project $Project -Path $Definition.Path

    if ($null -ne $field -and $field.State -eq 'CONFLICT') {
        return 'Two sources reported different values and neither outranks the other.'
    }

    if ($Definition.Discoverers.Count -eq 0) {
        return 'This is a deployment policy choice. Nothing about the installer can decide it.'
    }

    $attempted = $Definition.Discoverers -join ', '

    if ($null -ne $field -and $field.State -eq 'INVALID') {
        return "A value was found but failed validation. Sources tried: $attempted."
    }

    "Automatic discovery could not resolve this. Sources tried: $attempted."
}

function New-InformationPrompt {
    <#
    .SYNOPSIS
        Builds the descriptor a UI renders as a question.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][PSCustomObject]$Definition,
        [switch]$IsRequired
    )

    $field = Get-ProjectField -Project $Project -Path $Definition.Path
    $conflict = if ($null -ne $field -and $field.State -eq 'CONFLICT') {
        Get-FieldConflict -Project $Project -Path $Definition.Path
    } else {
        $null
    }

    [PSCustomObject]@{
        Path         = $Definition.Path
        Label        = $Definition.Label
        Type         = $Definition.Type
        Group        = $Definition.Group
        Priority     = $Definition.Priority
        Rank         = $Definition.PriorityRank
        IsRequired   = [bool]$IsRequired
        IsDecision   = $Definition.IsDecision
        Why          = $Definition.Why
        Explanation  = Get-PromptExplanation -Project $Project -Definition $Definition
        Choices      = $Definition.Choices
        Options      = Get-PromptOption -Project $Project -Definition $Definition
        CurrentValue = if ($null -eq $field) { $null } else { $field.Value }
        Conflict     = $conflict
    }
}

function Get-PendingPrompt {
    <#
    .SYNOPSIS
        Every question the current operation still needs answered, in the order
        they should be asked.
    .DESCRIPTION
        Required information comes before recommended, and within each, lower
        priority ranks come first. A cosmetic preference is never raised while
        something that blocks the build is outstanding.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$IncludeRecommended
    )

    $requirement = Get-OperationRequirement -Operation $Operation
    $prompts = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($definition in $requirement.Required) {
        if (-not (Test-PromptNeeded -Project $Project -Path $definition.Path)) { continue }
        $prompts.Add((New-InformationPrompt -Project $Project -Definition $definition -IsRequired))
    }

    if ($IncludeRecommended) {
        foreach ($definition in $requirement.Recommended) {
            if (-not (Test-PromptNeeded -Project $Project -Path $definition.Path)) { continue }
            $prompts.Add((New-InformationPrompt -Project $Project -Definition $definition))
        }
    }

    @($prompts | Sort-Object -Property @{ Expression = { -not $_.IsRequired } }, 'Rank', 'Path')
}

function Get-PromptGroup {
    <#
    .SYNOPSIS
        Pending prompts gathered into the screens they belong on, so related
        questions are asked together instead of as a run of single dialogs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$IncludeRecommended
    )

    $prompts = @(Get-PendingPrompt -Project $Project -Operation $Operation -IncludeRecommended:$IncludeRecommended)
    if ($prompts.Count -eq 0) { return @() }

    $groups = $prompts | Group-Object -Property Group

    $result = foreach ($group in $groups) {
        $members = @($group.Group | Sort-Object Rank, Path)
        [PSCustomObject]@{
            Group        = $group.Name
            Prompts      = $members
            Rank         = ($members | Measure-Object -Property Rank -Minimum).Minimum
            RequiredCount = @($members | Where-Object { $_.IsRequired }).Count
        }
    }

    @($result | Sort-Object Rank, Group)
}

function Resolve-InformationPrompt {
    <#
    .SYNOPSIS
        Applies an answer and records it so the question is never asked again.
    .DESCRIPTION
        An answer to a policy question is stored as a decision as well as a
        field, because a decision is what the platform consults to know the
        matter is settled even when the underlying fact later changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()]$Value,
        [string]$Method = 'FreeText',
        [string]$Rationale = ''
    )

    $definition = Get-FieldDefinition -Path $Path

    # Accepting a value the platform found keeps that value's original source,
    # so the report still shows where it came from rather than crediting it to
    # the user.
    $source = switch ($Method) {
        'UseCaptured'          { 'CAPTURED' }
        'UseInstalled'         { 'INSTALLED_SYSTEM' }
        'UseInstallerMetadata' { 'INSTALLER_METADATA' }
        'UsePreviousBuild'     { 'PREVIOUS_BUILD' }
        'UseDetected'          { 'DERIVED' }
        'BrowseFile'           { 'USER_SELECTED' }
        'BrowseFolder'         { 'USER_SELECTED' }
        'Choice'               { 'USER_SELECTED' }
        default                { 'USER_ENTERED' }
    }

    $existing = Get-ProjectField -Project $Project -Path $Path

    if ($null -ne $existing) {
        Set-FieldOverride -Field $existing -Value $Value -Reason $Rationale -Source $source | Out-Null
        Add-Fact -Store $Project.Evidence -Key $Path -Value $Value -Source $source `
                 -Evidence "Answered by user via $Method" | Out-Null
    } else {
        Set-ProjectField -Project $Project -Path $Path -Value $Value -Source $source `
            -Evidence "Answered by user via $Method" -State 'CONFIRMED' | Out-Null

        $field = Get-ProjectField -Project $Project -Path $Path
        $field.ConfirmedByUser = $true
        $field.Confidence      = 'CONFIRMED'
    }

    if ($null -ne $definition -and $definition.IsDecision) {
        Set-Decision -Store $Project.Evidence -Key $Path -Value $Value -Rationale $Rationale | Out-Null
    }

    Get-ProjectField -Project $Project -Path $Path
}

function Reset-InformationPrompt {
    <#
    .SYNOPSIS
        Forgets an answer so the platform asks again, used when the evidence
        underneath a decision changed or the user wants to redo a choice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path,
        [string]$Reason = 'reset by user'
    )

    Clear-Decision -Store $Project.Evidence -Key $Path -Reason $Reason | Out-Null

    $field = Get-ProjectField -Project $Project -Path $Path
    if ($null -eq $field) { return $null }

    if ($null -ne $field.OriginalSource) {
        return Reset-FieldToDiscovered -Field $field
    }

    $field.State           = 'UNKNOWN'
    $field.Value           = $null
    $field.ConfirmedByUser = $false
    $field.UpdatedAt       = (Get-Date).ToString('o')
    Add-FieldHistory -Field $field -Note "reset: $Reason"
}
