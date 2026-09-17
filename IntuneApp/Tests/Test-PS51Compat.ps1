#Requires -Version 5.1
<#
    Test-PS51Compat.ps1

    Windows PowerShell 5.1 compatibility, in three parts.

    1. Syntax audit (runs anywhere, real)
       Walks every shipped script's syntax tree and fails on any construct
       Windows PowerShell 5.1 cannot parse: ternaries, null-coalescing,
       null-conditional access, pipeline chain operators, and the automatic
       variables that exist only on PowerShell Core. Detection is by AST node
       type rather than by grep, so a construct inside a string or a comment
       cannot produce a false positive.

    2. The 5.1 loader path, executed (runs anywhere, real)
       Import-PowerShellDataFile on 5.1 rejects a script-block literal, taking
       the whole configuration with it. Import-PackageConfiguration -Strict is
       the reader that replaces it. -Strict is not a simulation: it is the
       exact code path 5.1 takes, forced to run here. Detection.ps1 is then
       driven end to end through that path with INTUNE_FORCE_PS51_LOADER, so
       config load, custom-detection load, execution and verdict are all
       genuinely exercised.

    3. A live Windows PowerShell 5.1 run (Windows only)
       Runs the same checks under powershell.exe when it is present, and
       reports [SKIP] otherwise. This is the only part that needs Windows, and
       it is never counted as a pass when it did not run.

    Run:
        pwsh -File Tests/Test-PS51Compat.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-PS51Compat.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

. (Join-Path $AppRoot 'Helpers\ConfigLoader.ps1')

$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Test-Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:pass++
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkRed }
        $script:fail++
        $script:failures.Add($Name)
    }
}

function Test-Skip {
    param([string]$Name, [string]$Reason)
    Write-Host "  SKIP  $Name" -ForegroundColor Yellow
    Write-Host "        $Reason" -ForegroundColor DarkYellow
    $script:skip++
}

function Test-Group { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor White }

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Windows PowerShell 5.1 Compatibility' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "  Running on: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor DarkGray

# ============================================================ 1. Syntax audit

Test-Group '1. PowerShell 7-only syntax must not appear in shipped scripts'

# Node type names rather than [Type] literals: TernaryExpressionAst and
# PipelineChainAst do not exist in the 5.1 assembly, so referencing the types
# would make this file itself fail to load on 5.1.
$ps7OnlyNodeTypes = @{
    'TernaryExpressionAst' = 'a ternary (a ? b : c)'
    'PipelineChainAst'     = 'a pipeline chain operator (&& or ||)'
}

# Operators that parse as ordinary binary/assignment nodes but whose token
# kinds arrived in PowerShell 7.
$ps7OnlyTokenKinds = @{
    'QuestionQuestion'       = 'null-coalescing (??)'
    'QuestionQuestionEquals' = 'null-coalescing assignment (??=)'
    'QuestionDot'            = 'null-conditional access (?.)'
    'QuestionLBracket'       = 'null-conditional index (?[])'
}

# Automatic variables that exist only on PowerShell Core. A bare reference
# throws on 5.1 under Set-StrictMode; Get-Variable is the safe form.
$coreOnlyVariables = @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR', 'PSStyle')

# Cmdlets and parameters with no 5.1 equivalent.
$ps7OnlyCommandPatterns = @(
    @{ Pattern = '(?i)ForEach-Object[^\r\n]*-Parallel';      What = 'ForEach-Object -Parallel' },
    @{ Pattern = '(?i)ConvertFrom-Json[^\r\n]*-AsHashtable'; What = 'ConvertFrom-Json -AsHashtable' },
    @{ Pattern = '(?i)\bGet-Error\b';                        What = 'Get-Error' },
    @{ Pattern = '(?i)\bJoin-String\b';                      What = 'Join-String' },
    @{ Pattern = '(?i)\bTest-Json\b';                        What = 'Test-Json' },
    @{ Pattern = '(?i)\bRemove-Service\b';                   What = 'Remove-Service' },
    @{ Pattern = '(?i)Split-Path[^\r\n]*-LeafBase';          What = 'Split-Path -LeafBase' },
    @{ Pattern = '(?i)-ErrorAction\s+Break';                 What = '-ErrorAction Break' }
)

function Remove-CommentSpans {
    <#
        Blanks out comments and string literals so the command-name scan
        cannot fire on prose or on an example inside a here-string. Spans are
        blanked from the end so earlier offsets stay valid.
    #>
    param([Parameter(Mandatory)][string]$Source)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors) | Out-Null

    $result = $Source
    $spans = @($tokens | Where-Object { $_.Kind -eq 'Comment' -or $_.Kind -eq 'StringLiteral' -or $_.Kind -eq 'StringExpandable' }) |
        Sort-Object { $_.Extent.StartOffset } -Descending

    foreach ($span in $spans) {
        $start = $span.Extent.StartOffset
        $length = $span.Extent.EndOffset - $start
        if ($length -gt 0 -and ($start + $length) -le $result.Length) {
            $result = $result.Remove($start, $length).Insert($start, ' ' * $length)
        }
    }
    return $result
}

