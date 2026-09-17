#Requires -Version 5.1
<#
    Test-WpfSmoke.ps1

    Smoke test for the graphical Studio.

    Two parts, deliberately separated so it is never ambiguous which ran.

    Part A - structure (runs anywhere, real)
        Parses the XAML, then cross-checks it against the code three ways:
        every x:Name in the markup is bound, every name the code binds exists
        in the markup, and every control the code actually touches ($ui.X, and
        every Add_Click target) is one of the bound names. These are the
        failures that would otherwise surface as a null reference the first
        time a technician clicked something.

    Part B - live WPF (Windows only)
        Builds the real window from the real XAML, resolves every control
        through FindName, attaches and fires an event handler, loads and saves
        a configuration through the Studio's own functions, and closes the
        window. Reports [SKIP] where WPF is unavailable; it is never counted
        as a pass when it did not run.

    What is still not covered: a human driving the window. ShowDialog blocks,
    and the file dialogs are modal, so those are constructed but never shown.
    That remains a manual check - see the manual checklist at the end.

    Test-Gui.ps1 covers the model-to-form functions themselves, without WPF.

    Run:
        pwsh -File Tests/Test-WpfSmoke.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-WpfSmoke.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$StudioDir = Join-Path $AppRoot 'Studio'

foreach ($module in @('ConfigGenerator.ps1', 'ConfigModel.ps1', 'ConfigValidator.ps1',
                      'Analyzer.ps1', 'Preview.ps1', 'Prompt.ps1', 'Wizard.ps1', 'Runner.ps1')) {
    . (Join-Path $StudioDir $module)
}

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
Write-Host 'Studio GUI Smoke Test' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

$studioPath = Join-Path $StudioDir 'Studio.ps1'
$studioSource = Get-Content -LiteralPath $studioPath -Raw

# Dot-sourcing defines the functions and $script:StudioXaml. It does not open
# anything: Show-PackagingStudio only runs when it is called.
. $studioPath

# ================================================================== Part A

Test-Group 'A. XAML and control binding (no WPF required)'

Test-Assert 'Studio.ps1 exposes its XAML' `
    ($null -ne $script:StudioXaml -and [string]$script:StudioXaml -ne '')

$xamlDocument = $null
try {
    $xamlDocument = [xml]$script:StudioXaml
    Test-Assert 'The XAML is well-formed XML' $true
}
catch {
    Test-Assert 'The XAML is well-formed XML' $false $_.Exception.Message
}

# Names declared in the markup.
$xamlNames = @()
if ($xamlDocument) {
    $namespace = New-Object System.Xml.XmlNamespaceManager($xamlDocument.NameTable)
    $namespace.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $xamlNames = @($xamlDocument.SelectNodes('//*[@x:Name]', $namespace) |
        ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
}
Write-Host "        $($xamlNames.Count) named controls in the markup" -ForegroundColor DarkGray

# Names the code binds, read out of Studio.ps1's own binding loop rather than
# copied here, so this cannot drift from the source.
$tokens = $null
$parseErrors = $null
$studioAst = [System.Management.Automation.Language.Parser]::ParseInput($studioSource, [ref]$tokens, [ref]$parseErrors)
Test-Assert 'Studio.ps1 parses cleanly' (-not $parseErrors -or @($parseErrors).Count -eq 0)

$bindLoop = $studioAst.Find({
    param($n)
    $n -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $n.Extent.Text -match 'FindName'
}, $true)

$boundNames = @()
if ($bindLoop) {
    $literals = $bindLoop.Condition.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true)
    $boundNames = @($literals | ForEach-Object { $_.Value })
}
Test-Assert 'The control binding loop was found in Studio.ps1' ($boundNames.Count -gt 0)
Write-Host "        $($boundNames.Count) controls bound by the code" -ForegroundColor DarkGray

$unbound = @($xamlNames | Where-Object { $boundNames -notcontains $_ })
Test-Assert 'Every named control in the XAML is bound by the code' `
    ($unbound.Count -eq 0) ("not bound: " + ($unbound -join ', '))

$missing = @($boundNames | Where-Object { $xamlNames -notcontains $_ })
Test-Assert 'Every control the code binds exists in the XAML' `
    ($missing.Count -eq 0) ("not in the XAML: " + ($missing -join ', '))

# Every $ui.<Name> the code touches must be one of the bound names. This is
# the check that catches a typo in a click handler, which would otherwise only
# show up when a technician pressed that button.
$uiReferences = @()
foreach ($match in [regex]::Matches($studioSource, '\$ui\.([A-Za-z0-9_]+)')) {
    $uiReferences += $match.Groups[1].Value
}
$uiReferences = @($uiReferences | Sort-Object -Unique)
$unknownReferences = @($uiReferences | Where-Object { $boundNames -notcontains $_ })
Test-Assert 'Every $ui control the code touches is bound' `
    ($unknownReferences.Count -eq 0) ("unknown: " + ($unknownReferences -join ', '))

# Buttons that have a click handler must be real, bound controls.
$clickTargets = @()
foreach ($match in [regex]::Matches($studioSource, '\$ui\.([A-Za-z0-9_]+)\.Add_Click')) {
    $clickTargets += $match.Groups[1].Value
}
$clickTargets = @($clickTargets | Sort-Object -Unique)
Test-Assert 'Click handlers are attached to buttons' ($clickTargets.Count -gt 0)
Test-Assert 'Every click handler targets a bound control' `
    (@($clickTargets | Where-Object { $boundNames -notcontains $_ }).Count -eq 0) `
    ($clickTargets -join ', ')

