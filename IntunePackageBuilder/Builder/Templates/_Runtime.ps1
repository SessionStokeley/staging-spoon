#Requires -Version 5.1

# =============================================================================
#  Intune Package Builder - package runtime
#
#  This is spliced into the generated Install.ps1, Uninstall.ps1 and
#  Detection.ps1, so each shipped script is self-contained and the package
#  needs no Helpers directory.
#
#  It is maintained here as one file rather than generated per package: a fix
#  to PATH handling should be one edit, and every package should be the same
#  program to debug.
#
#  Windows PowerShell 5.1 only. Intune's Management Extension runs 5.1, so
#  nothing here may use PowerShell 7 syntax or cmdlets.
#
#  No Set-StrictMode: an absent optional configuration key is normal.
# =============================================================================

$script:StateRoot       = 'C:\ProgramData\IntunePackageBuilder\State'
$script:LegacyStateRoot = 'C:\ProgramData\IntunePackagingStudio\State'
$script:ClassesRoot     = 'HKLM:\SOFTWARE\Classes'

# ----------------------------------------------------------------- logging

function Write-PackageLog {
    param(
        [string]$Message,
        [string]$LogFile,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (-not $LogFile) { return }

    try {
        $directory = Split-Path -Parent $LogFile
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        $line | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
    catch {
        # Logging must never be the reason an install fails.
        Write-Host "[WARN] Could not write to the log: $($_.Exception.Message)"
    }
}

function Get-CurrentIdentity {
    # Diagnostic only, and never allowed to abort the run: the Windows
    # principal API throws outright off-Windows.
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { return '(identity unavailable)' }
}

function Test-RunningAsSystem {
    return ((Get-CurrentIdentity) -eq 'NT AUTHORITY\SYSTEM')
}

# ------------------------------------------------- configuration loading

function Get-PsdScriptBlockBody {
    param($ScriptBlockAst)
    $current = $ScriptBlockAst
    while ($true) {
        if ($current -isnot [System.Management.Automation.Language.ScriptBlockAst]) { break }
        if (-not $current.EndBlock) { break }
        $statements = @($current.EndBlock.Statements)
        if ($statements.Count -ne 1) { break }
        if ($statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) { break }
        $elements = @($statements[0].PipelineElements)
        if ($elements.Count -ne 1) { break }
        if ($elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { break }
        $expression = $elements[0].Expression
        if ($expression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { break }
        $current = $expression.ScriptBlock
    }
    if ($current -is [System.Management.Automation.Language.ScriptBlockAst] -and $current.EndBlock) {
        return [string]$current.EndBlock.Extent.Text
    }
    return ''
}

function ConvertFrom-PsdAst {
    param([System.Management.Automation.Language.Ast]$Ast)

    $node = $Ast
    while ($node -is [System.Management.Automation.Language.ConvertExpressionAst] -or
           $node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node = $node.Child }
        else { $node = $node.Pipeline }
    }
    if ($node -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($node.PipelineElements)
        if ($elements.Count -ne 1) { throw "Unsupported expression at line $($node.Extent.StartLineNumber)." }
        $node = $elements[0].Expression
    }
    if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) { $node = $node.Expression }

    if ($node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        return Get-PsdScriptBlockBody -ScriptBlockAst $node.ScriptBlock
    }
    if ($node -is [System.Management.Automation.Language.HashtableAst]) {
        $result = @{}
        foreach ($pair in $node.KeyValuePairs) {
            $result[[string](ConvertFrom-PsdAst -Ast $pair.Item1)] = ConvertFrom-PsdAst -Ast $pair.Item2
        }
        return $result
    }
    if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $items = @()
        foreach ($element in $node.Elements) { $items += , (ConvertFrom-PsdAst -Ast $element) }
        return , $items
    }
    if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $items = @()
        foreach ($statement in $node.SubExpression.Statements) {
            $value = ConvertFrom-PsdAst -Ast $statement
            if ($null -ne $value -and $value -isnot [string] -and
                $value -is [System.Collections.IEnumerable] -and
                $value -isnot [System.Collections.IDictionary]) {
                foreach ($inner in $value) { $items += , $inner }
            }
            else { $items += , $value }
        }
        return , $items
    }
    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $node.Value }
    if ($node -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $node.Value }
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = [string]$node.VariablePath.UserPath
        if ($name -eq 'true')  { return $true }
        if ($name -eq 'false') { return $false }
        if ($name -eq 'null')  { return $null }
        throw "A configuration may not reference `$$name."
    }
    if ($node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        $operand = ConvertFrom-PsdAst -Ast $node.Child
        if ($node.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus) { return -$operand }
        return $operand
    }
    throw "Unsupported expression at line $($node.Extent.StartLineNumber)."
}

