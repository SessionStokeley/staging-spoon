#Requires -Version 5.1
<#
    Test-Studio.ps1

    Tests for the interactive configuration generator.

    Run:
        pwsh -File Tests/Test-Studio.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Studio.ps1

    These tests never install anything. The generator is expected to be inert,
    and several tests exist specifically to prove that.
#>

param()

$ErrorActionPreference = 'Stop'
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

function Test-Group { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor White }

function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("studio_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $d -ItemType Directory -Force | Out-Null
    return $d
}

function New-FakeInstaller {
    <#
        Writes a minimal PE header plus a technology marker so the analyzer has
        something realistic to read. It is never executed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Marker = 'Nullsoft Install System v3.08',
        [int]$Machine = 0x8664
    )

    $bytes = New-Object byte[] 4096
    $bytes[0] = 0x4D; $bytes[1] = 0x5A                                  # MZ
    [BitConverter]::GetBytes([int]0x100).CopyTo($bytes, 0x3C)           # e_lfanew
    [BitConverter]::GetBytes([int]0x00004550).CopyTo($bytes, 0x100)     # PE\0\0
    [BitConverter]::GetBytes([uint16]$Machine).CopyTo($bytes, 0x104)    # machine
    [System.Text.Encoding]::ASCII.GetBytes($Marker).CopyTo($bytes, 0x400)

    [System.IO.File]::WriteAllBytes($Path, $bytes)
    return $Path
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Interactive Configuration Generator Tests' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# =========================================================== Serializer
Test-Group 'psd1 serializer'

Test-Assert 'String is single-quoted' ((ConvertTo-Psd1Literal 'abc') -eq "'abc'")
Test-Assert 'Single quote is doubled' ((ConvertTo-Psd1Literal "it's") -eq "'it''s'")
Test-Assert 'Double quote needs no escape' ((ConvertTo-Psd1Literal 'say "hi"') -eq "'say ""hi""'".Replace('""', '"'))
Test-Assert 'True renders as $true' ((ConvertTo-Psd1Literal $true) -eq '$true')
Test-Assert 'False renders as $false' ((ConvertTo-Psd1Literal $false) -eq '$false')
Test-Assert 'Null renders as $null' ((ConvertTo-Psd1Literal $null) -eq '$null')
Test-Assert 'Integer renders bare' ((ConvertTo-Psd1Literal 42) -eq '42')
Test-Assert 'Empty array renders as @()' ((ConvertTo-Psd1String -InputObject @()) -eq '@()')
Test-Assert 'Empty hashtable renders as @{}' ((ConvertTo-Psd1String -InputObject @{}) -eq '@{}')

# A $null member must survive; this previously rendered as $true.
$nullModel = [ordered]@{ A = $null; B = 'x' }
$nullText = ConvertTo-Psd1String -InputObject $nullModel
Test-Assert 'Null member serializes as $null' ($nullText -match 'A\s*=\s*\$null') $nullText

# ============================================================ Round-trip
Test-Group 'Round-trip through Import-PowerShellDataFile'

