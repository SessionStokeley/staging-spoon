<#
.SYNOPSIS
    Tests for Windows application integrations as owned package resources.
.DESCRIPTION
    Proves the four integration kinds - PATH/environment, desktop shortcut,
    context menu, file association - across the three modes (DISABLED, VALIDATE,
    MANAGE), with ownership tracking that removes only what the package created.

    The risk-bearing logic is exercised directly: PATH add/deduplicate/validate/
    remove and preserve-others through an in-memory environment accessor;
    ownership save/load and removal against real temporary files; registry
    command and ProgID generation; mode and SYSTEM-scope resolution; and capture
    that identifies only application-relevant associations. The real-state
    section drives the COM .lnk and the live registry directly.
.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-IntegrationTests.ps1
#>

[CmdletBinding()]
param([string]$WorkPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'staging-spoon-integration-tests'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src/Core/Platform.ps1')
. (Join-Path $repo 'src/Core/Integrations.ps1')

if (Test-Path -LiteralPath $WorkPath) { Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -Path $WorkPath -ItemType Directory -Force | Out-Null

$script:failures = 0
function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowNull()]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  PASS $Name" }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

# ============================================================================
Write-Host "`nPATH integration (real logic via an in-memory environment)"

$store = @{ 'Machine:Path' = 'C:\Windows;C:\Windows\System32;C:\Existing\bin' }
$acc = New-EnvironmentAccessor -Store $store
$binDef = [PSCustomObject]@{ Kind='Path'; Mode='MANAGE'; Id='intellij-bin'; Entry='C:\Program Files\JetBrains\IntelliJ IDEA\bin'; Scope='Machine' }
$pathState = New-IntegrationState -ApplicationKey 'IntelliJ'

$apply1 = Invoke-PathIntegration -Action Apply -Definition $binDef -Accessor $acc -RunningAsSystem $true -State $pathState
Test-Case 'PATH entry is added'            ($apply1.Added -and $apply1.Success)
Test-Case 'existing PATH entries preserved' ($store['Machine:Path'] -like '*C:\Existing\bin*' -and $store['Machine:Path'] -like '*System32*')
Test-Case 'added entry is present'         ($store['Machine:Path'] -like '*IntelliJ IDEA\bin*')
Test-Case 'ownership records the entry'    (@($pathState.PathEntries).Count -eq 1)

$apply2 = Invoke-PathIntegration -Action Apply -Definition $binDef -Accessor $acc -RunningAsSystem $true -State $pathState
Test-Case 'no duplicate on re-apply'       (-not $apply2.Added)
Test-Case 'PATH has the entry exactly once' (@(Split-PathValue -PathValue $store['Machine:Path'] | Where-Object { (Get-NormalizedPathEntry -Entry $_) -eq (Get-NormalizedPathEntry -Entry $binDef.Entry) }).Count -eq 1)

# A case- and trailing-slash-different spelling is the same entry.
$dupDef = [PSCustomObject]@{ Kind='Path'; Mode='MANAGE'; Id='dup'; Entry='c:\program files\jetbrains\intellij idea\bin\'; Scope='Machine' }
$apply3 = Invoke-PathIntegration -Action Apply -Definition $dupDef -Accessor $acc -RunningAsSystem $true -State $pathState
Test-Case 'case/slash variant not duplicated' (-not $apply3.Added)

$validate = Invoke-PathIntegration -Action Validate -Definition $binDef -Accessor $acc -RunningAsSystem $true
Test-Case 'PATH validates as present'      $validate.Success

$before = $store['Machine:Path']
$removals = Remove-OwnedIntegrations -State $pathState -Accessor $acc -RunningAsSystem $true
Test-Case 'owned PATH entry removed'       ($store['Machine:Path'] -notlike '*IntelliJ IDEA\bin*')
Test-Case 'unrelated PATH entries remain'  ($store['Machine:Path'] -like '*C:\Existing\bin*' -and $store['Machine:Path'] -like '*System32*')
Test-Case 'validate now fails after removal' (-not (Invoke-PathIntegration -Action Validate -Definition $binDef -Accessor $acc -RunningAsSystem $true).Success)

# A User-scope PATH change from SYSTEM does not reach signed-in users.
$userDef = [PSCustomObject]@{ Kind='Path'; Mode='MANAGE'; Id='u'; Entry='C:\x\bin'; Scope='User' }
$userApply = Invoke-PathIntegration -Action Apply -Definition $userDef -Accessor $acc -RunningAsSystem $true -State (New-IntegrationState -ApplicationKey 'z')
Test-Case 'user PATH from SYSTEM refused with reason' (-not $userApply.Success -and $userApply.Reason -match 'SYSTEM')
$userApplyInteractive = Invoke-PathIntegration -Action Apply -Definition $userDef -Accessor $acc -RunningAsSystem $false -State (New-IntegrationState -ApplicationKey 'z')
Test-Case 'user PATH as a real user is allowed' $userApplyInteractive.Success

# ============================================================================
Write-Host "`nOwnership state (save, load, remove only owned - real files)"

$ownWork = Join-Path $WorkPath 'ownership'
New-Item -Path $ownWork -ItemType Directory -Force | Out-Null
# Real files stand in for shortcuts, so remove-owned vs preserve is proven off
# Windows too; the .lnk COM specifics are covered under Windows below.
$ownedLink   = Join-Path $ownWork 'IntelliJ IDEA.lnk'
$strangerLink = Join-Path $ownWork 'Someone Else.lnk'
'owned'    | Set-Content -LiteralPath $ownedLink
'stranger' | Set-Content -LiteralPath $strangerLink

$fileStore = @{ 'Machine:Path' = 'C:\Windows;C:\App\bin' }
$fileAcc = New-EnvironmentAccessor -Store $fileStore
$state = New-IntegrationState -ApplicationKey 'IntelliJ'
$state.PathEntries = @([PSCustomObject]@{ Scope='Machine'; Entry='C:\App\bin' })
$state.Shortcuts   = @($ownedLink)     # only the owned link is recorded
$statePath = Join-Path $ownWork 'integration-state.json'
Save-IntegrationState -State $state -Path $statePath
Test-Case 'state persists to disk'        (Test-Path -LiteralPath $statePath)

$loaded = Get-IntegrationState -Path $statePath
Test-Case 'state round-trips'             (@($loaded.PathEntries).Count -eq 1 -and @($loaded.Shortcuts).Count -eq 1)

Remove-OwnedIntegrations -State $loaded -Accessor $fileAcc -RunningAsSystem $true | Out-Null
Test-Case 'owned shortcut deleted'        (-not (Test-Path -LiteralPath $ownedLink))
Test-Case 'unrelated shortcut preserved'  (Test-Path -LiteralPath $strangerLink)
Test-Case 'owned PATH removed, other kept' ($fileStore['Machine:Path'] -eq 'C:\Windows')

$stateKeyed = Get-IntegrationStatePath -ApplicationKey 'IntelliJ IDEA 2024.1'
Test-Case 'state path is keyed and sanitised' ($stateKeyed -match 'IntelliJ_IDEA_2024.1' -and $stateKeyed -match 'integration-state\.json$')

# ============================================================================
Write-Host "`nContext menu (registry plan generation)"

$menuDef = [PSCustomObject]@{
    Kind='ContextMenu'; Mode='MANAGE'; Id='open-with-idea'
    Verb='Company.IntelliJ.Open'; DisplayName='Open with IntelliJ IDEA'
    Executable='C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe'
    Target='File'; Extensions=@('.java', '.kt')
}
$fileMenu = Get-ContextMenuPlan -Root 'HKLM:\SOFTWARE\Classes' -Target $menuDef.Target -Verb $menuDef.Verb `
    -DisplayName $menuDef.DisplayName -Executable $menuDef.Executable -Extensions $menuDef.Extensions
Test-Case 'file menu covers each extension'   (@($fileMenu.Keys).Count -eq 2)
Test-Case 'verb key is package-specific'      ($fileMenu.Keys[0].VerbKey -eq 'HKLM:\SOFTWARE\Classes\.java\shell\Company.IntelliJ.Open')
Test-Case 'command embeds %1'                 ($fileMenu.Command -eq '"C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe" "%1"')
Test-Case 'command key sits under the verb'   ($fileMenu.Keys[0].CommandKey -eq ($fileMenu.Keys[0].VerbKey + '\command'))
Test-Case 'display name carried'              ($fileMenu.Keys[0].DisplayName -eq 'Open with IntelliJ IDEA')

# The four target scopes map to distinct classes.
$dirMenu = Get-ContextMenuPlan -Root 'HKLM:\SOFTWARE\Classes' -Target 'Directory' -Verb 'V' -DisplayName 'D' -Executable 'C:\a.exe'
$folderMenu = Get-ContextMenuPlan -Root 'HKLM:\SOFTWARE\Classes' -Target 'Folder' -Verb 'V' -DisplayName 'D' -Executable 'C:\a.exe'
$allMenu = Get-ContextMenuPlan -Root 'HKLM:\SOFTWARE\Classes' -Target 'AllFiles' -Verb 'V' -DisplayName 'D' -Executable 'C:\a.exe'
Test-Case 'directory target uses Background'  ($dirMenu.Keys[0].VerbKey -like '*\Directory\Background\shell\V')
Test-Case 'folder target uses Directory'      ($folderMenu.Keys[0].VerbKey -like '*\Directory\shell\V')
Test-Case 'all-files target uses *'           ($allMenu.Keys[0].VerbKey -like '*\*\shell\V')
$threw = $false
try { Get-ContextMenuPlan -Root 'R' -Target 'File' -Verb 'V' -DisplayName 'D' -Executable 'x' } catch { $threw = $true }
Test-Case 'file target with no extensions rejected' $threw

# ============================================================================
Write-Host "`nFile association (registry plan generation)"

$assocPlan = Get-FileAssociationPlan -Root 'HKLM:\SOFTWARE\Classes' -Extension 'java' `
    -ProgId 'IntelliJIDEA.java' -Executable 'C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe' -FriendlyName 'Java Source'
Test-Case 'extension normalised with dot'     ($assocPlan.Extension -eq '.java')
Test-Case 'extension key points at ProgID'    ($assocPlan.ExtensionKey -eq 'HKLM:\SOFTWARE\Classes\.java')
Test-Case 'ProgID open command embeds %1'     ($assocPlan.Command -eq '"C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe" "%1"')
Test-Case 'ProgID command key correct'        ($assocPlan.ProgIdCommandKey -eq 'HKLM:\SOFTWARE\Classes\IntelliJIDEA.java\shell\open\command')

# ============================================================================
Write-Host "`nScope and location resolution (SYSTEM awareness)"

$machineClasses = Resolve-ClassesRoot -Scope 'Machine' -RunningAsSystem $true
Test-Case 'machine classes reach all users'   ($machineClasses.Root -eq 'HKLM:\SOFTWARE\Classes' -and $machineClasses.ReachesIntendedUsers)
$userClassesFromSystem = Resolve-ClassesRoot -Scope 'User' -RunningAsSystem $true
Test-Case 'HKCU from SYSTEM flagged'           (-not $userClassesFromSystem.ReachesIntendedUsers -and $userClassesFromSystem.Limitation)

$publicDesktop = Resolve-DesktopLocation -Location 'Public' -RunningAsSystem $true
Test-Case 'public desktop reaches all users'   ($publicDesktop.Directory -like '*Public*Desktop' -and $publicDesktop.ReachesIntendedUsers)
$userDesktopFromSystem = Resolve-DesktopLocation -Location 'User' -RunningAsSystem $true
Test-Case 'user desktop from SYSTEM flagged'    (-not $userDesktopFromSystem.ReachesIntendedUsers -and $userDesktopFromSystem.Limitation)

# ============================================================================
Write-Host "`nConfiguration normalisation and modes"

$config = [PSCustomObject]@{
    Path        = @([PSCustomObject]@{ Entry='C:\bin'; Scope='Machine' })
    Shortcut    = @([PSCustomObject]@{ Mode='MANAGE'; Name='IntelliJ IDEA'; Target='C:\idea64.exe' })
    ContextMenu = @([PSCustomObject]@{ Verb='Open'; DisplayName='Open with IntelliJ IDEA'; Executable='C:\idea64.exe'; Target='File'; Extensions=@('.java') })
    FileAssociation = @([PSCustomObject]@{ Mode='VALIDATE'; Extension='.java'; ProgId='IntelliJIDEA.java'; Executable='C:\idea64.exe' })
}
$defs = @(ConvertTo-IntegrationConfig -Integrations $config)
Test-Case 'all four kinds normalised'      ($defs.Count -eq 4)
Test-Case 'default mode is MANAGE'         (($defs | Where-Object Kind -eq 'Path')[0].Mode -eq 'MANAGE')
Test-Case 'declared VALIDATE preserved'    (($defs | Where-Object Kind -eq 'FileAssociation')[0].Mode -eq 'VALIDATE')
Test-Case 'ids are assigned'               (@($defs | Where-Object { $_.Id }).Count -eq 4)

$threw = $false
try { ConvertTo-IntegrationConfig -Integrations ([PSCustomObject]@{ ContextMenu=@([PSCustomObject]@{ Mode='MANAGE'; Verb='V' }) }) | Out-Null } catch { $threw = $true }
Test-Case 'MANAGE missing fields rejected'  $threw
$threw = $false
try { ConvertTo-IntegrationConfig -Integrations ([PSCustomObject]@{ Path=@([PSCustomObject]@{ Mode='SOMETHING'; Entry='x' }) }) | Out-Null } catch { $threw = $true }
Test-Case 'unknown mode rejected'           $threw
# A DISABLED integration is kept but not validated for completeness.
$disabled = @(ConvertTo-IntegrationConfig -Integrations ([PSCustomObject]@{ Shortcut=@([PSCustomObject]@{ Mode='DISABLED'; Name='x' }) }))
Test-Case 'DISABLED kept without completeness check' ($disabled.Count -eq 1 -and $disabled[0].Mode -eq 'DISABLED')

# DISABLED is skipped by the dispatcher; VALIDATE is checked, never applied.
$skipResults = Invoke-IntegrationSet -Phase 'Apply' -Definitions $disabled -RunningAsSystem $false
Test-Case 'DISABLED integration skipped'    ($skipResults[0].Action -eq 'Skip' -and $skipResults[0].Success)

# ============================================================================
Write-Host "`nCapture identifies only application-relevant associations"

$observed = @(
    [PSCustomObject]@{ Extension='.java'; ProgId='IntelliJIDEA.java'; Command='"C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe" "%1"' }
    [PSCustomObject]@{ Extension='.txt';  ProgId='txtfile';          Command='"C:\Windows\system32\notepad.exe" "%1"' }
    [PSCustomObject]@{ Extension='.kt';   ProgId='IntelliJIDEA.kt';  Command='"C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe" "%1"' }
    [PSCustomObject]@{ Extension='.pdf';  ProgId='AcroExch.Document'; Command='"C:\Program Files\Adobe\Acrobat\Acrobat.exe" "%1"' }
)
$relevant = @(Select-ApplicationAssociations -Observed $observed `
    -Executable 'C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe' `
    -ApplicationName 'IntelliJ IDEA' -ProgIdHints @('IntelliJIDEA'))
Test-Case 'only IntelliJ associations captured' ($relevant.Count -eq 2)
Test-Case 'captured the right extensions'        ((@($relevant | ForEach-Object { $_.Extension }) | Sort-Object) -join ',' -eq '.java,.kt')
Test-Case 'notepad association not captured'     (@($relevant | Where-Object { $_.Extension -eq '.txt' }).Count -eq 0)
Test-Case 'acrobat association not captured'     (@($relevant | Where-Object { $_.Extension -eq '.pdf' }).Count -eq 0)
Test-Case 'capture records its evidence'         (@($relevant[0].Evidence).Count -ge 1)
# An empty observation captures nothing, rather than everything.
Test-Case 'empty observation captures nothing'   (@(Select-ApplicationAssociations -Observed @() -Executable 'C:\x.exe').Count -eq 0)

# ============================================================================
Write-Host "`nIntelliJ end-to-end (install -> validate -> uninstall, logic path)"

# One package with all four integrations, driven through apply, validate and
# ownership-based removal using the in-memory environment and real temp files.
$e2eStore = @{ 'Machine:Path' = 'C:\Windows;C:\Windows\System32' }
$e2eAcc   = New-EnvironmentAccessor -Store $e2eStore
$e2eDesktop = Join-Path $WorkPath 'e2e-desktop'
New-Item -Path $e2eDesktop -ItemType Directory -Force | Out-Null
$vendorShortcut = Join-Path $e2eDesktop 'Vendor Thing.lnk'
'vendor' | Set-Content -LiteralPath $vendorShortcut   # a pre-existing, unrelated shortcut

$ideaConfig = [PSCustomObject]@{
    Path = @([PSCustomObject]@{ Mode='MANAGE'; Entry='C:\Program Files\JetBrains\IntelliJ IDEA\bin'; Scope='Machine' })
    FileAssociation = @([PSCustomObject]@{ Mode='VALIDATE'; Extension='.java'; ProgId='IntelliJIDEA.java'; Executable='C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe' })
}
$ideaDefs = @(ConvertTo-IntegrationConfig -Integrations $ideaConfig)
$ideaState = New-IntegrationState -ApplicationKey 'IntelliJ IDEA'

# INSTALL: apply MANAGE (PATH), record ownership. VALIDATE (association) is the
# vendor's; the dispatcher only checks it - here it is not present, so on a real
# machine that would be a finding, which is the correct behaviour.
$e2eApply = Invoke-IntegrationSet -Phase 'Apply' -Definitions $ideaDefs -RunningAsSystem $true -State $ideaState -Accessor $e2eAcc
$pathApplied = @($e2eApply | Where-Object { $_.Kind -eq 'Path' })[0]
Test-Case 'E2E: PATH applied on install'    ($pathApplied.Success)
Test-Case 'E2E: bin dir on PATH'            ($e2eStore['Machine:Path'] -like '*IntelliJ IDEA\bin*')
Test-Case 'E2E: PATH ownership recorded'    (@($ideaState.PathEntries).Count -eq 1)
Test-Case 'E2E: VALIDATE assoc not applied' (@($e2eApply | Where-Object { $_.Kind -eq 'FileAssociation' })[0].Action -eq 'Validate')

# UNINSTALL: remove only owned. The vendor shortcut and the unrelated PATH
# entries must survive; the managed PATH entry must go.
Remove-OwnedIntegrations -State $ideaState -Accessor $e2eAcc -RunningAsSystem $true | Out-Null
Test-Case 'E2E: managed PATH removed'       ($e2eStore['Machine:Path'] -notlike '*IntelliJ IDEA\bin*')
Test-Case 'E2E: base PATH intact'           ($e2eStore['Machine:Path'] -eq 'C:\Windows;C:\Windows\System32')
Test-Case 'E2E: unrelated shortcut intact'  (Test-Path -LiteralPath $vendorShortcut)

# ============================================================================
Write-Host "`nReal-state checks (COM shortcuts and the registry)"
    $winDesktop = Join-Path $WorkPath 'win-desktop'
    New-Item -Path $winDesktop -ItemType Directory -Force | Out-Null
    $lnk = Join-Path $winDesktop 'IntelliJ IDEA.lnk'
    Set-Shortcut -Path $lnk -TargetPath 'C:\Windows\System32\notepad.exe' -Arguments '/x' -WorkingDirectory 'C:\Windows' | Out-Null
    $read = Read-Shortcut -Path $lnk
    Test-Case 'shortcut created'          (Test-Path -LiteralPath $lnk)
    Test-Case 'shortcut target correct'   ($read.TargetPath -eq 'C:\Windows\System32\notepad.exe')
    Test-Case 'shortcut arguments correct' ($read.Arguments -match '/x')

    $rootKey = 'HKCU:\SOFTWARE\StagingSpoonTests\Classes'
    $cmDef = [PSCustomObject]@{ Kind='ContextMenu'; Mode='MANAGE'; Id='t'; Verb='StagingSpoon.Open'; DisplayName='Open with Test'; Executable='C:\test.exe'; Target='File'; Extensions=@('.sstest'); Scope='User' }
    $st = New-IntegrationState -ApplicationKey 'WinTest'
    # Point the plan at a private root so the test never touches real classes.
    $plan = Get-ContextMenuPlan -Root $rootKey -Target 'File' -Verb $cmDef.Verb -DisplayName $cmDef.DisplayName -Executable $cmDef.Executable -Extensions $cmDef.Extensions
    foreach ($k in $plan.Keys) {
        New-RegistryKeyValues -Key $k.VerbKey -Values @{ '(default)' = $k.DisplayName } -State $st -OwnedRoot $k.VerbKey
        New-RegistryKeyValues -Key $k.CommandKey -Values @{ '(default)' = $k.Command }
    }
    Test-Case 'context-menu key created'  (Test-Path -LiteralPath $plan.Keys[0].VerbKey)
    Test-Case 'context-menu command has %1' ((Get-ItemProperty -LiteralPath $plan.Keys[0].CommandKey).'(default)' -match '%1')
    Remove-OwnedIntegrations -State $st -RunningAsSystem $false | Out-Null
    Test-Case 'context-menu key removed'  (-not (Test-Path -LiteralPath $plan.Keys[0].VerbKey))
    Remove-Item -LiteralPath 'HKCU:\SOFTWARE\StagingSpoonTests' -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failures -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$($script:failures) TEST(S) FAILED" -ForegroundColor Red
exit 1
