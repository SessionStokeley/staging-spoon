#Requires -Version 5.1
<#
    Test-Integration.ps1

    Tests the Windows integration engine - shortcuts, context menus, file
    associations, services and scheduled tasks - against in-memory stand-ins
    for the shell, the registry, the service database and the task scheduler.

    Why stand-ins: creating a real .lnk needs WScript.Shell and writing a real
    verb needs HKLM, so on anything but an elevated Windows session none of the
    decision-making would ever execute. Substituting the primitives runs the
    real orchestration anywhere, which is where the interesting behaviour lives:
    which mode applies, whether something pre-existed, what gets recorded as
    owned, and what uninstall is therefore allowed to remove.

    This is the same approach Test-Lifecycle.ps1 takes for the registry.
    Test-Elevated.ps1 covers the primitives themselves on real Windows.

    Run:
        pwsh -File Tests/Test-Integration.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Integration.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

. (Join-Path $AppRoot 'Helpers\WindowsIntegration.ps1')

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

function Test-Throws {
    param([string]$Name, [scriptblock]$Action, [string]$Match = '')
    try {
        & $Action | Out-Null
        Test-Assert $Name $false 'expected an exception, none was thrown'
    }
    catch {
        if ($Match -and $_.Exception.Message -notmatch $Match) {
            Test-Assert $Name $false "message did not match '$Match': $($_.Exception.Message)"
        }
        else { Test-Assert $Name $true }
    }
}

function Test-Group { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor White }

# ===================================================== in-memory substitutes
# Defined after the dot-source so these win. PowerShell resolves function
# calls at invocation time, so the engine calls these.

$script:Shortcuts = @{}
$script:Reg       = @{}   # key path -> @{ valueName -> value }
$script:Services  = @{}
$script:Tasks     = @{}
$script:State     = $null
$script:Notified  = 0