$shippedScripts = @(
    Get-ChildItem -Path $AppRoot -Filter *.ps1 -File
    Get-ChildItem -Path (Join-Path $AppRoot 'Helpers') -Filter *.ps1 -File -ErrorAction SilentlyContinue
    Get-ChildItem -Path (Join-Path $AppRoot 'Studio') -Filter *.ps1 -File -ErrorAction SilentlyContinue
)

$violations = @()

foreach ($file in $shippedScripts) {
    $source = Get-Content -LiteralPath $file.FullName -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        foreach ($e in @($parseErrors)) {
            $violations += "$($file.Name):$($e.Extent.StartLineNumber) does not parse: $($e.Message)"
        }
        continue
    }

    # --- AST node types ---
    $allNodes = $ast.FindAll({ param($n) $true }, $true)
    foreach ($node in $allNodes) {
        $typeName = $node.GetType().Name
        if ($ps7OnlyNodeTypes.ContainsKey($typeName)) {
            $violations += "$($file.Name):$($node.Extent.StartLineNumber) uses $($ps7OnlyNodeTypes[$typeName])"
        }
    }

    # --- token kinds ---
    foreach ($token in @($tokens)) {
        $kind = [string]$token.Kind
        if ($ps7OnlyTokenKinds.ContainsKey($kind)) {
            $violations += "$($file.Name):$($token.Extent.StartLineNumber) uses $($ps7OnlyTokenKinds[$kind])"
        }
    }

    # --- Core-only automatic variables, referenced directly ---
    $variableNodes = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
    foreach ($node in @($variableNodes)) {
        $name = [string]$node.VariablePath.UserPath
        if ($coreOnlyVariables -contains $name) {
            $violations += "$($file.Name):$($node.Extent.StartLineNumber) references `$$name directly. Read it with Get-Variable, which is safe on 5.1."
        }
    }

    # --- PowerShell 7-only commands and parameters ---
    $code = Remove-CommentSpans -Source $source
    foreach ($rule in $ps7OnlyCommandPatterns) {
        if ($code -match $rule.Pattern) {
            $violations += "$($file.Name) uses $($rule.What)"
        }
    }
}

Test-Assert "All $($shippedScripts.Count) shipped scripts are free of PowerShell 7-only syntax" `
    ($violations.Count -eq 0) ($violations -join "`n        ")

