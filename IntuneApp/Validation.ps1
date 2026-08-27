#Requires -Version 5.1
<#
.SYNOPSIS
    Generic validation framework for Intune Win32 deployments.
.DESCRIPTION
    Performs pre-installation and post-installation validation checks
    using the Execution and PostInstallValidation sections of Configuration.psd1.
#>

function Test-PreInstallValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$PackagePath
    )

    $failures = @()

    # Validate execution context based on InstallPrivilege
    $installPrivilege = if ($Configuration.InstallPrivilege) { $Configuration.InstallPrivilege } else { 'System' }
    $requireSystem = switch ($installPrivilege) {
        'System'        { $true }
        'Administrator' { $false }
        'User'          { $false }
        default         { $true }
    }
    $execution = $Configuration.Execution
    if ($execution -and $null -ne $execution.RequireSystem) {
        $requireSystem = $execution.RequireSystem
    }

    if ($requireSystem) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.Name -ne 'NT AUTHORITY\SYSTEM') {
            if (-not $Configuration.Testing.AllowNonSystemExecution) {
                $failures += "Not running as SYSTEM. Current identity: $($identity.Name)"
            }
        }
    }

    # Validate InstallPrivilege value
    $validPrivileges = @('System', 'Administrator', 'User')
    if ($Configuration.InstallPrivilege -and $Configuration.InstallPrivilege -notin $validPrivileges) {
        $failures += "Invalid InstallPrivilege: $($Configuration.InstallPrivilege). Valid: $($validPrivileges -join ', ')"
    }

    # Reject interactive execution if disallowed
    if ($execution -and -not $execution.AllowInteractive) {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        if ($sessionId -ne 0 -and -not $Configuration.Testing.AllowNonSystemExecution) {
            Write-Log -Message "Running in interactive session $sessionId (non-interactive expected)." -Level 'Warning'
        }
    }

    # Validate configuration has required sections
    if (-not $Configuration.Installer) {
        $failures += "Configuration missing Installer section."
    }

    if (-not $Configuration.ApplicationName) {
        $failures += "Configuration missing ApplicationName."
    }

    # Validate install scope
    if ($Configuration.InstallScope) {
        $validScopes = @('Machine', 'User')
        if ($Configuration.InstallScope -notin $validScopes) {
            $failures += "Invalid InstallScope: $($Configuration.InstallScope). Valid: $($validScopes -join ', ')"
        }
    }

    # Validate installer file exists
    if ($Configuration.Installer) {
        $installerDir = $Configuration.Installer.WorkingDirectory
        if (-not $installerDir) { $installerDir = 'Files' }
        $installerPath = Join-Path $PackagePath (Join-Path $installerDir $Configuration.Installer.File)

        if ($Configuration.Installer.Type -eq 'MSI') {
            # MSI must have either a file or a product code
            if ($Configuration.Installer.File -and -not (Test-Path $installerPath)) {
                $failures += "MSI installer file not found: $installerPath"
            }
            if (-not $Configuration.Installer.ProductCode -and -not $Configuration.Installer.File) {
                $failures += "MSI installer requires either File or ProductCode."
            }
        }
        else {
            if (-not (Test-Path $installerPath)) {
                $failures += "Installer file not found: $installerPath"
            }
        }

        # Validate installer hash if configured
        if ($Configuration.Installer.SHA256 -and (Test-Path $installerPath)) {
            $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
            if ($actualHash -ne $Configuration.Installer.SHA256) {
                $failures += "Installer integrity check failed. Expected SHA256: $($Configuration.Installer.SHA256) | Actual: $actualHash"
            }
            else {
                Write-Log -Message "Installer integrity verified (SHA256 match)." -Level 'Info'
            }
        }

        # Validate MSI ProductCode is present when Type = MSI
        if ($Configuration.Installer.Type -eq 'MSI' -and -not $Configuration.Installer.ProductCode) {
            Write-Log -Message "MSI installer without ProductCode - may be needed for uninstall." -Level 'Warning'
        }
    }

    # Validate required directories
    $filesDir = Join-Path $PackagePath 'Files'
    if (-not (Test-Path $filesDir)) {
        Write-Log -Message "Files directory not found at $filesDir (may not be required)." -Level 'Warning'
    }

    # Validate disk space
    if ($Configuration.Requirements.MinimumDiskSpaceGB) {
        $systemDrive = $env:SystemDrive
        if (-not $systemDrive) { $systemDrive = 'C:' }
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'" -ErrorAction SilentlyContinue
        if ($disk) {
            $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
            if ($freeGB -lt $Configuration.Requirements.MinimumDiskSpaceGB) {
                $failures += "Insufficient disk space. Required: $($Configuration.Requirements.MinimumDiskSpaceGB)GB, Available: ${freeGB}GB"
            }
        }
    }

    # Validate OS compatibility
    if ($Configuration.Requirements.MinimumWindowsVersion) {
        $currentVersion = [System.Environment]::OSVersion.Version
        try {
            $requiredVersion = [version]$Configuration.Requirements.MinimumWindowsVersion
            if ($currentVersion -lt $requiredVersion) {
                $failures += "OS version $currentVersion does not meet minimum $requiredVersion"
            }
        }
        catch {
            $failures += "Invalid MinimumWindowsVersion format: $($Configuration.Requirements.MinimumWindowsVersion)"
        }
    }

    # Validate architecture compatibility (array)
    if ($Configuration.Requirements.Architecture) {
        $accepted = $Configuration.Requirements.Architecture
        if ($accepted -is [string]) { $accepted = @($accepted) }
        $currentArch = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        $archOk = ($currentArch -in $accepted) -or ($currentArch -eq 'x64' -and 'x86' -in $accepted)
        if (-not $archOk) {
            $failures += "Architecture mismatch. Accepted: $($accepted -join ', '), Current: $currentArch"
        }
    }

    # Validate upgrade/downgrade
    if ($Configuration.Upgrade -and $Configuration.Detection -and -not $Configuration.Testing.SkipDetection) {
        $existingDetection = Invoke-Detection -DetectionConfig $Configuration.Detection
        if ($existingDetection.Detected -and -not $Configuration.Upgrade.AllowDowngrade) {
            if ($Configuration.Detection.MinimumVersion -and $Configuration.ApplicationVersion) {
                try {
                    $targetVersion = [version]$Configuration.ApplicationVersion
                    $existingVersion = $null

                    # Try to extract version from detection detail
                    if ($existingDetection.Detail -match 'Version:\s*([\d.]+)') {
                        $existingVersion = [version]$Matches[1]
                    }

                    if ($existingVersion -and $targetVersion -lt $existingVersion) {
                        $failures += "Downgrade not allowed. Existing: $existingVersion, Target: $targetVersion"
                    }
                }
                catch {
                    Write-Log -Message "Could not compare versions for downgrade check: $_" -Level 'Warning'
                }
            }
        }
    }

    foreach ($f in $failures) {
        Write-Log -Message "Pre-install validation FAILED: $f" -Level 'Error'
    }

    if ($failures.Count -eq 0) {
        Write-Log -Message "Pre-install validation PASSED." -Level 'Info'
        return [PSCustomObject]@{ Passed = $true; Failures = @() }
    }

    return [PSCustomObject]@{ Passed = $false; Failures = $failures }
}

