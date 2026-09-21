#Requires -Version 5.1
<#
    Test-LocalTest.ps1

    Covers Builder\LocalTest.ps1 - the SYSTEM-context local test from section
    21 and the test-state invalidation from section 23.

    What can and cannot be proved here
    ----------------------------------
    The SYSTEM path itself needs Windows Task Scheduler. On any other host
    those assertions report SKIP and are counted separately from passes: a
    suite that skipped everything has proved nothing, and calling that a pass
    is how an untested path ships.

    What is proved everywhere:

      - the fingerprint changes when anything that decides package behaviour
        changes, and does not change when nothing does
      - a passing result stops counting the moment the configuration is edited
      - the test refuses a package that is missing a script or its installer,
        rather than reporting a stage it never ran
      - the wrapper that Task Scheduler executes is built correctly, including
        the -Report argument and quoting - that text is buildable and
        inspectable off Windows even though running it is not

    Run:
        pwsh -File Tests/Test-LocalTest.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-LocalTest.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$AppRoot = Split-Path -Parent $TestsDir
$BuilderDir = Join-Path $AppRoot 'Builder'

. (Join-Path $BuilderDir 'Psd1.ps1')
. (Join-Path $BuilderDir 'PackageConfig.ps1')
. (Join-Path $BuilderDir 'Generator.ps1')
. (Join-Path $BuilderDir 'LocalTest.ps1')

$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Test-Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
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

function New-TestPackage {
    <#
        A generated package in a temporary directory, with a stand-in
        installer. Real generation, not a hand-written imitation - the thing
        under test is what the builder actually produces.
    #>
    param([string]$Name = 'Fingerprint Test App')

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ipbtest_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $dir -ItemType Directory -Force | Out-Null

    $installer = Join-Path $dir 'setup-source.exe'
    Set-Content -LiteralPath $installer -Value 'stand-in installer' -Encoding ASCII

    $config = New-PackageConfig
    $config.ApplicationName = $Name
    $config.Publisher = 'Test Publisher'
    $config.Version = '1.0.0'
    $config.InstallerType = 'EXE'
    $config.InstallerFile = 'setup.exe'
    $config.InstallArguments = '/S'
    $config.Detection = @{ Type = 'File'; Path = 'C:\Program Files\Test\app.exe'; Version = ''; VersionComparison = 'GreaterThanOrEqual' }

    $source = Join-Path $dir 'PackageSource'
    New-PackageSource -Config $config -InstallerPath $installer -OutputPath $source | Out-Null
    return $source
}

# ============================================================== fingerprint

Test-Group 'Fingerprint (section 23)'