# Real Windows shell folder paths. Nothing is written to them - New-ShortcutFile
# and Test-ShortcutFile are both substituted - so they only ever exist as
# strings, and the engine assembles them with Join-WindowsPath rather than
# Join-Path precisely so this works off Windows.
function Get-ShellFolderPath {
    param([string]$Name)
    switch ($Name) {
        'PublicDesktop'     { return 'C:\Users\Public\Desktop' }
        'UserDesktop'       { return 'C:\Users\Tester\Desktop' }
        'AllUsersStartMenu' { return 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' }
        'UserStartMenu'     { return 'C:\Users\Tester\Start Menu\Programs' }
    }
}

function New-ShortcutFile {
    param($Path, $Target, $Arguments = '', $WorkingDirectory = '', $Icon = '', $Description = '')
    $script:Shortcuts[$Path] = @{
        Target = $Target; Arguments = $Arguments; WorkingDirectory = $WorkingDirectory
        Icon = $Icon; Description = $Description
    }
}
function Test-ShortcutFile {
    param($Path, $ExpectedTarget = '')
    if (-not $script:Shortcuts.ContainsKey($Path)) {
        return @{ Exists = $false; Target = ''; TargetMatches = $false }
    }
    $target = [string]$script:Shortcuts[$Path].Target
    $matches = $true
    if ($ExpectedTarget) { $matches = $target.Equals($ExpectedTarget, [StringComparison]::OrdinalIgnoreCase) }
    return @{ Exists = $true; Target = $target; TargetMatches = $matches }
}
function Remove-ShortcutFile {
    param($Path)
    $script:Shortcuts.Remove($Path)
}

function Test-IntegrationRegistryKey { param($Path) return $script:Reg.ContainsKey($Path) }
function Set-IntegrationRegistryValue {
    param($Path, $Name = '', $Value = '', $Type = 'String')
    if (-not $script:Reg.ContainsKey($Path)) { $script:Reg[$Path] = @{} }
    $n = $Name; if (-not $n) { $n = '(default)' }
    $script:Reg[$Path][$n] = $Value
}
function Get-IntegrationRegistryValue {
    param($Path, $Name = '')
    if (-not $script:Reg.ContainsKey($Path)) { return $null }
    $n = $Name; if (-not $n) { $n = '(default)' }
    if (-not $script:Reg[$Path].ContainsKey($n)) { return $null }
    return $script:Reg[$Path][$n]
}
function Remove-IntegrationRegistryKey {
    param($Path)
    # Subtree removal, as the real one does.
    foreach ($k in @($script:Reg.Keys)) {
        if ($k -eq $Path -or $k.StartsWith("$Path\")) { $script:Reg.Remove($k) }
    }
}
function Remove-IntegrationRegistryValue {
    param($Path, $Name)
    if ($script:Reg.ContainsKey($Path)) { $script:Reg[$Path].Remove($Name) }
}
function Update-ShellNotification {
    $script:Notified++
    return @{ Success = $true; Message = '(shell notification suppressed in tests)' }
}

function Test-IntegrationService {
    param($Name)
    if (-not $script:Services.ContainsKey($Name)) { return @{ Exists = $false; Status = ''; StartType = '' } }
    return @{ Exists = $true; Status = 'Stopped'; StartType = $script:Services[$Name].StartupType }
}
function New-IntegrationService {
    param($Name, $BinaryPath, $DisplayName = '', $Description = '', $StartupType = 'Manual')
    $script:Services[$Name] = @{ BinaryPath = $BinaryPath; DisplayName = $DisplayName; StartupType = $StartupType; Started = $false }
}
function Start-IntegrationService { param($Name) $script:Services[$Name].Started = $true }
function Remove-IntegrationService { param($Name) $script:Services.Remove($Name) }

function Test-IntegrationScheduledTask {
    param($Name, $Path = '\')
    $key = "$Path$Name"
    if (-not $script:Tasks.ContainsKey($key)) { return @{ Exists = $false; State = '' } }
    return @{ Exists = $true; State = 'Ready' }
}
function New-IntegrationScheduledTask {
    param($Name, $Path = '\', $Executable, $Arguments = '', $Trigger = 'AtLogon',
          $RunAsUser = '', $RunLevel = 'Limited', $RunWhetherLoggedOnOrNot = $false)
    $script:Tasks["$Path$Name"] = @{ Executable = $Executable; RunAsUser = $RunAsUser; RunLevel = $RunLevel; Trigger = $Trigger }
}
function Remove-IntegrationScheduledTask { param($Name, $Path = '\') $script:Tasks.Remove("$Path$Name") }

function Save-IntegrationState {
    param($ApplicationName, $Resources = @())
    # Round-tripped through JSON so records arrive as the PSCustomObject shape
    # the real state file produces.
    $script:State = (@{
        ApplicationName = $ApplicationName
        Resources       = $Resources
    } | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    return 'in-memory'
}
function Get-IntegrationState { param($ApplicationName) return $script:State }
function Remove-IntegrationState { param($ApplicationName) $script:State = $null }

# ============================================================== fixture

# A real file, because the engine refuses to create a shortcut to a target
# that is not there - a shortcut that fails when clicked is worse than none.
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wi_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
$appExe = Join-Path $workDir 'App.exe'
Set-Content -LiteralPath $appExe -Value 'stub' -Encoding UTF8

$missingTarget = Join-Path $workDir 'not-installed.exe'

function Reset-Machine {
    $script:Shortcuts = @{}
    $script:Reg       = @{}
    $script:Services  = @{}
    $script:Tasks     = @{}
    $script:State     = $null
    $script:Notified  = 0
}

function New-TestConfig {
    param([hashtable]$Integration)
    return @{
        ApplicationName    = 'IntegrationApp'
        WindowsIntegration = $Integration
    }
}

$desktopLnk     = 'C:\Users\Public\Desktop\App.lnk'
$userDesktopLnk = 'C:\Users\Tester\Desktop\App.lnk'
$startMenuLnk   = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Company\App.lnk'

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Windows Integration Tests' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

try {

# ============================================================ mode resolution
Test-Group 'Mode resolution'

Test-Assert 'Mode wins when set' `
    ((Resolve-IntegrationMode -Section @{ Mode = 'VALIDATE'; Enabled = $true }) -eq 'VALIDATE')
Test-Assert 'Mode is case-insensitive' `
    ((Resolve-IntegrationMode -Section @{ Mode = 'manage' }) -eq 'MANAGE')
Test-Assert 'Enabled = $true means MANAGE when no Mode is set' `
    ((Resolve-IntegrationMode -Section @{ Enabled = $true }) -eq 'MANAGE')
Test-Assert 'Enabled = $false means DISABLED' `
    ((Resolve-IntegrationMode -Section @{ Enabled = $false }) -eq 'DISABLED')
Test-Assert 'An empty Mode falls through to Enabled' `
    ((Resolve-IntegrationMode -Section @{ Mode = ''; Enabled = $true }) -eq 'MANAGE')
Test-Assert 'The master switch turns everything off' `
    ((Resolve-IntegrationMode -Section @{ Mode = 'MANAGE' } -MasterEnabled $false) -eq 'DISABLED')
Test-Assert 'A missing section is DISABLED' `
    ((Resolve-IntegrationMode -Section $null) -eq 'DISABLED')
Test-Throws 'An unknown Mode is rejected by name' `
    { Resolve-IntegrationMode -Section @{ Mode = 'ENABLE' } } 'not valid'

# ============================================================= desktop shortcut
Test-Group 'Desktop shortcut - MANAGE'

Reset-Machine
$config = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{
        Mode = 'MANAGE'; Required = $true; Name = 'App'; Target = $appExe
        Arguments = '/fast'; WorkingDirectory = $workDir; Location = 'PublicDesktop'
        RemoveOnUninstall = $true
    }
}
$r = Install-WindowsIntegration -Config $config -LogFile $null

Test-Assert 'Install reports success' $r.Success ($r.Findings -join '; ')
Test-Assert 'Shortcut created on the Public Desktop' $script:Shortcuts.ContainsKey($desktopLnk)
Test-Assert 'Shortcut points at the target' ($script:Shortcuts[$desktopLnk].Target -eq $appExe)
Test-Assert 'Shortcut carries its arguments' ($script:Shortcuts[$desktopLnk].Arguments -eq '/fast')
Test-Assert 'Ownership recorded' (@($script:State.Resources).Count -eq 1)
Test-Assert 'Ownership records the shortcut path' (@($script:State.Resources)[0].Path -eq $desktopLnk)
Test-Assert 'Ownership records it as not pre-existing' (@($script:State.Resources)[0].PreExisting -eq $false)

Uninstall-WindowsIntegration -Config $config -LogFile $null | Out-Null
Test-Assert 'Uninstall removes the shortcut it created' (-not $script:Shortcuts.ContainsKey($desktopLnk))
Test-Assert 'Uninstall clears the state file' ($null -eq $script:State)

Test-Group 'Desktop shortcut - UserDesktop location'
Reset-Machine
$userConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'MANAGE'; Name = 'App'; Target = $appExe; Location = 'UserDesktop' }
}
Install-WindowsIntegration -Config $userConfig -LogFile $null | Out-Null
Test-Assert 'Shortcut honours Location = UserDesktop' `
    ($script:Shortcuts.ContainsKey($userDesktopLnk))

# ============================================================== Required
Test-Group 'Required semantics'

Reset-Machine
$requiredConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'MANAGE'; Required = $true; Name = 'App'; Target = $missingTarget }
}
$r = Install-WindowsIntegration -Config $requiredConfig -LogFile $null
Test-Assert 'A Required shortcut that cannot be created fails the install' $r.RequiredFailed
Test-Assert 'The failure names the missing target' (($r.Findings -join ' ') -match 'target does not exist')
Test-Assert 'Nothing was created' ($script:Shortcuts.Count -eq 0)

Reset-Machine
$optionalConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'MANAGE'; Required = $false; Name = 'App'; Target = $missingTarget }
}
$r = Install-WindowsIntegration -Config $optionalConfig -LogFile $null
Test-Assert 'An optional failure does not fail the install' (-not $r.RequiredFailed)
Test-Assert 'An optional failure is still reported' (-not $r.Success)

# ============================================================== VALIDATE mode
Test-Group 'VALIDATE - the installer owns the integration'

Reset-Machine
# The vendor installer created this, not the framework.
$script:Shortcuts[$desktopLnk] = @{ Target = $appExe; Arguments = ''; WorkingDirectory = ''; Icon = ''; Description = '' }

$validateConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'VALIDATE'; Name = 'App'; Target = $appExe }
}
$r = Install-WindowsIntegration -Config $validateConfig -LogFile $null
Test-Assert 'VALIDATE passes when the installer created it' $r.Success ($r.Findings -join '; ')
Test-Assert 'VALIDATE records no ownership' (@($script:State.Resources).Count -eq 0)

Uninstall-WindowsIntegration -Config $validateConfig -LogFile $null | Out-Null
Test-Assert "VALIDATE never removes the installer's shortcut" ($script:Shortcuts.ContainsKey($desktopLnk))

Reset-Machine
$r = Install-WindowsIntegration -Config $validateConfig -LogFile $null
Test-Assert 'VALIDATE reports a missing integration' (-not $r.Success)
Test-Assert 'VALIDATE creates nothing' ($script:Shortcuts.Count -eq 0)

# ============================================================== DISABLED mode
Test-Group 'DISABLED'

Reset-Machine
$disabledConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'DISABLED'; Name = 'App'; Target = $appExe }
}
$r = Install-WindowsIntegration -Config $disabledConfig -LogFile $null
Test-Assert 'DISABLED changes nothing' ($script:Shortcuts.Count -eq 0 -and $r.Success)

Reset-Machine
$masterOff = New-TestConfig @{
    Enabled = $false
    DesktopShortcut = @{ Mode = 'MANAGE'; Name = 'App'; Target = $appExe }
}
Install-WindowsIntegration -Config $masterOff -LogFile $null | Out-Null
Test-Assert 'The master switch overrides a MANAGE feature' ($script:Shortcuts.Count -eq 0)

# ========================================================= Start Menu folder
Test-Group 'Start Menu shortcut'

Reset-Machine
$smConfig = New-TestConfig @{
    Enabled = $true
    StartMenuShortcut = @{ Mode = 'MANAGE'; Name = 'App'; Target = $appExe; Folder = 'Company' }
}
Install-WindowsIntegration -Config $smConfig -LogFile $null | Out-Null
Test-Assert 'Start Menu shortcut lands in its configured subfolder' `
    ($script:Shortcuts.ContainsKey($startMenuLnk)) (($script:Shortcuts.Keys) -join ', ')

# =============================================================== context menu
Test-Group 'Context menu'

Reset-Machine
$cmConfig = New-TestConfig @{
    Enabled = $true
    ContextMenu = @{
        Mode = 'MANAGE'
        Entries = @(
            @{
                Name = 'Open with App'; Verb = 'Company.App.Open'; Target = 'FILE'
                Extensions = @('.abc', '.xyz'); Executable = $appExe; Arguments = '"%1"'
            }
        )
        RemoveOnUninstall = $true
    }
}
$r = Install-WindowsIntegration -Config $cmConfig -LogFile $null
$abcVerb = 'HKLM:\SOFTWARE\Classes\.abc\shell\Company.App.Open'
$xyzVerb = 'HKLM:\SOFTWARE\Classes\.xyz\shell\Company.App.Open'

Test-Assert 'Context menu install succeeds' $r.Success ($r.Findings -join '; ')
Test-Assert 'A verb key is created per extension' `
    ($script:Reg.ContainsKey($abcVerb) -and $script:Reg.ContainsKey($xyzVerb))
Test-Assert 'The verb carries its display name' ($script:Reg[$abcVerb]['(default)'] -eq 'Open with App')
Test-Assert 'The command passes the selected file as "%1"' `
    ($script:Reg["$abcVerb\command"]['(default)'] -eq ('"{0}" "%1"' -f $appExe)) $script:Reg["$abcVerb\command"]['(default)']
Test-Assert 'Both verb keys are recorded as owned' (@($script:State.Resources).Count -eq 2)
Test-Assert 'Explorer was notified' ($script:Notified -ge 1)

# Uninstall must take the verb and nothing above it.
$script:Reg['HKLM:\SOFTWARE\Classes\.abc'] = @{ '(default)' = 'SomeOtherHandler' }
$script:Reg['HKLM:\SOFTWARE\Classes\.abc\shell\Vendor.Other'] = @{ '(default)' = 'Another product' }
Uninstall-WindowsIntegration -Config $cmConfig -LogFile $null | Out-Null

Test-Assert 'Uninstall removes this package verb' (-not $script:Reg.ContainsKey($abcVerb))
Test-Assert "Uninstall leaves another product's verb alone" `
    ($script:Reg.ContainsKey('HKLM:\SOFTWARE\Classes\.abc\shell\Vendor.Other'))
Test-Assert 'Uninstall does not delete the extension key itself' `
    ($script:Reg.ContainsKey('HKLM:\SOFTWARE\Classes\.abc'))

Test-Group 'Context menu - targets and guard rails'

Reset-Machine
foreach ($case in @(
    @{ Target = 'FOLDER';    Key = 'HKLM:\SOFTWARE\Classes\Folder\shell\V' },
    @{ Target = 'DIRECTORY'; Key = 'HKLM:\SOFTWARE\Classes\Directory\shell\V' },
    @{ Target = 'ALL_FILES'; Key = 'HKLM:\SOFTWARE\Classes\*\shell\V' }
)) {
    Reset-Machine
    $c = New-TestConfig @{
        Enabled = $true
        ContextMenu = @{ Mode = 'MANAGE'; Entries = @(@{ Name = 'V'; Verb = 'V'; Target = $case.Target; Executable = $appExe }) }
    }
    Install-WindowsIntegration -Config $c -LogFile $null | Out-Null
    Test-Assert "Target $($case.Target) registers under $($case.Key)" ($script:Reg.ContainsKey($case.Key))
}

Reset-Machine
$noVerb = New-TestConfig @{
    Enabled = $true
    ContextMenu = @{ Mode = 'MANAGE'; Entries = @(@{ Name = 'X'; Executable = $appExe }) }
}
$r = Install-WindowsIntegration -Config $noVerb -LogFile $null
Test-Assert 'An entry with no Verb is refused' (-not $r.Success)
Test-Assert 'The refusal explains why a verb is needed' (($r.Findings -join ' ') -match 'application-specific verb')

Reset-Machine
$script:Reg['HKLM:\SOFTWARE\Classes\*\shell\Company.App.Open'] = @{ '(default)' = 'Vendor original' }
$clash = New-TestConfig @{
    Enabled = $true
    ContextMenu = @{ Mode = 'MANAGE'; Entries = @(@{ Name = 'Mine'; Verb = 'Company.App.Open'; Target = 'ALL_FILES'; Executable = $appExe }) }
}
Install-WindowsIntegration -Config $clash -LogFile $null | Out-Null
Test-Assert 'An existing verb is not overwritten' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\*\shell\Company.App.Open']['(default)'] -eq 'Vendor original')
Test-Assert 'An existing verb is not claimed as owned' (@($script:State.Resources).Count -eq 0)

# ========================================================== file associations
Test-Group 'File associations'

Reset-Machine
$faConfig = New-TestConfig @{
    Enabled = $true
    FileAssociations = @{
        Mode = 'MANAGE'
        SetAsDefault = $false
        Associations = @(
            @{ Extension = '.abc'; ProgId = 'Company.App'; Description = 'App File'; Executable = $appExe; Arguments = '"%1"' }
        )
        RemoveOnUninstall = $true
    }
}
$script:Reg['HKLM:\SOFTWARE\Classes\.abc'] = @{ '(default)' = 'Existing.Handler' }
$r = Install-WindowsIntegration -Config $faConfig -LogFile $null

Test-Assert 'File association install succeeds' $r.Success ($r.Findings -join '; ')
Test-Assert 'The ProgID is registered' ($script:Reg.ContainsKey('HKLM:\SOFTWARE\Classes\Company.App'))
Test-Assert 'The open command is registered' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\Company.App\shell\open\command']['(default)'] -eq ('"{0}" "%1"' -f $appExe))
Test-Assert 'The application is offered under Open With' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\.abc\OpenWithProgids'].ContainsKey('Company.App'))
Test-Assert 'The existing default handler is NOT taken over' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\.abc']['(default)'] -eq 'Existing.Handler')

Uninstall-WindowsIntegration -Config $faConfig -LogFile $null | Out-Null
Test-Assert 'Uninstall removes the ProgID it registered' (-not $script:Reg.ContainsKey('HKLM:\SOFTWARE\Classes\Company.App'))
Test-Assert 'Uninstall removes only its Open With entry' `
    (-not $script:Reg['HKLM:\SOFTWARE\Classes\.abc\OpenWithProgids'].ContainsKey('Company.App'))
Test-Assert 'Uninstall leaves the extension key in place' ($script:Reg.ContainsKey('HKLM:\SOFTWARE\Classes\.abc'))

Test-Group 'File associations - SetAsDefault restores the previous handler'

Reset-Machine
$script:Reg['HKLM:\SOFTWARE\Classes\.abc'] = @{ '(default)' = 'Existing.Handler' }
$defaultConfig = New-TestConfig @{
    Enabled = $true
    FileAssociations = @{
        Mode = 'MANAGE'; SetAsDefault = $true
        Associations = @(@{ Extension = '.abc'; ProgId = 'Company.App'; Executable = $appExe })
        RemoveOnUninstall = $true
    }
}
Install-WindowsIntegration -Config $defaultConfig -LogFile $null | Out-Null
Test-Assert 'SetAsDefault takes the extension over when asked' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\.abc']['(default)'] -eq 'Company.App')

Uninstall-WindowsIntegration -Config $defaultConfig -LogFile $null | Out-Null
Test-Assert 'Uninstall puts the previous handler back' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\.abc']['(default)'] -eq 'Existing.Handler') `
    $script:Reg['HKLM:\SOFTWARE\Classes\.abc']['(default)']

Test-Group 'File associations - the older OpenCommand form still works'

Reset-Machine
$legacyAssoc = New-TestConfig @{
    Enabled = $true
    FileAssociations = @{
        Mode = 'MANAGE'
        Associations = @(@{ Extension = '.abc'; ProgId = 'Company.App'; OpenCommand = '"C:\App\App.exe" "%1"'; IconPath = 'C:\App\App.exe,0' })
    }
}
Install-WindowsIntegration -Config $legacyAssoc -LogFile $null | Out-Null
Test-Assert 'OpenCommand is used when Executable is absent' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\Company.App\shell\open\command']['(default)'] -eq '"C:\App\App.exe" "%1"')
Test-Assert 'IconPath is honoured as the icon' `
    ($script:Reg['HKLM:\SOFTWARE\Classes\Company.App\DefaultIcon']['(default)'] -eq 'C:\App\App.exe,0')

# ==================================================================== services
Test-Group 'Services'

Reset-Machine
$svcConfig = New-TestConfig @{
    Enabled = $true
    Services = @{
        Mode = 'MANAGE'
        Services = @(@{ Name = 'AppSvc'; DisplayName = 'App Service'; Executable = $appExe; StartupType = 'Automatic'; StartAfterInstall = $true })
        RemoveOnUninstall = $true
    }
}
$r = Install-WindowsIntegration -Config $svcConfig -LogFile $null
Test-Assert 'Service is created' $script:Services.ContainsKey('AppSvc')
Test-Assert 'Service startup type is applied' ($script:Services['AppSvc'].StartupType -eq 'Automatic')
Test-Assert 'StartAfterInstall starts it' $script:Services['AppSvc'].Started

Uninstall-WindowsIntegration -Config $svcConfig -LogFile $null | Out-Null
Test-Assert 'Uninstall removes the service it created' (-not $script:Services.ContainsKey('AppSvc'))

Reset-Machine
$script:Services['AppSvc'] = @{ BinaryPath = 'C:\Vendor\svc.exe'; StartupType = 'Manual'; Started = $false }
Install-WindowsIntegration -Config $svcConfig -LogFile $null | Out-Null
Test-Assert "A service the installer created is left as it is" `
    ($script:Services['AppSvc'].BinaryPath -eq 'C:\Vendor\svc.exe')
Test-Assert 'A pre-existing service is not claimed as owned' (@($script:State.Resources).Count -eq 0)

Uninstall-WindowsIntegration -Config $svcConfig -LogFile $null | Out-Null
Test-Assert "Uninstall does not remove the installer's service" ($script:Services.ContainsKey('AppSvc'))

# ============================================================= scheduled tasks
Test-Group 'Scheduled tasks'

Reset-Machine
$taskConfig = New-TestConfig @{
    Enabled = $true
    ScheduledTasks = @{
        Mode = 'MANAGE'
        Tasks = @(@{ Name = 'AppUpdate'; Path = '\Company\'; Executable = $appExe; Trigger = 'AtStartup'; RunAsUser = 'SYSTEM'; RunLevel = 'Highest' })
        RemoveOnUninstall = $true
    }
}
Install-WindowsIntegration -Config $taskConfig -LogFile $null | Out-Null
Test-Assert 'Scheduled task is created at its configured path' $script:Tasks.ContainsKey('\Company\AppUpdate')
Test-Assert 'RunAsUser is honoured only because it was configured' ($script:Tasks['\Company\AppUpdate'].RunAsUser -eq 'SYSTEM')

Uninstall-WindowsIntegration -Config $taskConfig -LogFile $null | Out-Null
Test-Assert 'Uninstall removes the task it created' (-not $script:Tasks.ContainsKey('\Company\AppUpdate'))

Reset-Machine
$defaultTask = New-TestConfig @{
    Enabled = $true
    ScheduledTasks = @{ Mode = 'MANAGE'; Tasks = @(@{ Name = 'T'; Executable = $appExe }) }
}
Install-WindowsIntegration -Config $defaultTask -LogFile $null | Out-Null
Test-Assert 'A task with no RunAsUser does not silently become SYSTEM' `
    ($script:Tasks['\T'].RunAsUser -ne 'SYSTEM')

# ================================================================== ownership
Test-Group 'Ownership is what decides removal'

Reset-Machine
$ownershipConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'MANAGE'; Name = 'App'; Target = $appExe; RemoveOnUninstall = $true }
}
Install-WindowsIntegration -Config $ownershipConfig -LogFile $null | Out-Null
$script:State = $null   # the state file was wiped, or never written
Uninstall-WindowsIntegration -Config $ownershipConfig -LogFile $null | Out-Null
Test-Assert 'With no state file nothing is removed' ($script:Shortcuts.ContainsKey($desktopLnk)) `
    'ownership cannot be established, and deleting the wrong shortcut is not recoverable'

Reset-Machine
$keepConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'MANAGE'; Name = 'App'; Target = $appExe; RemoveOnUninstall = $false }
}
Install-WindowsIntegration -Config $keepConfig -LogFile $null | Out-Null
Uninstall-WindowsIntegration -Config $keepConfig -LogFile $null | Out-Null
Test-Assert 'RemoveOnUninstall = $false keeps the shortcut' ($script:Shortcuts.ContainsKey($desktopLnk))

# ==================================================================== dry run
Test-Group 'Dry run'

Reset-Machine
$dryConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut = @{ Mode = 'MANAGE'; Name = 'App'; Target = $appExe }
    ContextMenu = @{ Mode = 'MANAGE'; Entries = @(@{ Name = 'Open'; Verb = 'Company.App.Open'; Target = 'ALL_FILES'; Executable = $appExe }) }
}
$r = Install-WindowsIntegration -Config $dryConfig -LogFile $null -DryRun

Test-Assert 'Dry run creates no shortcut' ($script:Shortcuts.Count -eq 0)
Test-Assert 'Dry run writes no registry key' ($script:Reg.Count -eq 0)
Test-Assert 'Dry run records no state' ($null -eq $script:State)
Test-Assert 'Dry run does not notify Explorer' ($script:Notified -eq 0)

# ============================================================== plan summary
Test-Group 'Plan'

$planConfig = New-TestConfig @{
    Enabled = $true
    DesktopShortcut   = @{ Mode = 'MANAGE' }
    StartMenuShortcut = @{ Enabled = $true }
    ContextMenu       = @{ Mode = 'VALIDATE' }
    FileAssociations  = @{ Mode = 'DISABLED' }
}
$plan = Get-WindowsIntegrationPlan -Config $planConfig
Test-Assert 'Plan resolves an explicit Mode' ($plan.DesktopShortcut -eq 'MANAGE')
Test-Assert 'Plan resolves a legacy Enabled flag' ($plan.StartMenuShortcut -eq 'MANAGE')
Test-Assert 'Plan resolves VALIDATE' ($plan.ContextMenu -eq 'VALIDATE')
Test-Assert 'Plan resolves DISABLED' ($plan.FileAssociations -eq 'DISABLED')
Test-Assert 'Plan defaults an unmentioned feature to DISABLED' ($plan.Services -eq 'DISABLED')

# ============================================== configuration without the section
Test-Group 'Configurations that predate Windows integration'

Reset-Machine
$r = Install-WindowsIntegration -Config @{ ApplicationName = 'Old' } -LogFile $null
Test-Assert 'A configuration with no WindowsIntegration section is inert' `
    ($r.Success -and $script:Shortcuts.Count -eq 0 -and $script:Reg.Count -eq 0)

$r = Uninstall-WindowsIntegration -Config @{ ApplicationName = 'Old' } -LogFile $null
Test-Assert 'Uninstall with no WindowsIntegration section is inert' $r.Success

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
