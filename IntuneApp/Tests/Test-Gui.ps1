#Requires -Version 5.1
<#
    Test-Gui.ps1

    Tests the graphical Studio's data layer without WPF.

    The GUI's model<->form functions are nested inside Show-PackagingStudio, so
    they cannot be dot-sourced directly. Rather than copy them into the test -
    which would drift from the real code - this extracts their definitions from
    Studio.ps1 with the PowerShell parser and runs them against a mock set of
    controls. The functions under test are therefore the real ones; only WPF
    itself is absent.

    This exists because the Studio shipped with a defect that made the window
    fail to open at all: an empty PATH text box produced $null from Split-Lines
    (a 'return @()' unrolls), and .Count on it threw under Set-StrictMode. That
    was on the startup path, so nothing in the GUI worked, and no other suite
    executed a single line of it.

    Run:
        pwsh -File Tests/Test-Gui.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Gui.ps1
#>

param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest   # the Studio sets this; the tests must match

$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$StudioDir = Join-Path $AppRoot 'Studio'

foreach ($module in @('ConfigGenerator.ps1', 'ConfigModel.ps1', 'ConfigValidator.ps1',
                      'Analyzer.ps1', 'Preview.ps1', 'Prompt.ps1', 'Wizard.ps1', 'Runner.ps1')) {
    . (Join-Path $StudioDir $module)
}
$envHelper = Join-Path $AppRoot 'Helpers\Environment.ps1'
if (Test-Path $envHelper) { . $envHelper }

$script:pass = 0
$script:fail = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Test-Step {
    <#
        Runs a step and records a failure if it throws. Most of the defects
        this file guards against are exceptions on the startup path, so
        "did not throw" is the assertion that matters.
    #>
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:pass++
    }
    catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:fail++
        $script:failures.Add($Name)
    }
}

function Test-Group { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor White }

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Studio GUI Data Layer Tests' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# --- Extract the nested functions from Show-PackagingStudio ----------------
$studioSource = Get-Content (Join-Path $StudioDir 'Studio.ps1') -Raw
$tokens = $null
$parseErrors = $null
$studioAst = [System.Management.Automation.Language.Parser]::ParseInput($studioSource, [ref]$tokens, [ref]$parseErrors)

$showFn = $studioAst.Find({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-PackagingStudio'
}, $true)

if (-not $showFn) { throw 'Show-PackagingStudio was not found in Studio.ps1.' }

$nestedFunctions = $showFn.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ne 'Show-PackagingStudio'
}, $true)

foreach ($fn in $nestedFunctions) { . ([scriptblock]::Create($fn.Extent.Text)) }

$extracted = @($nestedFunctions | ForEach-Object { $_.Name })
Write-Host "  Extracted from Studio.ps1: $($extracted -join ', ')" -ForegroundColor DarkGray

# The functions the startup path depends on must all have been found.
foreach ($required in @('Split-Lines', 'Write-FormFromModel', 'Read-ModelFromForm',
                        'Update-Psd1Text', 'Update-Validation', 'Update-Preview')) {
    if ($extracted -notcontains $required) {
        throw "Studio.ps1 no longer defines $required. Update this test to match."
    }
}

# --- Mock controls ---------------------------------------------------------
function New-MockControl {
    param([string]$Text = '', [bool]$Checked = $false)
    $c = [pscustomobject]@{}
    $c | Add-Member -NotePropertyName Text -NotePropertyValue $Text
    $c | Add-Member -NotePropertyName IsChecked -NotePropertyValue $Checked
    $c | Add-Member -NotePropertyName SelectedIndex -NotePropertyValue 0
    $c | Add-Member -NotePropertyName Foreground -NotePropertyValue ''
    return $c
}

$controlNames = @(
    'TxtInstaller', 'TxtStatus', 'Tabs',
    'TxtAppName', 'TxtPublisher', 'TxtVersion', 'RbArch64', 'RbArch86', 'RbArchArm', 'TxtAnalysis',
    'RbTypeExe', 'RbTypeMsi', 'TxtInsFile', 'RbCtxSystem', 'RbCtxUser',
    'RbUiSilent', 'RbUiBasic', 'RbUiInteractive', 'TxtInsArgs',
    'RbRstSuppress', 'RbRstAllow', 'RbRstPrompt', 'TxtExitCodes',
    'RbUnExe', 'RbUnMsi', 'TxtUnFile', 'TxtUnArgs', 'TxtUnCode',
    'RbDetFile', 'RbDetReg', 'RbDetMsi', 'RbDetCustom',
    'TxtDetPath', 'TxtDetFile', 'TxtDetVersion', 'TxtDetRegPath', 'TxtDetRegValue', 'TxtDetCode',
    'ChkEnvEnabled', 'RbPathSystem', 'RbPathUser', 'RbPathBoth', 'TxtPathEntries',
    'TxtTestCommand', 'ChkPathRemove', 'TxtEnvVars', 'RbVarMachine', 'RbVarUser',
    'ChkWiEnabled', 'ChkStartMenu', 'TxtSmName', 'TxtSmTarget',
    'ChkDesktop', 'TxtDtName', 'TxtDtTarget',
    'ChkAssoc', 'TxtAssoc', 'ChkServices', 'TxtServices', 'ChkTasks', 'TxtTasks',
    'TxtPsd1', 'TxtConfigPath', 'TxtValidation', 'TxtPreview'
)

