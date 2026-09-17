#Requires -Version 5.1

<#
    WindowsIntegration.ps1

    Creates, validates and removes the Windows integrations a packaged
    application needs: desktop and Start Menu shortcuts, Explorer context-menu
    verbs, file associations, services and scheduled tasks.

    Three states, per feature
    ------------------------
      DISABLED  the framework does nothing at all.
      VALIDATE  the framework checks that the installer created the
                integration, and reports. It never creates and never removes.
      MANAGE    the framework creates the integration, validates it, records
                that it owns it, and removes it on uninstall.

    Most commercial installers already create their own shortcuts and
    associations. Forcing the framework to own them would duplicate what is
    there and then delete the vendor's copy on uninstall, so VALIDATE is the
    honest default for anything an installer normally handles.

    Ownership
    ---------
    Nothing is removed unless this package's own state file says this package
    created it. A resource that already existed when MANAGE first ran is
    recorded as pre-existing and is left alone at uninstall, because deleting
    another product's shortcut or registry verb is not recoverable.

    Testability
    -----------
    Every operation that touches the machine goes through a named primitive
    (New-ShortcutFile, Set-IntegrationRegistryValue, New-IntegrationService
    and so on). PowerShell resolves those at call time, so the test suite
    substitutes in-memory versions and the real orchestration runs on any
    platform - the same approach Test-Lifecycle.ps1 uses for the registry.

    Windows PowerShell 5.1 only. No PowerShell 7 syntax or cmdlets.
#>

# Install.ps1 and Uninstall.ps1 define Write-Log. This fallback keeps the
# helper usable when it is dot-sourced anywhere else.
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param([string]$Message, [string]$LogFile)
        if (-not $LogFile) { return }
        $entry = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        $entry | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
}

$script:IntegrationClassesRoot = 'HKLM:\SOFTWARE\Classes'

# ---------------------------------------------------------------- utilities

function Get-IntegrationField {
    <#
        Reads a field from a record that may be a hashtable (from the .psd1)
        or a PSCustomObject (from the JSON state file). A hashtable's keys are
        not PSObject properties, so one probe cannot serve both shapes.
    #>
    param(
        [AllowNull()]$Record,
        [Parameter(Mandatory)][string]$Field,
        $Default = $null
    )

    if ($null -eq $Record) { return $Default }

    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Field)) { return $Record[$Field] }
        return $Default
    }

    $property = $Record.PSObject.Properties[$Field]
    if ($property) { return $property.Value }
    return $Default
}

function Resolve-IntegrationMode {
    <#
        .SYNOPSIS
        Decides whether a feature is DISABLED, VALIDATE or MANAGE.

        .DESCRIPTION
        Mode wins when it is set. Otherwise the older Enabled flag is honoured,
        where $true means MANAGE - which is what a configuration written before
        modes existed meant by it. The master WindowsIntegration.Enabled switch
        turns everything off regardless.

        Studio/ConfigValidator.ps1 and Studio/Preview.ps1 mirror this rule.
        They are deliberately kept free of any dependency on the execution
        engine, so the rule is stated in both places rather than shared.
    #>
    param(
        [AllowNull()]$Section,
        [bool]$MasterEnabled = $true
    )

    if (-not $MasterEnabled) { return 'DISABLED' }
    if ($null -eq $Section) { return 'DISABLED' }

    $mode = [string](Get-IntegrationField -Record $Section -Field 'Mode')
    if ($mode) {
        $upper = $mode.ToUpper()
        if ($upper -in @('DISABLED', 'VALIDATE', 'MANAGE')) { return $upper }
        throw "WindowsIntegration Mode '$mode' is not valid. Use DISABLED, VALIDATE or MANAGE."
    }

    $enabled = Get-IntegrationField -Record $Section -Field 'Enabled' -Default $false
    if ($enabled) { return 'MANAGE' }
    return 'DISABLED'
}

function Write-IntegrationPlan {
    <#
        Dry-run output. Goes to the host as well as the log, because the point
        of a dry run is that the operator reads it now.
    #>
    param([string]$Message, [string]$LogFile)
    Write-Host "[DRY-RUN] $Message"
    Write-Log "[DRY-RUN] $Message" $LogFile
}

# ------------------------------------------------------------- shell folders

