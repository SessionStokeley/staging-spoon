#Requires -Version 5.1

# Shared helper functions for PATH and environment variable management.
# Dot-source this file from Install.ps1, Uninstall.ps1, or Test-Local.ps1.

# Install.ps1 and Uninstall.ps1 define their own Write-Log. This fallback keeps
# the orchestrators usable when the helper is dot-sourced anywhere else
# (Test-Local.ps1, the Studio, the test suite), where a missing Write-Log would
# otherwise abort the whole environment step.
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param([string]$Message, [string]$LogFile)
        if (-not $LogFile) { return }
        $entry = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        $entry | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
}

# Registry locations of the persistent environment blocks.
$script:MachineEnvKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:UserEnvKey    = 'Environment'

function Get-EnvRegistryKey {
    <#
        Opens the environment registry key for a scope.

        The raw RegistryKey API is used rather than Get-ItemProperty because
        only it can read a REG_EXPAND_SZ without expanding it - see
        Get-PersistentPath.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope,
        [switch]$Writable
    )

    # Fail with a clear reason off-Windows instead of a null-reference error.
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        throw 'The Windows registry is not available on this platform. PATH management requires Windows.'
    }

    $hive = if ($Scope -eq 'Machine') {
        [Microsoft.Win32.Registry]::LocalMachine
    }
    else {
        [Microsoft.Win32.Registry]::CurrentUser
    }
    if (-not $hive) {
        throw 'The Windows registry is not available on this platform. PATH management requires Windows.'
    }

    $subKey = if ($Scope -eq 'Machine') { $script:MachineEnvKey } else { $script:UserEnvKey }
    return $hive.OpenSubKey($subKey, [bool]$Writable)
}