$ui = @{}
foreach ($n in $controlNames) { $ui[$n] = New-MockControl }

# Variables the nested functions close over in Show-PackagingStudio.
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gui_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

# The validator checks the installer exists under Files\, so give it one.
New-Item -Path (Join-Path $workDir 'Files') -ItemType Directory -Force | Out-Null
Set-Content -Path (Join-Path $workDir 'Files\Setup.exe') -Value 'stub' -Encoding UTF8

$state = [pscustomobject]@{
    Model       = (New-ConfigModel)
    Analysis    = $null
    ConfigPath  = (Join-Path $workDir 'Configuration.psd1')
    PackageRoot = $workDir
}

$archMap = @{ RbArch64 = 'x64'; RbArch86 = 'x86'; RbArchArm = 'ARM64' }
$typeMap = @{ RbTypeExe = 'EXE'; RbTypeMsi = 'MSI' }
$ctxMap  = @{ RbCtxSystem = 'System'; RbCtxUser = 'User' }
$uiMap   = @{ RbUiSilent = 'Silent'; RbUiBasic = 'BasicUI'; RbUiInteractive = 'Interactive' }
$rstMap  = @{ RbRstSuppress = 'Suppress'; RbRstAllow = 'Allow'; RbRstPrompt = 'Prompt' }
$unMap   = @{ RbUnExe = 'EXE'; RbUnMsi = 'MSI' }
$detMap  = @{ RbDetFile = 'File'; RbDetReg = 'Registry'; RbDetMsi = 'MSI'; RbDetCustom = 'Custom' }
$varMap  = @{ RbVarMachine = 'Machine'; RbVarUser = 'User' }