# Every button in the markup should do something, or it is dead UI.
$buttonNames = @()
if ($xamlDocument) {
    $buttonNames = @($xamlNames | Where-Object { $_ -like 'Btn*' })
}
$deadButtons = @($buttonNames | Where-Object { $clickTargets -notcontains $_ })
Test-Assert 'No button is left without a handler' `
    ($deadButtons.Count -eq 0) ("no handler: " + ($deadButtons -join ', '))

# Part B only runs on Windows, so nothing here would catch a call to a
# function that does not exist until someone ran it on Windows. This checks
# that from anywhere. It found one: an earlier draft called Save-ConfigModel,
# which is not a function this project has.
$partBFunctions = @('Test-WpfAvailable', 'New-ConfigModel', 'Import-ConfigModel',
                    'Export-ConfigurationFile', 'Get-ConfigurationComments')
$undefined = @($partBFunctions | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
Test-Assert 'Every function the Windows-only part calls is defined' `
    ($undefined.Count -eq 0) ("undefined: " + ($undefined -join ', '))

# ================================================================== Part B

Test-Group 'B. Live WPF window'

$wpfAvailable = $false
try { $wpfAvailable = Test-WpfAvailable }
catch { $wpfAvailable = $false }

if (-not $wpfAvailable) {
    $reason = 'WPF is unavailable on this host (PresentationFramework needs Windows). Part A above ran in full and covers the markup and every control binding.'
    Test-Skip 'Build the real window from the real XAML' $reason
    Test-Skip 'Resolve every control through FindName' $reason
    Test-Skip 'Attach and fire an event handler' $reason
    Test-Skip 'Load and save a configuration through the window' $reason
    Test-Skip 'Close the window cleanly' $reason
}
else {
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wpf_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $workDir -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $workDir 'Files') -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $workDir 'Files\Setup.exe') -Value 'stub' -Encoding UTF8

    $window = $null
    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName System.Windows.Forms

        $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:StudioXaml)
        $window = [Windows.Markup.XamlReader]::Load($reader)
        Test-Assert 'Build the real window from the real XAML' ($null -ne $window)
        Test-Assert 'The window has the expected title' `
            ([string]$window.Title -eq 'Intune Application Packaging Studio') ([string]$window.Title)

        $resolved = @{}
        $nullControls = @()
        foreach ($name in $boundNames) {
            $control = $window.FindName($name)
            $resolved[$name] = $control
            if ($null -eq $control) { $nullControls += $name }
        }
        Test-Assert "Resolve every control through FindName ($($boundNames.Count) controls)" `
            ($nullControls.Count -eq 0) ("null: " + ($nullControls -join ', '))

        # A handler that is attached but never fires is not wired.
        $script:clickFired = $false
        $resolved['BtnValidate'].Add_Click({ $script:clickFired = $true })
        $resolved['BtnValidate'].RaiseEvent(
            (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Assert 'Attach and fire an event handler' $script:clickFired

        # Text set on a real TextBox must read back, which is what every
        # model-to-form function depends on.
        $resolved['TxtAppName'].Text = 'Smoke Test App'
        Test-Assert 'A real TextBox round-trips its text' `
            ($resolved['TxtAppName'].Text -eq 'Smoke Test App')

        $resolved['ChkEnvEnabled'].IsChecked = $true
        Test-Assert 'A real CheckBox round-trips its state' ([bool]$resolved['ChkEnvEnabled'].IsChecked)

        # Configuration load and save, through the real serializer.
        $configPath = Join-Path $workDir 'Configuration.psd1'
        $model = New-ConfigModel -ApplicationName 'Smoke Test App'
        $model.Installer.File = 'Setup.exe'
        $model.Detection.Path = $workDir
        $model.Detection.FileName = 'Files\Setup.exe'
        # The same call the Save button makes.
        Export-ConfigurationFile -Model $model -Path $configPath -Comments (Get-ConfigurationComments) | Out-Null
        Test-Assert 'Load and save a configuration through the window' (Test-Path -LiteralPath $configPath)

        $reloaded = Import-ConfigModel -Path $configPath
        Test-Assert 'The saved configuration reloads' ($reloaded.ApplicationName -eq 'Smoke Test App')

        # The file dialogs are modal, so they are constructed but never shown.
        $openDialog = New-Object Microsoft.Win32.OpenFileDialog
        $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
        Test-Assert 'The file dialogs can be constructed' `
            ($null -ne $openDialog -and $null -ne $saveDialog)

        $window.Close()
        Test-Assert 'Close the window cleanly' $true
        $window = $null
    }
    catch {
        Test-Assert 'Live WPF smoke test' $false $_.Exception.Message
    }
    finally {
        if ($window) { try { $window.Close() } catch { } }
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Group 'Manual checks this test cannot make'
Write-Host '  These need a person at a Windows desktop:' -ForegroundColor DarkGray
Write-Host '    - New-IntuneApp.ps1 -Mode Gui opens and the window is laid out correctly' -ForegroundColor DarkGray
Write-Host '    - Browse, Open and Save show their file dialogs and return a path' -ForegroundColor DarkGray
Write-Host '    - Analyze fills the analysis pane for a real installer' -ForegroundColor DarkGray
Write-Host '    - Run shows the approval prompt and refuses to proceed without it' -ForegroundColor DarkGray

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