function Normalize-PathEntry {
    param([string]$Path)
    if (-not $Path) { return $null }
    $Path = $Path.TrimEnd('\', '/')
    return $Path
}

function Expand-PathEntry {
    <#
        Expands %VARIABLES% for comparison purposes only. The raw form is
        always what gets written back to the registry.
    #>
    param([string]$Path)
    if (-not $Path) { return $null }
    try { return [Environment]::ExpandEnvironmentVariables($Path) }
    catch { return $Path }
}

function Test-PathEntriesEqual {
    <#
        Case-insensitive comparison that ignores trailing slashes and treats
        an expandable entry as equal to its expanded form, so
        '%ProgramFiles%\App' and 'C:\Program Files\App' are recognised as the
        same directory rather than added twice.
    #>
    param([string]$A, [string]$B)

    $normA = Normalize-PathEntry $A
    $normB = Normalize-PathEntry $B
    if (-not $normA -or -not $normB) { return $false }

    if ($normA.Equals($normB, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    $expA = Normalize-PathEntry (Expand-PathEntry $normA)
    $expB = Normalize-PathEntry (Expand-PathEntry $normB)
    if (-not $expA -or -not $expB) { return $false }

    return ($expA.Equals($expB, [StringComparison]::OrdinalIgnoreCase))
}

function Get-PersistentPath {
    <#
        Reads the persistent PATH for a scope, WITHOUT expanding environment
        variables.

        This must not use Get-ItemProperty or [Environment]::GetEnvironmentVariable:
        both expand REG_EXPAND_SZ, so '%SystemRoot%\system32' comes back as
        'C:\Windows\system32'. Writing that expanded text back would strip every
        %VAR% out of the machine PATH permanently.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope
    )

    $key = $null
    try {
        $key = Get-EnvRegistryKey -Scope $Scope
        if (-not $key) { return '' }

        $value = $key.GetValue(
            'Path', '',
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

        if ($null -eq $value) { return '' }
        return [string]$value
    }
    finally {
        if ($key) { $key.Close() }
    }
}

function Get-PersistentPathKind {
    <#
        Returns the registry value kind of the PATH value so a write can
        preserve it (normally ExpandString).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope
    )

    $key = $null
    try {
        $key = Get-EnvRegistryKey -Scope $Scope
        if (-not $key) { return [Microsoft.Win32.RegistryValueKind]::ExpandString }

        $kind = $key.GetValueKind('Path')
        # Never downgrade to REG_SZ: PATH is expected to be REG_EXPAND_SZ, and
        # a REG_SZ PATH stops %VAR% entries resolving for other software.
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::String) {
            return [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
        return $kind
    }
    catch {
        return [Microsoft.Win32.RegistryValueKind]::ExpandString
    }
    finally {
        if ($key) { $key.Close() }
    }
}

function Set-PersistentPath {
    <#
        Writes the persistent PATH for a scope and confirms the write landed.

        Throws on failure so callers report a real reason instead of silently
        reporting success for a PATH that was never changed.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    # The registry caps a value at 32767 characters. Refuse rather than let
    # Windows truncate a PATH, which is unrecoverable for the machine.
    if ($Value.Length -gt 32767) {
        throw "The resulting $Scope PATH would be $($Value.Length) characters, over the 32767 limit. No change was made."
    }

    $kind = Get-PersistentPathKind -Scope $Scope

    $key = $null
    try {
        $key = Get-EnvRegistryKey -Scope $Scope -Writable
        if (-not $key) {
            throw "Could not open the $Scope environment registry key for writing. Machine scope requires administrator or SYSTEM rights."
        }
        $key.SetValue('Path', $Value, $kind)
        $key.Flush()
    }
    catch [System.UnauthorizedAccessException] {
        throw "Access denied writing the $Scope PATH. Machine scope requires administrator or SYSTEM rights."
    }
    finally {
        if ($key) { $key.Close() }
    }

    # Read back: a write that did not persist must not look like success.
    $written = Get-PersistentPath -Scope $Scope
    if ($written -ne $Value) {
        throw "The $Scope PATH did not persist. Expected $($Value.Length) characters, read back $($written.Length)."
    }
}

function Split-PathString {
    <#
        Splits a ';'-separated value into its entries, dropping empty segments.
        Used for PATH and for any other variable held as a list.
    #>
    param([string]$PathString)
    if (-not $PathString) { return @() }
    return @($PathString -split ';' | Where-Object { $_.Trim() -ne '' })
}

function Join-PathEntries {
    param([string[]]$Entries)
    return ($Entries -join ';')
}

function Add-ValueToList {
    <#
        .SYNOPSIS
        Adds one entry to a ';'-separated list without disturbing what is
        already there.

        .DESCRIPTION
        The shared list primitive behind both PATH and list-style environment
        variables, so appending behaves identically for each. Existing entries
        keep their original text and order; the entry is only added when it is
        not already present (case-insensitively, ignoring trailing slashes, and
        treating %VAR% as equal to its expanded form).

        .OUTPUTS
        Changed  whether the list needs writing back
        Value    the resulting list
        Reason   'Added' or 'AlreadyPresent'
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$CurrentValue,
        [Parameter(Mandatory)][string]$NewValue,
        [ValidateSet('Append', 'Prepend')][string]$Position = 'Append'
    )

    $normalized = Normalize-PathEntry $NewValue
    if (-not $normalized) {
        return [pscustomobject]@{ Changed = $false; Value = $CurrentValue; Reason = 'Empty' }
    }

    $entries = @(Split-PathString $CurrentValue)

    foreach ($existing in $entries) {
        if (Test-PathEntriesEqual $existing $normalized) {
            return [pscustomobject]@{ Changed = $false; Value = $CurrentValue; Reason = 'AlreadyPresent' }
        }
    }

    $updated = if ($Position -eq 'Prepend') { @($normalized) + $entries } else { $entries + @($normalized) }

    return [pscustomobject]@{
        Changed = $true
        Value   = Join-PathEntries $updated
        Reason  = 'Added'
    }
}

function Remove-ValueFromList {
    <#
        .SYNOPSIS
        Removes one entry from a ';'-separated list, leaving every other entry
        exactly as it was.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$CurrentValue,
        [Parameter(Mandatory)][string]$ValueToRemove
    )

    $entries = @(Split-PathString $CurrentValue)
    $kept = @($entries | Where-Object { -not (Test-PathEntriesEqual $_ $ValueToRemove) })

    if ($kept.Count -eq $entries.Count) {
        return [pscustomobject]@{ Changed = $false; Value = $CurrentValue; Reason = 'NotFound' }
    }

    return [pscustomobject]@{
        Changed = $true
        Value   = Join-PathEntries $kept
        Reason  = 'Removed'
    }
}

function Test-PathEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Entry,
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope
    )
    $currentPath = Get-PersistentPath -Scope $Scope
    $entries = Split-PathString $currentPath
    foreach ($existing in $entries) {
        if (Test-PathEntriesEqual $existing $Entry) { return $true }
    }
    return $false
}