function Join-WindowsPath {
    <#
        Joins Windows path segments as text.

        Join-Path resolves through the PowerShell provider and fails with
        "Cannot find drive" when the drive does not exist - which is every
        C:\ path on a non-Windows host, so a dry run could not even print its
        plan. These are Windows shell paths by definition, so joining them as
        strings is both correct and portable.
    #>
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    return ($Parent.TrimEnd('\', '/') + '\' + $Child.TrimStart('\', '/'))
}

function Get-ShellFolderPath {
    <#
        Resolves the well-known folders shortcuts are written into.

        Intune runs as SYSTEM, where "the current user" is not a real person's
        profile, so the all-users locations are the ones that produce a
        shortcut every user can see. That is why PublicDesktop and AllUsers are
        the defaults.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PublicDesktop', 'UserDesktop', 'AllUsersStartMenu', 'UserStartMenu')]
        [string]$Name
    )

    if ($Name -eq 'PublicDesktop') {
        $public = [Environment]::GetEnvironmentVariable('PUBLIC')
        if (-not $public) { $public = 'C:\Users\Public' }
        return (Join-WindowsPath $public 'Desktop')
    }
    if ($Name -eq 'UserDesktop') {
        return [Environment]::GetFolderPath('DesktopDirectory')
    }
    if ($Name -eq 'AllUsersStartMenu') {
        $programData = [Environment]::GetEnvironmentVariable('ProgramData')
        if (-not $programData) { $programData = 'C:\ProgramData' }
        return (Join-WindowsPath $programData 'Microsoft\Windows\Start Menu\Programs')
    }
    return (Join-WindowsPath ([Environment]::GetFolderPath('StartMenu')) 'Programs')
}

# ------------------------------------------------------------ shortcut files

function New-ShortcutFile {
    <#
        Writes a .lnk through WScript.Shell, which exists on every supported
        Windows build and needs no module import. Present on 5.1 and 7 alike.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$Icon = '',
        [string]$Description = ''
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $Target
        if ($Arguments)        { $shortcut.Arguments = $Arguments }
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
        if ($Description)      { $shortcut.Description = $Description }
        if ($Icon)             { $shortcut.IconLocation = $Icon }
        $shortcut.Save()
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Test-ShortcutFile {
    <#
        Returns @{ Exists; Target; TargetMatches }. TargetMatches is only
        meaningful when Exists is true.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedTarget = ''
    )

    $exists = $false
    try { $exists = Test-Path -LiteralPath $Path }
    catch { $exists = $false }

    if (-not $exists) {
        return @{ Exists = $false; Target = ''; TargetMatches = $false }
    }

    $target = ''
    try {
        $shell = New-Object -ComObject WScript.Shell
        try { $target = [string]$shell.CreateShortcut($Path).TargetPath }
        finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    catch {
        $target = ''
    }

    $matches = $true
    if ($ExpectedTarget) {
        $matches = $target.TrimEnd('\').Equals($ExpectedTarget.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    }
    return @{ Exists = $true; Target = $target; TargetMatches = $matches }
}

function Remove-ShortcutFile {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}

# ---------------------------------------------------------------- registry

function Test-IntegrationRegistryKey {
    param([Parameter(Mandatory)][string]$Path)
    # An unreachable registry provider means the key is not there, which is
    # the honest answer; it must not abort the caller.
    try { return [bool](Test-Path -LiteralPath $Path) }
    catch { return $false }
}

function Set-IntegrationRegistryValue {
    <#
        Writes one value, creating the key path if needed. An empty Name means
        the key's default value, which is what shell verbs and ProgIDs use.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Name = '',
        [AllowNull()]$Value = '',
        [string]$Type = 'String'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $valueName = $Name
    if (-not $valueName) { $valueName = '(default)' }
    New-ItemProperty -LiteralPath $Path -Name $valueName -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-IntegrationRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Name = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $valueName = $Name
    if (-not $valueName) { $valueName = '(default)' }
    $item = Get-ItemProperty -LiteralPath $Path -Name $valueName -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    return $item.$valueName
}

function Remove-IntegrationRegistryKey {
    <#
        Removes one key and the subtree beneath it.

        Callers only ever pass a key this package created - a verb key named
        after the application's own verb, or a ProgID it registered. Nothing
        here is ever pointed at a shared parent such as Classes\* or
        Classes\Directory, which would take unrelated software with it.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Remove-IntegrationRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    if (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Update-ShellNotification {
    <#
        Tells Explorer that file associations changed, so new verbs appear
        without a sign-out. SHCHANGENOTIFY / SHCNE_ASSOCCHANGED.

        Explorer is never restarted here. Killing it closes the user's open
        windows, and a packaging framework has no business doing that unless
        the configuration explicitly asks.
    #>
    param()

    $signature = @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
'@
    try {
        if (-not ('IntuneShellNotify' -as [type])) {
            Add-Type -MemberDefinition $signature -Name 'IntuneShellNotify' -Namespace 'Win32' | Out-Null
        }
        [Win32.IntuneShellNotify]::SHChangeNotify(0x08000000, 0x0000, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
        return @{ Success = $true; Message = 'Notified Explorer that associations changed.' }
    }
    catch {
        return @{ Success = $false; Message = "Could not notify Explorer: $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------- services

function Test-IntegrationService {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ Exists = $false; Status = ''; StartType = '' } }
    return @{ Exists = $true; Status = [string]$svc.Status; StartType = [string]$svc.StartType }
}

function New-IntegrationService {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BinaryPath,
        [string]$DisplayName = '',
        [string]$Description = '',
        [string]$StartupType = 'Manual'
    )

    $display = $DisplayName
    if (-not $display) { $display = $Name }

    New-Service -Name $Name -BinaryPathName $BinaryPath -DisplayName $display `
        -StartupType $StartupType -ErrorAction Stop | Out-Null

    if ($Description) {
        Set-Service -Name $Name -Description $Description -ErrorAction SilentlyContinue
    }
}

function Start-IntegrationService {
    param([Parameter(Mandatory)][string]$Name)
    Start-Service -Name $Name -ErrorAction Stop
}

function Remove-IntegrationService {
    param([Parameter(Mandatory)][string]$Name)
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    # Remove-Service is PowerShell 6+. sc.exe is on every Windows build and is
    # what keeps this working on Windows PowerShell 5.1.
    & sc.exe delete $Name | Out-Null
}

# ---------------------------------------------------------- scheduled tasks

function Test-IntegrationScheduledTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = '\'
    )
    $task = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
    if (-not $task) { return @{ Exists = $false; State = '' } }
    return @{ Exists = $true; State = [string]$task.State }
}

function New-IntegrationScheduledTask {
    <#
        Trigger accepts AtStartup, AtLogon, Daily or Once. RunAsUser defaults
        to the calling user rather than SYSTEM: a scheduled task running as
        SYSTEM is a privilege grant, and creating one silently is not something
        a packaging framework should do. SYSTEM has to be asked for by name.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = '\',
        [Parameter(Mandatory)][string]$Executable,
        [string]$Arguments = '',
        [string]$Trigger = 'AtLogon',
        [string]$RunAsUser = '',
        [string]$RunLevel = 'Limited',
        [bool]$RunWhetherLoggedOnOrNot = $false
    )

    $actionParams = @{ Execute = $Executable }
    if ($Arguments) { $actionParams['Argument'] = $Arguments }
    $action = New-ScheduledTaskAction @actionParams

    $triggerObject = $null
    switch ($Trigger.ToUpper()) {
        'ATSTARTUP' { $triggerObject = New-ScheduledTaskTrigger -AtStartup }
        'ATLOGON'   { $triggerObject = New-ScheduledTaskTrigger -AtLogOn }
        'DAILY'     { $triggerObject = New-ScheduledTaskTrigger -Daily -At (Get-Date).Date.AddHours(9) }
        'ONCE'      { $triggerObject = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) }
        default     { throw "Scheduled task trigger '$Trigger' is not supported. Use AtStartup, AtLogon, Daily or Once." }
    }

    $principalParams = @{ RunLevel = $RunLevel }
    if ($RunAsUser) {
        $principalParams['UserId'] = $RunAsUser
        if ($RunWhetherLoggedOnOrNot) { $principalParams['LogonType'] = 'Password' }
        else { $principalParams['LogonType'] = 'Interactive' }
    }
    else {
        $principalParams['UserId'] = 'BUILTIN\Users'
        $principalParams['LogonType'] = 'Interactive'
    }
    $principal = New-ScheduledTaskPrincipal @principalParams

    Register-ScheduledTask -TaskName $Name -TaskPath $Path -Action $action `
        -Trigger $triggerObject -Principal $principal -Force -ErrorAction Stop | Out-Null
}

function Remove-IntegrationScheduledTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = '\'
    )
    Unregister-ScheduledTask -TaskName $Name -TaskPath $Path -Confirm:$false -ErrorAction SilentlyContinue
}

# ------------------------------------------------------- ownership tracking

function Get-IntegrationStatePath {
    param([Parameter(Mandatory)][string]$ApplicationName)
    $stateDir = Join-WindowsPath 'C:\ProgramData\IntunePackagingStudio\State' $ApplicationName
    return (Join-WindowsPath $stateDir 'integration-state.json')
}

function Save-IntegrationState {
    <#
        Records every resource this package created. Resources that were
        already present are recorded too, with PreExisting = $true, so
        uninstall can tell "we made this" from "we found this".
    #>
    param(
        [Parameter(Mandatory)][string]$ApplicationName,
        [array]$Resources = @()
    )

    $statePath = Get-IntegrationStatePath -ApplicationName $ApplicationName
    $stateDir = Split-Path -Parent $statePath
    if (-not (Test-Path $stateDir)) {
        New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
    }

    $state = @{
        ApplicationName = $ApplicationName
        InstallDate     = (Get-Date -Format 'o')
        Resources       = $Resources
    }
    $state | ConvertTo-Json -Depth 6 | Out-File -FilePath $statePath -Encoding utf8 -Force
    return $statePath
}

function Get-IntegrationState {
    param([Parameter(Mandatory)][string]$ApplicationName)
    $statePath = Get-IntegrationStatePath -ApplicationName $ApplicationName
    $present = $false
    try { $present = Test-Path -LiteralPath $statePath }
    catch { $present = $false }
    if (-not $present) { return $null }
    return (Get-Content $statePath -Raw | ConvertFrom-Json)
}

function Remove-IntegrationState {
    param([Parameter(Mandatory)][string]$ApplicationName)
    $statePath = Get-IntegrationStatePath -ApplicationName $ApplicationName
    if (Test-Path $statePath) { Remove-Item $statePath -Force }
}

# --------------------------------------------------------------- shortcuts

function Invoke-ShortcutIntegration {
    <#
        Handles one shortcut section, desktop or Start Menu.

        Returns @{ Success; Required; Resources; Findings }.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('DesktopShortcut', 'StartMenuShortcut')][string]$Kind,
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)][string]$Mode,
        [string]$LogFile,
        [switch]$DryRun
    )

    $result = @{ Success = $true; Required = $false; Resources = @(); Findings = @() }

    $required = [bool](Get-IntegrationField -Record $Section -Field 'Required' -Default $false)
    $result.Required = $required

    $name = [string](Get-IntegrationField -Record $Section -Field 'Name')
    $target = [string](Get-IntegrationField -Record $Section -Field 'Target')

    if (-not $name) {
        $result.Findings += "$Kind has no Name."
        $result.Success = $false
        return $result
    }

    # Where the .lnk goes.
    $folder = ''
    if ($Kind -eq 'DesktopShortcut') {
        $location = [string](Get-IntegrationField -Record $Section -Field 'Location' -Default 'PublicDesktop')
        if ($location -eq 'UserDesktop') { $folder = Get-ShellFolderPath -Name 'UserDesktop' }
        else { $folder = Get-ShellFolderPath -Name 'PublicDesktop' }
    }
    else {
        $location = [string](Get-IntegrationField -Record $Section -Field 'Location' -Default 'AllUsers')
        if ($location -eq 'CurrentUser') { $folder = Get-ShellFolderPath -Name 'UserStartMenu' }
        else { $folder = Get-ShellFolderPath -Name 'AllUsersStartMenu' }

        $subFolder = [string](Get-IntegrationField -Record $Section -Field 'Folder')
        if ($subFolder) { $folder = Join-WindowsPath $folder $subFolder }
    }

    $shortcutPath = Join-WindowsPath $folder "$name.lnk"
    $existing = Test-ShortcutFile -Path $shortcutPath -ExpectedTarget $target

    # --- VALIDATE: report what the installer did, change nothing -----------
    if ($Mode -eq 'VALIDATE') {
        if ($existing.Exists) {
            Write-Log "[INFO] $Kind already exists; framework management disabled. $shortcutPath" $LogFile
            if ($target -and -not $existing.TargetMatches) {
                $result.Findings += "$Kind exists but points at '$($existing.Target)' rather than '$target'."
            }
        }
        else {
            $result.Findings += "$Kind was not found at $shortcutPath. The installer was expected to create it."
            $result.Success = $false
        }
        return $result
    }

    # --- MANAGE ------------------------------------------------------------
    if (-not $target) {
        $result.Findings += "$Kind is set to MANAGE but has no Target."
        $result.Success = $false
        return $result
    }

    # A shortcut to an executable that is not there is worse than none: it
    # looks installed and fails when clicked.
    $targetExists = $false
    try { $targetExists = Test-Path -LiteralPath $target }
    catch { $targetExists = $false }

    if (-not $targetExists) {
        $result.Findings += "$Kind target does not exist: $target"
        $result.Success = $false
        return $result
    }

    if ($DryRun) {
        Write-IntegrationPlan "Would create shortcut: $shortcutPath -> $target" $LogFile
        return $result
    }

    try {
        New-ShortcutFile -Path $shortcutPath -Target $target `
            -Arguments ([string](Get-IntegrationField -Record $Section -Field 'Arguments')) `
            -WorkingDirectory ([string](Get-IntegrationField -Record $Section -Field 'WorkingDirectory')) `
            -Icon ([string](Get-IntegrationField -Record $Section -Field 'Icon')) `
            -Description ([string](Get-IntegrationField -Record $Section -Field 'Description'))

        $verify = Test-ShortcutFile -Path $shortcutPath -ExpectedTarget $target
        if (-not $verify.Exists) {
            $result.Findings += "$Kind was not created at $shortcutPath."
            $result.Success = $false
            return $result
        }
        if (-not $verify.TargetMatches) {
            $result.Findings += "$Kind was created but points at '$($verify.Target)' rather than '$target'."
            $result.Success = $false
            return $result
        }

        Write-Log "Created $Kind`: $shortcutPath -> $target" $LogFile
        $result.Resources += @{
            Kind        = 'Shortcut'
            Path        = $shortcutPath
            Feature     = $Kind
            PreExisting = $existing.Exists
        }
    }
    catch {
        $result.Findings += "$Kind could not be created: $($_.Exception.Message)"
        $result.Success = $false
    }

    return $result
}

# ------------------------------------------------------------ context menu

function Get-ContextMenuKeyPaths {
    <#
        The Classes subkeys a context-menu entry attaches its verb to.

        FILE with Extensions listed attaches per extension, which is the
        narrow, well-behaved form. FILE without Extensions, and ALL_FILES,
        attach to '*' - every file on the machine - so that is only ever done
        when the configuration asks for it explicitly.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [string[]]$Extensions = @()
    )

    $roots = @()
    switch ($Target.ToUpper()) {
        'FILE' {
            if (@($Extensions).Count -gt 0) {
                foreach ($ext in $Extensions) {
                    $e = [string]$ext
                    if ($e -and -not $e.StartsWith('.')) { $e = ".$e" }
                    if ($e) { $roots += $e }
                }
            }
            else { $roots += '*' }
        }
        'ALL_FILES' { $roots += '*' }
        'FOLDER'    { $roots += 'Folder' }
        'DIRECTORY' { $roots += 'Directory' }
        default     { throw "Context menu Target '$Target' is not supported. Use FILE, FOLDER, DIRECTORY or ALL_FILES." }
    }
    return $roots
}

