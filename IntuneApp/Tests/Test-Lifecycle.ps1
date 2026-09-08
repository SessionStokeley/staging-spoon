#Requires -Version 5.1
<#
    Test-Lifecycle.ps1

    End-to-end tests of Install-EnvironmentConfig and Uninstall-EnvironmentConfig
    against an in-memory stand-in for the registry.

    Why this exists: the registry-backed tests in Test-Environment.ps1 only run
    elevated on Windows, so on every other machine the branching that decides
    what uninstall removes was never executed at all. Substituting the four
    persistence primitives lets the real orchestration logic run anywhere, which
    is where the interesting defects live.

    What is faked: reading and writing persisted values, the environment-change
    broadcast, and the state file. Everything above those - append versus
    replace, duplicate detection, ownership tracking, and every uninstall
    decision - is the real code under test.

    Run:
        pwsh -File Tests/Test-Lifecycle.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Lifecycle.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

. (Join-Path $AppRoot 'Helpers\Environment.ps1')

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

# --- In-memory stand-in for the persisted environment ---------------------
# Defined after the dot-source so these definitions win.

$script:Reg = @{ Machine = @{}; User = @{} }
$script:State = $null

function Get-PersistentVariable {
    param($Name, $Scope)
    if ($script:Reg[$Scope].ContainsKey($Name)) { return $script:Reg[$Scope][$Name] }
    return $null
}
function Set-PersistentVariable {
    param($Name, $Value, $Scope, [switch]$Expandable)
    $script:Reg[$Scope][$Name] = $Value
}
function Remove-PersistentVariable {
    param($Name, $Scope)
    $script:Reg[$Scope].Remove($Name)
}
function Get-PersistentPath {
    param($Scope)
    if ($script:Reg[$Scope].ContainsKey('Path')) { return $script:Reg[$Scope]['Path'] }
    return ''
}
function Set-PersistentPath {
    param($Scope, $Value)
    $script:Reg[$Scope]['Path'] = $Value
}
function Broadcast-EnvironmentChange {
    return @{ Success = $true; Message = '(broadcast suppressed in tests)' }
}

function Save-EnvironmentState {
    param($ApplicationName, $MachinePathEntries, $UserPathEntries, $EnvironmentVariables)
    # Round-tripped through JSON so records have the same PSCustomObject shape
    # the real state file produces. Reading them back is where the field-probe
    # defect lived.
    $script:State = (@{
        ApplicationName           = $ApplicationName
        MachinePathEntriesAdded   = $MachinePathEntries
        UserPathEntriesAdded      = $UserPathEntries
        EnvironmentVariablesAdded = $EnvironmentVariables
    } | ConvertTo-Json -Depth 5) | ConvertFrom-Json
    return 'in-memory'
}
function Get-EnvironmentState { param($ApplicationName) return $script:State }
function Remove-EnvironmentState { param($ApplicationName) $script:State = $null }

# --- Fixture --------------------------------------------------------------

# State belonging to the machine and to other software, which the package must
# never damage.
$script:OriginalPath      = '%SystemRoot%\system32;C:\Windows;C:\OtherApp\bin'
$script:OriginalClasspath = 'C:\Vendor\a.jar;C:\Vendor\b.jar'
$script:OriginalJavaHome  = 'C:\Existing\jdk'

function Reset-Machine {
    $script:Reg = @{ Machine = @{}; User = @{} }
    $script:State = $null
    $script:Reg.Machine['Path']      = $script:OriginalPath
    $script:Reg.Machine['CLASSPATH'] = $script:OriginalClasspath
    $script:Reg.Machine['JAVA_HOME'] = $script:OriginalJavaHome
}

