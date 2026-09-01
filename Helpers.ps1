#Requires -Version 5.1

# Registry path for Machine environment variables (used for REG_EXPAND_SZ-safe PATH writes)
$script:EnvRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

function Initialize-Logging {
    [CmdletBinding()]
    param()

    $logDir = $script:AppConfig.LogDirectory
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $script:LogFile = Join-Path $logDir $script:AppConfig.LogFileName
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR' { Write-Error $Message }
        'WARN'  { Write-Warning $Message }
        default { Write-Verbose $Message }
    }
}

function Send-EnvironmentChangeNotification {
    [CmdletBinding()]
    param()

    # Broadcast WM_SETTINGCHANGE so running processes pick up the new environment.
    # This is what [Environment]::SetEnvironmentVariable does internally, but we
    # need it explicitly when writing to the registry directly to preserve REG_EXPAND_SZ.
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
            [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
            public static extern IntPtr SendMessageTimeout(
                IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
                uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }

    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $result = [UIntPtr]::Zero

    [Win32.NativeMethods]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero,
        'Environment', $SMTO_ABORTIFHUNG, 5000, [ref]$result
    ) | Out-Null

    Write-Log 'Broadcast WM_SETTINGCHANGE for environment update'
}

function Get-MachinePathRaw {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Read PATH without expanding %VAR% references, preserving REG_EXPAND_SZ content
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false
    )
    try {
        return $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        if ($key) { $key.Close() }
    }
}

function Set-MachinePathRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value
    )

    # Write PATH as REG_EXPAND_SZ to preserve %VAR% references in existing entries
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true
    )
    try {
        $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        if ($key) { $key.Close() }
    }
}

function Get-InstalledJdkPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Strategy 1: Registry query — JavaSoft registers the current version here
    $regPath = $script:AppConfig.JdkRegistryPath
    if (Test-Path $regPath) {
        $currentVersion = (Get-ItemProperty -Path $regPath -Name 'CurrentVersion' -ErrorAction SilentlyContinue).CurrentVersion
        if ($currentVersion) {
            $versionKey = Join-Path $regPath $currentVersion
            if (Test-Path $versionKey) {
                $javaHome = (Get-ItemProperty -Path $versionKey -Name 'JavaHome' -ErrorAction SilentlyContinue).JavaHome
                if ($javaHome -and (Test-Path $javaHome)) {
                    Write-Log "JDK found via registry: $javaHome"
                    return $javaHome
                }
            }
        }
    }

    # Strategy 2: Filesystem fallback — find the newest jdk-* directory across known locations
    foreach ($parentDir in $script:AppConfig.InstallParentDirs) {
        if (-not $parentDir -or -not (Test-Path $parentDir)) { continue }

        $jdkDir = Get-ChildItem -Path $parentDir -Directory -Filter 'jdk-*' |
            Sort-Object {
                # Parse version from directory name: jdk-21, jdk-21.0.2, jdk-21.0.1_12
                $versionStr = $_.Name -replace '^jdk-', '' -replace '[_+].*', ''
                try { [version]$versionStr } catch { [version]'0.0' }
            } |
            Select-Object -Last 1

        if ($jdkDir) {
            Write-Log "JDK found via filesystem: $($jdkDir.FullName)"
            return $jdkDir.FullName
        }
    }

    return $null
}

function Get-InstalledProductGuid {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($regPath in $script:AppConfig.UninstallRegistryPaths) {
        $product = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $script:AppConfig.ProductNamePattern } |
            Select-Object -First 1

        if ($product -and $product.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
            Write-Log "Found product GUID: $($product.PSChildName) ($($product.DisplayName))"
            return $product.PSChildName
        }
    }

    return $null
}

function Test-JdkInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$JdkPath
    )

    $javaExe = Join-Path $JdkPath 'bin\java.exe'
    if (-not (Test-Path $javaExe)) {
        Write-Log "java.exe not found at: $javaExe" -Level WARN
        return $false
    }

    Write-Log "java.exe verified at: $javaExe"
    return $true
}

function Resolve-NormalizedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    return $Path.TrimEnd('\', '/').Trim()
}