function Invoke-ContextMenuIntegration {
    param(
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)][string]$Mode,
        [string]$LogFile,
        [switch]$DryRun
    )

    $result = @{ Success = $true; Required = $false; Resources = @(); Findings = @() }
    $result.Required = [bool](Get-IntegrationField -Record $Section -Field 'Required' -Default $false)

    $entries = @(Get-IntegrationField -Record $Section -Field 'Entries' -Default @())
    if ($entries.Count -eq 0) {
        $result.Findings += 'Context menu is enabled but no entries are configured.'
        $result.Success = $false
        return $result
    }

    foreach ($entry in $entries) {
        $verb = [string](Get-IntegrationField -Record $entry -Field 'Verb')
        $label = [string](Get-IntegrationField -Record $entry -Field 'Name')
        $target = [string](Get-IntegrationField -Record $entry -Field 'Target' -Default 'FILE')
        $executable = [string](Get-IntegrationField -Record $entry -Field 'Executable')
        $arguments = [string](Get-IntegrationField -Record $entry -Field 'Arguments' -Default '"%1"')
        $icon = [string](Get-IntegrationField -Record $entry -Field 'Icon')
        $extensions = @(Get-IntegrationField -Record $entry -Field 'Extensions' -Default @())

        if (-not $verb) {
            # An application-specific verb is what keeps uninstall from
            # touching anything else. Without one there is nothing safe to own.
            $result.Findings += "A context menu entry has no Verb. Use an application-specific verb such as Company.Application.Open."
            $result.Success = $false
            continue
        }

        $keyRoots = Get-ContextMenuKeyPaths -Target $target -Extensions $extensions

        foreach ($root in $keyRoots) {
            $verbKey = "$script:IntegrationClassesRoot\$root\shell\$verb"

            if ($Mode -eq 'VALIDATE') {
                if (Test-IntegrationRegistryKey -Path $verbKey) {
                    Write-Log "[INFO] Context menu verb already exists; framework management disabled. $verbKey" $LogFile
                }
                else {
                    $result.Findings += "Context menu verb was not found: $verbKey"
                    $result.Success = $false
                }
                continue
            }

            if (-not $executable) {
                $result.Findings += "Context menu entry '$verb' has no Executable."
                $result.Success = $false
                continue
            }

            $command = '"{0}" {1}' -f $executable, $arguments

            if ($DryRun) {
                Write-IntegrationPlan "Would register context menu verb: $verbKey" $LogFile
                Write-IntegrationPlan "  command: $command" $LogFile
                continue
            }

            # An existing verb belongs to whoever put it there. Overwriting it
            # would break their integration and leave nothing to restore.
            $preExisting = Test-IntegrationRegistryKey -Path $verbKey
            if ($preExisting) {
                Write-Log "[INFO] Context menu verb already exists and is left as it is: $verbKey" $LogFile
                continue
            }

            try {
                Set-IntegrationRegistryValue -Path $verbKey -Name '' -Value $label
                if ($icon) { Set-IntegrationRegistryValue -Path $verbKey -Name 'Icon' -Value $icon }
                Set-IntegrationRegistryValue -Path "$verbKey\command" -Name '' -Value $command

                Write-Log "Registered context menu verb: $verbKey" $LogFile
                $result.Resources += @{
                    Kind        = 'RegistryKey'
                    Path        = $verbKey
                    Feature     = 'ContextMenu'
                    PreExisting = $false
                }
            }
            catch {
                $result.Findings += "Context menu verb '$verb' could not be registered: $($_.Exception.Message)"
                $result.Success = $false
            }
        }
    }

    return $result
}