function Get-PackageConfiguration {
    <#
        Loads Configuration.psd1 from beside this script.

        Import-PowerShellDataFile cannot read a script-block literal on Windows
        PowerShell 5.1, and the failure takes the whole file rather than just
        the key that used one. The syntax-tree fallback exists for that; it
        parses and never executes.
    #>
    param([Parameter(Mandatory)][string]$PackageRoot)

    $path = Join-Path $PackageRoot 'Configuration.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Configuration.psd1 was not found beside the script: $path"
    }

    try { return Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop }
    catch { }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        throw "Configuration.psd1 does not parse: $(@($parseErrors)[0].Message)"
    }
    $hashtable = $ast.Find({
        param($n) $n -is [System.Management.Automation.Language.HashtableAst]
    }, $false)
    if (-not $hashtable) { throw 'Configuration.psd1 contains no hashtable.' }
    return ConvertFrom-PsdAst -Ast $hashtable
}

function Get-ConfigValue {
    <#
        Reads a key from a record that may be a hashtable (from the .psd1) or a
        PSCustomObject (from the JSON state file). A hashtable's keys are not
        PSObject properties, so one probe cannot serve both shapes.
    #>
    param([AllowNull()]$Record, [Parameter(Mandatory)][string]$Key, $Default = $null)

    if ($null -eq $Record) { return $Default }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Key)) { return $Record[$Key] }
        return $Default
    }
    $property = $Record.PSObject.Properties[$Key]
    if ($property) { return $property.Value }
    return $Default
}

# ------------------------------------------------------ installer command