$packageA = New-TestPackage
try {
    $first = Get-PackageFingerprint -PackagePath $packageA
    Test-Assert 'A fingerprint is produced' ($first -and $first.Length -eq 64) "Got '$first'"

    $again = Get-PackageFingerprint -PackagePath $packageA
    Test-Assert 'The same package fingerprints the same twice' ($first -eq $again)

    # An edit to the configuration must change it - that is the whole point.
    $configPath = Join-Path $packageA 'Configuration.psd1'
    $text = Get-Content -LiteralPath $configPath -Raw
    Set-Content -LiteralPath $configPath -Value ($text -replace "InstallArguments = '/S'", "InstallArguments = '/VERYSILENT'") -Encoding UTF8
    $afterConfigEdit = Get-PackageFingerprint -PackagePath $packageA
    Test-Assert 'Editing the configuration changes the fingerprint' ($afterConfigEdit -ne $first)

    # And so must an edit to a shipped script.
    $installPath = Join-Path $packageA 'Install.ps1'
    Add-Content -LiteralPath $installPath -Value '# an edit'
    $afterScriptEdit = Get-PackageFingerprint -PackagePath $packageA
    Test-Assert 'Editing a shipped script changes the fingerprint' ($afterScriptEdit -ne $afterConfigEdit)

    # Replacing the installer with one of a different size must change it.
    $installerPath = Join-Path $packageA 'setup.exe'
    Set-Content -LiteralPath $installerPath -Value 'a noticeably longer stand-in installer' -Encoding ASCII
    Test-Assert 'Replacing the installer changes the fingerprint' `
        ((Get-PackageFingerprint -PackagePath $packageA) -ne $afterScriptEdit)

    # ------------------------------------------------- test-state currency
    Test-Group 'Test-state currency (section 23)'

    $never = Test-PackageTestCurrent -PackagePath $packageA
    Test-Assert 'An untested package is not current' (-not $never.Current) $never.Reason
    Test-Assert 'And says it has never been tested' ($never.Reason -match 'never been tested')

    $recorded = Save-TestResult -PackagePath $packageA -Result @{
        Overall = 'PASS'
        Fingerprint = (Get-PackageFingerprint -PackagePath $packageA)
        Failure = ''
    }
    Test-Assert 'A result is recorded beside the package' (Test-Path -LiteralPath $recorded)

    $current = Test-PackageTestCurrent -PackagePath $packageA
    Test-Assert 'A fresh pass is current' $current.Current $current.Reason

    # The invalidation this section exists for.
    $text = Get-Content -LiteralPath $configPath -Raw
    Set-Content -LiteralPath $configPath -Value ($text -replace "Version = '1.0.0'", "Version = '1.0.1'") -Encoding UTF8
    $stale = Test-PackageTestCurrent -PackagePath $packageA
    Test-Assert 'A pass stops counting once the configuration is edited' (-not $stale.Current) $stale.Reason
    Test-Assert 'And says why' ($stale.Reason -match 'changed after the last successful test')

    Save-TestResult -PackagePath $packageA -Result @{
        Overall = 'FAILED'
        Fingerprint = (Get-PackageFingerprint -PackagePath $packageA)
        Failure = 'deliberate'
    } | Out-Null
    $failed = Test-PackageTestCurrent -PackagePath $packageA
    Test-Assert 'A failing result is never current' (-not $failed.Current) $failed.Reason
}
finally { Remove-Item -LiteralPath (Split-Path -Parent $packageA) -Recurse -Force -ErrorAction SilentlyContinue }

# ==================================================== refusals before running

Test-Group 'Refusals before anything runs'

$packageB = New-TestPackage
try {
    Remove-Item -LiteralPath (Join-Path $packageB 'Uninstall.ps1') -Force

    $threw = $false
    $message = ''
    try { Invoke-LocalPackageTest -PackagePath $packageB -Force | Out-Null }
    catch { $threw = $true; $message = $_.Exception.Message }

    Test-Assert 'A package missing a script is refused' $threw
    Test-Assert 'And the missing file is named' ($message -match 'Uninstall\.ps1') $message
}
finally { Remove-Item -LiteralPath (Split-Path -Parent $packageB) -Recurse -Force -ErrorAction SilentlyContinue }

$packageC = New-TestPackage
try {
    if (Test-IsWindowsHost -and (Test-AdministratorRights)) {
        Remove-Item -LiteralPath (Join-Path $packageC 'setup.exe') -Force
        $result = Invoke-LocalPackageTest -PackagePath $packageC -Force
        Test-Assert 'A package with no installer fails rather than reporting stages it never ran' `
            ($result.Overall -eq 'FAILED')
        Test-Assert 'And the installer stage is the one that failed' `
            (@($result.Stages | Where-Object { $_.Name -eq 'Installer' -and $_.Result -eq 'FAIL' }).Count -eq 1)
    }
    else {
        Test-Skip 'A package with no installer fails' 'Reaching the installer check needs an elevated Windows host; the SYSTEM guard returns SKIPPED first.'
    }
}
finally { Remove-Item -LiteralPath (Split-Path -Parent $packageC) -Recurse -Force -ErrorAction SilentlyContinue }

# ===================================================== the non-Windows guard

Test-Group 'Host guards'

$packageD = New-TestPackage
try {
    $result = Invoke-LocalPackageTest -PackagePath $packageD -Force

    if (-not (Test-IsWindowsHost)) {
        Test-Assert 'A non-Windows host is SKIPPED, not PASSED' ($result.Overall -eq 'SKIPPED') "Overall was $($result.Overall)"
        Test-Assert 'And the reason names Task Scheduler' `
            ($result.Stages[0].Detail -match 'Task Scheduler') $result.Stages[0].Detail
        Test-Assert 'A skipped run still fingerprints the package' ($result.Fingerprint.Length -eq 64)
    }
    elseif (-not (Test-AdministratorRights)) {
        Test-Assert 'An unelevated Windows host is SKIPPED, not PASSED' ($result.Overall -eq 'SKIPPED')
        Test-Assert 'And the reason says to re-run elevated' ($result.Stages[0].Detail -match 'elevated')
    }
    else {
        Test-Skip 'Host guard' 'Running elevated on Windows, so neither guard applies - the guarded path is the real test.'
    }

    # The report renders without throwing whatever the result is. A reporting
    # function that fails on a skipped result hides the reason for the skip.
    $rendered = $true
    try { Write-LocalTestReport -Result $result | Out-Null } catch { $rendered = $false }
    Test-Assert 'The result table renders a skipped result' $rendered
}
finally { Remove-Item -LiteralPath (Split-Path -Parent $packageD) -Recurse -Force -ErrorAction SilentlyContinue }

