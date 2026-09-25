<#
.SYNOPSIS
    Tests for the Intune Application Evaluator.
.DESCRIPTION
    Exercises the evidence model, the pure selectors, the capture diff and
    attribution, the evaluator orchestration (driven by injected fixtures), and
    the export - including a real check that the exported package.json is
    accepted by staging-spoon's own manifest and integration validators, and a
    live-inspection read of the machine.
.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-EvaluatorTests.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $toolRoot -Parent
. (Join-Path $toolRoot 'src/Load.ps1')

$script:failures = 0
function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowNull()]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  PASS $Name" }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

# ============================================================================
Write-Host "`nEvidence model"

$result = New-EvaluationResult -ApplicationName 'Test'
$verified = New-EvaluatedField -Path 'a' -Value 'x' -Source 'InstalledSystem' -Confidence 'High' -Verified $true
Test-Case 'verified field is Detected' ((Get-FieldStatus -Field $verified) -eq 'Detected')

$inferred = New-EvaluatedField -Path 'b' -Value 'y' -Source 'ToolkitHeuristic' -Confidence 'Medium'
Test-Case 'metadata guess is Inferred' ((Get-FieldStatus -Field $inferred) -eq 'Inferred')

$needsReview = New-EvaluatedField -Path 'c' -Value '/S' -Source 'ToolkitHeuristic' -Confidence 'Medium' -RequiresConfirmation $true
Test-Case 'flagged value requires confirmation' ((Get-FieldStatus -Field $needsReview) -eq 'RequiresConfirmation')

$lowConf = New-EvaluatedField -Path 'd' -Value 'z' -Source 'Default' -Confidence 'Low'
Test-Case 'low confidence requires confirmation' ((Get-FieldStatus -Field $lowConf) -eq 'RequiresConfirmation')

$empty = New-EvaluatedField -Path 'e' -Value '' -Source 'InstalledSystem' -Confidence 'High' -Verified $true
Test-Case 'missing value requires confirmation' ((Get-FieldStatus -Field $empty) -eq 'RequiresConfirmation')

# Source precedence: a strong observation is not overwritten by a later guess.
Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'p' -Value 'observed' -Source 'LiveCapture' -Confidence 'High' -Verified $true) | Out-Null
Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'p' -Value 'guess' -Source 'ToolkitHeuristic' -Confidence 'Low') | Out-Null
Test-Case 'stronger source wins' ($result.Fields['p'].Value -eq 'observed')
Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'p' -Value 'override' -Source 'UserOverride' -Confidence 'High' -Verified $true) | Out-Null
# A user override outranks everything.
$ov = Set-FieldOverride -Result $result -Path 'p' -Value 'final'
Test-Case 'user override is Confirmed' ((Get-FieldStatus -Field $result.Fields['p']) -eq 'Confirmed' -and $result.Fields['p'].Value -eq 'final')

# ============================================================================
Write-Host "`nSelectors"