# -------------------------------------------------------- file associations

function Invoke-FileAssociationIntegration {
    param(
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)][string]$Mode,
        [string]$LogFile,
        [switch]$DryRun
    )

    $result = @{ Success = $true; Required = $false; Resources = @(); Findings = @() }
    $result.Required = [bool](Get-IntegrationField -Record $Section -Field 'Required' -Default $false)

    $associations = @(Get-IntegrationField -Record $Section -Field 'Associations' -Default @())
    if ($associations.Count -eq 0) {
        $result.Findings += 'File associations are enabled but none are configured.'
        $result.Success = $false
        return $result
    }

    # Taking over an extension is a user-visible change, so it happens only
    # when asked for. Otherwise the ProgID is registered and offered under
    # "Open with", which adds the application without displacing anything.
    $setAsDefault = [bool](Get-IntegrationField -Record $Section -Field 'SetAsDefault' -Default $false)

    foreach ($assoc in $associations) {
        $extension = [string](Get-IntegrationField -Record $assoc -Field 'Extension')
        if ($extension -and -not $extension.StartsWith('.')) { $extension = ".$extension" }
        $progId = [string](Get-IntegrationField -Record $assoc -Field 'ProgId')
        $description = [string](Get-IntegrationField -Record $assoc -Field 'Description')
        $icon = [string](Get-IntegrationField -Record $assoc -Field 'Icon')
        $executable = [string](Get-IntegrationField -Record $assoc -Field 'Executable')
        $arguments = [string](Get-IntegrationField -Record $assoc -Field 'Arguments' -Default '"%1"')

        # OpenCommand is the older single-string form and still works.
        $openCommand = [string](Get-IntegrationField -Record $assoc -Field 'OpenCommand')
        if (-not $icon) { $icon = [string](Get-IntegrationField -Record $assoc -Field 'IconPath') }

        if (-not $extension) {
            $result.Findings += 'A file association has no Extension.'
            $result.Success = $false
            continue
        }
        if (-not $progId) {
            $result.Findings += "File association '$extension' has no ProgId."
            $result.Success = $false
            continue
        }

        $progIdKey = "$script:IntegrationClassesRoot\$progId"
        $extensionKey = "$script:IntegrationClassesRoot\$extension"

        if ($Mode -eq 'VALIDATE') {
            if (Test-IntegrationRegistryKey -Path $progIdKey) {
                Write-Log "[INFO] File association ProgID already exists; framework management disabled. $progIdKey" $LogFile
            }
            else {
                $result.Findings += "File association ProgID was not found: $progIdKey"
                $result.Success = $false
            }
            continue
        }

        $command = $openCommand
        if (-not $command) {
            if (-not $executable) {
                $result.Findings += "File association '$extension' has neither Executable nor OpenCommand."
                $result.Success = $false
                continue
            }
            $command = '"{0}" {1}' -f $executable, $arguments
        }

        if ($DryRun) {
            Write-IntegrationPlan "Would register ProgID: $progIdKey" $LogFile
            Write-IntegrationPlan "  command: $command" $LogFile
            Write-IntegrationPlan "  offer $extension under 'Open with'" $LogFile
            if ($setAsDefault) { Write-IntegrationPlan "  make $progId the default handler for $extension" $LogFile }
            continue
        }

        try {
            $progIdPreExisting = Test-IntegrationRegistryKey -Path $progIdKey

            Set-IntegrationRegistryValue -Path $progIdKey -Name '' -Value $description
            if ($icon) { Set-IntegrationRegistryValue -Path "$progIdKey\DefaultIcon" -Name '' -Value $icon }
            Set-IntegrationRegistryValue -Path "$progIdKey\shell\open\command" -Name '' -Value $command

            if (-not $progIdPreExisting) {
                $result.Resources += @{
                    Kind        = 'RegistryKey'
                    Path        = $progIdKey
                    Feature     = 'FileAssociations'
                    PreExisting = $false
                }
            }

            # Offer the application without stealing the extension.
            Set-IntegrationRegistryValue -Path "$extensionKey\OpenWithProgids" -Name $progId -Value ''
            $result.Resources += @{
                Kind        = 'RegistryValue'
                Path        = "$extensionKey\OpenWithProgids"
                Name        = $progId
                Feature     = 'FileAssociations'
                PreExisting = $false
            }

            if ($setAsDefault) {
                $previousDefault = Get-IntegrationRegistryValue -Path $extensionKey -Name ''
                Set-IntegrationRegistryValue -Path $extensionKey -Name '' -Value $progId
                # PreExisting is deliberately false: this package changed the
                # value, so it owns the change and must undo it. Whether there
                # was a value here before is carried by PreviousValue, which
                # decides restore-versus-clear at uninstall.
                $result.Resources += @{
                    Kind          = 'RegistryDefault'
                    Path          = $extensionKey
                    Feature       = 'FileAssociations'
                    PreviousValue = $previousDefault
                    PreExisting   = $false
                }
                Write-Log "Set $progId as the default handler for $extension (previous: '$previousDefault')." $LogFile
            }

            Write-Log "Registered file association: $extension -> $progId" $LogFile
        }
        catch {
            $result.Findings += "File association '$extension' could not be registered: $($_.Exception.Message)"
            $result.Success = $false
        }
    }

    return $result
}

