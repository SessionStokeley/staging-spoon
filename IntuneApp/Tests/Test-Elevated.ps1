#Requires -Version 5.1
<#
    Test-Elevated.ps1

    The parts that can only be tested against a real Windows machine: the
    registry, shell and service primitives themselves.

    Everything above those primitives - which mode applies, what is recorded
    as owned, what uninstall is allowed to remove - runs on any platform in
    Test-Lifecycle.ps1 and Test-Integration.ps1, against in-memory stand-ins.
    That leaves exactly one gap, which is whether the primitives do what the
    stand-ins pretend they do. This closes it.

    Requires Windows and administrator or SYSTEM rights. Anywhere else, every
    check reports [SKIP] with the reason. A skip is never counted as a pass.

    Safety
    ------
    This writes to the real machine PATH and the real HKLM\SOFTWARE\Classes.
    Three things keep that safe:

      * Every name is unique to this run, so nothing can collide with real
        software.
      * The original PATH and every variable touched are captured before the
        first write and restored in a finally block, whether the run passes,
        fails or throws.
      * The final check compares the PATH byte for byte against the snapshot,
        so a restore that did not fully work is itself a failure rather than
        something the next person discovers.

    Run (elevated):
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Elevated.ps1
        pwsh -File Tests/Test-Elevated.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

. (Join-Path $AppRoot 'Helpers\Environment.ps1')
. (Join-Path $AppRoot 'Helpers\WindowsIntegration.ps1')

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
Write-Host 'Elevated Windows Tests' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# ------------------------------------------------------------ capability probe

$isWindows51OrCore = $false
$isAdmin = $false
$isSystem = $false
$identityName = '(unknown)'

# The Windows principal APIs throw outright on other platforms.
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $identityName = $identity.Name
    $isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSystem = ($identity.Name -eq 'NT AUTHORITY\SYSTEM')
    $isWindows51OrCore = $true
}
catch {
    $isWindows51OrCore = $false
}

$edition = $PSVersionTable.PSEdition
$version = $PSVersionTable.PSVersion
Write-Host "  PowerShell : $version ($edition)" -ForegroundColor DarkGray
Write-Host "  Identity   : $identityName" -ForegroundColor DarkGray
Write-Host "  Windows    : $isWindows51OrCore" -ForegroundColor DarkGray
Write-Host "  Elevated   : $($isAdmin -or $isSystem)" -ForegroundColor DarkGray

# The elevated branch below only runs on an elevated Windows session, so a
# call to a function that does not exist would sit undetected everywhere else
# until someone ran this on Windows. This check runs on every platform.
Test-Group 'Dependencies (checked everywhere)'