function Join-WindowsPath {
    <#
        Joins Windows path segments as text. Join-Path resolves through the
        PowerShell provider and fails with "Cannot find drive" where the drive
        does not exist, which is every C:\ path off Windows.
    #>
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    return ($Parent.TrimEnd('\', '/') + '\' + $Child.TrimStart('\', '/'))
}

function Get-ParentPath {
    # Split-Path returns the host's separator, so a Windows path handed to it
    # off-Windows comes back with forward slashes.
    param([Parameter(Mandatory)][string]$Path)
    $index = $Path.LastIndexOfAny([char[]]@('\', '/'))
    if ($index -gt 0) { return $Path.Substring(0, $index) }
    return ''
}

function New-InstallerCommand {
    <#
        The one place an installer command line is assembled.

        Arguments is a single string rather than an array on purpose:
        Start-Process re-quotes each element of an array, which mangles an MSI
        property whose value contains spaces.

        Arguments is $null when there are none, because Windows PowerShell 5.1
        rejects an empty -ArgumentList and the parameter has to be omitted.
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$InstallerPath,
        [AllowEmptyString()][string]$Arguments = ''
    )

    $tail = ''
    if ($Arguments) { $tail = $Arguments.Trim() }
    $upper = $Type.ToUpper()

    if ($upper -eq 'MSI') {
        $full = "/i `"$InstallerPath`""
        if ($tail) { $full = "$full $tail" }
        return @{ FilePath = 'msiexec.exe'; Arguments = $full; WorkingDirectory = $null
                  Display = "msiexec.exe $full" }
    }

    if ($upper -eq 'BAT') {
        # 'call' is not decoration. cmd /? documents that when the text after
        # /c begins with a quote, cmd strips the outer pair unless the line has
        # exactly two quotes around an executable name. An argument containing
        # quotes adds a third and fourth, the exemption stops applying, and the
        # quotes around the script path are eaten. 'call' means the text no
        # longer starts with a quote, so the rule never fires.
        $inner = "call `"$InstallerPath`""
        if ($tail) { $inner = "$inner $tail" }
        return @{ FilePath = 'cmd.exe'; Arguments = "/c $inner"
                  WorkingDirectory = (Get-ParentPath $InstallerPath)
                  Display = "cmd.exe /c $inner" }
    }

    if ($upper -eq 'EXE') {
        $value = $null
        if ($tail) { $value = $tail }
        $display = $InstallerPath
        if ($tail) { $display = "$InstallerPath $tail" }
        return @{ FilePath = $InstallerPath; Arguments = $value; WorkingDirectory = $null
                  Display = $display }
    }

    throw "Unknown installer type: $Type. Use EXE, MSI or BAT."
}

function Start-InstallerProcess {
    param([Parameter(Mandatory)]$Command)

    $parameters = @{
        FilePath    = $Command.FilePath
        Wait        = $true
        PassThru    = $true
        NoNewWindow = $true
    }
    if ($Command.Arguments) { $parameters['ArgumentList'] = $Command.Arguments }
    if ($Command.WorkingDirectory -and (Test-Path -LiteralPath $Command.WorkingDirectory)) {
        $parameters['WorkingDirectory'] = $Command.WorkingDirectory
    }
    return Start-Process @parameters
}

# ------------------------------------------------------------------- PATH

function Get-EnvRegistryKey {
    param([ValidateSet('Machine', 'User')][string]$Scope, [switch]$Writable)

    $machineKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $hive = if ($Scope -eq 'Machine') { [Microsoft.Win32.Registry]::LocalMachine }
            else { [Microsoft.Win32.Registry]::CurrentUser }
    if (-not $hive) { throw 'The Windows registry is not available on this platform.' }

    $subKey = if ($Scope -eq 'Machine') { $machineKey } else { 'Environment' }
    return $hive.OpenSubKey($subKey, [bool]$Writable)
}

function Get-PersistentPath {
    <#
        Read through the RegistryKey API with DoNotExpandEnvironmentNames.
        Get-ItemProperty expands REG_EXPAND_SZ, and writing that back replaces
        every %SystemRoot% on the machine with a literal path.
    #>
    param([ValidateSet('Machine', 'User')][string]$Scope)

    $key = Get-EnvRegistryKey -Scope $Scope
    if (-not $key) { return '' }
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [string]$value
    }
    finally { $key.Close() }
}

function Get-PersistentPathKind {
    param([ValidateSet('Machine', 'User')][string]$Scope)
    $key = Get-EnvRegistryKey -Scope $Scope
    if (-not $key) { return [Microsoft.Win32.RegistryValueKind]::Unknown }
    try { return $key.GetValueKind('Path') }
    catch { return [Microsoft.Win32.RegistryValueKind]::Unknown }
    finally { $key.Close() }
}

function Set-PersistentPath {
    <#
        Writes PATH back, preserving its value kind and confirming the write
        landed. A silent failure here is worse than a loud one: the install
        reports success and the application is not on PATH.
    #>
    param([ValidateSet('Machine', 'User')][string]$Scope, [Parameter(Mandatory)][string]$Value)

    if ($Value.Length -gt 32767) {
        throw "The new PATH is $($Value.Length) characters, over the 32767 registry limit. Refusing to write a value Windows would truncate."
    }

    $kind = Get-PersistentPathKind -Scope $Scope
    if ($kind -eq [Microsoft.Win32.RegistryValueKind]::Unknown) {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    }

    $key = Get-EnvRegistryKey -Scope $Scope -Writable
    if (-not $key) {
        throw "Could not open the $Scope environment key for writing. Machine scope needs administrator or SYSTEM rights."
    }
    try { $key.SetValue('Path', $Value, $kind) }
    finally { $key.Close() }

    $readBack = Get-PersistentPath -Scope $Scope
    if ($readBack -ne $Value) {
        throw "The PATH write did not land: wrote $($Value.Length) characters, read back $($readBack.Length)."
    }
}

function Split-PathString {
    param([string]$Value)
    if (-not $Value) { return @() }
    return @($Value -split ';' | Where-Object { $_ -ne '' })
}

function Test-PathEntriesEqual {
    <#
        Case-insensitive, ignoring a trailing slash, and treating %VAR% as
        equal to its expansion - so a directory is never added twice under two
        spellings.
    #>
    param([string]$A, [string]$B)

    if (-not $A -or -not $B) { return $false }
    $normA = $A.TrimEnd('\', '/')
    $normB = $B.TrimEnd('\', '/')
    if ($normA.Equals($normB, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    try {
        $expA = ([Environment]::ExpandEnvironmentVariables($normA)).TrimEnd('\', '/')
        $expB = ([Environment]::ExpandEnvironmentVariables($normB)).TrimEnd('\', '/')
        return $expA.Equals($expB, [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Test-PathEntry {
    param([string]$Entry, [ValidateSet('Machine', 'User')][string]$Scope)
    foreach ($part in (Split-PathString (Get-PersistentPath -Scope $Scope))) {
        if (Test-PathEntriesEqual $part $Entry) { return $true }
    }
    return $false
}

function Add-PathEntry {
    param([Parameter(Mandatory)][string]$Entry, [ValidateSet('Machine', 'User')][string]$Scope)

    $result = @{ Action = 'None'; Success = $true; Message = '' }
    $current = Get-PersistentPath -Scope $Scope
    $parts = @(Split-PathString $current)

    foreach ($part in $parts) {
        if (Test-PathEntriesEqual $part $Entry) {
            $result.Action = 'AlreadyPresent'
            $result.Message = "$Scope PATH already contains $Entry"
            return $result
        }
    }

    $updated = if ($current) { "$($current.TrimEnd(';'));$Entry" } else { $Entry }
    try {
        Set-PersistentPath -Scope $Scope -Value $updated
        $result.Action = 'Added'
        $result.Message = "Added to $Scope PATH: $Entry"
    }
    catch {
        $result.Action = 'Failed'
        $result.Success = $false
        $result.Message = "Could not add to $Scope PATH: $($_.Exception.Message)"
    }
    return $result
}

function Remove-PathEntry {
    param([Parameter(Mandatory)][string]$Entry, [ValidateSet('Machine', 'User')][string]$Scope)

    $result = @{ Action = 'None'; Success = $true; Message = '' }
    $current = Get-PersistentPath -Scope $Scope
    $parts = @(Split-PathString $current)

    $kept = @()
    $removed = $false
    foreach ($part in $parts) {
        if (Test-PathEntriesEqual $part $Entry) { $removed = $true }
        else { $kept += $part }
    }

    if (-not $removed) {
        $result.Action = 'NotFound'
        $result.Message = "$Scope PATH does not contain $Entry"
        return $result
    }

    try {
        Set-PersistentPath -Scope $Scope -Value ($kept -join ';')
        $result.Action = 'Removed'
        $result.Message = "Removed from $Scope PATH: $Entry"
    }
    catch {
        $result.Action = 'Failed'
        $result.Success = $false
        $result.Message = "Could not remove from $Scope PATH: $($_.Exception.Message)"
    }
    return $result
}

function Send-EnvironmentChange {
    # Tells running processes the environment changed, so a new console picks
    # up PATH without a sign-out.
    $signature = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@
    try {
        if (-not ('IpbNative' -as [type])) {
            Add-Type -MemberDefinition $signature -Name 'IpbNative' -Namespace 'Win32' | Out-Null
        }
        $result = [System.IntPtr]::Zero
        [Win32.IpbNative]::SendMessageTimeout([System.IntPtr]0xffff, 0x1A, [System.IntPtr]::Zero,
            'Environment', 2, 5000, [ref]$result) | Out-Null
        return @{ Success = $true; Message = 'Broadcast the environment change.' }
    }
    catch {
        return @{ Success = $false; Message = "Could not broadcast the environment change: $($_.Exception.Message)" }
    }
}

# --------------------------------------------------------------- registry

function Test-RegKey {
    param([Parameter(Mandatory)][string]$Path)
    try { return [bool](Test-Path -LiteralPath $Path) }
    catch { return $false }
}

function Set-RegValue {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = '', [AllowNull()]$Value = '')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $valueName = $Name
    if (-not $valueName) { $valueName = '(default)' }
    New-ItemProperty -LiteralPath $Path -Name $valueName -Value $Value -PropertyType String -Force | Out-Null
}

function Get-RegValue {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = '')
    if (-not (Test-RegKey -Path $Path)) { return $null }
    $valueName = $Name
    if (-not $valueName) { $valueName = '(default)' }
    $item = Get-ItemProperty -LiteralPath $Path -Name $valueName -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    return $item.$valueName
}

function Remove-RegKey {
    <#
        Removes one key and its subtree.

        Callers only ever pass a key this package created - a verb named after
        the package's own verb, or a ProgID it registered. Nothing here is ever
        pointed at a shared parent such as Classes\* or Classes\Directory.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-RegKey -Path $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Remove-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (Test-RegKey -Path $Path) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Update-ShellAssociations {
    # SHCNE_ASSOCCHANGED, so new verbs and associations appear without a
    # sign-out. Explorer is never restarted: that closes the user's windows.
    $signature = @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
'@
    try {
        if (-not ('IpbShell' -as [type])) {
            Add-Type -MemberDefinition $signature -Name 'IpbShell' -Namespace 'Win32' | Out-Null
        }
        [Win32.IpbShell]::SHChangeNotify(0x08000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
        return @{ Success = $true; Message = 'Notified Explorer that associations changed.' }
    }
    catch {
        return @{ Success = $false; Message = "Could not notify Explorer: $($_.Exception.Message)" }
    }
}

# --------------------------------------------------------------- shortcuts

function Get-ShellFolder {
    <#
        Intune runs as SYSTEM, where the current user is the system profile and
        not any real person - so the all-users locations are the ones that
        produce a shortcut somebody can actually see.
    #>
    param([ValidateSet('Desktop', 'StartMenu')][string]$Location)

    if ($Location -eq 'Desktop') {
        $public = [Environment]::GetEnvironmentVariable('PUBLIC')
        if (-not $public) { $public = 'C:\Users\Public' }
        return (Join-WindowsPath $public 'Desktop')
    }

    $programData = [Environment]::GetEnvironmentVariable('ProgramData')
    if (-not $programData) { $programData = 'C:\ProgramData' }
    return (Join-WindowsPath $programData 'Microsoft\Windows\Start Menu\Programs')
}

function New-ShortcutFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$Icon = ''
    )

    $parent = Get-ParentPath $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $Target
        if ($Arguments)        { $shortcut.Arguments = $Arguments }
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
        if ($Icon)             { $shortcut.IconLocation = $Icon }
        $shortcut.Save()
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Test-ShortcutFile {
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedTarget = '')

    $exists = $false
    try { $exists = Test-Path -LiteralPath $Path } catch { $exists = $false }
    if (-not $exists) { return @{ Exists = $false; Target = ''; TargetMatches = $false } }

    $target = ''
    try {
        $shell = New-Object -ComObject WScript.Shell
        try { $target = [string]$shell.CreateShortcut($Path).TargetPath }
        finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    catch { $target = '' }

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

function Get-ShortcutPath {
    param([Parameter(Mandatory)]$Shortcut)

    $name = [string](Get-ConfigValue -Record $Shortcut -Key 'Name')
    $location = [string](Get-ConfigValue -Record $Shortcut -Key 'Location' -Default 'Desktop')
    $folder = [string](Get-ConfigValue -Record $Shortcut -Key 'Folder')

    $directory = Get-ShellFolder -Location $location
    if ($folder) { $directory = Join-WindowsPath $directory $folder }
    return (Join-WindowsPath $directory "$name.lnk")
}

# ------------------------------------------------------ ownership tracking

function Get-StatePath {
    param([Parameter(Mandatory)][string]$ApplicationName)
    return (Join-WindowsPath (Join-WindowsPath $script:StateRoot $ApplicationName) 'package-state.json')
}

function Get-LegacyStatePath {
    # Packages built by the previous framework recorded ownership elsewhere.
    # A machine holding one has state this package cannot see, so uninstall
    # would silently leave its PATH entries and shortcuts behind. Reading the
    # old location is cheap; the alternative is permanent orphaning.
    param([Parameter(Mandatory)][string]$ApplicationName)
    return (Join-WindowsPath (Join-WindowsPath $script:LegacyStateRoot $ApplicationName) 'environment-state.json')
}

function Save-PackageState {
    <#
        Records what this package created, so uninstall removes that and
        nothing else. A resource found already in place is recorded with
        PreExisting so it is never removed.
    #>
    param(
        [Parameter(Mandatory)][string]$ApplicationName,
        [array]$Resources = @()
    )

    $path = Get-StatePath -ApplicationName $ApplicationName
    $directory = Get-ParentPath $path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $state = @{
        ApplicationName = $ApplicationName
        InstallDate     = (Get-Date -Format 'o')
        Builder         = 'Intune Package Builder'
        Resources       = $Resources
    }
    $state | ConvertTo-Json -Depth 6 | Out-File -FilePath $path -Encoding utf8 -Force
    return $path
}

function Get-PackageState {
    param([Parameter(Mandatory)][string]$ApplicationName)

    $path = Get-StatePath -ApplicationName $ApplicationName
    $present = $false
    try { $present = Test-Path -LiteralPath $path } catch { $present = $false }
    if (-not $present) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-LegacyPackageState {
    <#
        Reads PATH ownership recorded by the previous framework. Only the PATH
        entries are read: a stale PATH entry is the orphan that actually harms
        a machine, and the rest of the old format has no equivalent here.
    #>
    param([Parameter(Mandatory)][string]$ApplicationName)

    $path = Get-LegacyStatePath -ApplicationName $ApplicationName
    $present = $false
    try { $present = Test-Path -LiteralPath $path } catch { $present = $false }
    if (-not $present) { return $null }

    try {
        $legacy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @{
            Path    = $path
            Machine = @(Get-ConfigValue -Record $legacy -Key 'MachinePathEntriesAdded' -Default @())
            User    = @(Get-ConfigValue -Record $legacy -Key 'UserPathEntriesAdded' -Default @())
        }
    }
    catch { return $null }
}

function Remove-PackageState {
    param([Parameter(Mandatory)][string]$ApplicationName)
    $path = Get-StatePath -ApplicationName $ApplicationName
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
