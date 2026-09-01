#Requires -Version 5.1

$script:EnvRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

#region Logging

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

#endregion

#region Configuration Validation

function Test-PackageConfiguration {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [switch]$ValidateInstallerExists
    )

    $valid = $true
    $cfg = $script:AppConfig

    # Validate InstallerType
    if ($cfg.InstallerType -notin @('MSI', 'EXE')) {
        Write-Log "Invalid InstallerType: '$($cfg.InstallerType)'. Must be 'MSI' or 'EXE'." -Level ERROR
        $valid = $false
    }

    # Validate UninstallType
    if ($cfg.UninstallType -notin @('MSI', 'EXE')) {
        Write-Log "Invalid UninstallType: '$($cfg.UninstallType)'. Must be 'MSI' or 'EXE'." -Level ERROR
        $valid = $false
    }

    # Validate InstallerFileName is set
    if (-not $cfg.InstallerFileName) {
        Write-Log 'InstallerFileName is not configured.' -Level ERROR
        $valid = $false
    }

    # Validate file extension matches InstallerType
    if ($cfg.InstallerFileName -and $cfg.InstallerType) {
        $ext = [System.IO.Path]::GetExtension($cfg.InstallerFileName).ToLower()
        switch ($cfg.InstallerType) {
            'MSI' {
                if ($ext -ne '.msi') {
                    Write-Log "InstallerType is MSI but InstallerFileName has extension '$ext'. Expected '.msi'." -Level ERROR
                    $valid = $false
                }
            }
            'EXE' {
                if ($ext -ne '.exe') {
                    Write-Log "InstallerType is EXE but InstallerFileName has extension '$ext'. Expected '.exe'." -Level ERROR
                    $valid = $false
                }
            }
        }
    }

    # Validate installer file exists on disk
    if ($ValidateInstallerExists -and $cfg.InstallerFileName) {
        $installerPath = Join-Path $PackageRoot $cfg.InstallerFileName
        if (-not (Test-Path $installerPath)) {
            Write-Log "Installer file not found: $installerPath" -Level ERROR
            $valid = $false
        }
    }

    # Validate DetectionMethod
    if ($cfg.DetectionMethod -notin @('Registry', 'File', 'Both')) {
        Write-Log "Invalid DetectionMethod: '$($cfg.DetectionMethod)'. Must be 'Registry', 'File', or 'Both'." -Level ERROR
        $valid = $false
    }

    return $valid
}

#endregion

#region Installer Execution

function Invoke-Installer {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$PackageRoot
    )

    $cfg = $script:AppConfig
    $installerPath = Join-Path $PackageRoot $cfg.InstallerFileName

    if (-not (Test-Path $installerPath)) {
        Write-Log "Installer not found: $installerPath" -Level ERROR
        return 1
    }

    $logFile = Join-Path $cfg.LogDirectory ('installer-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

    switch ($cfg.InstallerType) {
        'MSI' {
            Write-Log "Executing MSI installer: $installerPath"
            $arguments = "/i `"$installerPath`" $($cfg.InstallerArguments) /l*v `"$logFile`""
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        }
        'EXE' {
            Write-Log "Executing EXE installer: $installerPath"
            Write-Log "Arguments: $($cfg.InstallerArguments)"
            $splat = @{
                FilePath  = $installerPath
                Wait      = $true
                PassThru  = $true
                NoNewWindow = $true
            }
            if ($cfg.InstallerArguments) {
                $splat.ArgumentList = $cfg.InstallerArguments
            }
            $process = Start-Process @splat
        }
    }

    Write-Log "Installer exit code: $($process.ExitCode)"
    return $process.ExitCode
}

function Invoke-Uninstaller {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$PackageRoot
    )

    $cfg = $script:AppConfig
    $logFile = Join-Path $cfg.LogDirectory ('uninstaller-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

    switch ($cfg.UninstallType) {
        'MSI' {
            return Invoke-MsiUninstall -PackageRoot $PackageRoot -LogFile $logFile
        }
        'EXE' {
            return Invoke-ExeUninstall -PackageRoot $PackageRoot -LogFile $logFile
        }
    }

    return 1
}

function Invoke-MsiUninstall {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$LogFile
    )

    $cfg = $script:AppConfig

    # Strategy 1: Product GUID from registry
    $productGuid = Get-InstalledProductGuid
    if ($productGuid) {
        Write-Log "Uninstalling MSI via product GUID: $productGuid"
        $arguments = "/x `"$productGuid`" /qn /norestart /l*v `"$LogFile`""
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        Write-Log "MSI uninstall exit code: $($process.ExitCode)"
        return $process.ExitCode
    }

    # Strategy 2: Fallback to MSI file
    $msiPath = Join-Path $PackageRoot $cfg.InstallerFileName
    if (Test-Path $msiPath) {
        Write-Log "Product GUID not found. Uninstalling via MSI file: $msiPath"
        $arguments = "/x `"$msiPath`" /qn /norestart /l*v `"$LogFile`""
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        Write-Log "MSI uninstall exit code: $($process.ExitCode)"
        return $process.ExitCode
    }

    Write-Log 'No product GUID or MSI file found for uninstall' -Level WARN
    return -1
}