$tmp = New-TempDir
try {
    $model = [ordered]@{
        ApplicationName = "Vendor's ""Special"" App"
        Count           = 7
        Flag            = $false
        Nothing         = $null
        Codes           = @(0, 3010)
        Nested          = [ordered]@{ Deep = [ordered]@{ Value = 'here' } }
        Items           = @([ordered]@{ Name = 'a' }, [ordered]@{ Name = 'b' })
    }
    $file = Join-Path $tmp 'rt.psd1'
    Export-ConfigurationFile -Model $model -Path $file | Out-Null
    $back = Import-PowerShellDataFile -Path $file

    Test-Assert 'Quotes survive round-trip' ($back.ApplicationName -eq $model.ApplicationName) $back.ApplicationName
    Test-Assert 'Integer type preserved' ($back.Count -is [int] -and $back.Count -eq 7)
    Test-Assert 'Boolean false preserved' ($back.Flag -eq $false)
    Test-Assert 'Null preserved' ($null -eq $back.Nothing)
    Test-Assert 'Array preserved' (@($back.Codes).Count -eq 2)
    Test-Assert 'Nesting preserved' ($back.Nested.Deep.Value -eq 'here')
    Test-Assert 'Array of hashtables preserved' (@($back.Items).Count -eq 2 -and $back.Items[1].Name -eq 'b')

    $syntax = Test-Psd1Syntax -Path $file
    Test-Assert 'Generated file parses cleanly' $syntax.Valid ($syntax.Errors -join '; ')
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ============================================================== Stability
Test-Group 'Serialization stability'

$tmp = New-TempDir
try {
    $m = New-ConfigModel -ApplicationName 'Stable'
    $m.Environment.Variables = @(
        (New-EnvironmentVariableEntry -Name 'JAVA_HOME' -Value 'C:\J' -Scope 'Machine')
    )
    $m.WindowsIntegration.FileAssociations.Associations = @(
        (New-FileAssociationEntry -Extension '.zzz' -Description 'Test')
    )

    $f1 = Join-Path $tmp 'a.psd1'; $f2 = Join-Path $tmp 'b.psd1'; $f3 = Join-Path $tmp 'c.psd1'
    Export-ConfigurationFile -Model $m -Path $f1 -NoHeader | Out-Null
    Export-ConfigurationFile -Model (Import-ConfigModel -Path $f1) -Path $f2 -NoHeader | Out-Null
    Export-ConfigurationFile -Model (Import-ConfigModel -Path $f2) -Path $f3 -NoHeader | Out-Null

    $t1 = Get-Content $f1 -Raw; $t2 = Get-Content $f2 -Raw; $t3 = Get-Content $f3 -Raw
    Test-Assert 'Save cycle 1->2 is byte-stable' ($t1 -eq $t2)
    Test-Assert 'Save cycle 2->3 is byte-stable' ($t2 -eq $t3)

    $reloaded = Import-ConfigModel -Path $f3
    Test-Assert 'Variable key order is canonical' `
        ((@($reloaded.Environment.Variables[0].Keys) -join ',') -eq 'Name,Value,Scope,Expandable,RemoveOnUninstall')
    Test-Assert 'Association key order is canonical' `
        ((@($reloaded.WindowsIntegration.FileAssociations.Associations[0].Keys) -join ',') -eq 'Extension,ProgId,Description,OpenCommand,IconPath')
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ================================================================== Model
Test-Group 'Configuration model'

$default = New-ConfigModel
Test-Assert 'Environment disabled by default' ($default.Environment.Enabled -eq $false)
Test-Assert 'WindowsIntegration disabled by default' ($default.WindowsIntegration.Enabled -eq $false)
Test-Assert 'System PATH disabled by default' ($default.Environment.SystemPath.Enabled -eq $false)
Test-Assert 'Default success codes are 0 and 3010' ((@($default.SuccessExitCodes) -join ',') -eq '0,3010')
Test-Assert 'Default install behavior is System' ($default.Intune.InstallBehavior -eq 'System')

$tmp = New-TempDir
try {
    # A minimal legacy configuration, as written before the Studio existed.
    $legacy = Join-Path $tmp 'legacy.psd1'
    @'
@{
    ApplicationName = 'Legacy'
    Installer   = @{ Type = 'MSI'; File = 'a.msi'; Arguments = '/qn' }
    Uninstaller = @{ Type = 'MSI'; ProductCode = '{11111111-2222-3333-4444-555555555555}' }
    Detection   = @{ Type = 'File'; Path = 'C:\L'; FileName = 'l.exe' }
    Logging     = @{ Enabled = $true; Path = 'C:\Logs' }
    HandWritten = @{ Note = 'keep me'; Values = @(1,2,3) }
}
'@ | Set-Content -Path $legacy -Encoding UTF8

    $loaded = Import-ConfigModel -Path $legacy
    Test-Assert 'Legacy config opens' ($loaded.ApplicationName -eq 'Legacy')
    Test-Assert 'Legacy values win over defaults' ($loaded.Installer.Type -eq 'MSI' -and $loaded.Installer.File -eq 'a.msi')
    Test-Assert 'Missing sections get defaults' ($loaded.Environment.Enabled -eq $false)
    Test-Assert 'Missing Intune section is added' ($loaded.Intune.InstallBehavior -eq 'System')
    Test-Assert 'Hand-written keys are preserved' ($loaded.HandWritten.Note -eq 'keep me')
    Test-Assert 'Hand-written arrays are preserved' (@($loaded.HandWritten.Values).Count -eq 3)
    Test-Assert 'Custom logging path preserved' ($loaded.Logging.Path -eq 'C:\Logs')

    # The repository's own configuration must keep opening.
    $repoConfig = Join-Path $AppRoot 'Configuration.psd1'
    if (Test-Path $repoConfig) {
        $repoModel = Import-ConfigModel -Path $repoConfig
        Test-Assert 'Repository Configuration.psd1 opens' ($null -ne $repoModel.ApplicationName)
    }
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# =============================================================== Analyzer
Test-Group 'Installer analysis'

$tmp = New-TempDir
try {
    $nsis = New-FakeInstaller -Path (Join-Path $tmp 'nsis.exe') -Marker 'Nullsoft Install System v3.08'
    $inno = New-FakeInstaller -Path (Join-Path $tmp 'inno.exe') -Marker 'Inno Setup Setup Data (6.2.0)'
    $wix  = New-FakeInstaller -Path (Join-Path $tmp 'wix.exe')  -Marker 'WixBundleOriginalSource'
    $unk  = New-FakeInstaller -Path (Join-Path $tmp 'unk.exe')  -Marker 'nothing recognisable here'
    $x86  = New-FakeInstaller -Path (Join-Path $tmp 'x86.exe')  -Marker 'Inno Setup' -Machine 0x014c

    $a = Get-InstallerAnalysis -Path $nsis
    Test-Assert 'NSIS detected' ($a.Technology -eq 'NSIS')
    Test-Assert 'NSIS silent switch is /S' ($a.SilentArguments -eq '/S')
    Test-Assert 'NSIS confidence is High' ($a.TechnologyConfidence -eq 'High')
    Test-Assert 'Architecture x64 detected' ($a.Architecture -eq 'x64')
    Test-Assert 'SHA256 computed' ($a.Sha256 -and $a.Sha256.Length -eq 64)
    Test-Assert 'Installer type is EXE' ($a.InstallerType -eq 'EXE')

    Test-Assert 'Inno Setup detected' ((Get-InstallerAnalysis -Path $inno).Technology -eq 'Inno Setup')
    Test-Assert 'WiX Burn detected' ((Get-InstallerAnalysis -Path $wix).Technology -eq 'WiX Burn')
    Test-Assert 'Architecture x86 detected' ((Get-InstallerAnalysis -Path $x86).Architecture -eq 'x86')

    $u = Get-InstallerAnalysis -Path $unk
    Test-Assert 'Unknown technology reported as Unknown' ($u.Technology -eq 'Unknown')
    Test-Assert 'Unknown technology has Low confidence' ($u.TechnologyConfidence -eq 'Low')
    Test-Assert 'Unknown technology warns the technician' (@($u.Notes).Count -gt 0)

    Test-Assert 'Recommendations include Install' ($a.Recommendations.Contains('Install'))
    Test-Assert 'Recommendations include Detection' ($a.Recommendations.Contains('Detection'))
    Test-Assert 'Recommendations include Uninstall' ($a.Recommendations.Contains('Uninstall'))
    Test-Assert 'Detection recommendation is honest about confidence' `
        ($a.Recommendations.Detection.Confidence -eq 'Low')

    # Error handling
    $threw = $false
    try { Get-InstallerAnalysis -Path (Join-Path $tmp 'missing.exe') } catch { $threw = $true }
    Test-Assert 'Missing installer throws' $threw

    $threw = $false
    'x' | Set-Content (Join-Path $tmp 'thing.zip')
    try { Get-InstallerAnalysis -Path (Join-Path $tmp 'thing.zip') } catch { $threw = $true }
    Test-Assert 'Unsupported extension throws' $threw
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ============================================================== Validator
Test-Group 'Validation'

function New-ValidModel {
    $m = New-ConfigModel -ApplicationName 'App' -Publisher 'V' -Version '1.0'
    $m.Installer.File = 'Setup.exe'
    $m.Installer.Arguments = '/S'
    $m.Uninstaller.File = 'C:\App\uninstall.exe'
    $m.Uninstaller.Arguments = '/S'
    $m.Detection.Path = 'C:\App'
    $m.Detection.FileName = 'App.exe'
    return $m
}

$valid = @(Test-ConfigModel -Model (New-ValidModel) -SkipFileChecks)
$s = Get-ValidationSummary -Findings $valid
Test-Assert 'Complete configuration is valid' $s.IsValid ($valid | ForEach-Object { $_.Message } | Out-String)
Test-Assert 'Complete configuration has no errors' ($s.ErrorCount -eq 0)

$empty = @(Test-ConfigModel -Model (New-ConfigModel) -SkipFileChecks)
Test-Assert 'Incomplete configuration is invalid' (-not (Get-ValidationSummary -Findings $empty).IsValid)

$m = New-ValidModel; $m.ApplicationName = ''
Test-Assert 'Missing ApplicationName is an error' `
    (@(Test-ConfigModel -Model $m -SkipFileChecks | Where-Object { $_.Severity -eq 'Error' -and $_.Category -eq 'Application' }).Count -gt 0)

$m = New-ValidModel; $m.Uninstaller.Type = 'MSI'; $m.Uninstaller.ProductCode = $null
Test-Assert 'MSI uninstall without ProductCode is an error' `
    (@(Test-ConfigModel -Model $m -SkipFileChecks | Where-Object { $_.Severity -eq 'Error' -and $_.Category -eq 'Uninstall' }).Count -gt 0)

$m = New-ValidModel; $m.Uninstaller.Type = 'MSI'; $m.Uninstaller.ProductCode = 'nonsense'
$f = @(Test-ConfigModel -Model $m -SkipFileChecks)
Test-Assert 'Malformed ProductCode is a warning, not an error' `
    ((Get-ValidationSummary -Findings $f).IsValid -and
     @($f | Where-Object { $_.Severity -eq 'Warning' -and $_.Category -eq 'Uninstall' }).Count -gt 0)

$m = New-ValidModel; $m.Installer.UserInterface = 'Interactive'
Test-Assert 'Interactive install under SYSTEM is an error' `
    (@(Test-ConfigModel -Model $m -SkipFileChecks | Where-Object { $_.Severity -eq 'Error' -and $_.Message -match 'Interactive' }).Count -gt 0)

$m = New-ValidModel
$m.Environment.Enabled = $true
$m.Environment.UserPath.Enabled = $true
$m.Environment.UserPath.Entries = @('C:\App\bin')
$f = @(Test-ConfigModel -Model $m -SkipFileChecks)
Test-Assert 'User PATH under SYSTEM is a warning, not an error' `
    ((Get-ValidationSummary -Findings $f).IsValid -and
     @($f | Where-Object { $_.Severity -eq 'Warning' -and $_.Category -eq 'Environment' }).Count -gt 0)

$m = New-ValidModel
$m.Environment.Enabled = $true
$m.Environment.SystemPath.Enabled = $true
$m.Environment.SystemPath.Entries = @('C:\A;C:\B')
Test-Assert 'PATH entry with a semicolon is an error' `
    (@(Test-ConfigModel -Model $m -SkipFileChecks | Where-Object { $_.Severity -eq 'Error' -and $_.Message -match 'semicolon' }).Count -gt 0)

$m = New-ValidModel
$m.Environment.Enabled = $true
$m.Environment.SystemPath.Enabled = $true
$m.Environment.SystemPath.Entries = @('C:\App\bin', 'c:\app\bin\')
Test-Assert 'Case/slash duplicate PATH entry is flagged' `
    (@(Test-ConfigModel -Model $m -SkipFileChecks | Where-Object { $_.Message -match 'Duplicate' }).Count -gt 0)

$m = New-ValidModel
$m.Environment.Enabled = $true
$m.Environment.SystemPath.Enabled = $true
$m.Environment.SystemPath.Entries = @()
Test-Assert 'Enabled System PATH with no entries is an error' `
    (@(Test-ConfigModel -Model $m -SkipFileChecks | Where-Object { $_.Severity -eq 'Error' -and $_.Category -eq 'Environment' }).Count -gt 0)

$m = New-ValidModel
$m.WindowsIntegration.Enabled = $true
$m.WindowsIntegration.StartMenuShortcut.Enabled = $true
$m.WindowsIntegration.StartMenuShortcut.Name = 'App'
$m.WindowsIntegration.StartMenuShortcut.Target = 'C:\App\App.exe'
$f = @(Test-ConfigModel -Model $m -SkipFileChecks)
Test-Assert 'Recorded-only integration is reported as Information' `
    (@($f | Where-Object { $_.Severity -eq 'Information' -and $_.Category -eq 'Windows Integration' }).Count -gt 0)

$m = New-ValidModel; $m.Detection.Type = 'File'; $m.Detection.MinimumVersion = 'not.a.version'
Test-Assert 'Unparseable MinimumVersion is a warning' `
    (@(Test-ConfigModel -Model $m -SkipFileChecks | Where-Object { $_.Severity -eq 'Warning' -and $_.Category -eq 'Detection' }).Count -gt 0)

Test-Assert 'Empty finding list summarises as valid' ((Get-ValidationSummary -Findings @()).IsValid)
Test-Assert 'Null finding list summarises as valid' ((Get-ValidationSummary -Findings $null).IsValid)

# File-level validation
$tmp = New-TempDir
try {
    $broken = Join-Path $tmp 'broken.psd1'
    '@{ ApplicationName = ' | Set-Content $broken
    $f = @(Test-ConfigFile -Path $broken)
    Test-Assert 'Broken syntax is reported as a Syntax error' `
        (@($f | Where-Object { $_.Category -eq 'Syntax' }).Count -gt 0)

    $f = @(Test-ConfigFile -Path (Join-Path $tmp 'nope.psd1'))
    Test-Assert 'Missing configuration file is an error' `
        (@($f | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0)

    # Installer existence is checked against the package's Files directory.
    New-Item -Path (Join-Path $tmp 'Files') -ItemType Directory -Force | Out-Null
    $cfg = Join-Path $tmp 'Configuration.psd1'
    Export-ConfigurationFile -Model (New-ValidModel) -Path $cfg | Out-Null
    $f = @(Test-ConfigFile -Path $cfg -PackageRoot $tmp)
    Test-Assert 'Missing installer on disk is an error' `
        (@($f | Where-Object { $_.Severity -eq 'Error' -and $_.Category -eq 'Installer' }).Count -gt 0)

    New-FakeInstaller -Path (Join-Path $tmp 'Files\Setup.exe') | Out-Null
    $f = @(Test-ConfigFile -Path $cfg -PackageRoot $tmp)
    Test-Assert 'Present installer clears the error' `
        (@($f | Where-Object { $_.Severity -eq 'Error' -and $_.Category -eq 'Installer' }).Count -eq 0)
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ================================================================ Preview
Test-Group 'Preview'

$m = New-ValidModel
$m.Environment.Enabled = $true
$m.Environment.SystemPath.Enabled = $true
$m.Environment.SystemPath.Entries = @('C:\App\bin')

$preview = Get-ConfigurationPreview -Model $m
foreach ($section in @('Application', 'Installation', 'PATH', 'Detection', 'Uninstall', 'Intune')) {
    Test-Assert "Preview includes '$section'" ($preview.Contains($section))
}
Test-Assert 'Preview lists the PATH entry' (($preview['PATH'] -join ' ') -match 'C:\\App\\bin')
Test-Assert 'Preview shows the install command' (($preview['Installation'] -join ' ') -match 'Setup\.exe')

$noPath = Get-ConfigurationPreview -Model (New-ValidModel)
Test-Assert 'Preview states when there are no PATH changes' (($noPath['PATH'] -join ' ') -match 'No PATH changes')

$warn = Get-ExecutionWarningText -Model $m
Test-Assert 'Execution warning mentions installing software' ((@($warn.Effects) -join ' ') -match 'Install software')
Test-Assert 'Execution warning mentions the PATH change' ((@($warn.Effects) -join ' ') -match 'PATH')

$warnPlain = Get-ExecutionWarningText -Model (New-ValidModel)
Test-Assert 'Execution warning omits effects that are not configured' `
    (-not ((@($warnPlain.Effects) -join ' ') -match 'PATH'))

# ================================================================= Safety
Test-Group 'Safety boundary'

function Remove-PowerShellComments {
    <#
        Strips comments so the safety checks below inspect real code rather
        than prose. Without this, a comment explaining that execution happens
        elsewhere would look like an execution call.
    #>
    param([Parameter(Mandatory)][string]$Source)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors) | Out-Null

    $result = $Source
    # Blank out comment spans from the end so earlier offsets stay valid.
    $comments = @($tokens | Where-Object { $_.Kind -eq 'Comment' }) |
        Sort-Object { $_.Extent.StartOffset } -Descending

    foreach ($c in $comments) {
        $start = $c.Extent.StartOffset
        $length = $c.Extent.EndOffset - $start
        $result = $result.Remove($start, $length).Insert($start, ' ' * $length)
    }
    return $result
}

# The generator must not contain execution paths. This encodes the rule that
# analysis and configuration never modify the machine.
$wizardSource = Remove-PowerShellComments (Get-Content (Join-Path $StudioDir 'Wizard.ps1') -Raw)
$analyzerSource = Remove-PowerShellComments (Get-Content (Join-Path $StudioDir 'Analyzer.ps1') -Raw)

foreach ($pair in @(
    @{ Name = 'Wizard';   Source = $wizardSource },
    @{ Name = 'Analyzer'; Source = $analyzerSource }
)) {
    Test-Assert "$($pair.Name) does not start processes" `
        (-not ($pair.Source -match 'Start-Process'))
    Test-Assert "$($pair.Name) does not write the registry" `
        (-not ($pair.Source -match 'Set-ItemProperty|New-ItemProperty|Remove-ItemProperty'))
    # \b prevents Invoke-ConfigurationWizard (the generator itself) from
    # matching Invoke-Configuration (the executor).
    Test-Assert "$($pair.Name) does not call the packaging engine" `
        (-not ($pair.Source -match 'Install\.ps1|Uninstall\.ps1|Invoke-Configuration\b'))
    Test-Assert "$($pair.Name) does not modify PATH" `
        (-not ($pair.Source -match 'Add-PathEntry|Remove-PathEntry|Set-PersistentPath'))
    Test-Assert "$($pair.Name) does not build packages" `
        (-not ($pair.Source -match 'IntuneWinAppUtil'))
}

# Approval is required before anything runs.
$runnerSource = Get-Content (Join-Path $StudioDir 'Runner.ps1') -Raw
Test-Assert 'Runner has an explicit approval gate' ($runnerSource -match 'Confirm-ConfigurationExecution')
Test-Assert 'Approval requires typing the word run' ($runnerSource -match "-eq 'run'")

$entrySource = Remove-PowerShellComments (Get-Content (Join-Path $AppRoot 'New-IntuneApp.ps1') -Raw)
Test-Assert 'Run mode is gated by approval' ($entrySource -match 'Confirm-ConfigurationExecution')

# Isolate the Wizard switch branch and confirm it performs no execution.
$wizardBranchIndex = $entrySource.IndexOf("'Wizard' {")
Test-Assert 'Wizard branch is present in the entry point' ($wizardBranchIndex -ge 0)
if ($wizardBranchIndex -ge 0) {
    $wizardBranch = $entrySource.Substring($wizardBranchIndex)
    Test-Assert 'Wizard mode does not run the package workflow' `
        (-not ($wizardBranch -match 'Test-PackageWorkflow'))
    Test-Assert 'Wizard mode does not invoke the engine' `
        (-not ($wizardBranch -match 'Invoke-Configuration\b'))
    Test-Assert 'Wizard mode does not build a package' `
        (-not ($wizardBranch -match 'Build-IntunePackage'))
}

# ============================================== Wizard end-to-end (scripted)
Test-Group 'Wizard end to end'

$tmp = New-TempDir
try {
    New-Item -Path (Join-Path $tmp 'Files') -ItemType Directory -Force | Out-Null
    New-FakeInstaller -Path (Join-Path $tmp 'Files\Setup.exe') | Out-Null
    $out = Join-Path $tmp 'Configuration.psd1'

    Set-WizardAnswers -Answers @(
        '1',                                     # pick the discovered installer
        'Scripted App', 'Scripted Vendor', '3.1', '1',
        '1', '1', '', '1',                       # context, silent, default args, suppress restart
        '1', 'C:\Scripted\uninstall.exe', '/S',  # EXE uninstall
        '1', 'C:\Scripted', 'Scripted.exe', 'n', # File detection, no minimum version
        'n',                                     # no environment configuration
        'n',                                     # no Windows integration
        $out
    )

    $result = Invoke-ConfigurationWizard -PackageRoot $tmp -OutputPath $out 6>$null
    Clear-WizardAnswers

    Test-Assert 'Wizard writes the configuration file' (Test-Path $out)
    Test-Assert 'Wizard returns the model' ($result.Model.ApplicationName -eq 'Scripted App')
    Test-Assert 'Wizard captured the publisher' ($result.Model.Publisher -eq 'Scripted Vendor')
    Test-Assert 'Wizard captured the version' ($result.Model.Version -eq '3.1')
    Test-Assert 'Wizard used the analyzed silent switches' ($result.Model.Installer.Arguments -eq '/S')
    Test-Assert 'Wizard left Environment disabled' ($result.Model.Environment.Enabled -eq $false)

    $reloaded = Import-PowerShellDataFile -Path $out
    Test-Assert 'Generated file is loadable by the engine' ($reloaded.ApplicationName -eq 'Scripted App')
    Test-Assert 'Generated detection matches the answers' `
        ($reloaded.Detection.Path -eq 'C:\Scripted' -and $reloaded.Detection.FileName -eq 'Scripted.exe')

    $findings = @(Test-ConfigFile -Path $out -PackageRoot $tmp)
    Test-Assert 'Generated configuration validates cleanly' `
        ((Get-ValidationSummary -Findings $findings).IsValid) `
        (($findings | ForEach-Object { $_.Message }) -join '; ')

    # Nothing may have been installed or recorded as installed.
    Test-Assert 'Wizard created no package state directory' `
        (-not (Test-Path 'C:\ProgramData\IntunePackagingStudio\State\Scripted App'))

    # Re-opening the generated file reproduces the same model.
    $reopened = Import-ConfigModel -Path $out
    Test-Assert 'Generated file re-opens for editing' ($reopened.ApplicationName -eq 'Scripted App')
    Test-Assert 'Re-opened model keeps the install arguments' ($reopened.Installer.Arguments -eq '/S')
}
finally {
    Clear-WizardAnswers
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Scripted mode must fail fast rather than block on a hidden prompt.
Test-Group 'Scripted mode robustness'

Set-WizardAnswers -Answers @()
$threw = $false
try { Read-WizardInput -Prompt 'test' | Out-Null } catch { $threw = $true }
Clear-WizardAnswers
Test-Assert 'Exhausted answer queue throws instead of blocking' $threw

# ================================================================= Summary
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
$total = $script:pass + $script:fail
$color = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "Total: $total   Pass: $($script:pass)   Fail: $($script:fail)" -ForegroundColor $color
if ($script:fail -gt 0) {
    Write-Host ''
    Write-Host 'Failed:' -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
}
Write-Host '========================================' -ForegroundColor Cyan

if ($script:fail -gt 0) { exit 1 }
exit 0