# ----------------------------------------------------------------- services

function Invoke-ServiceIntegration {
    param(
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)][string]$Mode,
        [string]$LogFile,
        [switch]$DryRun
    )

    $result = @{ Success = $true; Required = $false; Resources = @(); Findings = @() }
    $result.Required = [bool](Get-IntegrationField -Record $Section -Field 'Required' -Default $false)

    $services = @(Get-IntegrationField -Record $Section -Field 'Services' -Default @())
    if ($services.Count -eq 0) {
        $result.Findings += 'Services are enabled but none are configured.'
        $result.Success = $false
        return $result
    }

    foreach ($service in $services) {
        $name = [string](Get-IntegrationField -Record $service -Field 'Name')
        if (-not $name) {
            $result.Findings += 'A service entry has no Name.'
            $result.Success = $false
            continue
        }

        $state = Test-IntegrationService -Name $name

        if ($Mode -eq 'VALIDATE') {
            if ($state.Exists) {
                Write-Log "[INFO] Service '$name' already exists; framework management disabled." $LogFile
            }
            else {
                $result.Findings += "Service '$name' was not found. The installer was expected to create it."
                $result.Success = $false
            }
            continue
        }

        if ($state.Exists) {
            # The vendor installer got there first. Adopting it would mean
            # deleting their service on uninstall.
            Write-Log "[INFO] Service '$name' already exists and is left as it is." $LogFile
            continue
        }

        $executable = [string](Get-IntegrationField -Record $service -Field 'Executable')
        if (-not $executable) {
            $result.Findings += "Service '$name' has no Executable."
            $result.Success = $false
            continue
        }

        $arguments = [string](Get-IntegrationField -Record $service -Field 'Arguments')
        $binaryPath = $executable
        if ($arguments) { $binaryPath = '"{0}" {1}' -f $executable, $arguments }

        $startupType = [string](Get-IntegrationField -Record $service -Field 'StartupType' -Default 'Manual')
        if ($startupType -eq 'Unchanged') { $startupType = 'Manual' }

        if ($DryRun) {
            Write-IntegrationPlan "Would create service: $name ($startupType) -> $binaryPath" $LogFile
            continue
        }

        try {
            New-IntegrationService -Name $name -BinaryPath $binaryPath `
                -DisplayName ([string](Get-IntegrationField -Record $service -Field 'DisplayName')) `
                -Description ([string](Get-IntegrationField -Record $service -Field 'Description')) `
                -StartupType $startupType

            $verify = Test-IntegrationService -Name $name
            if (-not $verify.Exists) {
                $result.Findings += "Service '$name' was not created."
                $result.Success = $false
                continue
            }

            Write-Log "Created service: $name" $LogFile
            $result.Resources += @{
                Kind        = 'Service'
                Name        = $name
                Feature     = 'Services'
                PreExisting = $false
            }

            if ([bool](Get-IntegrationField -Record $service -Field 'StartAfterInstall' -Default $false)) {
                Start-IntegrationService -Name $name
                Write-Log "Started service: $name" $LogFile
            }
        }
        catch {
            $result.Findings += "Service '$name' could not be created: $($_.Exception.Message)"
            $result.Success = $false
        }
    }

    return $result
}

# ----------------------------------------------------------- scheduled tasks

function Invoke-ScheduledTaskIntegration {
    param(
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)][string]$Mode,
        [string]$LogFile,
        [switch]$DryRun
    )

    $result = @{ Success = $true; Required = $false; Resources = @(); Findings = @() }
    $result.Required = [bool](Get-IntegrationField -Record $Section -Field 'Required' -Default $false)

    $tasks = @(Get-IntegrationField -Record $Section -Field 'Tasks' -Default @())
    if ($tasks.Count -eq 0) {
        $result.Findings += 'Scheduled tasks are enabled but none are configured.'
        $result.Success = $false
        return $result
    }

    foreach ($task in $tasks) {
        $name = [string](Get-IntegrationField -Record $task -Field 'Name')
        $path = [string](Get-IntegrationField -Record $task -Field 'Path' -Default '\')
        if (-not $name) {
            $result.Findings += 'A scheduled task entry has no Name.'
            $result.Success = $false
            continue
        }

        $state = Test-IntegrationScheduledTask -Name $name -Path $path

        if ($Mode -eq 'VALIDATE') {
            if ($state.Exists) {
                Write-Log "[INFO] Scheduled task '$name' already exists; framework management disabled." $LogFile
            }
            else {
                $result.Findings += "Scheduled task '$name' was not found. The installer was expected to create it."
                $result.Success = $false
            }
            continue
        }

        if ($state.Exists) {
            Write-Log "[INFO] Scheduled task '$name' already exists and is left as it is." $LogFile
            continue
        }

        $executable = [string](Get-IntegrationField -Record $task -Field 'Executable')
        if (-not $executable) {
            $result.Findings += "Scheduled task '$name' has no Executable."
            $result.Success = $false
            continue
        }

        $runAsUser = [string](Get-IntegrationField -Record $task -Field 'RunAsUser')
        $runLevel = [string](Get-IntegrationField -Record $task -Field 'RunLevel' -Default 'Limited')

        # Running as SYSTEM, or at highest privileges, is a privilege grant.
        # It is honoured when the configuration asks for it and never inferred.
        if ($runLevel -eq 'Highest' -and -not $runAsUser) {
            Write-Log "WARNING: Scheduled task '$name' requests Highest privileges without naming RunAsUser." $LogFile
        }

        if ($DryRun) {
            $who = $runAsUser
            if (-not $who) { $who = 'BUILTIN\Users' }
            Write-IntegrationPlan "Would create scheduled task: $path$name -> $executable (as $who, $runLevel)" $LogFile
            continue
        }

        try {
            New-IntegrationScheduledTask -Name $name -Path $path -Executable $executable `
                -Arguments ([string](Get-IntegrationField -Record $task -Field 'Arguments')) `
                -Trigger ([string](Get-IntegrationField -Record $task -Field 'Trigger' -Default 'AtLogon')) `
                -RunAsUser $runAsUser -RunLevel $runLevel `
                -RunWhetherLoggedOnOrNot ([bool](Get-IntegrationField -Record $task -Field 'RunWhetherLoggedOnOrNot' -Default $false))

            $verify = Test-IntegrationScheduledTask -Name $name -Path $path
            if (-not $verify.Exists) {
                $result.Findings += "Scheduled task '$name' was not created."
                $result.Success = $false
                continue
            }

            Write-Log "Created scheduled task: $path$name" $LogFile
            $result.Resources += @{
                Kind        = 'ScheduledTask'
                Name        = $name
                Path        = $path
                Feature     = 'ScheduledTasks'
                PreExisting = $false
            }
        }
        catch {
            $result.Findings += "Scheduled task '$name' could not be created: $($_.Exception.Message)"
            $result.Success = $false
        }
    }

    return $result
}

# ------------------------------------------------------------ orchestration

function Get-WindowsIntegrationPlan {
    <#
        Resolves every feature to its effective mode. Used by install,
        uninstall, dry run and the deployment summary, so all four agree on
        what the configuration means.
    #>
    param([Parameter(Mandatory)]$Config)

    $section = Get-IntegrationField -Record $Config -Field 'WindowsIntegration'
    $master = [bool](Get-IntegrationField -Record $section -Field 'Enabled' -Default $false)

    $plan = [ordered]@{}
    foreach ($feature in @('DesktopShortcut', 'StartMenuShortcut', 'ContextMenu',
                           'FileAssociations', 'Services', 'ScheduledTasks')) {
        $featureSection = Get-IntegrationField -Record $section -Field $feature
        $plan[$feature] = Resolve-IntegrationMode -Section $featureSection -MasterEnabled $master
    }
    return $plan
}

function Install-WindowsIntegration {
    <#
        .SYNOPSIS
        Applies the WindowsIntegration section after the application installed.

        .DESCRIPTION
        Runs only after installation has been confirmed, because an integration
        pointing at an application that is not there is worse than no
        integration at all.

        A feature marked Required that cannot be created fails the install. A
        feature that is not required logs a warning and the install continues.

        Returns @{ Success; RequiredFailed; Findings }.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$LogFile,
        [switch]$DryRun
    )

    $section = Get-IntegrationField -Record $Config -Field 'WindowsIntegration'
    $result = @{ Success = $true; RequiredFailed = $false; Findings = @() }

    if (-not $section) { return $result }

    $plan = Get-WindowsIntegrationPlan -Config $Config
    $active = @($plan.Keys | Where-Object { $plan[$_] -ne 'DISABLED' })
    if ($active.Count -eq 0) {
        Write-Log 'Windows integration: nothing enabled.' $LogFile
        return $result
    }

    Write-Log "Windows integration started. $(($active | ForEach-Object { "$_=$($plan[$_])" }) -join ', ')" $LogFile

    $appName = [string](Get-IntegrationField -Record $Config -Field 'ApplicationName')
    $resources = @()

    foreach ($feature in $plan.Keys) {
        $mode = $plan[$feature]
        if ($mode -eq 'DISABLED') { continue }

        $featureSection = Get-IntegrationField -Record $section -Field $feature
        $outcome = $null

        switch ($feature) {
            'DesktopShortcut' {
                $outcome = Invoke-ShortcutIntegration -Kind 'DesktopShortcut' -Section $featureSection -Mode $mode -LogFile $LogFile -DryRun:$DryRun
            }
            'StartMenuShortcut' {
                $outcome = Invoke-ShortcutIntegration -Kind 'StartMenuShortcut' -Section $featureSection -Mode $mode -LogFile $LogFile -DryRun:$DryRun
            }
            'ContextMenu' {
                $outcome = Invoke-ContextMenuIntegration -Section $featureSection -Mode $mode -LogFile $LogFile -DryRun:$DryRun
            }
            'FileAssociations' {
                $outcome = Invoke-FileAssociationIntegration -Section $featureSection -Mode $mode -LogFile $LogFile -DryRun:$DryRun
            }
            'Services' {
                $outcome = Invoke-ServiceIntegration -Section $featureSection -Mode $mode -LogFile $LogFile -DryRun:$DryRun
            }
            'ScheduledTasks' {
                $outcome = Invoke-ScheduledTaskIntegration -Section $featureSection -Mode $mode -LogFile $LogFile -DryRun:$DryRun
            }
        }

        if (-not $outcome) { continue }

        foreach ($finding in @($outcome.Findings)) {
            $result.Findings += "$feature`: $finding"
            if ($outcome.Required) {
                Write-Log "ERROR: $feature (Required) - $finding" $LogFile
            }
            else {
                Write-Log "WARNING: $feature - $finding" $LogFile
            }
        }

        if (-not $outcome.Success) {
            $result.Success = $false
            if ($outcome.Required) { $result.RequiredFailed = $true }
        }

        $resources += @($outcome.Resources)
    }

    if ($DryRun) {
        Write-Log 'Windows integration dry run complete. Nothing was changed.' $LogFile
        return $result
    }

    # Explorer only picks up new verbs and associations when told.
    $shellFeatures = @('ContextMenu', 'FileAssociations')
    $touchedShell = @($shellFeatures | Where-Object { $plan[$_] -eq 'MANAGE' })
    if ($touchedShell.Count -gt 0 -and
        [bool](Get-IntegrationField -Record $section -Field 'NotifyShell' -Default $true)) {
        $notify = Update-ShellNotification
        Write-Log $notify.Message $LogFile
    }

    if ($appName) {
        Save-IntegrationState -ApplicationName $appName -Resources $resources | Out-Null
        Write-Log "Windows integration recorded $(@($resources).Count) owned resource(s)." $LogFile
    }

    Write-Log "Windows integration completed. Success: $($result.Success)" $LogFile
    return $result
}