function Update-MachinePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NewEntry,
        [string]$ObsoletePattern = $script:AppConfig.VendorPathPattern
    )

    $currentPath = Get-MachinePathRaw
    Write-Log "Current Machine PATH: $currentPath"

    $normalizedNew = Resolve-NormalizedPath $NewEntry
    # Also produce the expanded form for comparison against entries that may already be expanded
    $expandedNew = Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($NewEntry))
    Write-Log "Required PATH entry: $normalizedNew"

    $entries = $currentPath -split ';' | Where-Object { $_.Trim() -ne '' }

    $keptEntries = [System.Collections.Generic.List[string]]::new()
    $removedEntries = [System.Collections.Generic.List[string]]::new()
    $alreadyPresent = $false

    foreach ($entry in $entries) {
        $normalized = Resolve-NormalizedPath $entry
        # Expand for comparison — an entry might be stored as %ProgramFiles%\...
        $expanded = Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($entry))

        # Check if this is the entry we want to add (compare both raw and expanded forms)
        if (($normalized -ieq $normalizedNew) -or ($expanded -ieq $expandedNew)) {
            if (-not $alreadyPresent) {
                $keptEntries.Add($entry)  # preserve original form (may contain %VAR%)
                $alreadyPresent = $true
                Write-Log "PATH entry already exists: $entry"
            } else {
                $removedEntries.Add($entry)
                Write-Log "Removing duplicate PATH entry: $entry"
            }
            continue
        }

        # Check if this is an obsolete managed entry to remove (compare expanded form)
        if ($ObsoletePattern -and ($expanded -match $ObsoletePattern)) {
            $removedEntries.Add($entry)
            Write-Log "Removing obsolete managed PATH entry: $entry"
            continue
        }

        $keptEntries.Add($entry)
    }

    if (-not $alreadyPresent) {
        $keptEntries.Add($normalizedNew)
        Write-Log "Adding new PATH entry: $normalizedNew"
    }

    foreach ($removed in $removedEntries) {
        Write-Log "Removed PATH entry: $removed"
    }

    $newPath = $keptEntries -join ';'
    Set-MachinePathRaw -Value $newPath
    Send-EnvironmentChangeNotification
    Write-Log "Machine PATH updated successfully"
}

function Remove-ManagedPathEntries {
    [CmdletBinding()]
    param(
        [string]$Pattern = $script:AppConfig.VendorPathPattern
    )

    $currentPath = Get-MachinePathRaw
    $entries = $currentPath -split ';' | Where-Object { $_.Trim() -ne '' }

    $keptEntries = [System.Collections.Generic.List[string]]::new()
    $removed = $false

    foreach ($entry in $entries) {
        $expanded = Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($entry))
        if ($expanded -match $Pattern) {
            Write-Log "Removing managed PATH entry: $entry"
            $removed = $true
        } else {
            $keptEntries.Add($entry)
        }
    }

    if ($removed) {
        $newPath = $keptEntries -join ';'
        Set-MachinePathRaw -Value $newPath
        Send-EnvironmentChangeNotification
        Write-Log "Managed PATH entries removed"
    } else {
        Write-Log "No managed PATH entries found to remove"
    }
}

function Set-MachineEnvVar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    $existing = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    Write-Log "Existing $Name`: $existing"

    if ($Value -eq '') {
        [Environment]::SetEnvironmentVariable($Name, $null, 'Machine')
        Write-Log "Removed $Name"
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
        Write-Log "Set $Name = $Value"
    }
}

function Test-EnvironmentConfiguration {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ExpectedJavaHome,
        [Parameter(Mandatory)][string]$ExpectedBinDir
    )

    $valid = $true
    $normalizedExpectedBin = Resolve-NormalizedPath $ExpectedBinDir

    # Validate JAVA_HOME
    $actualJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if ($actualJavaHome -ne $ExpectedJavaHome) {
        Write-Log "JAVA_HOME validation failed. Expected: $ExpectedJavaHome, Got: $actualJavaHome" -Level ERROR
        $valid = $false
    } else {
        Write-Log "JAVA_HOME validated: $actualJavaHome"
    }

    # Validate PATH contains the bin directory (check expanded values)
    $machinePath = Get-MachinePathRaw
    $pathEntries = $machinePath -split ';' | ForEach-Object {
        Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($_))
    }
    if ($pathEntries -inotcontains $normalizedExpectedBin) {
        Write-Log "PATH validation failed. Expected entry not found: $normalizedExpectedBin" -Level ERROR
        $valid = $false
    } else {
        Write-Log "PATH validated: contains $normalizedExpectedBin"
    }

    # Validate java.exe exists
    $javaExe = Join-Path $ExpectedJavaHome 'bin\java.exe'
    if (-not (Test-Path $javaExe)) {
        Write-Log "java.exe validation failed: $javaExe not found" -Level ERROR
        $valid = $false
    } else {
        Write-Log "java.exe validated: $javaExe"
    }

    # Attempt runtime verification in a new process
    try {
        $result = & cmd.exe /c "`"$javaExe`" -version" 2>&1
        Write-Log "java -version output: $($result | Out-String)"
    } catch {
        Write-Log "java -version check failed: $_" -Level WARN
    }

    return $valid
}