$Config = @{
    ApplicationName = 'LifecycleApp'
    Environment = @{
        Enabled = $true
        SystemPath = @{
            Enabled = $true; Entries = @('C:\LifecycleApp\bin')
            AddIfMissing = $true; RemoveOnUninstall = $true
        }
        UserPath = @{ Enabled = $false; Entries = @(); RemoveOnUninstall = $true }
        Variables = @(
            @{ Name = 'CLASSPATH'; Value = 'C:\LifecycleApp\lib.jar'; Scope = 'Machine'; Mode = 'Append'; RemoveOnUninstall = $true }
            @{ Name = 'JAVA_HOME'; Value = 'C:\LifecycleApp\jdk';     Scope = 'Machine'; Mode = 'Set';    RemoveOnUninstall = $true }
            @{ Name = 'APP_ONLY';  Value = 'C:\LifecycleApp';         Scope = 'Machine'; Mode = 'Set';    RemoveOnUninstall = $true }
        )
        BroadcastChange = $false
    }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Environment Lifecycle Tests' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# =================================================== Install
Test-Group 'Install'

Reset-Machine
$installOk = Install-EnvironmentConfig -Config $Config -LogFile $null

Test-Assert 'Install reports success' $installOk
Test-Assert 'PATH gained the package entry' `
    ($script:Reg.Machine['Path'] -eq "$($script:OriginalPath);C:\LifecycleApp\bin") $script:Reg.Machine['Path']
Test-Assert 'PATH kept its expandable variables' ($script:Reg.Machine['Path'] -match '%SystemRoot%')
Test-Assert 'PATH kept the unrelated third-party entry' ($script:Reg.Machine['Path'] -match 'C:\\OtherApp\\bin')
Test-Assert 'Append kept both pre-existing jars' `
    ($script:Reg.Machine['CLASSPATH'] -eq "$($script:OriginalClasspath);C:\LifecycleApp\lib.jar") $script:Reg.Machine['CLASSPATH']
Test-Assert 'Append used a semicolon separator' (@(Split-PathString $script:Reg.Machine['CLASSPATH']).Count -eq 3)
Test-Assert 'Set replaced the single-value variable' ($script:Reg.Machine['JAVA_HOME'] -eq 'C:\LifecycleApp\jdk')
Test-Assert 'A new variable was created' ($script:Reg.Machine['APP_ONLY'] -eq 'C:\LifecycleApp')
Test-Assert 'Install recorded all three variables' (@($script:State.EnvironmentVariablesAdded).Count -eq 3)

$javaRecord = @($script:State.EnvironmentVariablesAdded | Where-Object { $_.Name -eq 'JAVA_HOME' })[0]
Test-Assert 'State recorded that JAVA_HOME pre-existed' ($javaRecord.Existed -eq $true)
Test-Assert 'State recorded the replaced value' ($javaRecord.PreviousValue -eq $script:OriginalJavaHome)

# =================================================== Idempotency
Test-Group 'Re-running the install'

$pathAfterFirst = $script:Reg.Machine['Path']
$cpAfterFirst = $script:Reg.Machine['CLASSPATH']
Install-EnvironmentConfig -Config $Config -LogFile $null | Out-Null

Test-Assert 'PATH is not duplicated' ($script:Reg.Machine['Path'] -eq $pathAfterFirst) $script:Reg.Machine['Path']
Test-Assert 'Appended entry is not duplicated' ($script:Reg.Machine['CLASSPATH'] -eq $cpAfterFirst) $script:Reg.Machine['CLASSPATH']

# =================================================== Uninstall with state
Test-Group 'Uninstall with install state recorded'

Reset-Machine
Install-EnvironmentConfig -Config $Config -LogFile $null | Out-Null
Uninstall-EnvironmentConfig -Config $Config -LogFile $null | Out-Null

Test-Assert 'PATH restored exactly' ($script:Reg.Machine['Path'] -eq $script:OriginalPath) $script:Reg.Machine['Path']
Test-Assert 'CLASSPATH restored exactly' ($script:Reg.Machine['CLASSPATH'] -eq $script:OriginalClasspath) $script:Reg.Machine['CLASSPATH']
Test-Assert 'Replaced JAVA_HOME restored to its original value' `
    ($script:Reg.Machine['JAVA_HOME'] -eq $script:OriginalJavaHome) $script:Reg.Machine['JAVA_HOME']
Test-Assert 'Package-created variable deleted' (-not $script:Reg.Machine.ContainsKey('APP_ONLY'))
Test-Assert 'State file cleared' ($null -eq $script:State)

# =================================================== Uninstall without state
Test-Group 'Uninstall with no install state (ownership unknown)'

# The state file can be missing: wiped, never written, or the install happened
# under a different package name. Nothing that pre-existed may be destroyed.
Reset-Machine
Install-EnvironmentConfig -Config $Config -LogFile $null | Out-Null
$script:State = $null
Uninstall-EnvironmentConfig -Config $Config -LogFile $null | Out-Null

Test-Assert 'PATH still restored' ($script:Reg.Machine['Path'] -eq $script:OriginalPath) $script:Reg.Machine['Path']
Test-Assert 'Pre-existing jars survive' `
    ($script:Reg.Machine['CLASSPATH'] -eq $script:OriginalClasspath) $script:Reg.Machine['CLASSPATH']
Test-Assert 'CLASSPATH itself is not deleted' ($script:Reg.Machine.ContainsKey('CLASSPATH'))
# Holding this package's value proves it wrote the variable, not that it
# created it. Deleting here would destroy a pre-existing JAVA_HOME.
Test-Assert 'A replaced variable is never deleted without state' `
    ($script:Reg.Machine.ContainsKey('JAVA_HOME')) 'deleting would destroy a variable that was already on the machine'
Test-Assert 'An ambiguous variable is left rather than deleted' `
    ($script:Reg.Machine.ContainsKey('APP_ONLY')) 'created and replaced are indistinguishable without state; leaving is recoverable'

# =================================================== Append-created variable
Test-Group 'Append to a variable that does not exist'

Reset-Machine
$script:Reg.Machine.Remove('CLASSPATH')
Install-EnvironmentConfig -Config $Config -LogFile $null | Out-Null
Test-Assert 'Created list has no leading separator' `
    ($script:Reg.Machine['CLASSPATH'] -eq 'C:\LifecycleApp\lib.jar') $script:Reg.Machine['CLASSPATH']

Uninstall-EnvironmentConfig -Config $Config -LogFile $null | Out-Null
Test-Assert 'A list variable this package created is removed' (-not $script:Reg.Machine.ContainsKey('CLASSPATH'))

# =================================================== Disabled section
Test-Group 'Environment section disabled'

Reset-Machine
$disabled = @{ ApplicationName = 'X'; Environment = @{ Enabled = $false } }
Install-EnvironmentConfig -Config $disabled -LogFile $null | Out-Null
Test-Assert 'A disabled Environment section changes nothing' `
    ($script:Reg.Machine['Path'] -eq $script:OriginalPath -and
     $script:Reg.Machine['CLASSPATH'] -eq $script:OriginalClasspath)

# A configuration with no Environment section at all must be inert.
Reset-Machine
Install-EnvironmentConfig -Config @{ ApplicationName = 'X' } -LogFile $null | Out-Null
Test-Assert 'A configuration with no Environment section changes nothing' `
    ($script:Reg.Machine['Path'] -eq $script:OriginalPath)

# =================================================== Summary
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