function Invoke-ExeUninstall {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$LogFile
    )

    $cfg = $script:AppConfig

    # Strategy 1: QuietUninstallString from registry
    $uninstallInfo = Get-UninstallRegistryInfo
    if ($uninstallInfo) {
        $quietCmd = $uninstallInfo.QuietUninstallString
        if ($quietCmd) {
            Write-Log "Using QuietUninstallString from registry: $quietCmd"
            $parsed = Split-UninstallCommand $quietCmd
            if ($parsed) {
                $process = Start-Process -FilePath $parsed.Executable -ArgumentList $parsed.Arguments -Wait -PassThru -NoNewWindow
                Write-Log "EXE uninstall exit code (QuietUninstallString): $($process.ExitCode)"
                return $process.ExitCode
            }
        }

        # Strategy 2: UninstallString + configured silent arguments
        $uninstallCmd = $uninstallInfo.UninstallString
        if ($uninstallCmd -and $cfg.UninstallArguments) {
            Write-Log "Using UninstallString with configured silent args: $uninstallCmd"
            $parsed = Split-UninstallCommand $uninstallCmd
            if ($parsed) {
                $allArgs = if ($parsed.Arguments) { "$($parsed.Arguments) $($cfg.UninstallArguments)" } else { $cfg.UninstallArguments }
                $process = Start-Process -FilePath $parsed.Executable -ArgumentList $allArgs -Wait -PassThru -NoNewWindow
                Write-Log "EXE uninstall exit code (UninstallString): $($process.ExitCode)"
                return $process.ExitCode
            }
        }
    }

    # Strategy 3: Configured UninstallFileName
    if ($cfg.UninstallFileName) {
        $uninstallPath = if ([System.IO.Path]::IsPathRooted($cfg.UninstallFileName)) {
            $cfg.UninstallFileName
        } else {
            Join-Path $PackageRoot $cfg.UninstallFileName
        }

        if (Test-Path $uninstallPath) {
            Write-Log "Using configured uninstall executable: $uninstallPath"
            $splat = @{
                FilePath    = $uninstallPath
                Wait        = $true
                PassThru    = $true
                NoNewWindow = $true
            }
            if ($cfg.UninstallArguments) {
                $splat.ArgumentList = $cfg.UninstallArguments
            }
            $process = Start-Process @splat
            Write-Log "EXE uninstall exit code: $($process.ExitCode)"
            return $process.ExitCode
        } else {
            Write-Log "Configured uninstall executable not found: $uninstallPath" -Level WARN
        }
    }

    Write-Log 'No uninstall method found for EXE application' -Level WARN
    return -1
}

function Split-UninstallCommand {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$CommandString
    )

    # Safely parse an uninstall command into executable + arguments.
    # Handles quoted paths: "C:\Program Files\App\uninstall.exe" /silent
    # and unquoted: C:\App\uninstall.exe /silent

    $cmd = $CommandString.Trim()

    if ($cmd.StartsWith('"')) {
        $closeQuote = $cmd.IndexOf('"', 1)
        if ($closeQuote -lt 0) {
            Write-Log "Malformed quoted command: $cmd" -Level WARN
            return $null
        }
        $exe = $cmd.Substring(1, $closeQuote - 1)
        $args = $cmd.Substring($closeQuote + 1).Trim()
    } else {
        $parts = $cmd -split '\s+', 2
        $exe = $parts[0]
        $args = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }

    if (-not (Test-Path $exe)) {
        Write-Log "Uninstall executable not found: $exe" -Level WARN
        return $null
    }

    return [PSCustomObject]@{
        Executable = $exe
        Arguments  = $args
    }
}

#endregion

#region Registry Discovery

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

function Get-UninstallRegistryInfo {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    foreach ($regPath in $script:AppConfig.UninstallRegistryPaths) {
        $product = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $script:AppConfig.ProductNamePattern } |
            Select-Object -First 1

        if ($product) {
            $info = [PSCustomObject]@{
                DisplayName          = $product.DisplayName
                DisplayVersion       = $product.DisplayVersion
                UninstallString      = $product.UninstallString
                QuietUninstallString = $product.QuietUninstallString
                InstallLocation      = $product.InstallLocation
                ProductGuid          = if ($product.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') { $product.PSChildName } else { $null }
            }
            Write-Log "Found uninstall registry entry: $($info.DisplayName) v$($info.DisplayVersion)"
            return $info
        }
    }

    return $null
}

