#Requires -Version 5.1
<#
    Prompt.ps1

    Console prompt primitives used by the wizard.

    Every prompt reads through Read-WizardInput. When $script:AnswerQueue holds
    values they are consumed instead of the console, which is what lets the
    whole wizard be driven end-to-end by the test suite without a human.
#>

Set-StrictMode -Version Latest

$script:AnswerQueue = [System.Collections.Generic.Queue[string]]::new()

# True once answers have been supplied programmatically. In that mode an
# exhausted queue is an error rather than a fall-through to Read-Host, so an
# unattended run fails fast instead of blocking forever on a hidden prompt.
$script:ScriptedMode = $false

function Set-WizardAnswers {
    <#
        Pre-seeds scripted answers. Used by tests and unattended runs.
    #>
    param([AllowNull()][string[]]$Answers)

    $script:AnswerQueue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($a in @($Answers)) { $script:AnswerQueue.Enqueue([string]$a) }
    $script:ScriptedMode = $true
}

function Clear-WizardAnswers {
    $script:AnswerQueue = [System.Collections.Generic.Queue[string]]::new()
    $script:ScriptedMode = $false
}

function Get-WizardAnswerCount { return $script:AnswerQueue.Count }

function Read-WizardInput {
    param([string]$Prompt = '')

    if ($script:AnswerQueue.Count -gt 0) {
        $value = $script:AnswerQueue.Dequeue()
        Write-Host "$Prompt$value" -ForegroundColor DarkCyan
        return $value
    }

    if ($script:ScriptedMode) {
        throw "Scripted answers exhausted at prompt: '$Prompt'. Supply another answer, or omit -Answers to run interactively."
    }

    return Read-Host -Prompt $Prompt
}

function Write-WizardTitle {
    param([Parameter(Mandatory)][string]$Text, [string]$Step = '')

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Cyan
    if ($Step) {
        Write-Host "$Step  $Text" -ForegroundColor Cyan
    }
    else {
        Write-Host $Text -ForegroundColor Cyan
    }
    Write-Host ('=' * 62) -ForegroundColor Cyan
}

function Write-WizardSection {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor White
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Write-WizardNote {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "  $Text" -ForegroundColor DarkGray
}

function Write-WizardWarning {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "  ! $Text" -ForegroundColor Yellow
}

function Read-WizardText {
    <#
        Free-text prompt. Enter accepts the default.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Default = '',
        [switch]$AllowEmpty
    )

    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-WizardInput -Prompt "  $Question$suffix"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($Default) { return $Default }
            if ($AllowEmpty) { return '' }
            Write-WizardWarning 'A value is required.'
            continue
        }
        return $answer.Trim()
    }
}

function Read-WizardChoice {
    <#
        Single-select. Renders the options as a radio list and returns the
        chosen option's value.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][object[]]$Options,   # @{ Label=..; Value=..; Note=.. }
        [int]$DefaultIndex = 0
    )

    Write-Host ''
    Write-Host "  $Question" -ForegroundColor White

    for ($i = 0; $i -lt $Options.Count; $i++) {
        $opt = $Options[$i]
        $marker = if ($i -eq $DefaultIndex) { '(*)' } else { '( )' }
        Write-Host "    $($i + 1). $marker $($opt.Label)"
        if ($opt.Contains('Note') -and $opt.Note) {
            Write-Host "           $($opt.Note)" -ForegroundColor DarkGray
        }
    }

    while ($true) {
        $answer = Read-WizardInput -Prompt "  Select 1-$($Options.Count) [$($DefaultIndex + 1)]"

        if ([string]::IsNullOrWhiteSpace($answer)) { return $Options[$DefaultIndex].Value }

        $n = 0
        if ([int]::TryParse($answer.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $Options[$n - 1].Value
        }
        Write-WizardWarning "Enter a number between 1 and $($Options.Count)."
    }
}

function Read-WizardYesNo {
    param(
        [Parameter(Mandatory)][string]$Question,
        [bool]$Default = $true
    )

    $hint = if ($Default) { 'Y/n' } else { 'y/N' }

    while ($true) {
        $answer = Read-WizardInput -Prompt "  $Question [$hint]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }

        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-WizardWarning 'Enter y or n.' }
        }
    }
}

function Read-WizardMultiSelect {
    <#
        Multi-select. Accepts a comma separated list of numbers, 'all', 'none',
        or Enter to take the pre-checked defaults.

        Returns the selected items' values.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][object[]]$Options,   # @{ Label=..; Value=..; Checked=$true/$false; Note=.. }
        [string]$Hint = 'Enter numbers separated by commas, "all", "none", or press Enter to accept'
    )

    if ($Options.Count -eq 0) { return @() }

    Write-Host ''
    Write-Host "  $Question" -ForegroundColor White

    for ($i = 0; $i -lt $Options.Count; $i++) {
        $opt = $Options[$i]
        $checked = $opt.Contains('Checked') -and $opt.Checked
        $box = if ($checked) { '[x]' } else { '[ ]' }
        Write-Host "    $($i + 1). $box $($opt.Label)"
        if ($opt.Contains('Note') -and $opt.Note) {
            foreach ($noteLine in ($opt.Note -split "`n")) {
                Write-Host "           $noteLine" -ForegroundColor DarkGray
            }
        }
    }
    Write-WizardNote $Hint

    while ($true) {
        $answer = Read-WizardInput -Prompt '  Selection'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return @($Options | Where-Object { $_.Contains('Checked') -and $_.Checked } |
                ForEach-Object { $_.Value })
        }

        $trimmed = $answer.Trim().ToLowerInvariant()
        if ($trimmed -eq 'none') { return @() }
        if ($trimmed -eq 'all')  { return @($Options | ForEach-Object { $_.Value }) }

        $selected = @()
        $ok = $true
        foreach ($part in $trimmed.Split(',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
                $selected += $Options[$n - 1].Value
            }
            else {
                Write-WizardWarning "'$($part.Trim())' is not a valid selection."
                $ok = $false
                break
            }
        }
        if ($ok) { return $selected }
    }
}

function Read-WizardList {
    <#
        Collects a list of free-text values (used for PATH entries).
        A blank line ends the list.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [string[]]$Existing = @()
    )

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($Existing)) { $items.Add([string]$e) }

    Write-Host ''
    Write-Host "  $Question" -ForegroundColor White
    Write-WizardNote 'Enter one value per line. Blank line finishes.'

    if ($items.Count -gt 0) {
        Write-WizardNote 'Current:'
        foreach ($i in $items) { Write-WizardNote "  $i" }
    }

    while ($true) {
        $answer = Read-WizardInput -Prompt '  >'
        if ([string]::IsNullOrWhiteSpace($answer)) { break }

        $value = $answer.Trim()
        if ($value.Contains(';')) {
            Write-WizardWarning 'A PATH entry cannot contain a semicolon. Enter each directory separately.'
            continue
        }
        if ($items -contains $value) {
            Write-WizardWarning 'Already in the list.'
            continue
        }
        $items.Add($value)
    }

    return , $items.ToArray()
}
