#Requires -Version 5.1
<#
.SYNOPSIS
    Package validation script for Intune Win32 deployment packages.
.DESCRIPTION
    Validates that a deployment package is complete and correctly configured
    before creating the .intunewin file and uploading to Intune.

.PARAMETER PackagePath
    Path to the deployment package directory. Defaults to $PSScriptRoot.

.EXAMPLE
    .\Validate-Package.ps1
    .\Validate-Package.ps1 -PackagePath "C:\Packages\MyApp"
#>

[CmdletBinding()]
param(
    [string]$PackagePath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$Errors   = @()
$Warnings = @()

function Add-ValidationError {
    param([string]$Message)
    $script:Errors += $Message
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
}

function Add-ValidationWarning {
    param([string]$Message)
    $script:Warnings += $Message
    Write-Host "  [WARN]  $Message" -ForegroundColor Yellow
}

function Add-ValidationPass {
    param([string]$Message)
    Write-Host "  [PASS]  $Message" -ForegroundColor Green
}

Write-Host ""
Write-Host "Intune Win32 Package Validator" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Package: $PackagePath"
Write-Host ("=" * 60) -ForegroundColor Cyan

# =========================================================================
# 1. REQUIRED FILES
# =========================================================================
Write-Host ""
Write-Host "Checking required files..." -ForegroundColor White

$requiredFiles = @{
    'Configuration.psd1' = 'Application configuration'
    'Install.ps1'        = 'Installation script'
    'Uninstall.ps1'      = 'Uninstallation script'
    'Detection.ps1'      = 'Detection script'
    'Validation.ps1'     = 'Validation framework'
    'Logging.ps1'        = 'Logging framework'
    'Requirements.ps1'   = 'Requirements validation'
}

foreach ($file in $requiredFiles.GetEnumerator()) {
    $filePath = Join-Path $PackagePath $file.Key
    if (Test-Path $filePath) {
        Add-ValidationPass "$($file.Key) ($($file.Value))"
    }
    else {
        Add-ValidationError "Missing: $($file.Key) - $($file.Value)"
    }
}

# =========================================================================
# 2. CONFIGURATION VALIDATION
# =========================================================================
Write-Host ""
Write-Host "Validating configuration..." -ForegroundColor White

$configPath = Join-Path $PackagePath 'Configuration.psd1'
$Config = $null

if (Test-Path $configPath) {
    try {
        $Config = Import-PowerShellDataFile -Path $configPath
        Add-ValidationPass "Configuration.psd1 parses successfully"
    }
    catch {
        Add-ValidationError "Configuration.psd1 parse error: $_"
    }
}

if ($Config) {
    # --- Application info ---
    if ($Config.ApplicationName) {
        Add-ValidationPass "ApplicationName: $($Config.ApplicationName)"
    } else {
        Add-ValidationError "ApplicationName is empty or missing"
    }

    if ($Config.ApplicationVersion) {
        Add-ValidationPass "ApplicationVersion: $($Config.ApplicationVersion)"
    } else {
        Add-ValidationWarning "ApplicationVersion is empty"
    }

    if ($Config.CompanyName) {
        Add-ValidationPass "CompanyName: $($Config.CompanyName)"
    } else {
        Add-ValidationError "CompanyName is empty or missing (required for log paths)"
    }

    # --- Install privilege ---
    if ($Config.InstallPrivilege) {
        $validPrivileges = @('System', 'Administrator', 'User')
        if ($Config.InstallPrivilege -in $validPrivileges) {
            Add-ValidationPass "InstallPrivilege: $($Config.InstallPrivilege)"
        } else {
            Add-ValidationError "Invalid InstallPrivilege: $($Config.InstallPrivilege). Valid: $($validPrivileges -join ', ')"
        }
    } else {
        Add-ValidationWarning "InstallPrivilege not set (defaults to System)"
    }

    # --- Install scope ---
    if ($Config.InstallScope) {
        $validScopes = @('Machine', 'User')
        if ($Config.InstallScope -in $validScopes) {
            Add-ValidationPass "InstallScope: $($Config.InstallScope)"
        } else {
            Add-ValidationError "Invalid InstallScope: $($Config.InstallScope). Valid: $($validScopes -join ', ')"
        }
    } else {
        Add-ValidationWarning "InstallScope not set (defaults to Machine)"
    }

    # --- Installer section ---
    if ($Config.Installer) {
        $installerDir = if ($Config.Installer.WorkingDirectory) { $Config.Installer.WorkingDirectory } else { 'Files' }

        if ($Config.Installer.File) {
            $installerPath = Join-Path $PackagePath (Join-Path $installerDir $Config.Installer.File)
            if (Test-Path $installerPath) {
                Add-ValidationPass "Installer file exists: $($Config.Installer.File)"
                $fileSize = (Get-Item $installerPath).Length / 1MB
                Add-ValidationPass "Installer size: $([math]::Round($fileSize, 2)) MB"

                # SHA256 check
                if ($Config.Installer.SHA256) {
                    $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
                    if ($actualHash -eq $Config.Installer.SHA256) {
                        Add-ValidationPass "Installer SHA256 verified"
                    } else {
                        Add-ValidationError "Installer SHA256 mismatch. Expected: $($Config.Installer.SHA256) | Actual: $actualHash"
                    }
                }
            }
            else {
                Add-ValidationError "Installer file not found: $installerPath"
            }
        }
        else {
            Add-ValidationError "Installer.File is not specified"
        }

        $validTypes = @('EXE', 'MSI', 'MSIX', 'CMD', 'BAT', 'PS1')
        $installerType = if ($Config.Installer.Type) { $Config.Installer.Type } else { 'EXE' }
        if ($installerType -in $validTypes) {
            Add-ValidationPass "Installer type: $installerType"
        }
        else {
            Add-ValidationWarning "Installer type '$installerType' is not standard ($($validTypes -join ', '))"
        }

        if ($Config.Installer.Arguments) {
            Add-ValidationPass "Installer arguments configured"
        }
        else {
            Add-ValidationWarning "No installer arguments configured (ensure silent install)"
        }

        # MSI-specific: ProductCode required
        if ($installerType -eq 'MSI' -and -not $Config.Installer.ProductCode) {
            Add-ValidationError "MSI installer requires ProductCode"
        }
    }
    else {
        Add-ValidationError "Installer section missing from configuration"
    }

    # --- Uninstaller section ---
    if ($Config.Uninstaller) {
        $validUninstallTypes = @('Executable', 'MSI', 'Registry', 'Custom')
        $uninstallType = if ($Config.Uninstaller.Type) { $Config.Uninstaller.Type } else { 'Executable' }
        if ($uninstallType -in $validUninstallTypes) {
            Add-ValidationPass "Uninstaller type: $uninstallType"
        }
        else {
            Add-ValidationError "Invalid uninstaller type: $uninstallType (valid: $($validUninstallTypes -join ', '))"
        }

        switch ($uninstallType) {
            'MSI' {
                if (-not $Config.Uninstaller.ProductCode -and -not ($Config.Detection.Type -eq 'MSI' -and $Config.Detection.ProductCode)) {
                    Add-ValidationError "MSI uninstall requires ProductCode in Uninstaller or Detection config"
                }
            }
            'Executable' {
                if (-not $Config.Uninstaller.File) {
                    Add-ValidationError "Executable uninstall requires File in Uninstaller config"
                }
            }
            'Registry' {
                if (-not $Config.Uninstaller.DisplayName -and -not $Config.ApplicationName) {
                    Add-ValidationWarning "Registry uninstall without DisplayName will fall back to ApplicationName"
                }
            }
            'Custom' {
                if (-not $Config.Uninstaller.Command) {
                    Add-ValidationError "Custom uninstall requires Command in Uninstaller config"
                }
            }
        }
    }
    else {
        Add-ValidationWarning "Uninstaller section missing - uninstall may not work"
    }

    # --- Detection section ---
    if ($Config.Detection) {
        $validDetectionTypes = @('File', 'Registry', 'MSI', 'Service', 'Custom')
        if ($Config.Detection.Type -in $validDetectionTypes) {
            Add-ValidationPass "Detection type: $($Config.Detection.Type)"
        }
        else {
            Add-ValidationError "Invalid detection type: $($Config.Detection.Type)"
        }

        # VersionComparison
        if ($Config.Detection.VersionComparison) {
            $validComparisons = @('Equal', 'GreaterThan', 'GreaterThanOrEqual', 'LessThan', 'LessThanOrEqual')
            if ($Config.Detection.VersionComparison -in $validComparisons) {
                Add-ValidationPass "VersionComparison: $($Config.Detection.VersionComparison)"
            } else {
                Add-ValidationError "Invalid VersionComparison: $($Config.Detection.VersionComparison)"
            }
        }

        switch ($Config.Detection.Type) {
            'File' {
                if (-not $Config.Detection.Path) {
                    Add-ValidationError "File detection requires Path"
                }
            }
            'MSI' {
                if (-not $Config.Detection.ProductCode) {
                    Add-ValidationError "MSI detection requires ProductCode"
                }
            }
            'Service' {
                if (-not $Config.Detection.ServiceName) {
                    Add-ValidationError "Service detection requires ServiceName"
                }
            }
            'Custom' {
                if (-not $Config.Detection.CustomScript) {
                    Add-ValidationError "Custom detection requires CustomScript"
                }
            }
        }
    }
    else {
        Add-ValidationError "Detection section missing - Intune requires detection rules"
    }

    # --- ProcessManagement section ---
    if ($Config.ProcessManagement) {
        Add-ValidationPass "ProcessManagement section present (ForceStop: $($Config.ProcessManagement.ForceStop))"
    }

    # --- Execution section ---
    if ($Config.Execution) {
        Add-ValidationPass "Execution section present (RequireSystem: $($Config.Execution.RequireSystem))"
    }

    # --- Architecture validation ---
    if ($Config.Requirements.Architecture) {
        if ($Config.Requirements.Architecture -is [array]) {
            Add-ValidationPass "Architecture: array format ($($Config.Requirements.Architecture -join ', '))"
        } else {
            Add-ValidationWarning "Architecture should be an array: @('$($Config.Requirements.Architecture)') instead of '$($Config.Requirements.Architecture)'"
        }
    }

    # --- Return codes ---
    if ($Config.ReturnCodes) {
        if ($Config.ReturnCodes.Success -contains 0) {
            Add-ValidationPass "Return codes include 0 as success"
        }
        else {
            Add-ValidationWarning "Return codes do not include 0 as success"
        }
    }
    else {
        Add-ValidationWarning "ReturnCodes section missing"
    }

    # --- Upgrade section ---
    if ($Config.Upgrade) {
        Add-ValidationPass "Upgrade section present (RemovePreviousVersion: $($Config.Upgrade.RemovePreviousVersion), AllowDowngrade: $($Config.Upgrade.AllowDowngrade))"
    }

    # --- Logging section ---
    if ($Config.Logging) {
        Add-ValidationPass "Logging section present (Enabled: $($Config.Logging.Enabled))"
    }

    # --- PATH entries ---
    if ($Config.PathEntries -and $Config.PathEntries.Count -gt 0) {
        Add-ValidationPass "PathEntries configured: $($Config.PathEntries.Count) entries"
        foreach ($pathEntry in $Config.PathEntries) {
            if ($pathEntry -and -not [System.IO.Path]::IsPathRooted($pathEntry)) {
                Add-ValidationWarning "PathEntry is not an absolute path: $pathEntry"
            }
        }
    }

    # --- File associations ---
    if ($Config.FileAssociations -and $Config.FileAssociations.Count -gt 0) {
        Add-ValidationPass "FileAssociations configured: $($Config.FileAssociations.Count) extension(s)"
        foreach ($ext in $Config.FileAssociations.Keys) {
            if (-not $ext.StartsWith('.')) {
                Add-ValidationWarning "FileAssociation key '$ext' should start with a dot (e.g., '.java')"
            }
            $assocExe = $Config.FileAssociations[$ext]
            if (-not $assocExe -or -not [System.IO.Path]::IsPathRooted($assocExe)) {
                Add-ValidationWarning "FileAssociation for '$ext' should be an absolute path to the executable"
            }
        }
    }

    # --- Persistent environment variables ---
    if ($Config.Environment -and $Config.Environment.PersistentVariables -and $Config.Environment.PersistentVariables.Count -gt 0) {
        Add-ValidationPass "PersistentVariables configured: $($Config.Environment.PersistentVariables.Count) variable(s)"
    }

    # --- Security: no secrets ---
    $configContent = Get-Content $configPath -Raw
    $secretPatterns = @('password', 'secret', 'token', 'apikey', 'api_key', 'credential')
    foreach ($pattern in $secretPatterns) {
        if ($configContent -match "(?i)$pattern\s*=\s*['""](?!null)[^'""]+") {
            Add-ValidationWarning "Configuration may contain sensitive data (matched: $pattern). Review before packaging."
        }
    }
}

# =========================================================================
# 3. FILES DIRECTORY
# =========================================================================
Write-Host ""
Write-Host "Checking Files directory..." -ForegroundColor White

$filesDir = Join-Path $PackagePath 'Files'
if (Test-Path $filesDir) {
    $files = Get-ChildItem -Path $filesDir -Recurse -File
    Add-ValidationPass "Files directory exists ($($files.Count) file(s))"

    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum / 1MB
    Add-ValidationPass "Total package size: $([math]::Round($totalSize, 2)) MB"

    if ($totalSize -gt 8192) {
        Add-ValidationWarning "Package exceeds 8GB - verify Intune size limits"
    }
}
else {
    Add-ValidationWarning "Files directory not found"
}

# =========================================================================
# 4. SCRIPT SYNTAX CHECK
# =========================================================================
Write-Host ""
Write-Host "Checking script syntax..." -ForegroundColor White

$scripts = @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1', 'Validation.ps1', 'Logging.ps1', 'Requirements.ps1')
foreach ($script in $scripts) {
    $scriptPath = Join-Path $PackagePath $script
    if (Test-Path $scriptPath) {
        $syntaxErrors = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content $scriptPath -Raw), [ref]$syntaxErrors)
        if ($syntaxErrors.Count -eq 0) {
            Add-ValidationPass "$script syntax OK"
        }
        else {
            Add-ValidationError "$script has syntax errors: $($syntaxErrors[0].Message)"
        }
    }
}

