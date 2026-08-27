#Requires -Version 5.1
<#
.SYNOPSIS
    Generic validation framework for Intune Win32 deployments.
.DESCRIPTION
    Performs pre-installation and post-installation validation checks
    as configured in Configuration.psd1.
#>

function Test-PreInstallValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$PackagePath
    )

    $failures = @()

    # Validate SYSTEM context (unless testing mode)
    if (-not $Configuration.Testing.AllowNonSystemExecution) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.Name -ne 'NT AUTHORITY\SYSTEM') {
            $failures += "Not running as SYSTEM. Current identity: $($identity.Name)"
        }
    }

    # Validate configuration has required sections
    if (-not $Configuration.Installer) {
        $failures += "Configuration missing Installer section."
    }

    if (-not $Configuration.ApplicationName) {
        $failures += "Configuration missing ApplicationName."
    }

    # Validate installer file exists
    if ($Configuration.Installer) {
        $installerDir = $Configuration.Installer.WorkingDirectory
        if (-not $installerDir) { $installerDir = 'Files' }
        $installerPath = Join-Path $PackagePath (Join-Path $installerDir $Configuration.Installer.File)

        if ($Configuration.Installer.Type -eq 'MSI' -and $Configuration.Installer.ProductCode) {
            # MSI installs use msiexec; the .msi file should still exist if specified
            if ($Configuration.Installer.File -and -not (Test-Path $installerPath)) {
                $failures += "MSI installer file not found: $installerPath"
            }
        }
        elseif ($Configuration.Installer.Type -ne 'MSI') {
            if (-not (Test-Path $installerPath)) {
                $failures += "Installer file not found: $installerPath"
            }
        }
    }

    # Validate required directories
    $filesDir = Join-Path $PackagePath 'Files'
    if (-not (Test-Path $filesDir)) {
        Write-Log -Message "Files directory not found at $filesDir (may not be required for all installer types)" -Level 'Warning'
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

    # Validate architecture compatibility
    if ($Configuration.Requirements.Architecture) {
        $currentArch = if ([System.Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        $reqArch = $Configuration.Requirements.Architecture
        if ($reqArch -eq 'x64' -and $currentArch -ne 'x64') {
            $failures += "Architecture mismatch. Required: $reqArch, Current: $currentArch"
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
            if (-not (Test-Path $expectedFile)) {
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