function Add-PathEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Entry,
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,
        # Retained so existing callers keep working. Adding only when missing
        # is now unconditional, since adding a duplicate is never correct.
        [switch]$AddIfMissing
    )
    $result = @{ Action = 'None'; Success = $true; Message = '' }

    $normalized = Normalize-PathEntry $Entry
    if (-not $normalized) {
        $result.Success = $false
        $result.Message = 'Empty path entry.'
        return $result
    }

    $currentPath = Get-PersistentPath -Scope $Scope
    $entries = Split-PathString $currentPath

    foreach ($existing in $entries) {
        if (Test-PathEntriesEqual $existing $normalized) {
            $result.Action = 'AlreadyExists'
            $result.Message = "PATH entry already exists in $Scope scope: $normalized"
            return $result
        }
    }

    # The duplicate check above already implements "add only if missing", so
    # reaching here means the entry is absent and must be added. The previous
    # gate here evaluated to false whenever AddIfMissing was passed as $false,
    # which skipped the write silently and then failed validation with no
    # reason logged.
    $entries += $normalized
    $newPath = Join-PathEntries $entries

    try {
        Set-PersistentPath -Scope $Scope -Value $newPath
        $result.Action = 'Added'
        $result.Message = "PATH entry added to $Scope scope: $normalized"
    }
    catch {
        $result.Success = $false
        $result.Action = 'Failed'
        $result.Message = "Failed to modify $Scope PATH: $($_.Exception.Message)"
    }

    return $result
}

function Remove-PathEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Entry,
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope
    )
    $result = @{ Action = 'None'; Success = $true; Message = '' }

    $normalized = Normalize-PathEntry $Entry
    if (-not $normalized) {
        $result.Success = $false
        $result.Message = 'Empty path entry.'
        return $result
    }

    $currentPath = Get-PersistentPath -Scope $Scope
    $entries = Split-PathString $currentPath
    $filtered = @($entries | Where-Object { -not (Test-PathEntriesEqual $_ $normalized) })

    if ($filtered.Count -eq $entries.Count) {
        $result.Action = 'NotFound'
        $result.Message = "PATH entry not found in $Scope scope: $normalized"
        return $result
    }

    $newPath = Join-PathEntries $filtered
    try {
        Set-PersistentPath -Scope $Scope -Value $newPath
        $result.Action = 'Removed'
        $result.Message = "PATH entry removed from $Scope scope: $normalized"
    }
    catch {
        $result.Success = $false
        $result.Action = 'Failed'
        $result.Message = "Failed to modify $Scope PATH: $($_.Exception.Message)"
    }

    return $result
}

function Get-PersistentVariable {
    <#
        Reads a persistent environment variable WITHOUT expanding it, so an
        append never rewrites %VAR% references as literal paths. Returns $null
        when the variable does not exist, which is distinct from an empty value.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope
    )

    $key = $null
    try {
        $key = Get-EnvRegistryKey -Scope $Scope
        if (-not $key) { return $null }

        $value = $key.GetValue(
            $Name, $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

        if ($null -eq $value) { return $null }
        return [string]$value
    }
    finally {
        if ($key) { $key.Close() }
    }
}

function Set-PersistentVariable {
    <#
        Writes a persistent environment variable and confirms it landed.
        Preserves REG_EXPAND_SZ when the value contains %VAR% references.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope,
        [switch]$Expandable
    )

    if ($Value.Length -gt 32767) {
        throw "The resulting value of $Name would be $($Value.Length) characters, over the 32767 limit. No change was made."
    }

    # A value containing %VAR% must be REG_EXPAND_SZ or it will never resolve.
    $kind = if ($Expandable -or $Value -match '%\w+%') {
        [Microsoft.Win32.RegistryValueKind]::ExpandString
    }
    else {
        [Microsoft.Win32.RegistryValueKind]::String
    }

    $key = $null
    try {
        $key = Get-EnvRegistryKey -Scope $Scope -Writable
        if (-not $key) {
            throw "Could not open the $Scope environment key for writing. Machine scope requires administrator or SYSTEM rights."
        }
        $key.SetValue($Name, $Value, $kind)
        $key.Flush()
    }
    catch [System.UnauthorizedAccessException] {
        throw "Access denied writing $Name in $Scope scope. Machine scope requires administrator or SYSTEM rights."
    }
    finally {
        if ($key) { $key.Close() }
    }

    $written = Get-PersistentVariable -Name $Name -Scope $Scope
    if ($written -ne $Value) {
        throw "$Name did not persist in $Scope scope."
    }
}

function Remove-PersistentVariable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope
    )

    $key = $null
    try {
        $key = Get-EnvRegistryKey -Scope $Scope -Writable
        if (-not $key) {
            throw "Could not open the $Scope environment key for writing."
        }
        $key.DeleteValue($Name, $false)
        $key.Flush()
    }
    catch [System.UnauthorizedAccessException] {
        throw "Access denied removing $Name from $Scope scope."
    }
    finally {
        if ($key) { $key.Close() }
    }
}