$requiredFunctions = @(
    'Get-PersistentPath', 'Set-PersistentPath', 'Get-PersistentPathKind',
    'Get-PersistentVariable', 'Set-PersistentVariable', 'Remove-PersistentVariable',
    'Add-PathEntry', 'Remove-PathEntry', 'Test-PathEntry',
    'Split-PathString', 'Test-PathEntriesEqual',
    'Add-EnvironmentVariable', 'Remove-EnvironmentVariable',
    'Broadcast-EnvironmentChange',
    'Save-EnvironmentState', 'Get-EnvironmentState', 'Remove-EnvironmentState',
    'New-ShortcutFile', 'Test-ShortcutFile', 'Remove-ShortcutFile',
    'Test-IntegrationRegistryKey', 'Set-IntegrationRegistryValue',
    'Get-IntegrationRegistryValue', 'Remove-IntegrationRegistryKey',
    'Save-IntegrationState', 'Get-IntegrationState', 'Remove-IntegrationState'
)
$undefinedFunctions = @($requiredFunctions | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
Test-Assert "All $($requiredFunctions.Count) primitives this suite exercises are defined" `
    ($undefinedFunctions.Count -eq 0) ("undefined: " + ($undefinedFunctions -join ', '))

$elevatedChecks = @(
    'PATH modification',
    'PATH deduplication',
    'REG_EXPAND_SZ preservation',
    'Environment variables',
    'Environment refresh broadcast',
    'Ownership tracking',
    'Cleanup',
    'Shortcut primitives',
    'Registry verb primitives'
)

if (-not $isWindows51OrCore) {
    Test-Group 'Elevated Windows checks'
    foreach ($check in $elevatedChecks) {
        Test-Skip "Elevated Windows test - $check" 'not running on Windows'
    }
    Write-Host ''
    Write-Host '  The logic these would cover runs on this platform already:' -ForegroundColor DarkGray
    Write-Host '    Test-Lifecycle.ps1    install/uninstall orchestration and ownership' -ForegroundColor DarkGray
    Write-Host '    Test-Integration.ps1  Windows integration modes and ownership' -ForegroundColor DarkGray
    Write-Host '    Test-Environment.ps1  path normalization and list semantics' -ForegroundColor DarkGray
    Write-Host '  What is not covered anywhere but here: the primitives themselves.' -ForegroundColor DarkGray
}
elseif (-not ($isAdmin -or $isSystem)) {
    Test-Group 'Elevated Windows checks'
    foreach ($check in $elevatedChecks) {
        Test-Skip "Elevated Windows test - $check" 'running on Windows, but not elevated. Re-run as administrator.'
    }
}
else {
    # ================================================= the real thing
    $runId = "IntuneElevTest_$(Get-Random)"
    $testEntry = "C:\$runId\bin"
    $secondEntry = "C:\$runId\tools"
    $varName = "INTUNE_TEST_$runId"
    $listVarName = "INTUNE_LIST_$runId"
    $verbKey = "HKLM:\SOFTWARE\Classes\*\shell\$runId.Open"
    $shortcutDir = Join-Path ([System.IO.Path]::GetTempPath()) $runId
    $shortcutPath = Join-Path $shortcutDir 'Elevated.lnk'

    # Captured before anything is written, restored in the finally block.
    $originalPath = Get-PersistentPath -Scope 'Machine'
    $originalListVar = Get-PersistentVariable -Name $listVarName -Scope 'Machine'

    try {
        # ------------------------------------------------ PATH modification
        Test-Group 'PATH modification'

        $add = Add-PathEntry -Entry $testEntry -Scope 'Machine'
        Test-Assert 'A PATH entry is added' ($add.Success -and $add.Action -eq 'Added') $add.Message
        Test-Assert 'The added entry reads back' (Test-PathEntry -Entry $testEntry -Scope 'Machine')

        # ----------------------------------------------- PATH deduplication
        Test-Group 'PATH deduplication'

        $again = Add-PathEntry -Entry $testEntry -Scope 'Machine'
        Test-Assert 'Adding the same entry twice is a no-op' ($again.Action -eq 'AlreadyExists') $again.Message

        $trailing = Add-PathEntry -Entry "$testEntry\" -Scope 'Machine'
        Test-Assert 'A trailing separator is recognised as the same entry' `
            ($trailing.Action -eq 'AlreadyExists') $trailing.Message

        $cased = Add-PathEntry -Entry $testEntry.ToUpper() -Scope 'Machine'
        Test-Assert 'A different case is recognised as the same entry' `
            ($cased.Action -eq 'AlreadyExists') $cased.Message

        $occurrences = @(Split-PathString (Get-PersistentPath -Scope 'Machine') |
            Where-Object { Test-PathEntriesEqual $_ $testEntry })
        Test-Assert 'The entry appears exactly once' ($occurrences.Count -eq 1) "found $($occurrences.Count)"

        # --------------------------------------- REG_EXPAND_SZ preservation
        Test-Group 'REG_EXPAND_SZ preservation'

        $rawPath = Get-PersistentPath -Scope 'Machine'
        $expandedPath = [Environment]::ExpandEnvironmentVariables($rawPath)

        if ($originalPath -match '%') {
            Test-Assert 'The PATH is read unexpanded' ($rawPath -ne $expandedPath) `
                'a raw read must differ from an expanded one, or %VAR% tokens were lost'
            $originalTokens = @([regex]::Matches($originalPath, '%[^%]+%') | ForEach-Object { $_.Value })
            $survivors = @($originalTokens | Where-Object { $rawPath -like "*$_*" })
            Test-Assert 'Every %VAR% token survived a PATH write' `
                ($survivors.Count -eq $originalTokens.Count) `
                "$($survivors.Count) of $($originalTokens.Count) survived"
        }
        else {
            Test-Skip 'REG_EXPAND_SZ preservation' 'this machine PATH contains no %VAR% tokens to preserve'
        }

        $kind = Get-PersistentPathKind -Scope 'Machine'
        Test-Assert 'The PATH value kind is not downgraded to REG_SZ' `
            ($kind -ne [Microsoft.Win32.RegistryValueKind]::String) "kind is $kind"

        # ------------------------------------------- environment variables
        Test-Group 'Environment variables'

        $created = Add-EnvironmentVariable -Name $varName -Value 'C:\First' -Scope 'Machine' -Mode 'Set'
        Test-Assert 'A new variable is created' ($created.Action -eq 'Created') $created.Message
        Test-Assert 'The variable reads back' `
            ((Get-PersistentVariable -Name $varName -Scope 'Machine') -eq 'C:\First')
        Test-Assert 'Creation records that it did not exist before' ($created.Existed -eq $false)

        $replaced = Add-EnvironmentVariable -Name $varName -Value 'C:\Second' -Scope 'Machine' -Mode 'Set'
        Test-Assert 'An existing variable is replaced' ($replaced.Action -eq 'Replaced') $replaced.Message
        Test-Assert 'Replacement records the previous value' ($replaced.PreviousValue -eq 'C:\First')

        Set-PersistentVariable -Name $listVarName -Value 'C:\Vendor\a.jar' -Scope 'Machine'
        $appended = Add-EnvironmentVariable -Name $listVarName -Value 'C:\Mine\b.jar' -Scope 'Machine' -Mode 'Append'
        Test-Assert 'Append keeps the existing entry' `
            ((Get-PersistentVariable -Name $listVarName -Scope 'Machine') -eq 'C:\Vendor\a.jar;C:\Mine\b.jar') `
            (Get-PersistentVariable -Name $listVarName -Scope 'Machine')

        $appendAgain = Add-EnvironmentVariable -Name $listVarName -Value 'C:\Mine\b.jar' -Scope 'Machine' -Mode 'Append'
        Test-Assert 'Append is idempotent' `
            ((Get-PersistentVariable -Name $listVarName -Scope 'Machine') -eq 'C:\Vendor\a.jar;C:\Mine\b.jar')

        $expandable = Add-EnvironmentVariable -Name "${varName}_EXP" -Value '%ProgramFiles%\App' `
            -Scope 'Machine' -Mode 'Set' -Expandable
        Test-Assert 'An expandable value is stored unexpanded' `
            ((Get-PersistentVariable -Name "${varName}_EXP" -Scope 'Machine') -eq '%ProgramFiles%\App') `
            (Get-PersistentVariable -Name "${varName}_EXP" -Scope 'Machine')

        # -------------------------------------- environment refresh broadcast
        Test-Group 'Environment refresh'

        $broadcast = Broadcast-EnvironmentChange
        Test-Assert 'WM_SETTINGCHANGE is broadcast' $broadcast.Success $broadcast.Message

        # ------------------------------------------------- shortcut primitives
        Test-Group 'Shortcut primitives'

        New-Item -Path $shortcutDir -ItemType Directory -Force | Out-Null
        $shortcutTarget = Join-Path $env:SystemRoot 'System32\notepad.exe'

        if (Test-Path -LiteralPath $shortcutTarget) {
            New-ShortcutFile -Path $shortcutPath -Target $shortcutTarget `
                -Arguments '/test' -WorkingDirectory $shortcutDir -Description 'Elevated test'

            $check = Test-ShortcutFile -Path $shortcutPath -ExpectedTarget $shortcutTarget
            Test-Assert 'A real .lnk is created' $check.Exists
            Test-Assert 'The .lnk points at its target' $check.TargetMatches $check.Target

            Remove-ShortcutFile -Path $shortcutPath
            Test-Assert 'The .lnk is removed' (-not (Test-ShortcutFile -Path $shortcutPath).Exists)
        }
        else {
            Test-Skip 'Shortcut primitives' 'notepad.exe was not found to point a shortcut at'
        }

        # ------------------------------------------- registry verb primitives
        Test-Group 'Registry verb primitives'

        Test-Assert 'A verb key does not exist before it is created' `
            (-not (Test-IntegrationRegistryKey -Path $verbKey))

        Set-IntegrationRegistryValue -Path $verbKey -Name '' -Value 'Open with test'
        Set-IntegrationRegistryValue -Path "$verbKey\command" -Name '' -Value '"C:\App\App.exe" "%1"'

        Test-Assert 'The verb key is created' (Test-IntegrationRegistryKey -Path $verbKey)
        Test-Assert 'The verb default value reads back' `
            ((Get-IntegrationRegistryValue -Path $verbKey -Name '') -eq 'Open with test')
        Test-Assert 'The command subkey reads back' `
            ((Get-IntegrationRegistryValue -Path "$verbKey\command" -Name '') -eq '"C:\App\App.exe" "%1"')

        Remove-IntegrationRegistryKey -Path $verbKey
        Test-Assert 'The verb key and its subtree are removed' `
            (-not (Test-IntegrationRegistryKey -Path $verbKey))
        Test-Assert 'Classes\* itself is untouched' `
            (Test-IntegrationRegistryKey -Path 'HKLM:\SOFTWARE\Classes\*')

        # --------------------------------------------------- ownership tracking
        Test-Group 'Ownership tracking'

        $stateApp = "ElevatedTest_$runId"
        $statePath = Save-EnvironmentState -ApplicationName $stateApp `
            -MachinePathEntries @($testEntry) -UserPathEntries @() `
            -EnvironmentVariables @(@{ Name = $varName; Value = 'C:\Second'; Scope = 'Machine'; Mode = 'Set'; Existed = $false; PreviousValue = $null })

        Test-Assert 'The state file is written' (Test-Path -LiteralPath $statePath) $statePath

        $state = Get-EnvironmentState -ApplicationName $stateApp
        Test-Assert 'The state file reads back' ($null -ne $state)
        Test-Assert 'The state records the PATH entry' `
            (@($state.MachinePathEntriesAdded) -contains $testEntry)
        Test-Assert 'The state records the variable and its ownership' `
            (@($state.EnvironmentVariablesAdded)[0].Name -eq $varName -and
             @($state.EnvironmentVariablesAdded)[0].Existed -eq $false)

        $integrationState = Save-IntegrationState -ApplicationName $stateApp `
            -Resources @(@{ Kind = 'Shortcut'; Path = $shortcutPath; Feature = 'DesktopShortcut'; PreExisting = $false })
        Test-Assert 'The integration state file is written' (Test-Path -LiteralPath $integrationState)
        Test-Assert 'The integration state records the owned resource' `
            (@((Get-IntegrationState -ApplicationName $stateApp).Resources)[0].Path -eq $shortcutPath)

        # ------------------------------------------------------------ cleanup
        Test-Group 'Cleanup'

        Remove-EnvironmentState -ApplicationName $stateApp
        Test-Assert 'The environment state file is removed' (-not (Test-Path -LiteralPath $statePath))
        Remove-IntegrationState -ApplicationName $stateApp
        Test-Assert 'The integration state file is removed' (-not (Test-Path -LiteralPath $integrationState))

        $removed = Remove-PathEntry -Entry $testEntry -Scope 'Machine'
        Test-Assert 'The PATH entry is removed' ($removed.Success) $removed.Message
        Test-Assert 'The removed entry no longer resolves' (-not (Test-PathEntry -Entry $testEntry -Scope 'Machine'))

        $unknownRemoval = Remove-EnvironmentVariable -Name $listVarName -Scope 'Machine' -Mode 'Set' `
            -Value 'C:\Vendor\a.jar;C:\Mine\b.jar' -Existed $false -PreviousValue $null -OwnershipUnknown
        Test-Assert 'Set mode with unknown ownership never deletes' `
            ($unknownRemoval.Action -eq 'Skipped' -and
             $null -ne (Get-PersistentVariable -Name $listVarName -Scope 'Machine')) `
            "Action was $($unknownRemoval.Action)"
    }
    finally {
        # ---------------------------------------------------------- restore
        # Runs whatever happened above, so a failure never leaves the machine
        # modified.
        Write-Host ''
        Write-Host 'Restoring the machine...' -ForegroundColor DarkGray

        try { Set-PersistentPath -Scope 'Machine' -Value $originalPath } catch { Write-Host "  PATH restore failed: $($_.Exception.Message)" -ForegroundColor Red }

        foreach ($name in @($varName, "${varName}_EXP")) {
            try { Remove-PersistentVariable -Name $name -Scope 'Machine' } catch { }
        }

        try {
            if ($null -eq $originalListVar) { Remove-PersistentVariable -Name $listVarName -Scope 'Machine' }
            else { Set-PersistentVariable -Name $listVarName -Value $originalListVar -Scope 'Machine' }
        }
        catch { }

        try { Remove-IntegrationRegistryKey -Path $verbKey } catch { }
        try { Remove-Item $shortcutDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-EnvironmentState -ApplicationName "ElevatedTest_$runId" } catch { }
        try { Remove-IntegrationState -ApplicationName "ElevatedTest_$runId" } catch { }

        # A restore that did not fully work is a failure in its own right.
        Test-Group 'Restore'
        $finalPath = Get-PersistentPath -Scope 'Machine'
        Test-Assert 'The machine PATH is restored byte for byte' ($finalPath -eq $originalPath) `
            "length before $($originalPath.Length), after $($finalPath.Length)"
        Test-Assert 'No test variable is left behind' `
            ($null -eq (Get-PersistentVariable -Name $varName -Scope 'Machine') -and
             $null -eq (Get-PersistentVariable -Name "${varName}_EXP" -Scope 'Machine'))
        Test-Assert 'No test registry key is left behind' (-not (Test-IntegrationRegistryKey -Path $verbKey))

        Broadcast-EnvironmentChange | Out-Null
    }
}

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