# -notmatch against an array filters it rather than returning a boolean, so
# the header is joined into one string before it is tested.
$missingRequires = @($shippedScripts | Where-Object {
    ((Get-Content -LiteralPath $_.FullName -TotalCount 3) -join "`n") -notmatch '#Requires\s+-Version\s+5\.1'
})
Test-Assert 'Every shipped script declares #Requires -Version 5.1' `
    ($missingRequires.Count -eq 0) (($missingRequires | ForEach-Object { $_.Name }) -join ', ')

# ================================================ 2. The 5.1 loader, executed

Test-Group '2. Custom detection under the Windows PowerShell 5.1 loader'

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ps51_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

try {
    $installedMarker = Join-Path $workDir 'Installed.txt'
    Set-Content -LiteralPath $installedMarker -Value 'present' -Encoding UTF8
    $absentMarker = Join-Path $workDir 'NotInstalled.txt'
    $markerLiteral = $installedMarker.Replace("'", "''")
    $absentLiteral = $absentMarker.Replace("'", "''")

    # --- 2a. A script-block configuration: what 5.1's native loader refuses ---
    $legacyConfig = Join-Path $workDir 'legacy.psd1'
    Set-Content -LiteralPath $legacyConfig -Encoding UTF8 -Value @"
@{
    ApplicationName = 'Legacy'
    Detection = @{
        Type        = 'Custom'
        ScriptBlock = { Test-Path '$markerLiteral' }
    }
}
"@

    $report = Test-ConfigurationLoadsOnPS51 -Path $legacyConfig
    Test-Assert 'A script-block configuration is identified as needing the fallback reader' `
        (-not $report.Loads)
    Test-Assert 'The reason names the script block and the fix' `
        (($report.Reasons -join ' ') -match 'script block literal' -and ($report.Reasons -join ' ') -match 'ScriptFile')

    # -Strict is the 5.1 path, not a stand-in for it.
    $loaded = Import-PackageConfiguration -Path $legacyConfig -Strict
    Test-Assert '1. Config loads under the 5.1 reader' ($loaded.ApplicationName -eq 'Legacy')
    Test-Assert '   Nested sections survive the 5.1 reader' ($loaded.Detection.Type -eq 'Custom')

    $resolved = Resolve-DetectionScript -Detection $loaded.Detection -PackageRoot $workDir
    Test-Assert '2. Custom detection loads' ($null -ne $resolved -and $resolved -is [scriptblock])

    $verdict = & $resolved
    Test-Assert '3. Custom detection executes' ($verdict -is [bool])
    Test-Assert '4. Custom detection returns the expected result' ($verdict -eq $true) "got '$verdict'"

    # --- 2b. The 5.1-safe forms ---
    $stringConfig = Join-Path $workDir 'string.psd1'
    Set-Content -LiteralPath $stringConfig -Encoding UTF8 -Value @"
@{
    ApplicationName = 'Modern'
    Detection = @{
        Type   = 'Custom'
        Script = 'Test-Path ''$markerLiteral'''
    }
}
"@
    $stringReport = Test-ConfigurationLoadsOnPS51 -Path $stringConfig
    Test-Assert '5. The Script form needs no fallback on 5.1' $stringReport.Loads ($stringReport.Reasons -join '; ')
    Test-Assert '   The Script form resolves and returns true' `
        ((& (Resolve-DetectionScript -Detection (Import-PackageConfiguration -Path $stringConfig -Strict).Detection)) -eq $true)

    Set-Content -LiteralPath (Join-Path $workDir 'Detect.ps1') -Encoding UTF8 `
        -Value "Test-Path '$markerLiteral'"
    $fileConfig = Join-Path $workDir 'file.psd1'
    Set-Content -LiteralPath $fileConfig -Encoding UTF8 -Value @"
@{
    ApplicationName = 'Modern'
    Detection = @{ Type = 'Custom'; ScriptFile = 'Detect.ps1' }
}
"@
    $fileReport = Test-ConfigurationLoadsOnPS51 -Path $fileConfig
    Test-Assert '   The ScriptFile form needs no fallback on 5.1' $fileReport.Loads
    Test-Assert '   The ScriptFile form resolves relative to the package' `
        ((& (Resolve-DetectionScript -Detection (Import-PackageConfiguration -Path $fileConfig -Strict).Detection -PackageRoot $workDir)) -eq $true)

    # --- 2c. The reader must agree with the native loader on ordinary files ---
    $plainConfig = Join-Path $workDir 'plain.psd1'
    Set-Content -LiteralPath $plainConfig -Encoding UTF8 -Value @'
@{
    ApplicationName  = 'Plain'
    SuccessExitCodes = @(0, 3010)
    Installer        = @{ Type = 'MSI'; File = 'x.msi'; Arguments = '/qn' }
    Uninstaller      = @{ Type = 'MSI'; ProductCode = $null }
    Nested           = @{ Truthy = $true; Falsey = $false; Nothing = $null; Negative = -5 }
    Empty            = @()
    List             = @(
        @{ Name = 'A'; Value = 'one' }
        @{ Name = 'B'; Value = 'two' }
    )
}
'@
    $native = Import-PowerShellDataFile -LiteralPath $plainConfig
    $viaTree = Import-PackageConfiguration -Path $plainConfig -Strict

    Test-Assert '6. The 5.1 reader agrees with the native loader on scalars' `
        ($viaTree.ApplicationName -eq $native.ApplicationName -and
         $viaTree.Nested.Truthy -eq $true -and $viaTree.Nested.Falsey -eq $false -and
         $null -eq $viaTree.Nested.Nothing -and $viaTree.Nested.Negative -eq -5)
    Test-Assert '   ...on arrays' `
        (@($viaTree.SuccessExitCodes).Count -eq 2 -and $viaTree.SuccessExitCodes[1] -eq 3010 -and
         @($viaTree.Empty).Count -eq 0 -and @($viaTree.List).Count -eq 2 -and $viaTree.List[1].Value -eq 'two')
    Test-Assert '   ...and returns the same Hashtable shape' `
        ($viaTree -is [hashtable] -and $viaTree.Installer -is [hashtable])

    # --- 2d. Detection.ps1 end to end through the 5.1 loader ---
    Test-Group '   Detection.ps1 driven end to end through the 5.1 reader'

    function Invoke-DetectionEndToEnd {
        param([string]$ConfigText, [switch]$ForceTreeReader)

        $dir = Join-Path $workDir ("e2e_" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $AppRoot 'Detection.ps1') (Join-Path $dir 'Detection.ps1')
        Copy-Item (Join-Path $AppRoot 'Helpers') (Join-Path $dir 'Helpers') -Recurse -Force
        Set-Content -LiteralPath (Join-Path $dir 'Configuration.psd1') -Value $ConfigText -Encoding UTF8

        $previous = $env:INTUNE_FORCE_PS51_LOADER
        if ($ForceTreeReader) { $env:INTUNE_FORCE_PS51_LOADER = '1' }
        try {
            $out = & (Join-Path $dir 'Detection.ps1') 2>&1
            return @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        }
        finally {
            $env:INTUNE_FORCE_PS51_LOADER = $previous
        }
    }

    $legacyText = @"
@{
    ApplicationName = 'Legacy'
    Detection = @{ Type = 'Custom'; ScriptBlock = { Test-Path '$markerLiteral' } }
}
"@
    $r = Invoke-DetectionEndToEnd -ConfigText $legacyText -ForceTreeReader
    Test-Assert 'Installed application detected through the 5.1 reader' ($r.ExitCode -eq 0) $r.Output

    $legacyAbsent = @"
@{
    ApplicationName = 'Legacy'
    Detection = @{ Type = 'Custom'; ScriptBlock = { Test-Path '$absentLiteral' } }
}
"@
    $r = Invoke-DetectionEndToEnd -ConfigText $legacyAbsent -ForceTreeReader
    Test-Assert 'Absent application NOT detected through the 5.1 reader' ($r.ExitCode -ne 0) $r.Output

    # The bug this guards: Import-PowerShellDataFile hands back a script block
    # whose body is the literal '{ ... }', so invoking it returned a script
    # block - always truthy - and every application looked installed.
    $r = Invoke-DetectionEndToEnd -ConfigText $legacyAbsent
    Test-Assert 'Absent application NOT detected through the native loader either' `
        ($r.ExitCode -ne 0) 'a script block value must be unwrapped before it is invoked'

    $r = Invoke-DetectionEndToEnd -ConfigText @"