function Add-EnvironmentVariable {
    <#
        .SYNOPSIS
        Creates or updates a persistent environment variable.

        .PARAMETER Mode
        Append   add Value to the variable's ';'-separated list, keeping every
                 existing entry. This is what application installs normally
                 need for list variables such as CLASSPATH or PSModulePath.
        Prepend  as Append, but the new entry goes first so it wins.
        Set      replace the whole value. Correct for single-value variables
                 such as JAVA_HOME.

        Append and Prepend are idempotent: re-running never duplicates an entry.
        Whatever the mode, the previous value is returned so uninstall can put
        the variable back exactly as it was.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,
        [switch]$Expandable,
        [ValidateSet('Set', 'Append', 'Prepend')]
        [string]$Mode = 'Set'
    )

    $result = @{
        Action        = 'None'
        Success       = $true
        Message       = ''
        Existed       = $false
        PreviousValue = $null
        Mode          = $Mode
    }

    try {
        $existing = Get-PersistentVariable -Name $Name -Scope $Scope
        $result.Existed = ($null -ne $existing)
        $result.PreviousValue = $existing

        if ($Mode -eq 'Set') {
            if ($existing -eq $Value) {
                $result.Action = 'AlreadyPresent'
                $result.Message = "$Name already has this value in $Scope scope. No change required."
                return $result
            }

            Set-PersistentVariable -Name $Name -Value $Value -Scope $Scope -Expandable:$Expandable

            if ($result.Existed) {
                $result.Action = 'Replaced'
                $result.Message = "$Name replaced in $Scope scope. Previous value preserved for uninstall: $existing"
            }
            else {
                $result.Action = 'Created'
                $result.Message = "$Name created in $Scope scope = $Value"
            }
            return $result
        }

        # Append / Prepend: never discard what is already there.
        $listResult = Add-ValueToList -CurrentValue $existing -NewValue $Value -Position $Mode

        if (-not $listResult.Changed) {
            $result.Action = if ($listResult.Reason -eq 'Empty') { 'Failed' } else { 'AlreadyPresent' }
            if ($listResult.Reason -eq 'Empty') {
                $result.Success = $false
                $result.Message = "No value supplied for $Name."
            }
            else {
                $result.Message = "$Name already contains '$Value' in $Scope scope. No change required."
            }
            return $result
        }

        Set-PersistentVariable -Name $Name -Value $listResult.Value -Scope $Scope -Expandable:$Expandable

        $result.Action = if ($result.Existed) { 'Appended' } else { 'Created' }
        $result.Message = if ($result.Existed) {
            "$Name in $Scope scope: appended '$Value' to the existing list ($(@(Split-PathString $existing).Count) entry/entries kept)."
        }
        else {
            "$Name created in $Scope scope = $Value"
        }
        return $result
    }
    catch {
        $result.Success = $false
        $result.Action = 'Failed'
        $result.Message = "Failed to set $Name in $Scope scope: $($_.Exception.Message)"
        return $result
    }
}

function Remove-EnvironmentVariable {
    <#
        .SYNOPSIS
        Undoes what this package did to an environment variable.

        .DESCRIPTION
        Removes only the package's own contribution:

          appended to an existing variable -> that entry is removed and every
            other entry is left in place
          created by this package          -> the variable is deleted
          replaced an existing value       -> the previous value is restored

        .PARAMETER Value
        The entry this package added. Required to un-append.

        .PARAMETER Existed
        Whether the variable was already present before installation.

        .PARAMETER PreviousValue
        The value the variable held before installation, used to restore a
        replaced variable.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,
        [ValidateSet('Set', 'Append', 'Prepend')]
        [string]$Mode = 'Set',
        [AllowEmptyString()][AllowNull()]
        [string]$Value,
        [bool]$Existed = $false,
        [AllowEmptyString()][AllowNull()]
        [string]$PreviousValue
    )

    $result = @{ Action = 'None'; Success = $true; Message = '' }

    try {
        $current = Get-PersistentVariable -Name $Name -Scope $Scope
        if ($null -eq $current) {
            $result.Action = 'NotFound'
            $result.Message = "Environment variable not found: $Name (Scope: $Scope)"
            return $result
        }

        # Appended to a variable that already existed: take out only our entry.
        if ($Mode -in @('Append', 'Prepend') -and $Existed) {
            if (-not $Value) {
                $result.Action = 'Skipped'
                $result.Message = "$Name was appended to but no entry was recorded, so nothing was removed."
                return $result
            }

            $listResult = Remove-ValueFromList -CurrentValue $current -ValueToRemove $Value
            if (-not $listResult.Changed) {
                $result.Action = 'NotFound'
                $result.Message = "$Name no longer contains '$Value'. Left unchanged."
                return $result
            }

            if ([string]::IsNullOrWhiteSpace($listResult.Value)) {
                # Every entry is gone; restore what was there before, or delete.
                if ($PreviousValue) {
                    Set-PersistentVariable -Name $Name -Value $PreviousValue -Scope $Scope
                    $result.Action = 'Restored'
                    $result.Message = "$Name restored to its pre-install value in $Scope scope."
                }
                else {
                    Remove-PersistentVariable -Name $Name -Scope $Scope
                    $result.Action = 'Removed'
                    $result.Message = "$Name removed from $Scope scope (no entries left)."
                }
                return $result
            }

            Set-PersistentVariable -Name $Name -Value $listResult.Value -Scope $Scope
            $result.Action = 'EntryRemoved'
            $result.Message = "$Name in $Scope scope: removed '$Value', kept $(@(Split-PathString $listResult.Value).Count) other entry/entries."
            return $result
        }

        # Replaced a variable that already existed: restore the old value.
        if ($Existed -and $PreviousValue) {
            Set-PersistentVariable -Name $Name -Value $PreviousValue -Scope $Scope
            $result.Action = 'Restored'
            $result.Message = "$Name restored to its pre-install value in $Scope scope."
            return $result
        }

        # This package created the variable, so it owns the whole thing.
        Remove-PersistentVariable -Name $Name -Scope $Scope
        $result.Action = 'Removed'
        $result.Message = "Environment variable removed: $Name (Scope: $Scope)"
        return $result
    }
    catch {
        $result.Success = $false
        $result.Action = 'Failed'
        $result.Message = "Failed to remove $Name from $Scope scope: $($_.Exception.Message)"
        return $result
    }
}