function Uninstall-WindowsIntegration {
    <#
        .SYNOPSIS
        Removes the integrations this package created, and nothing else.

        .DESCRIPTION
        Driven entirely by the state file written at install time. A resource
        recorded as pre-existing is left alone, and a feature in VALIDATE mode
        never recorded anything, so its integrations are never touched.

        With no state file nothing is removed. Deleting another product's
        shortcut or registry verb cannot be undone, and a leftover shortcut
        can. The names are logged so they can be removed by hand.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$LogFile,
        [switch]$DryRun
    )

    $result = @{ Success = $true; Findings = @() }
    $appName = [string](Get-IntegrationField -Record $Config -Field 'ApplicationName')
    if (-not $appName) { return $result }

    $section = Get-IntegrationField -Record $Config -Field 'WindowsIntegration'
    if (-not $section) { return $result }

    $state = Get-IntegrationState -ApplicationName $appName
    if (-not $state) {
        Write-Log 'No Windows integration state recorded. Nothing is removed, because ownership cannot be established.' $LogFile
        return $result
    }

    $resources = @(Get-IntegrationField -Record $state -Field 'Resources' -Default @())
    if ($resources.Count -eq 0) {
        Write-Log 'Windows integration state records no owned resources.' $LogFile
        Remove-IntegrationState -ApplicationName $appName
        return $result
    }

    Write-Log "Removing $($resources.Count) package-owned Windows integration resource(s)." $LogFile

    foreach ($resource in $resources) {
        $kind = [string](Get-IntegrationField -Record $resource -Field 'Kind')
        $path = [string](Get-IntegrationField -Record $resource -Field 'Path')
        $name = [string](Get-IntegrationField -Record $resource -Field 'Name')
        $preExisting = [bool](Get-IntegrationField -Record $resource -Field 'PreExisting' -Default $false)

        if ($preExisting) {
            Write-Log "Left in place (existed before this package): $kind $path$name" $LogFile
            continue
        }

        # The feature's RemoveOnUninstall can still veto removal.
        $feature = [string](Get-IntegrationField -Record $resource -Field 'Feature')
        if ($feature) {
            $featureSection = Get-IntegrationField -Record $section -Field $feature
            $removeOnUninstall = Get-IntegrationField -Record $featureSection -Field 'RemoveOnUninstall' -Default $true
            if ($removeOnUninstall -eq $false) {
                Write-Log "Left in place (RemoveOnUninstall is false): $kind $path$name" $LogFile
                continue
            }
        }

        if ($DryRun) {
            Write-IntegrationPlan "Would remove $kind`: $path$name" $LogFile
            continue
        }

        try {
            switch ($kind) {
                'Shortcut' {
                    Remove-ShortcutFile -Path $path
                    Write-Log "Removed shortcut: $path" $LogFile
                }
                'RegistryKey' {
                    Remove-IntegrationRegistryKey -Path $path
                    Write-Log "Removed registry key: $path" $LogFile
                }
                'RegistryValue' {
                    Remove-IntegrationRegistryValue -Path $path -Name ([string](Get-IntegrationField -Record $resource -Field 'Name'))
                    Write-Log "Removed registry value: $path\$name" $LogFile
                }
                'RegistryDefault' {
                    # This package replaced an extension's default handler.
                    # Put back exactly what was there.
                    $previous = [string](Get-IntegrationField -Record $resource -Field 'PreviousValue')
                    if ($previous) {
                        Set-IntegrationRegistryValue -Path $path -Name '' -Value $previous
                        Write-Log "Restored default handler for $path to '$previous'." $LogFile
                    }
                    else {
                        Remove-IntegrationRegistryValue -Path $path -Name '(default)'
                        Write-Log "Cleared the default handler this package set on $path." $LogFile
                    }
                }
                'Service' {
                    Remove-IntegrationService -Name $name
                    Write-Log "Removed service: $name" $LogFile
                }
                'ScheduledTask' {
                    Remove-IntegrationScheduledTask -Name $name -Path $path
                    Write-Log "Removed scheduled task: $path$name" $LogFile
                }
                default {
                    Write-Log "Unknown resource kind in state file, left alone: $kind" $LogFile
                }
            }
        }
        catch {
            $result.Findings += "Could not remove $kind '$path$name': $($_.Exception.Message)"
            $result.Success = $false
            Write-Log "WARNING: could not remove $kind '$path$name': $($_.Exception.Message)" $LogFile
        }
    }

    if (-not $DryRun) {
        if ([bool](Get-IntegrationField -Record $section -Field 'NotifyShell' -Default $true)) {
            $notify = Update-ShellNotification
            Write-Log $notify.Message $LogFile
        }
        Remove-IntegrationState -ApplicationName $appName
    }

    Write-Log "Windows integration cleanup completed. Success: $($result.Success)" $LogFile
    return $result
}