try {
    # === Startup ===========================================================
    # Every one of these runs before the window is shown. A throw here means
    # the Studio does not open at all.
    Test-Group 'Startup with an empty form'

    Test-Step 'Write-FormFromModel does not throw' { Write-FormFromModel }
    Test-Step 'Read-ModelFromForm does not throw'  { Read-ModelFromForm | Out-Null }
    Test-Step 'Update-Psd1Text does not throw'     { Update-Psd1Text }
    Test-Step 'Update-Validation does not throw'   { Update-Validation | Out-Null }
    Test-Step 'Update-Preview does not throw'      { Update-Preview }
    Test-Step 'Empty form still renders psd1'      {
        if (-not $ui.TxtPsd1.Text) { throw 'psd1 pane is empty' }
    }

    # === Single-line input =================================================
    # A one-line text box is the case that unrolls to a bare string. Each of
    # these boxes feeds a .Count or an enumeration.
    Test-Group 'Single-line input in every multi-line box'

    $ui.TxtAppName.Text = 'App'; $ui.TxtPublisher.Text = 'V'; $ui.TxtVersion.Text = '1.0'
    $ui.TxtInsFile.Text = 'Setup.exe'; $ui.TxtInsArgs.Text = '/S'; $ui.TxtExitCodes.Text = '0, 3010'
    $ui.TxtUnFile.Text = 'C:\App\uninstall.exe'; $ui.TxtUnArgs.Text = '/S'
    $ui.TxtDetPath.Text = 'C:\App'; $ui.TxtDetFile.Text = 'App.exe'
    $ui.ChkEnvEnabled.IsChecked = $true
    $ui.RbPathSystem.IsChecked = $true
    $ui.TxtPathEntries.Text = 'C:\App\bin'

    Test-Step 'One PATH entry is read as one entry' {
        $m = Read-ModelFromForm
        $count = @($m.Environment.SystemPath.Entries).Count
        if ($count -ne 1) { throw "expected 1 PATH entry, got $count" }
    }

    $ui.TxtEnvVars.Text = 'JAVA_HOME=C:\J'
    $ui.ChkWiEnabled.IsChecked = $true
    $ui.ChkAssoc.IsChecked = $true;    $ui.TxtAssoc.Text = '.rvt'
    $ui.ChkServices.IsChecked = $true; $ui.TxtServices.Text = 'SvcOne'
    $ui.ChkTasks.IsChecked = $true;    $ui.TxtTasks.Text = 'TaskOne'

    Test-Step 'One environment variable is read' {
        $m = Read-ModelFromForm
        if (@($m.Environment.Variables).Count -ne 1) { throw 'expected 1 variable' }
    }
    Test-Step 'One file association is read' {
        $m = Read-ModelFromForm
        if (@($m.WindowsIntegration.FileAssociations.Associations).Count -ne 1) { throw 'expected 1 association' }
    }
    Test-Step 'One service is read' {
        $m = Read-ModelFromForm
        if (@($m.WindowsIntegration.Services.Services).Count -ne 1) { throw 'expected 1 service' }
    }
    Test-Step 'One scheduled task is read' {
        $m = Read-ModelFromForm
        if (@($m.WindowsIntegration.ScheduledTasks.Tasks).Count -ne 1) { throw 'expected 1 task' }
    }

    # === Multi-line input ==================================================
    Test-Group 'Multi-line input'

    $ui.TxtPathEntries.Text = "C:\App\bin`nC:\App\tools"
    Test-Step 'Two PATH entries are read as two' {
        $m = Read-ModelFromForm
        $count = @($m.Environment.SystemPath.Entries).Count
        if ($count -ne 2) { throw "expected 2 PATH entries, got $count" }
    }
    Test-Step 'Blank lines are ignored' {
        $ui.TxtPathEntries.Text = "C:\App\bin`n`n   `nC:\App\tools"
        $m = Read-ModelFromForm
        $count = @($m.Environment.SystemPath.Entries).Count
        if ($count -ne 2) { throw "expected 2 PATH entries, got $count" }
        $ui.TxtPathEntries.Text = "C:\App\bin`nC:\App\tools"
    }

    # === PATH scope ========================================================
    Test-Group 'PATH scope selection'

    Test-Step 'Both scope populates System and User' {
        $ui.RbPathSystem.IsChecked = $false; $ui.RbPathUser.IsChecked = $false
        $ui.RbPathBoth.IsChecked = $true
        $m = Read-ModelFromForm
        if (-not $m.Environment.SystemPath.Enabled) { throw 'System PATH not enabled' }
        if (-not $m.Environment.UserPath.Enabled) { throw 'User PATH not enabled' }
        $ui.RbPathBoth.IsChecked = $false; $ui.RbPathSystem.IsChecked = $true
    }
    Test-Step 'Empty PATH box disables both scopes' {
        $saved = $ui.TxtPathEntries.Text
        $ui.TxtPathEntries.Text = ''
        $m = Read-ModelFromForm
        if ($m.Environment.SystemPath.Enabled) { throw 'System PATH enabled with no entries' }
        if ($m.Environment.UserPath.Enabled) { throw 'User PATH enabled with no entries' }
        $ui.TxtPathEntries.Text = $saved
    }

    # === Round trip ========================================================
    Test-Group 'Form to psd1 to model to form'

    Test-Step 'Generated psd1 parses and reloads into the form' {
        Update-Psd1Text
        $file = Join-Path $workDir 'roundtrip.psd1'
        [System.IO.File]::WriteAllText($file, $ui.TxtPsd1.Text, (New-Object System.Text.UTF8Encoding($false)))

        $syntax = Test-Psd1Syntax -Path $file
        if (-not $syntax.Valid) { throw ($syntax.Errors -join '; ') }

        $state.Model = Import-ConfigModel -Path $file
        Write-FormFromModel

        if ($ui.TxtAppName.Text -ne 'App') { throw "application name lost: '$($ui.TxtAppName.Text)'" }
        if ($ui.TxtInsFile.Text -ne 'Setup.exe') { throw 'installer file lost' }
        if ($ui.TxtPathEntries.Text -notmatch 'C:\\App\\bin') { throw 'PATH entries lost' }
    }

    # The inactive scope must hold a genuinely empty list, not $null. A block
    # whose only output is @() emits nothing, so the assignment used to store
    # $null; @($null) then reads as one blank entry and validation reported
    # "A PATH entry is empty" against a form that was perfectly valid.
    Test-Step 'The inactive PATH scope is an empty list, not null' {
        $m = Read-ModelFromForm
        $inactive = $m.Environment.UserPath.Entries
        if ($null -eq $inactive) { throw 'UserPath.Entries is $null; it must be an empty array' }
        if (@($inactive).Count -ne 0) {
            throw "UserPath.Entries should be empty but has $(@($inactive).Count) element(s)"
        }
    }

    Test-Step 'No blank entry is invented for the inactive scope' {
        $m = Read-ModelFromForm
        $all = @($m.Environment.SystemPath.Entries) + @($m.Environment.UserPath.Entries)
        $blank = @($all | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) })
        if ($blank.Count -gt 0) { throw "$($blank.Count) blank PATH entry/entries present" }
    }

    Test-Step 'Validation reports a complete form as valid' {
        $summary = Update-Validation
        if (-not $summary.IsValid) { throw $ui.TxtValidation.Text }
    }
}
finally {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
$total = $script:pass + $script:fail
Write-Host "Total: $total   Pass: $($script:pass)   Fail: $($script:fail)" `
    -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) {
    Write-Host ''
    Write-Host 'Failed:' -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
}
Write-Host '========================================' -ForegroundColor Cyan

if ($script:fail -gt 0) { exit 1 }
exit 0