function Get-PathDiagnostics {
    <#
        .SYNOPSIS
        Reports why PATH registration is or is not working on this machine.

        .DESCRIPTION
        Read-only. Shows the identity, whether each scope is writable, the raw
        (unexpanded) PATH, and whether expandable variables are still intact.
        Run this first when a PATH change reports failure.
    #>
    param([string[]]$Entries = @())

    $identity = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { 'unknown' }
    $isAdmin = $false
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { }

    Write-Host ''
    Write-Host 'PATH Diagnostics' -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host "  Identity      : $identity"
    Write-Host "  Elevated      : $isAdmin"
    Write-Host "  PowerShell    : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Host "  Process bits  : $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' })"

    foreach ($scope in @('Machine', 'User')) {
        Write-Host ''
        Write-Host "  $scope scope" -ForegroundColor White
        Write-Host ('  ' + ('-' * 40))

        # Readable?
        try {
            $raw = Get-PersistentPath -Scope $scope
            $entryList = @(Split-PathString $raw)
            Write-Host "    Readable        : yes"
            Write-Host "    Entries         : $($entryList.Count)"
            Write-Host "    Length          : $($raw.Length) / 32767 characters"

            $kind = Get-PersistentPathKind -Scope $scope
            Write-Host "    Value kind      : $kind"

            $expandable = @($entryList | Where-Object { $_ -match '%\w+%' })
            Write-Host "    Expandable vars : $($expandable.Count)"
            foreach ($e in ($expandable | Select-Object -First 5)) {
                Write-Host "                      $e" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "    Readable        : NO - $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        # Writable? Rewrites the current value unchanged, so nothing is altered.
        try {
            $key = Get-EnvRegistryKey -Scope $scope -Writable
            if ($key) {
                Write-Host "    Writable        : yes"
                $key.Close()
            }
            else {
                Write-Host "    Writable        : NO (key could not be opened for writing)" -ForegroundColor Red
                if ($scope -eq 'Machine' -and -not $isAdmin) {
                    Write-Host "                      Machine scope needs administrator or SYSTEM." -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host "    Writable        : NO - $($_.Exception.Message)" -ForegroundColor Red
            if ($scope -eq 'Machine' -and -not $isAdmin) {
                Write-Host "                      Machine scope needs administrator or SYSTEM." -ForegroundColor Yellow
            }
        }

        foreach ($entry in $Entries) {
            $present = Test-PathEntry -Entry $entry -Scope $scope
            $color = if ($present) { 'Green' } else { 'Yellow' }
            Write-Host "    Registered      : $present  <- $entry" -ForegroundColor $color
        }
    }

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host 'Nothing was modified by this check.' -ForegroundColor Green
    Write-Host ''
}

function Broadcast-EnvironmentChange {
    $result = @{ Success = $true; Message = '' }

    try {
        if (-not ('Win32.NativeMethods' -as [type])) {
            Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }

        $HWND_BROADCAST = [IntPtr]0xFFFF
        $WM_SETTINGCHANGE = 0x001A
        $SMTO_ABORTIFHUNG = 0x0002
        $timeout = 5000
        $lpdwResult = [UIntPtr]::Zero

        [Win32.NativeMethods]::SendMessageTimeout(
            $HWND_BROADCAST,
            $WM_SETTINGCHANGE,
            [UIntPtr]::Zero,
            'Environment',
            $SMTO_ABORTIFHUNG,
            $timeout,
            [ref]$lpdwResult
        ) | Out-Null

        $result.Message = 'Environment change broadcast sent (WM_SETTINGCHANGE).'
    }
    catch {
        $result.Success = $false
        $result.Message = "Failed to broadcast environment change: $($_.Exception.Message)"
    }

    return $result
}

function Test-CommandResolution {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )
    $result = @{ Found = $false; Path = $null; Message = '' }

    try {
        $whereOutput = & where.exe $Command 2>$null
        if ($LASTEXITCODE -eq 0 -and $whereOutput) {
            $resolved = ($whereOutput | Select-Object -First 1).Trim()
            $result.Found = $true
            $result.Path = $resolved
            $result.Message = "Resolved: $resolved"
        }
        else {
            $result.Message = "Command not found in PATH: $Command"
        }
    }
    catch {
        $result.Message = "Resolution check failed: $($_.Exception.Message)"
    }

    return $result
}

function Find-CliDirectories {
    param(
        [Parameter(Mandatory)]
        [string]$InstallPath
    )
    if (-not (Test-Path $InstallPath)) { return @() }

    $cliPatterns = @('*cli*', '*cmd*', '*tool*', '*ctl*', '*console*')
    $cliDirNames = @('bin', 'tools', 'cli', 'cmd')
    $exeExtensions = @('.exe', '.cmd', '.bat')

    $candidates = @()

    $allDirs = @($InstallPath) + @(Get-ChildItem -Path $InstallPath -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

    foreach ($dir in $allDirs) {
        $dirName = Split-Path $dir -Leaf
        $executables = @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | Where-Object {
            $exeExtensions -contains $_.Extension.ToLower()
        })

        if ($executables.Count -eq 0) { continue }

        $cliExes = @()
        $confidence = 'Low'

        foreach ($exe in $executables) {
            $nameNoExt = $exe.BaseName.ToLower()
            $isCli = $false

            if ($cliDirNames -contains $dirName.ToLower()) {
                $isCli = $true
                $confidence = 'High'
            }
            else {
                foreach ($pattern in $cliPatterns) {
                    if ($nameNoExt -like $pattern) {
                        $isCli = $true
                        if ($confidence -ne 'High') { $confidence = 'Medium' }
                        break
                    }
                }
            }

            $cliExes += @{
                Name       = $exe.Name
                FullPath   = $exe.FullName
                IsCli      = $isCli
                Confidence = if ($isCli) { $confidence } else { 'Low' }
            }
        }

        # @() keeps a single match an array; without it .Count is missing when
        # exactly one executable matches and strict mode is on.
        $hasCli = @($cliExes | Where-Object { $_.IsCli }).Count -gt 0
        if (-not $hasCli -and $dir -eq $InstallPath) {
            if ($executables.Count -gt 0) { $hasCli = $true }
        }

        if ($hasCli -or ($cliDirNames -contains $dirName.ToLower())) {
            $candidates += @{
                Directory   = $dir
                Executables = $cliExes
                Confidence  = $confidence
            }
        }
    }

    return $candidates
}

# --- State Tracking ---

function Get-EnvironmentStatePath {
    param([string]$ApplicationName)
    $stateDir = Join-Path 'C:\ProgramData\IntunePackagingStudio\State' $ApplicationName
    return Join-Path $stateDir 'environment-state.json'
}

function Save-EnvironmentState {
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationName,
        [string[]]$MachinePathEntries = @(),
        [string[]]$UserPathEntries = @(),
        [hashtable[]]$EnvironmentVariables = @()
    )
    $statePath = Get-EnvironmentStatePath $ApplicationName
    $stateDir = Split-Path $statePath -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
    }

    $state = @{
        ApplicationName           = $ApplicationName
        InstallDate               = (Get-Date -Format 'o')
        MachinePathEntriesAdded   = $MachinePathEntries
        UserPathEntriesAdded      = $UserPathEntries
        EnvironmentVariablesAdded = $EnvironmentVariables
    }

    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $statePath -Encoding utf8 -Force
    return $statePath
}

function Get-EnvironmentState {
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationName
    )
    $statePath = Get-EnvironmentStatePath $ApplicationName
    if (-not (Test-Path $statePath)) { return $null }
    return (Get-Content $statePath -Raw | ConvertFrom-Json)
}

