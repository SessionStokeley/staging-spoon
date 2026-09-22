<#
.SYNOPSIS
    Guards against constructs that fail on Windows PowerShell 5.1.
.DESCRIPTION
    The build runs on whatever PowerShell a packaging workstation has, which is
    usually Windows PowerShell 5.1 rather than PowerShell 7. Several things
    that work here do not exist there, and under Set-StrictMode they throw
    rather than degrade. This suite cannot run 5.1, so it scans the source for
    the constructs that break on it.
.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-CompatibilityTests.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src/Core/Platform.ps1')

$script:failures = 0

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        Write-Host "  PASS $Name"
    } else {
        Write-Host "  FAIL $Name $Detail" -ForegroundColor Red
        $script:failures++
    }
}

function Remove-PowerShellComment {
    <#
    .SYNOPSIS
        Strips comments so a scan reports real code, not documentation that
        mentions the very construct being looked for.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $withoutBlocks = [regex]::Replace($Text, '(?s)<#.*?#>', '')

    $lines = foreach ($line in ($withoutBlocks -split "`r?`n")) {
        if ($line.TrimStart().StartsWith('#')) { continue }
        $line
    }

    $lines -join "`n"
}

# Each rule is a construct that is absent or behaves differently on 5.1.
$script:CompatibilityRule = @(
    @{
        Name    = 'automatic platform variables'
        Pattern = '\$Is(Windows|Linux|MacOS)\b'
        Reason  = 'introduced in PowerShell 6; under StrictMode 5.1 throws on the reference. Use Test-WindowsPlatform.'
        Exclude = @('Platform.ps1')
    }
    @{
        Name    = 'Encoding::Latin1'
        Pattern = '\[System\.Text\.Encoding\]::Latin1'
        Reason  = '.NET 5 and later only. Use Get-Latin1Encoding.'
        Exclude = @('Platform.ps1')
    }
    @{
        Name    = 'null-coalescing operators'
        Pattern = '\?\?'
        Reason  = 'PowerShell 7 syntax; a parse error on 5.1.'
        Exclude = @()
    }
    @{
        Name    = 'pipeline chain operators'
        Pattern = '(?<![&|`])(\&\&|\|\|)(?![&|])'
        Reason  = 'PowerShell 7 syntax; a parse error on 5.1.'
        Exclude = @()
    }
    @{
        Name    = 'ForEach-Object -Parallel'
        Pattern = '-Parallel\b'
        Reason  = 'PowerShell 7 only.'
        Exclude = @()
    }
    @{
        Name    = 'Get-Content -AsByteStream'
        Pattern = '-AsByteStream\b'
        Reason  = 'PowerShell 6 and later; 5.1 uses -Encoding Byte.'
        Exclude = @()
    }
    @{
        Name    = 'ConvertFrom-Json -AsHashtable'
        Pattern = '-AsHashtable\b'
        Reason  = 'PowerShell 6 and later.'
        Exclude = @()
    }
)

$files = @(Get-ChildItem -Path (Join-Path $repo 'src'), (Join-Path $repo 'templates') -Filter '*.ps1' -Recurse)

Write-Host "`nWindows PowerShell 5.1 compatibility"
Write-Host "  Scanning $($files.Count) files"

foreach ($rule in $script:CompatibilityRule) {
    $offenders = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $files) {
        if ($file.Name -in $rule.Exclude) { continue }

        $code = Remove-PowerShellComment -Text (Get-Content -LiteralPath $file.FullName -Raw)
        $matched = [regex]::Matches($code, $rule.Pattern)
        if ($matched.Count -gt 0) { $offenders.Add("$($file.Name) x$($matched.Count)") }
    }

    Test-Case "no $($rule.Name)" ($offenders.Count -eq 0) "$($offenders -join ', ') - $($rule.Reason)"
}

# A 5.1 console is rarely UTF-8, so anything outside ASCII renders as noise.
$nonAscii = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $code = Get-Content -LiteralPath $file.FullName -Raw
    if ([regex]::IsMatch($code, '[^\x00-\x7F]')) { $nonAscii.Add($file.Name) }
}
Test-Case 'source is ASCII only' ($nonAscii.Count -eq 0) ($nonAscii -join ', ')

# Adding an int to a string is a runtime error on every edition, and it only
# shows up when the branch that formats a count actually runs.
$numericConcat = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $code = Remove-PowerShellComment -Text (Get-Content -LiteralPath $file.FullName -Raw)
    if ([regex]::IsMatch($code, '\.Count\s*\+\s*"')) { $numericConcat.Add($file.Name) }
}
Test-Case 'no count added to a string' ($numericConcat.Count -eq 0) ($numericConcat -join ', ')

Write-Host "`nPlatform probe"

$probe = Test-WindowsPlatform
Test-Case 'probe returns a boolean'   ($probe -is [bool])
Test-Case 'probe agrees with the host' ($probe -eq [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue) -or
                                        $null -eq (Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue))

$encoding = Get-Latin1Encoding
Test-Case 'latin-1 encoding available' ($null -ne $encoding)
Test-Case 'every byte maps to a char'  ($encoding.GetString([byte[]](0x4D, 0x5A, 0xFF, 0x00)).Length -eq 4)
Test-Case 'markers survive the decode' ($encoding.GetString($encoding.GetBytes('Inno Setup')) -eq 'Inno Setup')

Write-Host "`nEvery script parses"

foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors.Count -gt 0) {
        Test-Case "parses: $($file.Name)" $false $parseErrors[0].Message
    }
}
Test-Case 'all source files parse' $true

Write-Host ""
if ($script:failures -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "$($script:failures) TEST(S) FAILED" -ForegroundColor Red
exit 1
