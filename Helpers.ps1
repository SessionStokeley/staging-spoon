#Requires -Version 5.1

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

function Get-InstalledJdkPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Strategy 1: Registry query — JavaSoft registers the current version here
    $regPath = $script:AppConfig.RegistryPath
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

    # Strategy 2: Filesystem fallback — find the newest jdk-* directory
    $parentDir = $script:AppConfig.InstallParentDir
    if (Test-Path $parentDir) {
        $jdkDir = Get-ChildItem -Path $parentDir -Directory -Filter 'jdk-*' |
            Sort-Object { [version]($_.Name -replace '^jdk-', '' -replace '[^0-9.]', '') } -ErrorAction SilentlyContinue |
            Select-Object -Last 1

        if ($jdkDir) {
            Write-Log "JDK found via filesystem: $($jdkDir.FullName)"
            return $jdkDir.FullName
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

    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    Write-Log "Current Machine PATH: $currentPath"

    $normalizedNew = Resolve-NormalizedPath $NewEntry
    Write-Log "Required PATH entry: $normalizedNew"

    $entries = $currentPath -split ';' | Where-Object { $_.Trim() -ne '' }

    $keptEntries = [System.Collections.Generic.List[string]]::new()
    $removedEntries = [System.Collections.Generic.List[string]]::new()
    $alreadyPresent = $false

    foreach ($entry in $entries) {
        $normalized = Resolve-NormalizedPath $entry

        # Check if this is the entry we want to add
        if ($normalized -ieq $normalizedNew) {
            if (-not $alreadyPresent) {
                $keptEntries.Add($normalized)
                $alreadyPresent = $true
                Write-Log "PATH entry already exists: $normalized"
            } else {
                $removedEntries.Add($entry)
                Write-Log "Removing duplicate PATH entry: $entry"
            }
            continue
        }

        # Check if this is an obsolete managed entry to remove
        if ($ObsoletePattern -and ($normalized -match $ObsoletePattern)) {
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
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Log "Machine PATH updated successfully"
}

function Remove-ManagedPathEntries {
    [CmdletBinding()]
    param(
        [string]$Pattern = $script:AppConfig.VendorPathPattern
    )

    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $entries = $currentPath -split ';' | Where-Object { $_.Trim() -ne '' }

    $keptEntries = [System.Collections.Generic.List[string]]::new()
    $removed = $false

    foreach ($entry in $entries) {
        $normalized = Resolve-NormalizedPath $entry
        if ($normalized -match $Pattern) {
            Write-Log "Removing managed PATH entry: $entry"
            $removed = $true
        } else {
            $keptEntries.Add($entry)
        }
    }

    if ($removed) {
        $newPath = $keptEntries -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
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

    # Validate PATH contains the bin directory
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $pathEntries = $machinePath -split ';' | ForEach-Object { Resolve-NormalizedPath $_ }
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