function Remove-EnvironmentState {
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationName
    )
    $statePath = Get-EnvironmentStatePath $ApplicationName
    if (Test-Path $statePath) {
        Remove-Item $statePath -Force
        $stateDir = Split-Path $statePath -Parent
        if (@(Get-ChildItem $stateDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $stateDir -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Orchestration ---

function Install-EnvironmentConfig {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [string]$LogFile
    )
    $envConfig = $Config.Environment
    if (-not $envConfig -or -not $envConfig.Enabled) { return $true }

    $appName = $Config.ApplicationName
    $allSuccess = $true
    $machineAdded = @()
    $userAdded = @()
    $varsAdded = @()

    Write-Log 'Environment configuration started.' $LogFile

    # System PATH
    if ($envConfig.SystemPath -and $envConfig.SystemPath.Enabled) {
        foreach ($entry in $envConfig.SystemPath.Entries) {
            Write-Log "Scope: Machine | Requested PATH: $entry" $LogFile
            $r = Add-PathEntry -Entry $entry -Scope 'Machine'
            Write-Log "$($r.Action): $($r.Message)" $LogFile
            if (-not $r.Success) { $allSuccess = $false }
            if ($r.Action -eq 'Added') { $machineAdded += $entry }
        }
    }

    # User PATH
    if ($envConfig.UserPath -and $envConfig.UserPath.Enabled) {
        Write-Log 'WARNING: User PATH from SYSTEM context only affects the Default user profile.' $LogFile
        foreach ($entry in $envConfig.UserPath.Entries) {
            Write-Log "Scope: User | Requested PATH: $entry" $LogFile
            $r = Add-PathEntry -Entry $entry -Scope 'User'
            Write-Log "$($r.Action): $($r.Message)" $LogFile
            if (-not $r.Success) { $allSuccess = $false }
            if ($r.Action -eq 'Added') { $userAdded += $entry }
        }
    }

    # Environment variables
    if ($envConfig.Variables) {
        foreach ($var in $envConfig.Variables) {
            $scope = if ($var.Scope) { $var.Scope } else { 'Machine' }
            $expandable = if ($null -ne $var.Expandable) { $var.Expandable } else { $false }
            # Append keeps an existing list intact; Set replaces a single value.
            $mode = if ($var.Mode) { $var.Mode } else { 'Set' }

            Write-Log "Environment variable: $($var.Name) (Scope: $scope, Mode: $mode) <- $($var.Value)" $LogFile

            $r = Add-EnvironmentVariable -Name $var.Name -Value $var.Value -Scope $scope `
                -Expandable:$expandable -Mode $mode

            Write-Log "$($r.Action): $($r.Message)" $LogFile
            if (-not $r.Success) { $allSuccess = $false }

            if ($r.Action -eq 'Replaced') {
                Write-Log "  NOTE: $($var.Name) already existed and was replaced. Uninstall will restore the previous value." $LogFile
            }

            # Record what was actually changed, including the pre-install value,
            # so uninstall removes only this package's contribution.
            if ($r.Action -in @('Created', 'Appended', 'Replaced')) {
                $varsAdded += @{
                    Name          = $var.Name
                    Value         = $var.Value
                    Scope         = $scope
                    Mode          = $mode
                    Existed       = $r.Existed
                    PreviousValue = $r.PreviousValue
                }
            }
        }
    }

    # Broadcast
    if ($envConfig.BroadcastChange -ne $false) {
        $bc = Broadcast-EnvironmentChange
        Write-Log $bc.Message $LogFile
        if (-not $bc.Success) { $allSuccess = $false }
    }

    # Validate PATH entries were persisted. A failure here logs why, so the
    # log answers "why did registration fail" without a second run.
    foreach ($check in @(
        @{ Scope = 'Machine'; Section = $envConfig.SystemPath },
        @{ Scope = 'User';    Section = $envConfig.UserPath }
    )) {
        if (-not $check.Section -or -not $check.Section.Enabled) { continue }

        foreach ($entry in $check.Section.Entries) {
            $exists = Test-PathEntry -Entry $entry -Scope $check.Scope
            Write-Log "Validation: $($check.Scope) PATH '$entry' registered = $exists" $LogFile

            if (-not $exists) {
                $allSuccess = $false
                Write-Log "ERROR: $($check.Scope) PATH entry was not registered: $entry" $LogFile

                # Narrow it down for whoever reads the log.
                try {
                    $key = Get-EnvRegistryKey -Scope $check.Scope -Writable
                    if ($key) {
                        $key.Close()
                        Write-Log "  The $($check.Scope) key is writable, so this is not a permissions problem." $LogFile
                    }
                    else {
                        Write-Log "  The $($check.Scope) environment key could not be opened for writing." $LogFile
                        Write-Log "  Machine scope requires administrator or SYSTEM rights." $LogFile
                    }
                }
                catch {
                    Write-Log "  Cannot open the $($check.Scope) environment key: $($_.Exception.Message)" $LogFile
                }

                $current = Get-PersistentPath -Scope $check.Scope
                Write-Log "  Current $($check.Scope) PATH length: $($current.Length) characters." $LogFile
                Write-Log "  Run Test-Local.ps1 -Mode PathDiagnostics for a full report." $LogFile
            }
        }
    }

    # Save state for uninstall
    Save-EnvironmentState -ApplicationName $appName `
        -MachinePathEntries $machineAdded `
        -UserPathEntries $userAdded `
        -EnvironmentVariables $varsAdded | Out-Null

    Write-Log "Environment configuration completed. Success: $allSuccess" $LogFile
    return $allSuccess
}

function Uninstall-EnvironmentConfig {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [string]$LogFile
    )
    $envConfig = $Config.Environment
    if (-not $envConfig -or -not $envConfig.Enabled) { return $true }

    $appName = $Config.ApplicationName
    $allSuccess = $true
    $state = Get-EnvironmentState -ApplicationName $appName

    Write-Log 'Environment cleanup started.' $LogFile

    # Remove only package-owned PATH entries
    if ($envConfig.SystemPath -and $envConfig.SystemPath.Enabled -and $envConfig.SystemPath.RemoveOnUninstall) {
        $entriesToRemove = if ($state -and $state.MachinePathEntriesAdded) { $state.MachinePathEntriesAdded } else { $envConfig.SystemPath.Entries }
        foreach ($entry in $entriesToRemove) {
            Write-Log "Removing Machine PATH: $entry" $LogFile
            $r = Remove-PathEntry -Entry $entry -Scope 'Machine'
            Write-Log "$($r.Action): $($r.Message)" $LogFile
            if (-not $r.Success) { $allSuccess = $false }
        }
    }

    if ($envConfig.UserPath -and $envConfig.UserPath.Enabled -and $envConfig.UserPath.RemoveOnUninstall) {
        $entriesToRemove = if ($state -and $state.UserPathEntriesAdded) { $state.UserPathEntriesAdded } else { $envConfig.UserPath.Entries }
        foreach ($entry in $entriesToRemove) {
            Write-Log "Removing User PATH: $entry" $LogFile
            $r = Remove-PathEntry -Entry $entry -Scope 'User'
            Write-Log "$($r.Action): $($r.Message)" $LogFile
            if (-not $r.Success) { $allSuccess = $false }
        }
    }

    # Remove environment variables
    if ($envConfig.Variables) {
        $varsToRemove = if ($state -and $state.EnvironmentVariablesAdded) {
            $state.EnvironmentVariablesAdded
        }
        else {
            $envConfig.Variables | Where-Object { $_.RemoveOnUninstall -ne $false }
        }
        foreach ($var in $varsToRemove) {
            $scope = if ($var.Scope) { $var.Scope } else { 'Machine' }
            $name = if ($var.Name) { $var.Name } else { $var }
            $mode = if ($var.Mode) { $var.Mode } else { 'Set' }

            # These come from the install-time state file, so an appended entry
            # is un-appended and a replaced variable is restored, rather than
            # the whole variable being deleted.
            $value = if ($var.PSObject.Properties.Name -contains 'Value') { $var.Value } else { $null }
            $existed = if ($var.PSObject.Properties.Name -contains 'Existed') { [bool]$var.Existed } else { $false }
            $previous = if ($var.PSObject.Properties.Name -contains 'PreviousValue') { $var.PreviousValue } else { $null }

            Write-Log "Reverting environment variable: $name (Scope: $scope, Mode: $mode, pre-existing: $existed)" $LogFile

            $r = Remove-EnvironmentVariable -Name $name -Scope $scope -Mode $mode `
                -Value $value -Existed $existed -PreviousValue $previous

            Write-Log "$($r.Action): $($r.Message)" $LogFile
            if (-not $r.Success) { $allSuccess = $false }
        }
    }

    # Broadcast
    if ($envConfig.BroadcastChange -ne $false) {
        $bc = Broadcast-EnvironmentChange
        Write-Log $bc.Message $LogFile
    }

    # Clean up state file
    Remove-EnvironmentState -ApplicationName $appName

    Write-Log "Environment cleanup completed. Success: $allSuccess" $LogFile
    return $allSuccess
}
