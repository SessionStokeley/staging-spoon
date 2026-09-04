#Requires -Version 5.1
# Unit tests for Helpers/Environment.ps1
# Run: powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Environment.ps1

param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

. (Join-Path $ScriptDir 'Helpers\Environment.ps1')

$pass = 0
$fail = 0
$skip = 0

function Test-Assert {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:pass++
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        $script:fail++
    }
}

function Test-Skip {
    param([string]$Name, [string]$Reason)
    Write-Host "  SKIP  $Name ($Reason)" -ForegroundColor Yellow
    $script:skip++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Environment Helper Unit Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Normalize-PathEntry ---
Write-Host "Normalize-PathEntry" -ForegroundColor White

$r = Normalize-PathEntry 'C:\Program Files\App\'
Test-Assert 'Strips trailing backslash' ($r -eq 'C:\Program Files\App')

$r = Normalize-PathEntry 'C:\Program Files\App'
Test-Assert 'No trailing slash unchanged' ($r -eq 'C:\Program Files\App')

$r = Normalize-PathEntry 'C:\App\bin\\'
Test-Assert 'Strips multiple trailing slashes' ($r -eq 'C:\App\bin')

$r = Normalize-PathEntry ''
Test-Assert 'Empty returns null' ($null -eq $r)

$r = Normalize-PathEntry $null
Test-Assert 'Null returns null' ($null -eq $r)

$r = Normalize-PathEntry '%ProgramFiles%\App\'
Test-Assert 'Preserves env var, strips slash' ($r -eq '%ProgramFiles%\App')

Write-Host ""

# --- Test-PathEntriesEqual ---
Write-Host "Test-PathEntriesEqual" -ForegroundColor White

$r = Test-PathEntriesEqual 'C:\Program Files\App' 'C:\Program Files\App'
Test-Assert 'Identical paths are equal' $r

$r = Test-PathEntriesEqual 'C:\Program Files\App' 'c:\program files\app'
Test-Assert 'Case-insensitive comparison' $r

$r = Test-PathEntriesEqual 'C:\Program Files\App\' 'C:\Program Files\App'
Test-Assert 'Trailing slash normalized' $r

$r = Test-PathEntriesEqual 'C:\Program Files\App' 'C:\Program Files\Other'
Test-Assert 'Different paths not equal' (-not $r)

$r = Test-PathEntriesEqual '' 'C:\App'
Test-Assert 'Empty vs non-empty not equal' (-not $r)

$r = Test-PathEntriesEqual 'C:\App' $null
Test-Assert 'Non-empty vs null not equal' (-not $r)

# An expandable entry and its expanded form are the same directory, so the
# duplicate check must catch it rather than adding the folder twice.
$expanded = [Environment]::ExpandEnvironmentVariables('%TESTVAR_EQ%')
$env:TESTVAR_EQ = 'C:\ExpandCompare'
$r = Test-PathEntriesEqual '%TESTVAR_EQ%\bin' 'C:\ExpandCompare\bin'
Test-Assert 'Expandable entry equals its expanded form' $r
$r = Test-PathEntriesEqual '%TESTVAR_EQ%\bin' 'C:\Somewhere\else'
Test-Assert 'Expansion does not create false matches' (-not $r)
Remove-Item Env:\TESTVAR_EQ -ErrorAction SilentlyContinue

Write-Host ""

# --- Split-PathString / Join-PathEntries ---
Write-Host "Split-PathString / Join-PathEntries" -ForegroundColor White

$r = Split-PathString 'C:\Windows;C:\Windows\System32'
Test-Assert 'Splits two entries' ($r.Count -eq 2)

$r = Split-PathString 'C:\Windows;;C:\System32'
Test-Assert 'Ignores empty segments' ($r.Count -eq 2)

$r = Split-PathString ''
Test-Assert 'Empty string returns empty array' ($r.Count -eq 0)

$r = Split-PathString $null
Test-Assert 'Null returns empty array' ($r.Count -eq 0)

$r = Join-PathEntries @('C:\A', 'C:\B')
Test-Assert 'Joins with semicolons' ($r -eq 'C:\A;C:\B')

Write-Host ""

# --- State Tracking (in-memory simulation) ---
Write-Host "State Tracking" -ForegroundColor White

$testApp = "TestApp_$(Get-Random)"

try {
    # Inside the try: resolving a C:\ path throws on non-Windows, and this
    # whole section is Windows-only.
    $statePath = Get-EnvironmentStatePath $testApp
    Test-Assert 'State path contains app name' ($statePath -like "*$testApp*")

    $savedPath = Save-EnvironmentState -ApplicationName $testApp `
        -MachinePathEntries @('C:\Test\bin') `
        -UserPathEntries @() `
        -EnvironmentVariables @(@{ Name = 'TEST_VAR'; Value = 'test'; Scope = 'Machine' })
    Test-Assert 'Save state creates file' (Test-Path $savedPath)

    $state = Get-EnvironmentState -ApplicationName $testApp
    Test-Assert 'Load state returns object' ($null -ne $state)
    Test-Assert 'State has correct app name' ($state.ApplicationName -eq $testApp)
    Test-Assert 'State tracks machine entries' ($state.MachinePathEntriesAdded.Count -eq 1)
    Test-Assert 'State tracks env vars' ($state.EnvironmentVariablesAdded.Count -eq 1)

    Remove-EnvironmentState -ApplicationName $testApp
    Test-Assert 'Remove state deletes file' (-not (Test-Path $savedPath))
}
catch {
    Write-Host "  State tracking tests require write access to C:\ProgramData" -ForegroundColor Yellow
    Test-Skip 'State tracking' 'No write access to ProgramData'
}

Write-Host ""

# --- Find-CliDirectories ---
Write-Host "Find-CliDirectories" -ForegroundColor White

$testDir = Join-Path ([System.IO.Path]::GetTempPath()) "cli_test_$(Get-Random)"
try {
    New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $testDir 'bin') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $testDir 'tools') -ItemType Directory -Force | Out-Null

    # Create test executables
    '' | Out-File (Join-Path $testDir 'app.exe')
    '' | Out-File (Join-Path $testDir 'bin\app-cli.exe')
    '' | Out-File (Join-Path $testDir 'bin\helper.cmd')
    '' | Out-File (Join-Path $testDir 'tools\appctl.exe')
    '' | Out-File (Join-Path $testDir 'readme.txt')

    $candidates = Find-CliDirectories -InstallPath $testDir

    Test-Assert 'Finds CLI directories' ($candidates.Count -gt 0)

    $binDir = $candidates | Where-Object { $_.Directory -like '*bin*' }
    Test-Assert 'Detects bin directory' ($null -ne $binDir)
    if ($binDir) {
        Test-Assert 'bin has High confidence' ($binDir.Confidence -eq 'High')
    }

    $toolsDir = $candidates | Where-Object { $_.Directory -like '*tools*' }
    Test-Assert 'Detects tools directory' ($null -ne $toolsDir)

    # Non-existent path
    $empty = Find-CliDirectories -InstallPath 'C:\NonExistent_12345'
    Test-Assert 'Non-existent path returns empty' ($empty.Count -eq 0)
}
finally {
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# --- PATH Modification Tests (require elevation) ---
Write-Host "PATH Modification (requires elevation)" -ForegroundColor White

# Windows principal APIs throw on other platforms, so probe defensively.
$isAdmin = $false
$isSystem = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSystem = ($identity.Name -eq 'NT AUTHORITY\SYSTEM')
}
catch {
    # Not Windows: the elevated tests below are skipped.
}

if ($isAdmin -or $isSystem) {
    $testEntry = "C:\IntunePkgTest_$(Get-Random)"

    # Add
    $r = Add-PathEntry -Entry $testEntry -Scope 'Machine'
    Test-Assert 'Add Machine PATH succeeds' $r.Success
    Test-Assert 'Add action is Added' ($r.Action -eq 'Added')

    # Verify registered
    $exists = Test-PathEntry -Entry $testEntry -Scope 'Machine'
    Test-Assert 'PATH entry is registered' $exists

    # Duplicate detection
    $r2 = Add-PathEntry -Entry $testEntry -Scope 'Machine'
    Test-Assert 'Duplicate returns AlreadyExists' ($r2.Action -eq 'AlreadyExists')

    # Case-insensitive duplicate
    $r3 = Add-PathEntry -Entry $testEntry.ToLower() -Scope 'Machine'
    Test-Assert 'Case-insensitive duplicate detected' ($r3.Action -eq 'AlreadyExists')

    # Trailing slash duplicate
    $r4 = Add-PathEntry -Entry "$testEntry\" -Scope 'Machine'
    Test-Assert 'Trailing slash duplicate detected' ($r4.Action -eq 'AlreadyExists')

    # Preserve existing entries
    $currentPath = Get-PersistentPath -Scope 'Machine'
    $hasSystemRoot = $currentPath -like '*%SystemRoot%*' -or $currentPath -like '*C:\Windows*'
    Test-Assert 'Existing PATH preserved' $hasSystemRoot

    # Remove
    $r5 = Remove-PathEntry -Entry $testEntry -Scope 'Machine'
    Test-Assert 'Remove PATH succeeds' $r5.Success
    Test-Assert 'Remove action is Removed' ($r5.Action -eq 'Removed')

    # Verify gone
    $gone = Test-PathEntry -Entry $testEntry -Scope 'Machine'
    Test-Assert 'PATH entry removed' (-not $gone)

    # Remove non-existent
    $r6 = Remove-PathEntry -Entry 'C:\ThisDoesNotExist_99999' -Scope 'Machine'
    Test-Assert 'Remove non-existent returns NotFound' ($r6.Action -eq 'NotFound')

    # Idempotency: add twice, remove once
    $testEntry2 = "C:\IdempotencyTest_$(Get-Random)"
    Add-PathEntry -Entry $testEntry2 -Scope 'Machine' | Out-Null
    Add-PathEntry -Entry $testEntry2 -Scope 'Machine' | Out-Null
    $pathStr = Get-PersistentPath -Scope 'Machine'
    $count = (Split-PathString $pathStr | Where-Object { Test-PathEntriesEqual $_ $testEntry2 }).Count
    Test-Assert 'Idempotent add: only one entry' ($count -eq 1)
    Remove-PathEntry -Entry $testEntry2 -Scope 'Machine' | Out-Null

    # Regression: passing -AddIfMissing:$false used to skip the write silently
    # and still report Success, so registration "failed" with no reason logged.
    $testEntry3 = "C:\AddIfMissingFalse_$(Get-Random)"
    $r10 = Add-PathEntry -Entry $testEntry3 -Scope 'Machine' -AddIfMissing:$false
    Test-Assert 'AddIfMissing:$false still adds a missing entry' ($r10.Action -eq 'Added') "Action was $($r10.Action)"
    Test-Assert 'AddIfMissing:$false entry is really registered' (Test-PathEntry -Entry $testEntry3 -Scope 'Machine')
    Remove-PathEntry -Entry $testEntry3 -Scope 'Machine' | Out-Null

    # A failed write must report Success = $false, never a silent no-op.
    $r11 = Add-PathEntry -Entry '' -Scope 'Machine'
    Test-Assert 'Empty entry reports failure' (-not $r11.Success)

    # Environment variable test
    $testVarName = "INTUNE_TEST_VAR_$(Get-Random)"
    $r7 = Add-EnvironmentVariable -Name $testVarName -Value 'TestValue' -Scope 'Machine'
    Test-Assert 'Add env var succeeds' $r7.Success
    $r8 = Remove-EnvironmentVariable -Name $testVarName -Scope 'Machine'
    Test-Assert 'Remove env var succeeds' $r8.Success
    $r9 = Remove-EnvironmentVariable -Name $testVarName -Scope 'Machine'
    Test-Assert 'Remove missing env var returns NotFound' ($r9.Action -eq 'NotFound')
}
else {
    Test-Skip 'Add Machine PATH' 'Not elevated'
    Test-Skip 'Duplicate detection' 'Not elevated'
    Test-Skip 'Remove PATH' 'Not elevated'
    Test-Skip 'Idempotency' 'Not elevated'
    Test-Skip 'Environment variables' 'Not elevated'
}

Write-Host ""

# --- Expandable Variable Preservation ---
Write-Host "Expandable Variable Preservation" -ForegroundColor White

if ($isAdmin -or $isSystem) {
    $beforePath = Get-PersistentPath -Scope 'Machine'
    $hasExpandable = $beforePath -match '%\w+%'
    Test-Assert 'Machine PATH has expandable vars' $hasExpandable

    # The read must not expand: Get-ItemProperty and
    # [Environment]::GetEnvironmentVariable both do, and writing the expanded
    # text back would strip every %VAR% from the machine PATH.
    $expandedRead = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($hasExpandable) {
        Test-Assert 'Get-PersistentPath returns the raw, unexpanded value' `
            ($beforePath -ne $expandedRead) `
            'The raw read matched the expanded read, so expansion is leaking through.'
    }

    $testEntry = "C:\ExpandTest_$(Get-Random)"
    Add-PathEntry -Entry $testEntry -Scope 'Machine' | Out-Null
    $afterPath = Get-PersistentPath -Scope 'Machine'
    Test-Assert 'Expandable vars preserved after add' ($afterPath -match '%\w+%')

    # The exact %VAR% tokens must survive, not merely "some" variable.
    $beforeVars = @([regex]::Matches($beforePath, '%\w+%') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique)
    $afterVars  = @([regex]::Matches($afterPath,  '%\w+%') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique)
    Test-Assert 'Every expandable token survives the write' `
        ((($beforeVars -join ',') -eq ($afterVars -join ','))) `
        "before: $($beforeVars -join ',') / after: $($afterVars -join ',')"

    # The value must stay REG_EXPAND_SZ, or %VAR% entries stop resolving.
    Test-Assert 'PATH remains REG_EXPAND_SZ' `
        ((Get-PersistentPathKind -Scope 'Machine') -eq [Microsoft.Win32.RegistryValueKind]::ExpandString)

    Remove-PathEntry -Entry $testEntry -Scope 'Machine' | Out-Null
    $finalPath = Get-PersistentPath -Scope 'Machine'
    Test-Assert 'Expandable vars preserved after remove' ($finalPath -match '%\w+%')
    Test-Assert 'PATH restored exactly after add and remove' ($finalPath -eq $beforePath) `
        'Add followed by remove did not return the PATH to its original text.'
}
else {
    Test-Skip 'Expandable variable preservation' 'Not elevated'
}

Write-Host ""

# --- Config Backward Compatibility ---
Write-Host "Backward Compatibility" -ForegroundColor White

$minimalConfig = @{
    ApplicationName = 'TestApp'
    Installer       = @{ Type = 'EXE'; File = 'setup.exe'; Arguments = '/quiet' }
    Uninstaller     = @{ Type = 'EXE'; File = 'uninstall.exe'; Arguments = '/quiet' }
    Detection       = @{ Type = 'File'; Path = 'C:\Test'; FileName = 'test.exe' }
    Logging         = @{ Enabled = $false }
}

$hasEnv = $null -ne $minimalConfig.Environment
Test-Assert 'Config without Environment works' (-not $hasEnv)

$envEnabled = $minimalConfig.Environment -and $minimalConfig.Environment.Enabled
Test-Assert 'Missing Environment defaults to disabled' (-not $envEnabled)

Write-Host ""

# --- Summary ---
Write-Host "========================================" -ForegroundColor Cyan
$total = $pass + $fail + $skip
Write-Host "Total: $total  Pass: $pass  Fail: $fail  Skip: $skip" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "========================================" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 }
exit 0