# =========================================================================
# SUMMARY
# =========================================================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  VALIDATION SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

if ($Errors.Count -eq 0 -and $Warnings.Count -eq 0) {
    Write-Host "  Package is VALID and ready for packaging." -ForegroundColor Green
}
elseif ($Errors.Count -eq 0) {
    Write-Host "  Package is VALID with $($Warnings.Count) warning(s)." -ForegroundColor Yellow
}
else {
    Write-Host "  Package FAILED validation: $($Errors.Count) error(s), $($Warnings.Count) warning(s)." -ForegroundColor Red
}

Write-Host ""
Write-Host "  Errors   : $($Errors.Count)" -ForegroundColor $(if ($Errors.Count -eq 0) { 'Green' } else { 'Red' })
Write-Host "  Warnings : $($Warnings.Count)" -ForegroundColor $(if ($Warnings.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ""

if ($Errors.Count -eq 0) {
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "    1. Place installer in the Files\ directory" -ForegroundColor Gray
    Write-Host "    2. Run: .\Test-Local.ps1 -Test All -EnableTestMode" -ForegroundColor Gray
    Write-Host "    3. Package with IntuneWinAppUtil.exe:" -ForegroundColor Gray
    Write-Host "       IntuneWinAppUtil.exe -c `"$PackagePath`" -s Install.ps1 -o `"<output>`"" -ForegroundColor Gray
    Write-Host ""
}

exit $Errors.Count