@{ ApplicationName = 'M'; Detection = @{ Type = 'Custom'; Script = 'Test-Path ''$markerLiteral''' } }
"@ -ForceTreeReader
    Test-Assert 'The Script form works end to end through the 5.1 reader' ($r.ExitCode -eq 0) $r.Output

    # ====================================== 3. A live Windows PowerShell 5.1 run
    Test-Group '3. Live Windows PowerShell 5.1'

    $windowsPowerShell = $null
    if ($PSVersionTable.PSEdition -ne 'Core' -or
        (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)) {
        $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $candidate) { $windowsPowerShell = $candidate }
    }

    if (-not $windowsPowerShell) {
        Test-Skip 'Elevated-free Windows PowerShell 5.1 run' `
            'Not running on Windows, so powershell.exe is unavailable. Parts 1 and 2 above still ran in full and cover the 5.1 code path.'
    }
    else {
        # The real thing: 5.1's own loader, 5.1's own parser.
        $probe = Join-Path $workDir 'probe51.ps1'
        Set-Content -LiteralPath $probe -Encoding UTF8 -Value @"
`$ErrorActionPreference = 'Stop'
. '$((Join-Path $AppRoot 'Helpers\ConfigLoader.ps1').Replace("'","''"))'
`$results = @()

# The native 5.1 loader must refuse a script block...
try { Import-PowerShellDataFile -LiteralPath '$($legacyConfig.Replace("'","''"))' | Out-Null; `$results += 'native=loaded' }
catch { `$results += 'native=refused' }

# ...and the fallback reader must succeed where it did not.
`$cfg = Import-PackageConfiguration -Path '$($legacyConfig.Replace("'","''"))'
`$results += "appname=`$(`$cfg.ApplicationName)"
`$sb = Resolve-DetectionScript -Detection `$cfg.Detection -PackageRoot '$($workDir.Replace("'","''"))'
`$results += "verdict=`$(& `$sb)"
`$results += "version=`$(`$PSVersionTable.PSVersion.Major).`$(`$PSVersionTable.PSVersion.Minor)"
`$results -join '|'
"@
        $raw = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1
        $text = ($raw -join ' ')

        Test-Assert 'Windows PowerShell 5.1 reports version 5.1' ($text -match 'version=5\.1') $text
        Test-Assert '1. Config loads on 5.1 (via the fallback reader)' ($text -match 'appname=Legacy') $text
        Test-Assert '4. Custom detection returns the expected result on 5.1' ($text -match 'verdict=True') $text
        Test-Assert '5. No PowerShell 7-only syntax was required' ($text -notmatch 'ParserError|not recognized') $text

        if ($text -match 'native=refused') {
            Write-Host '        (confirmed: 5.1 native loader refuses the script-block form)' -ForegroundColor DarkGray
        }
    }
}
finally {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
$total = $script:pass + $script:fail + $script:skip
Write-Host "Total: $total   Pass: $($script:pass)   Fail: $($script:fail)   Skip: $($script:skip)" `
    -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) {
    Write-Host ''
    Write-Host 'Failed:' -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
}
Write-Host '========================================' -ForegroundColor Cyan

if ($script:fail -gt 0) { exit 1 }
exit 0