function Test-ProductDetected {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $cfg = $script:AppConfig
    $method = $cfg.DetectionMethod

    $registryDetected = $false
    $fileDetected = $false

    # Registry-based detection
    if ($method -in @('Registry', 'Both')) {
        foreach ($regPath in $cfg.UninstallRegistryPaths) {
            $product = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like $cfg.ProductNamePattern } |
                Select-Object -First 1
            if ($product) {
                $registryDetected = $true
                break
            }
        }
    }

    # File-based detection
    if ($method -in @('File', 'Both')) {
        if ($cfg.DetectionFilePath -and (Test-Path $cfg.DetectionFilePath)) {
            $fileDetected = $true
        }
    }

    switch ($method) {
        'Registry' { return $registryDetected }
        'File'     { return $fileDetected }
        'Both'     { return ($registryDetected -or $fileDetected) }
    }

    return $false
}

#endregion

#region Application-Specific: JDK Path Discovery

function Get-InstalledJdkPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Strategy 1: Registry query
    $regPath = $script:AppConfig.JdkRegistryPath
    if ($regPath -and (Test-Path $regPath)) {
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

    # Strategy 2: Filesystem fallback
    foreach ($parentDir in $script:AppConfig.InstallParentDirs) {
        if (-not $parentDir -or -not (Test-Path $parentDir)) { continue }

        $jdkDir = Get-ChildItem -Path $parentDir -Directory -Filter 'jdk-*' |
            Sort-Object {
                $versionStr = $_.Name -replace '^jdk-', '' -replace '[_+].*', ''
                try { [version]$versionStr } catch { [version]'0.0' }
            } |
            Select-Object -Last 1

        if ($jdkDir) {
            Write-Log "JDK found via filesystem: $($jdkDir.FullName)"
            return $jdkDir.FullName
        }
    }

    # Strategy 3: InstallLocation from uninstall registry
    $uninstallInfo = Get-UninstallRegistryInfo
    if ($uninstallInfo -and $uninstallInfo.InstallLocation -and (Test-Path $uninstallInfo.InstallLocation)) {
        Write-Log "Application found via InstallLocation: $($uninstallInfo.InstallLocation)"
        return $uninstallInfo.InstallLocation
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

#endregion

#region PATH and Environment Variable Management

function Send-EnvironmentChangeNotification {
    [CmdletBinding()]
    param()

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

function Resolve-NormalizedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    return $Path.TrimEnd('\', '/').Trim()
}

function Get-MachinePathRaw {
    [CmdletBinding()]
    [OutputType([string])]
    param()

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

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true
    )
    try {
        $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        if ($key) { $key.Close() }
    }
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
    $expandedNew = Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($NewEntry))
    Write-Log "Required PATH entry: $normalizedNew"

    $entries = $currentPath -split ';' | Where-Object { $_.Trim() -ne '' }

    $keptEntries = [System.Collections.Generic.List[string]]::new()
    $removedEntries = [System.Collections.Generic.List[string]]::new()
    $alreadyPresent = $false

    foreach ($entry in $entries) {
        $normalized = Resolve-NormalizedPath $entry
        $expanded = Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($entry))

        if (($normalized -ieq $normalizedNew) -or ($expanded -ieq $expandedNew)) {
            if (-not $alreadyPresent) {
                $keptEntries.Add($entry)
                $alreadyPresent = $true
                Write-Log "PATH entry already exists: $entry"
            } else {
                $removedEntries.Add($entry)
                Write-Log "Removing duplicate PATH entry: $entry"
            }
            continue
        }

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

    if (-not $Pattern) {
        Write-Log 'No VendorPathPattern configured — skipping PATH cleanup'
        return
    }

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

    $actualJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if ($actualJavaHome -ne $ExpectedJavaHome) {
        Write-Log "JAVA_HOME validation failed. Expected: $ExpectedJavaHome, Got: $actualJavaHome" -Level ERROR
        $valid = $false
    } else {
        Write-Log "JAVA_HOME validated: $actualJavaHome"
    }

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

    $javaExe = Join-Path $ExpectedJavaHome 'bin\java.exe'
    if (-not (Test-Path $javaExe)) {
        Write-Log "java.exe validation failed: $javaExe not found" -Level ERROR
        $valid = $false
    } else {
        Write-Log "java.exe validated: $javaExe"
    }

    try {
        $result = & cmd.exe /c "`"$javaExe`" -version" 2>&1
        Write-Log "java -version output: $($result | Out-String)"
    } catch {
        Write-Log "java -version check failed: $_" -Level WARN
    }

    return $valid
}

#endregion