function Test-WindowsIntegrationState {
    <#
        .SYNOPSIS
        Reports whether the configured integrations are present, without
        changing anything.

        Used by the post-install validation step and by Test-Local.ps1.
        Returns @{ Success; Findings }.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$LogFile
    )

    $section = Get-IntegrationField -Record $Config -Field 'WindowsIntegration'
    $result = @{ Success = $true; Findings = @() }
    if (-not $section) { return $result }

    $plan = Get-WindowsIntegrationPlan -Config $Config

    foreach ($feature in $plan.Keys) {
        if ($plan[$feature] -eq 'DISABLED') { continue }
        $featureSection = Get-IntegrationField -Record $section -Field $feature

        # VALIDATE is exactly this check, and MANAGE is verified the same way
        # once it has run, so both use the section's VALIDATE behaviour here.
        $outcome = $null
        switch ($feature) {
            'DesktopShortcut'   { $outcome = Invoke-ShortcutIntegration -Kind 'DesktopShortcut'   -Section $featureSection -Mode 'VALIDATE' -LogFile $LogFile }
            'StartMenuShortcut' { $outcome = Invoke-ShortcutIntegration -Kind 'StartMenuShortcut' -Section $featureSection -Mode 'VALIDATE' -LogFile $LogFile }
            'ContextMenu'       { $outcome = Invoke-ContextMenuIntegration -Section $featureSection -Mode 'VALIDATE' -LogFile $LogFile }
            'FileAssociations'  { $outcome = Invoke-FileAssociationIntegration -Section $featureSection -Mode 'VALIDATE' -LogFile $LogFile }
            'Services'          { $outcome = Invoke-ServiceIntegration -Section $featureSection -Mode 'VALIDATE' -LogFile $LogFile }
            'ScheduledTasks'    { $outcome = Invoke-ScheduledTaskIntegration -Section $featureSection -Mode 'VALIDATE' -LogFile $LogFile }
        }

        if (-not $outcome) { continue }
        foreach ($finding in @($outcome.Findings)) { $result.Findings += "$feature`: $finding" }
        if (-not $outcome.Success) { $result.Success = $false }
    }

    return $result
}