# ======================================================== the report parser

Test-Group 'Reading the package report'

$sample = @"

Application: Test App
Installed: True
Version: 1.0.0
Executable: PASS
PATH: PASS (Machine, C:\Program Files\Test)
Associations: not configured
Context Menu: FAIL - missing .txt\Open
Desktop Shortcut: PASS
Owned resources: 3
"@

$map = ConvertFrom-DetectionReport -Text $sample
Test-Assert 'The installed verdict is read' ($map['Installed'] -eq 'True')
Test-Assert 'A passing feature is read' ($map['Desktop Shortcut'] -eq 'PASS')
Test-Assert 'A failing feature keeps its reason' ($map['Context Menu'] -eq 'FAIL - missing .txt\Open')
Test-Assert 'A value containing a colon is not truncated' `
    ($map['PATH'] -eq 'PASS (Machine, C:\Program Files\Test)') $map['PATH']
Test-Assert 'An unconfigured feature is distinguishable from a failing one' `
    ($map['Associations'] -eq 'not configured')
Test-Assert 'Empty input yields an empty map, not an error' ((ConvertFrom-DetectionReport -Text '').Count -eq 0)

# ==================================== the wrapper Task Scheduler would run

Test-Group 'SYSTEM wrapper construction'

# Invoke-AsSystem returns before building anything off Windows, so the wrapper
# text is checked by building it the same way here. This proves the quoting and
# the argument, not that Task Scheduler accepts it - see the SKIPs below.
function Build-WrapperText {
    param([string]$ScriptPath, [string[]]$Arguments, [string]$OutputFile)
    $argumentText = ''
    foreach ($argument in @($Arguments)) {
        $argumentText += " '" + ([string]$argument).Replace("'", "''") + "'"
    }
    return "& '$($ScriptPath.Replace("'", "''"))'$argumentText *>&1 | Out-File -FilePath '$($OutputFile.Replace("'", "''"))' -Encoding utf8"
}

$wrapperLine = Build-WrapperText -ScriptPath "C:\Package Source\Detection.ps1" -Arguments @('-Report') -OutputFile 'C:\Temp\out.txt'
Test-Assert 'The script path is quoted, so a space in it survives' `
    ($wrapperLine -match "& 'C:\\Package Source\\Detection\.ps1'") $wrapperLine
Test-Assert 'The -Report argument is passed through' ($wrapperLine -match "'-Report'") $wrapperLine

$quoted = Build-WrapperText -ScriptPath "C:\It's Here\Install.ps1" -Arguments @() -OutputFile 'C:\Temp\out.txt'
Test-Assert 'A quote in the path is doubled rather than closing the literal' `
    ($quoted -match "C:\\It''s Here") $quoted

