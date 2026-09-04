#Requires -Version 5.1

# Shared helper functions for PATH and environment variable management.
# Dot-source this file from Install.ps1, Uninstall.ps1, or Test-Local.ps1.

function Normalize-PathEntry {
    param([string]$Path)
    if (-not $Path) { return $null }
    $Path = $Path.TrimEnd('\', '/')
    return $Path
}

function Test-PathEntriesEqual {
    param([string]$A, [string]$B)
    $normA = Normalize-PathEntry $A
    $normB = Normalize-PathEntry $B
    if (-not $normA -or -not $normB) { return $false }
    return ($normA.Equals($normB, [StringComparison]::OrdinalIgnoreCase))
}

function Get-PersistentPath {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope
    )
    $target = [System.EnvironmentVariableTarget]::$Scope
    $regPath = if ($Scope -eq 'Machine') {
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    }
    else {
        'HKCU:\Environment'
    }
    $prop = Get-ItemProperty -Path $regPath -Name 'Path' -ErrorAction SilentlyContinue
    if ($prop) {
        return $prop.Path
    }
    return [Environment]::GetEnvironmentVariable('Path', $target)
}

function Set-PersistentPath {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,
        [Parameter(Mandatory)]
        [string]$Value
    )
    $regPath = if ($Scope -eq 'Machine') {
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    }
    else {
        'HKCU:\Environment'
    }
    Set-ItemProperty -Path $regPath -Name 'Path' -Value $Value -Type ExpandString
}

function Split-PathString {
    param([string]$PathString)
    if (-not $PathString) { return @() }
    return @($PathString -split ';' | Where-Object { $_.Trim() -ne '' })
}

function Join-PathEntries {
    param([string[]]$Entries)
    return ($Entries -join ';')
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

    if ($AddIfMissing -or (-not $AddIfMissing.IsPresent)) {
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

function Add-EnvironmentVariable {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Value,
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,
        [switch]$Expandable
    )
    $result = @{ Action = 'None'; Success = $true; Message = '' }

    try {
        $regPath = if ($Scope -eq 'Machine') {
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        }
        else {
            'HKCU:\Environment'
        }
        $regType = if ($Expandable) { 'ExpandString' } else { 'String' }
        Set-ItemProperty -Path $regPath -Name $Name -Value $Value -Type $regType
        $result.Action = 'Set'
        $result.Message = "Environment variable set: $Name = $Value (Scope: $Scope)"
    }
    catch {
        $result.Success = $false
        $result.Action = 'Failed'
        $result.Message = "Failed to set $Name in $Scope scope: $($_.Exception.Message)"
    }

    return $result
}

function Remove-EnvironmentVariable {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope
    )
    $result = @{ Action = 'None'; Success = $true; Message = '' }

    try {
        $regPath = if ($Scope -eq 'Machine') {
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        }
        else {
            'HKCU:\Environment'
        }
        $existing = Get-ItemProperty -Path $regPath -Name $Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            $result.Action = 'NotFound'
            $result.Message = "Environment variable not found: $Name (Scope: $Scope)"
            return $result
        }
        Remove-ItemProperty -Path $regPath -Name $Name
        $result.Action = 'Removed'
        $result.Message = "Environment variable removed: $Name (Scope: $Scope)"
    }
    catch {
        $result.Success = $false
        $result.Action = 'Failed'
        $result.Message = "Failed to remove $Name from $Scope scope: $($_.Exception.Message)"
    }

    return $result
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

        $hasCli = ($cliExes | Where-Object { $_.IsCli }).Count -gt 0
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
        if ((Get-ChildItem $stateDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
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
            $r = Add-PathEntry -Entry $entry -Scope 'Machine' -AddIfMissing:($envConfig.SystemPath.AddIfMissing)
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
            $r = Add-PathEntry -Entry $entry -Scope 'User' -AddIfMissing:($envConfig.UserPath.AddIfMissing)
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
            Write-Log "Setting environment variable: $($var.Name) = $($var.Value) (Scope: $scope)" $LogFile
            $r = Add-EnvironmentVariable -Name $var.Name -Value $var.Value -Scope $scope -Expandable:$expandable
            Write-Log "$($r.Action): $($r.Message)" $LogFile
            if (-not $r.Success) { $allSuccess = $false }
            if ($r.Action -eq 'Set') {
                $varsAdded += @{ Name = $var.Name; Value = $var.Value; Scope = $scope }
            }
        }
    }

    # Broadcast
    if ($envConfig.BroadcastChange -ne $false) {
        $bc = Broadcast-EnvironmentChange
        Write-Log $bc.Message $LogFile
        if (-not $bc.Success) { $allSuccess = $false }
    }

    # Validate PATH entries were persisted
    if ($envConfig.SystemPath -and $envConfig.SystemPath.Enabled) {
        foreach ($entry in $envConfig.SystemPath.Entries) {
            $exists = Test-PathEntry -Entry $entry -Scope 'Machine'
            Write-Log "Validation: Machine PATH '$entry' registered = $exists" $LogFile
            if (-not $exists) { $allSuccess = $false }
        }
    }
    if ($envConfig.UserPath -and $envConfig.UserPath.Enabled) {
        foreach ($entry in $envConfig.UserPath.Entries) {
            $exists = Test-PathEntry -Entry $entry -Scope 'User'
            Write-Log "Validation: User PATH '$entry' registered = $exists" $LogFile
            if (-not $exists) { $allSuccess = $false }
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
            Write-Log "Removing environment variable: $name (Scope: $scope)" $LogFile
            $r = Remove-EnvironmentVariable -Name $name -Scope $scope
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