$arp = @(
    [PSCustomObject]@{ KeyName='7zip'; Hive='HKLM'; DisplayName='7-Zip 23.01'; UninstallString='C:\Program Files\7-Zip\Uninstall.exe' }
    [PSCustomObject]@{ KeyName='IntelliJ IDEA 2024.1'; Hive='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; DisplayName='IntelliJ IDEA 2024.1'; Publisher='JetBrains s.r.o.'; DisplayVersion='2024.1'; InstallLocation='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1'; DisplayIcon='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe'; UninstallString='"C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\Uninstall.exe"'; QuietUninstallString='"C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\Uninstall.exe" /S' }
)
$picked = Select-ArpApplication -Records $arp -Name 'IntelliJ IDEA*'
Test-Case 'ARP match picks the right app' ($picked.DisplayName -eq 'IntelliJ IDEA 2024.1')
Test-Case 'no match returns nothing' ($null -eq (Select-ArpApplication -Records $arp -Name 'Nonexistent App'))

Test-Case 'MSI GUID key is a product code' ((Get-MsiProductCode -KeyName '{11111111-2222-3333-4444-555555555555}') -ne '')
Test-Case 'non-GUID key is not a product code' ((Get-MsiProductCode -KeyName 'IntelliJ IDEA 2024.1') -eq '')

$exe = Resolve-MainExecutable -DisplayIcon 'C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe,0' -ApplicationName 'IntelliJ IDEA'
Test-Case 'DisplayIcon resolves main exe' ($exe.Path -match 'idea64\.exe$' -and $exe.Confidence -eq 'High')
$exe2 = Resolve-MainExecutable -ApplicationName 'Notepad++' -Executables @('C:\a\notepad++.exe', 'C:\a\updater.exe')
Test-Case 'name match resolves main exe' ($null -ne $exe2 -and $exe2.Path -match 'notepad\+\+\.exe$')
# When nothing matches by name and there are several executables, it declines
# rather than guessing.
Test-Case 'ambiguous executables decline'  ($null -eq (Resolve-MainExecutable -ApplicationName 'Zzz' -Executables @('C:\a\one.exe', 'C:\a\two.exe')))

$pathHits = @(Select-PathEntriesUnder -PathValue 'C:\Windows;C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin;C:\Other' -InstallLocation 'C:\Program Files\JetBrains\IntelliJ IDEA 2024.1' -Scope 'Machine')
Test-Case 'PATH entry under install location found' ($pathHits.Count -eq 1 -and $pathHits[0].Entry -like '*IntelliJ*bin')
Test-Case 'unrelated PATH entries not matched' (@(Select-PathEntriesUnder -PathValue 'C:\Windows;C:\Other' -InstallLocation 'C:\Program Files\JetBrains\IntelliJ IDEA 2024.1').Count -eq 0)

$items = @(
    [PSCustomObject]@{ Name='IntelliJ IDEA'; Target='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe' }
    [PSCustomObject]@{ Name='Notepad'; Target='C:\Windows\system32\notepad.exe' }
)
$appItems = @(Select-ArtifactsForApp -Items $items -Executable 'C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe' -InstallLocation 'C:\Program Files\JetBrains\IntelliJ IDEA 2024.1' -ApplicationName 'IntelliJ IDEA')
Test-Case 'artifact attribution keeps only the app' ($appItems.Count -eq 1 -and $appItems[0].Name -eq 'IntelliJ IDEA')
Test-Case 'attribution records evidence' (@($appItems[0].Evidence).Count -ge 1)

Test-Case 'machine-wide install implies elevation' ((Test-RequiresElevation -InstallLocation 'C:\Program Files\App').RequiresElevation)
Test-Case 'per-user install does not' (-not (Test-RequiresElevation -InstallLocation 'C:\Users\me\AppData\Local\App').RequiresElevation)

# ============================================================================
Write-Host "`nCapture diff and attribution"

$before = [PSCustomObject]@{ Applications=@([PSCustomObject]@{ KeyName='7zip' }); MachinePath='C:\Windows'; UserPath=''; Shortcuts=@() }
$after  = [PSCustomObject]@{
    Applications=@([PSCustomObject]@{ KeyName='7zip' }, [PSCustomObject]@{ KeyName='IntelliJ'; DisplayName='IntelliJ IDEA' })
    MachinePath='C:\Windows;C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin'
    UserPath=''
    Shortcuts=@([PSCustomObject]@{ Path='C:\Users\Public\Desktop\IntelliJ IDEA.lnk'; Name='IntelliJ IDEA'; Target='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe' })
}
$diff = Compare-SystemStateSnapshot -Before $before -After $after
Test-Case 'diff sees the new application' (@($diff.AddedApplications).Count -eq 1)
Test-Case 'diff sees the new PATH entry' (@($diff.AddedPathEntries).Count -eq 1)
Test-Case 'diff sees the new shortcut' (@($diff.AddedShortcuts).Count -eq 1)

$changes = Select-ApplicationChanges -Diff $diff -Executable 'C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe' -InstallLocation 'C:\Program Files\JetBrains\IntelliJ IDEA 2024.1' -ApplicationName 'IntelliJ IDEA'
Test-Case 'attributed the PATH change' (@($changes.PathEntries).Count -eq 1)
Test-Case 'attributed the shortcut' (@($changes.Shortcuts).Count -eq 1)

# ============================================================================
Write-Host "`nEvaluator (IntelliJ, injected fixtures)"

$shortcuts = @(
    [PSCustomObject]@{ Path='C:\Users\Public\Desktop\IntelliJ IDEA.lnk'; Name='IntelliJ IDEA'; Target='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe'; Arguments=''; WorkingDirectory='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin'; Icon=''; Location='PublicDesktop'; MachineWide=$true }
    [PSCustomObject]@{ Path='C:\Users\Public\Desktop\Firefox.lnk'; Name='Firefox'; Target='C:\Program Files\Mozilla Firefox\firefox.exe'; Location='PublicDesktop'; MachineWide=$true }
)
$menus = @(
    [PSCustomObject]@{ DisplayName='Open with IntelliJ IDEA'; Verb='JetBrains.IntelliJ.Open'; Executable='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe'; Command='"C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe" "%1"'; Scope='File'; Extensions=@('.java', '.kt') }
)
$assoc = @(
    [PSCustomObject]@{ Extension='.java'; ProgId='IntelliJIDEA.java'; Executable='C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe'; Command='"C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe" "%1"' }
    [PSCustomObject]@{ Extension='.pdf'; ProgId='AcroExch.Document'; Executable='C:\Program Files\Adobe\Acrobat\Acrobat.exe'; Command='"C:\Program Files\Adobe\Acrobat\Acrobat.exe" "%1"' }
)

$eval = Invoke-ApplicationEvaluation -Name 'IntelliJ IDEA*' `
    -InstallerPath 'C:\sources\ideaIU-2024.1.exe' `
    -ArpRecords $arp `
    -MachinePath 'C:\Windows;C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin' -UserPath '' `
    -Executables @('C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe') `
    -Shortcuts $shortcuts -ContextMenus $menus -FileAssociations $assoc

Test-Case 'evaluated the right application'  ($eval.ApplicationName -eq 'IntelliJ IDEA 2024.1')
Test-Case 'name detected'                    ($eval.Fields['application.name'].Value -eq 'IntelliJ IDEA 2024.1' -and $eval.Fields['application.name'].Verified)
Test-Case 'publisher detected'               ($eval.Fields['application.publisher'].Value -eq 'JetBrains s.r.o.')
Test-Case 'version detected'                 ($eval.Fields['application.version'].Value -eq '2024.1')
Test-Case 'main executable resolved'         ($eval.Fields['installation.executable'].Value -match 'idea64\.exe$')
Test-Case 'silent uninstall preferred'       ($eval.Fields['installation.uninstallString'].Value -match '/S$')
Test-Case 'installer type EXE (non-GUID key)' ($eval.Fields['installer.type'].Value -eq 'EXE')
Test-Case 'machine PATH entry detected'      ($eval.Fields['integration.path'].Value -like '*IntelliJ*bin' -and $eval.Fields['integration.path'].Verified)
Test-Case 'desktop shortcut detected'        ($eval.Fields.Contains('integration.shortcut.IntelliJ IDEA'))
Test-Case 'unrelated shortcut not captured'  (-not $eval.Fields.Contains('integration.shortcut.Firefox'))
Test-Case 'context menu detected'            ($eval.Fields.Contains('integration.contextmenu.Open with IntelliJ IDEA'))
Test-Case 'java association detected'         ($eval.Fields.Contains('integration.association..java'))
Test-Case 'pdf association not captured'      (-not $eval.Fields.Contains('integration.association..pdf'))

$counts = Get-EvaluationSummaryCounts -Result $eval
Test-Case 'summary counts populated'         (($counts.Detected + $counts.Inferred + $counts.RequiresConfirmation + $counts.Confirmed) -eq @($eval.Fields.Keys).Count)

# A per-user install's context is flagged for confirmation.
$perUser = @([PSCustomObject]@{ KeyName='LocalApp'; Hive='HKCU'; DisplayName='Local App'; InstallLocation='C:\Users\me\AppData\Local\LocalApp'; DisplayIcon='C:\Users\me\AppData\Local\LocalApp\app.exe' })
$evalU = Invoke-ApplicationEvaluation -Name 'Local App' -ArpRecords $perUser -MachinePath 'C:\Windows' -UserPath '' -Executables @()
Test-Case 'per-user context flagged for review' ((Get-FieldStatus -Field $evalU.Fields['installation.context']) -eq 'RequiresConfirmation')

# ============================================================================
Write-Host "`nExport (and staging-spoon accepts it)"

$package = ConvertTo-StagingSpoonPackage -Result $eval
Test-Case 'export names the application'      ($package.ApplicationName -eq 'IntelliJ IDEA 2024.1')
Test-Case 'install command is wrapper form'   ($package.InstallCommand -match '-File \./Install\.ps1 -InstallerName' -or $package.InstallCommand -match '-File \./Install\.ps1$')
Test-Case 'integrations exported'             ($package.PSObject.Properties.Name -contains 'Integrations')
Test-Case 'PATH exported as VALIDATE'         (@($package.Integrations.Path)[0].Mode -eq 'VALIDATE')
Test-Case 'shortcut exported'                 (@($package.Integrations.Shortcut).Count -eq 1)
Test-Case 'context menu exported with %1 exe' (@($package.Integrations.ContextMenu)[0].Executable -match 'idea64\.exe$')
Test-Case 'association exported'              (@($package.Integrations.FileAssociation)[0].Extension -eq '.java')

# The real interop guarantee: staging-spoon's own validators accept the export.
. (Join-Path $repoRoot 'src/Core/Integrations.ps1')
. (Join-Path $repoRoot 'src/Core/PackageManifest.ps1')
$accepted = $true
try { ConvertTo-IntegrationConfig -Integrations $package.Integrations | Out-Null } catch { $accepted = $false; Write-Host "    integration rejection: $($_.Exception.Message)" -ForegroundColor Red }
Test-Case 'staging-spoon accepts the Integrations block' $accepted

$manifest = New-PackageManifest -ApplicationName $package.ApplicationName -ApplicationVersion $package.ApplicationVersion `
    -PackageVersion $package.PackageVersion -InstallerType $package.InstallerType -SourceInstaller $package.SourceInstaller `
    -InstallCommand $package.InstallCommand -UninstallCommand $package.UninstallCommand `
    -DetectionMethod $package.DetectionMethod -DetectionScript $package.DetectionScript `
    -ContentDirectory (Split-Path $PSScriptRoot -Parent) -InstallBehavior $package.InstallBehavior `
    -Architecture $package.Architecture -Integrations $package.Integrations
$check = Test-PackageManifest -Manifest $manifest
Test-Case 'staging-spoon manifest is valid'   $check.IsValid ($check.Errors -join '; ')

# ============================================================================
Write-Host "`nLive inspection"
$snap = New-SystemStateSnapshot
Test-Case 'live snapshot reads applications' (@($snap.Applications).Count -ge 0)
Test-Case 'live snapshot reads machine PATH' ($null -ne $snap.MachinePath)

# ============================================================================
Write-Host ''
if ($script:failures -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$($script:failures) TEST(S) FAILED" -ForegroundColor Red
exit 1