$parsed = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($quoted, [ref]$parsed, [ref]$parseErrors) | Out-Null
Test-Assert 'The generated wrapper line parses' (@($parseErrors).Count -eq 0) `
    (@($parseErrors | ForEach-Object { $_.Message }) -join '; ')

# The detection stage reads "Installed:", which only -Report prints. A wrapper
# that ran Detection.ps1 bare would leave every feature line absent and report
# the application as missing.
$localTestText = Get-Content -LiteralPath (Join-Path $BuilderDir 'LocalTest.ps1') -Raw
Test-Assert 'Detection is invoked in -Report mode' `
    (([regex]::Matches($localTestText, "Invoke-AsSystem -ScriptPath \`$detectionScript -Arguments @\('-Report'\)")).Count -eq 2) `
    'Both the post-install and post-uninstall detection runs must pass -Report.'

Test-Assert 'The installer stage is checked rather than asserted' `
    ($localTestText -notmatch "New-TestStage 'Installer' 'PASS' 'Present in the package'")

# =========================================== Windows-only, honestly skipped

Test-Group 'SYSTEM execution (Windows only)'

if (-not (Test-IsWindowsHost)) {
    Test-Skip 'A script runs as NT AUTHORITY\SYSTEM' 'Not a Windows host - there is no Task Scheduler.'
    Test-Skip 'The scheduled task is removed afterwards' 'Not a Windows host.'
    Test-Skip 'The exit code comes back from the wrapper, not the task host' 'Not a Windows host.'
}
elseif (-not (Test-AdministratorRights)) {
    Test-Skip 'A script runs as NT AUTHORITY\SYSTEM' 'Not elevated - registering a SYSTEM task needs administrator rights.'
    Test-Skip 'The scheduled task is removed afterwards' 'Not elevated.'
    Test-Skip 'The exit code comes back from the wrapper, not the task host' 'Not elevated.'
}
else {
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ipbsys_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $probeDir -ItemType Directory -Force | Out-Null
    try {
        # Reports who it is and exits with a code the task host would not
        # produce on its own, so a wrong exit code cannot pass by coincidence.
        $probe = Join-Path $probeDir 'probe.ps1'
        Set-Content -LiteralPath $probe -Encoding UTF8 -Value @'
param([switch]$Report)
Write-Output "Identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Output "Report: $Report"
exit 42
'@
        $before = @(Get-ScheduledTask -TaskPath '\IntunePackageBuilder\' -ErrorAction SilentlyContinue).Count

        $run = Invoke-AsSystem -ScriptPath $probe -Arguments @('-Report') -TimeoutSeconds 180

        Test-Assert 'A script runs as NT AUTHORITY\SYSTEM' `
            ($run.Ran -and $run.Output -match 'Identity: NT AUTHORITY\\SYSTEM') "$($run.Error) $($run.Output)"
        Test-Assert 'The argument reaches the script' ($run.Output -match 'Report: True') $run.Output
        Test-Assert 'The exit code comes back from the wrapper, not the task host' `
            ($run.ExitCode -eq 42) "Got $($run.ExitCode)"

        $after = @(Get-ScheduledTask -TaskPath '\IntunePackageBuilder\' -ErrorAction SilentlyContinue).Count
        Test-Assert 'The scheduled task is removed afterwards' ($after -eq $before) "Before $before, after $after"
    }
    finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ===================================================================== summary

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host "  Passed: $script:pass   Failed: $script:fail   Skipped: $script:skip" -ForegroundColor Cyan
if ($script:skip -gt 0) {
    Write-Host '  Skipped assertions proved nothing and are not counted as passes.' -ForegroundColor DarkYellow
}
Write-Host ('=' * 60) -ForegroundColor Cyan
if ($script:fail -gt 0) {
    Write-Host ''
    Write-Host 'Failures:' -ForegroundColor Red
    foreach ($item in $script:failures) { Write-Host "  - $item" -ForegroundColor Red }
    exit 1
}
exit 0
