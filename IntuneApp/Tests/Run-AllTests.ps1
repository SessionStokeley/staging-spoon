#Requires -Version 5.1
<#
    Run-AllTests.ps1

    Runs every suite and prints one table.

    Skips are reported separately from passes throughout, and the exit code
    ignores them: a suite that skipped everything has proved nothing, and
    counting that as success is how an untested path ships. The summary says
    plainly which suites ran in full and which did not.

    Run:
        pwsh -File Tests/Run-AllTests.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Run-AllTests.ps1
#>

param(
    # Run only the suites that need no Windows-specific capability.
    [switch]$PortableOnly
)

$ErrorActionPreference = 'Stop'
$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$suites = @(
    @{ Name = 'Environment';  File = 'Test-Environment.ps1';  Covers = 'PATH and variable semantics' },
    @{ Name = 'Lifecycle';    File = 'Test-Lifecycle.ps1';    Covers = 'install/uninstall orchestration' },
    @{ Name = 'Integration';  File = 'Test-Integration.ps1';  Covers = 'Windows integration modes and ownership' },
    @{ Name = 'Detection';    File = 'Test-Detection.ps1';    Covers = 'the Intune detection contract' },
    @{ Name = 'PS51Compat';   File = 'Test-PS51Compat.ps1';   Covers = 'Windows PowerShell 5.1 compatibility' },
    @{ Name = 'Studio';       File = 'Test-Studio.ps1';       Covers = 'the configuration generator' },
    @{ Name = 'Gui';          File = 'Test-Gui.ps1';          Covers = 'the Studio data layer' },
    @{ Name = 'WpfSmoke';     File = 'Test-WpfSmoke.ps1';     Covers = 'XAML, control binding, live WPF'; Windows = $true },
    @{ Name = 'Elevated';     File = 'Test-Elevated.ps1';     Covers = 'registry, shell and service primitives'; Windows = $true }
)

# The same interpreter that is running this file.
$interpreter = (Get-Process -Id $PID).Path
if (-not $interpreter) { $interpreter = 'powershell.exe' }

$results = @()

foreach ($suite in $suites) {
    if ($PortableOnly -and $suite.Windows) { continue }

    $path = Join-Path $TestsDir $suite.File
    if (-not (Test-Path -LiteralPath $path)) {
        $results += [pscustomobject]@{
            Suite = $suite.Name; Pass = 0; Fail = 0; Skip = 0; Exit = -1; Covers = $suite.Covers
        }
        continue
    }

    Write-Host ''
    Write-Host "--- $($suite.Name) " -NoNewline -ForegroundColor Cyan
    Write-Host ('-' * [Math]::Max(1, 50 - $suite.Name.Length)) -ForegroundColor DarkCyan

    $output = & $interpreter -NoProfile -File $path 2>&1
    $exitCode = $LASTEXITCODE

    $totalLine = @($output | Where-Object { "$_" -match '^Total:' }) | Select-Object -Last 1
    $pass = 0; $fail = 0; $skip = 0
    if ($totalLine) {
        if ("$totalLine" -match 'Pass:\s*(\d+)') { $pass = [int]$Matches[1] }
        if ("$totalLine" -match 'Fail:\s*(\d+)') { $fail = [int]$Matches[1] }
        if ("$totalLine" -match 'Skip:\s*(\d+)') { $skip = [int]$Matches[1] }
    }

    # Only the failures are echoed; a green suite does not need 100 lines.
    if ($exitCode -ne 0 -or $fail -gt 0) {
        foreach ($line in $output) {
            if ("$line" -match '(FAIL|Failed:|^\s+-\s)') { Write-Host "  $line" -ForegroundColor Red }
        }
    }
    $status = if ($fail -gt 0 -or $exitCode -ne 0) { 'FAIL' } elseif ($skip -gt 0) { "ok ($skip skipped)" } else { 'ok' }
    Write-Host "  $status  $pass passed" -ForegroundColor $(if ($fail -gt 0 -or $exitCode -ne 0) { 'Red' } else { 'Green' })

    $results += [pscustomobject]@{
        Suite = $suite.Name; Pass = $pass; Fail = $fail; Skip = $skip; Exit = $exitCode; Covers = $suite.Covers
    }
}

Write-Host ''
Write-Host '========================================================================' -ForegroundColor Cyan
Write-Host ' Summary' -ForegroundColor Cyan
Write-Host '========================================================================' -ForegroundColor Cyan
Write-Host ('{0,-14} {1,6} {2,6} {3,6}   {4}' -f 'Suite', 'Pass', 'Fail', 'Skip', 'Covers')
Write-Host ('-' * 72) -ForegroundColor DarkGray

foreach ($r in $results) {
    $colour = if ($r.Fail -gt 0 -or $r.Exit -ne 0) { 'Red' } elseif ($r.Skip -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ('{0,-14} {1,6} {2,6} {3,6}   {4}' -f $r.Suite, $r.Pass, $r.Fail, $r.Skip, $r.Covers) -ForegroundColor $colour
}

$totalPass = ($results | Measure-Object -Property Pass -Sum).Sum
$totalFail = ($results | Measure-Object -Property Fail -Sum).Sum
$totalSkip = ($results | Measure-Object -Property Skip -Sum).Sum

Write-Host ('-' * 72) -ForegroundColor DarkGray
Write-Host ('{0,-14} {1,6} {2,6} {3,6}' -f 'TOTAL', $totalPass, $totalFail, $totalSkip) `
    -ForegroundColor $(if ($totalFail -eq 0) { 'Green' } else { 'Red' })

$skipped = @($results | Where-Object { $_.Skip -gt 0 })
if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Host 'Not verified in this environment:' -ForegroundColor Yellow
    foreach ($r in $skipped) {
        Write-Host "  $($r.Suite): $($r.Skip) check(s) skipped - $($r.Covers)" -ForegroundColor Yellow
    }
    Write-Host '  Re-run on an elevated Windows session to cover these.' -ForegroundColor DarkYellow
}

Write-Host ''
if ($totalFail -gt 0) { exit 1 }
exit 0