function Test-PostInstallValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][int]$InstallerExitCode
    )

    # Skip if validation is disabled
    if ($Configuration.PostInstallValidation -and $Configuration.PostInstallValidation.Enabled -eq $false) {
        Write-Log -Message "Post-install validation disabled in configuration." -Level 'Info'
        return [PSCustomObject]@{ Passed = $true; Failures = @() }
    }

    $failures = @()
    $returnCodes = $Configuration.ReturnCodes

    # Validate exit code
    $successCodes = @()
    if ($returnCodes.Success) { $successCodes += $returnCodes.Success }
    if ($returnCodes.SuccessWithReboot) { $successCodes += $returnCodes.SuccessWithReboot }

    if ($InstallerExitCode -notin $successCodes) {
        $failures += "Installer returned exit code $InstallerExitCode (not in configured success codes)"
    }

    # Validate expected files
    if ($Configuration.PostInstallValidation.ExpectedFiles) {
        foreach ($expectedFile in $Configuration.PostInstallValidation.ExpectedFiles) {
            if ($expectedFile -and -not (Test-Path $expectedFile)) {
                $failures += "Expected file not found: $expectedFile"
            }
        }
    }

    # Validate expected registry entries
    if ($Configuration.PostInstallValidation.ExpectedRegistryEntries) {
        foreach ($regEntry in $Configuration.PostInstallValidation.ExpectedRegistryEntries) {
            try {
                $value = Get-ItemProperty -Path $regEntry.Path -Name $regEntry.Name -ErrorAction Stop
                if ($regEntry.Value -and $value.$($regEntry.Name) -ne $regEntry.Value) {
                    $failures += "Registry value mismatch at $($regEntry.Path)\$($regEntry.Name): Expected '$($regEntry.Value)', Got '$($value.$($regEntry.Name))'"
                }
            }
            catch {
                $failures += "Expected registry entry not found: $($regEntry.Path)\$($regEntry.Name)"
            }
        }
    }

    # Validate version via detection
    if ($Configuration.PostInstallValidation.ValidateVersion -and $Configuration.Detection) {
        $detectionResult = Invoke-Detection -DetectionConfig $Configuration.Detection
        if (-not $detectionResult.Detected) {
            $failures += "Post-install detection failed: $($detectionResult.Detail)"
        }
    }

    foreach ($f in $failures) {
        Write-Log -Message "Post-install validation FAILED: $f" -Level 'Error'
    }

    if ($failures.Count -eq 0) {
        Write-Log -Message "Post-install validation PASSED." -Level 'Info'
        return [PSCustomObject]@{ Passed = $true; Failures = @() }
    }

    return [PSCustomObject]@{ Passed = $false; Failures = $failures }
}

function Test-SystemContext {
    [CmdletBinding()]
    param(
        [bool]$AllowNonSystem = $false
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.Name -eq 'NT AUTHORITY\SYSTEM'

    if (-not $isSystem -and -not $AllowNonSystem) {
        Write-Log -Message "Script must run as SYSTEM. Current identity: $($identity.Name)" -Level 'Error'
        Write-Log -Message "Set Testing.AllowNonSystemExecution = `$true in Configuration.psd1 for local testing." -Level 'Info'
        return $false
    }

    if (-not $isSystem -and $AllowNonSystem) {
        Write-Log -Message "Running as $($identity.Name) (non-SYSTEM testing mode enabled)." -Level 'Warning'
    }

    return $true
}
