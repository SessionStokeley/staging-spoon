#Requires -Version 5.1
<#
.SYNOPSIS
    Package validation script for Intune Win32 deployment packages.
.DESCRIPTION
    Validates that a deployment package is complete and correctly configured
    before creating the .intunewin file and uploading to Intune.
    Each finding has a unique ID (PKG-xxx) with Component, Problem, Expected, and Fix.

.PARAMETER PackagePath
    Path to the deployment package directory. Defaults to $PSScriptRoot.

.PARAMETER Detailed
    Shows full remediation guidance for each finding.

.EXAMPLE
    .\Validate-Package.ps1
    .\Validate-Package.ps1 -PackagePath "C:\Packages\MyApp"
    .\Validate-Package.ps1 -Detailed
#>

[CmdletBinding()]
param(
    [string]$PackagePath = $PSScriptRoot,
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
$script:Findings = @()

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Error','Warning','Pass')]$Severity,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Message,
        [string]$Expected = '',
        [string]$Fix = ''
    )

    $script:Findings += [PSCustomObject]@{
        Id        = $Id
        Severity  = $Severity
        Component = $Component
        Message   = $Message
        Expected  = $Expected
        Fix       = $Fix
    }

    switch ($Severity) {
        'Error'   { Write-Host "  [$Id] ERROR   $Component: $Message" -ForegroundColor Red }
        'Warning' { Write-Host "  [$Id] WARN    $Component: $Message" -ForegroundColor Yellow }
        'Pass'    { Write-Host "  [$Id] PASS    $Component: $Message" -ForegroundColor Green }
    }

    if ($Detailed -and $Severity -ne 'Pass') {
        if ($Expected) { Write-Host "           Expected: $Expected" -ForegroundColor Gray }
        if ($Fix)      { Write-Host "           Fix:      $Fix" -ForegroundColor Gray }
    }
}

Write-Host ""
Write-Host "Intune Win32 Package Validator" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  Package: $PackagePath"
Write-Host ("=" * 70) -ForegroundColor Cyan

# =========================================================================
# 1. REQUIRED FILES
# =========================================================================
Write-Host ""
Write-Host "Required Files" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

$requiredFiles = @{
    'Configuration.psd1' = 'Application configuration'
    'Install.ps1'        = 'Installation script'
    'Uninstall.ps1'      = 'Uninstallation script'
    'Detection.ps1'      = 'Detection script'
    'Validation.ps1'     = 'Validation framework'
    'Logging.ps1'        = 'Logging framework'
    'Requirements.ps1'   = 'Requirements validation'
    'Helpers.ps1'        = 'Shared helper functions'
}

$fileIndex = 0
foreach ($file in $requiredFiles.GetEnumerator()) {
    $fileIndex++
    $pkgId = "PKG-{0:D3}" -f $fileIndex
    $filePath = Join-Path $PackagePath $file.Key
    if (Test-Path $filePath) {
        Add-Finding -Id $pkgId -Severity 'Pass' -Component 'RequiredFiles' `
            -Message "$($file.Key) ($($file.Value))"
    }
    else {
        Add-Finding -Id $pkgId -Severity 'Error' -Component 'RequiredFiles' `
            -Message "Missing: $($file.Key) - $($file.Value)" `
            -Expected "File must exist at $filePath" `
            -Fix "Add $($file.Key) to the package directory"
    }
}

# =========================================================================
# 2. CONFIGURATION PARSE
# =========================================================================
Write-Host ""
Write-Host "Configuration" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

$configPath = Join-Path $PackagePath 'Configuration.psd1'
$Config = $null

if (Test-Path $configPath) {
    try {
        $Config = Import-PowerShellDataFile -Path $configPath
        Add-Finding -Id 'PKG-010' -Severity 'Pass' -Component 'Configuration' `
            -Message "Configuration.psd1 parses successfully"
    }
    catch {
        Add-Finding -Id 'PKG-010' -Severity 'Error' -Component 'Configuration' `
            -Message "Configuration.psd1 parse error: $_" `
            -Expected 'Valid PowerShell data file syntax' `
            -Fix 'Check for syntax errors: unmatched braces, missing commas, invalid expressions'
    }
}
else {
    Add-Finding -Id 'PKG-010' -Severity 'Error' -Component 'Configuration' `
        -Message 'Configuration.psd1 not found' `
        -Expected "File at $configPath" `
        -Fix 'Create Configuration.psd1 from the template'
}

if (-not $Config) {
    Write-Host ""
    Write-Host "Cannot continue validation without a valid Configuration.psd1" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# =========================================================================
# 3. APPLICATION METADATA
# =========================================================================
Write-Host ""
Write-Host "Application Metadata" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Application) {
    if ($Config.Application.Name -and $Config.Application.Name.Trim() -ne '') {
        Add-Finding -Id 'PKG-020' -Severity 'Pass' -Component 'Application' `
            -Message "Name: $($Config.Application.Name)"
    }
    else {
        Add-Finding -Id 'PKG-020' -Severity 'Error' -Component 'Application' `
            -Message 'Application.Name is empty or missing' `
            -Expected 'A non-empty application name' `
            -Fix 'Set Application.Name in Configuration.psd1'
    }

    if ($Config.Application.Version) {
        Add-Finding -Id 'PKG-021' -Severity 'Pass' -Component 'Application' `
            -Message "Version: $($Config.Application.Version)"
    }
    else {
        Add-Finding -Id 'PKG-021' -Severity 'Warning' -Component 'Application' `
            -Message 'Application.Version is empty' `
            -Expected 'A version string (e.g. 1.0.0)' `
            -Fix 'Set Application.Version for tracking deployed versions'
    }

    if ($Config.Application.Publisher) {
        Add-Finding -Id 'PKG-022' -Severity 'Pass' -Component 'Application' `
            -Message "Publisher: $($Config.Application.Publisher)"
    }
}
else {
    Add-Finding -Id 'PKG-020' -Severity 'Error' -Component 'Application' `
        -Message 'Application section missing from configuration' `
        -Expected 'Application = @{ Name = "..."; Version = "..." }' `
        -Fix 'Add Application section with at least Name'
}

if ($Config.CompanyName -and $Config.CompanyName.Trim() -ne '') {
    Add-Finding -Id 'PKG-023' -Severity 'Pass' -Component 'Application' `
        -Message "CompanyName: $($Config.CompanyName)"
}
else {
    Add-Finding -Id 'PKG-023' -Severity 'Error' -Component 'Application' `
        -Message 'CompanyName is empty or missing (required for log paths)' `
        -Expected 'CompanyName = "YourOrganization"' `
        -Fix 'Set CompanyName at the root of Configuration.psd1'
}

# =========================================================================
# 4. PRIVILEGES
# =========================================================================
Write-Host ""
Write-Host "Privileges" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Privileges) {
    Add-Finding -Id 'PKG-030' -Severity 'Pass' -Component 'Privileges' `
        -Message "InstallAsSystem=$($Config.Privileges.InstallAsSystem), RequireElevation=$($Config.Privileges.RequireElevation)"
}
else {
    Add-Finding -Id 'PKG-030' -Severity 'Warning' -Component 'Privileges' `
        -Message 'Privileges section not set (defaults to InstallAsSystem=$true)' `
        -Expected 'Privileges = @{ InstallAsSystem = $true; RequireElevation = $true }' `
        -Fix 'Add Privileges section to explicitly set execution context'
}

# =========================================================================
# 5. INSTALLER
# =========================================================================
Write-Host ""
Write-Host "Installer" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Installer) {
    $validTypes = @('EXE', 'MSI', 'MSIX', 'CMD', 'BAT', 'PS1')
    $installerType = if ($Config.Installer.Type) { $Config.Installer.Type } else { 'EXE' }

    if ($installerType -in $validTypes) {
        Add-Finding -Id 'PKG-040' -Severity 'Pass' -Component 'Installer' `
            -Message "Type: $installerType"
    }
    else {
        Add-Finding -Id 'PKG-040' -Severity 'Warning' -Component 'Installer' `
            -Message "Type '$installerType' is not standard ($($validTypes -join ', '))" `
            -Expected "One of: $($validTypes -join ', ')" `
            -Fix 'Use a supported installer type'
    }

    if ($Config.Installer.File) {
        $installerPath = Join-Path $PackagePath (Join-Path 'Files' $Config.Installer.File)
        if (Test-Path $installerPath) {
            $fileSize = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
            Add-Finding -Id 'PKG-041' -Severity 'Pass' -Component 'Installer' `
                -Message "File exists: $($Config.Installer.File) ($fileSize MB)"

            # SHA256 verification
            if ($Config.Installer.SHA256) {
                $actualHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
                if ($actualHash -eq $Config.Installer.SHA256) {
                    Add-Finding -Id 'PKG-042' -Severity 'Pass' -Component 'Installer' `
                        -Message 'SHA256 integrity verified'
                }
                else {
                    Add-Finding -Id 'PKG-042' -Severity 'Error' -Component 'Installer' `
                        -Message "SHA256 mismatch" `
                        -Expected "SHA256: $($Config.Installer.SHA256)" `
                        -Fix "Actual hash: $actualHash - update SHA256 in config or replace the installer file"
                }
            }
        }
        else {
            # Show available files in the Files directory
            $filesDir = Join-Path $PackagePath 'Files'
            $availableFiles = @()
            if (Test-Path $filesDir) {
                $availableFiles = Get-ChildItem -Path $filesDir -File | Select-Object -ExpandProperty Name
            }

            $detail = "Configured: $($Config.Installer.File) | Resolved path: $installerPath"
            if ($availableFiles.Count -gt 0) {
                $detail += " | Available files in Files\: $($availableFiles -join ', ')"
            }
            else {
                $detail += " | Files\ directory is empty or missing"
            }

            Add-Finding -Id 'PKG-041' -Severity 'Error' -Component 'Installer' `
                -Message "Installer file not found" `
                -Expected $detail `
                -Fix "Place the installer at Files\$($Config.Installer.File) or update Installer.File to match an available file"
        }
    }
    else {
        Add-Finding -Id 'PKG-041' -Severity 'Error' -Component 'Installer' `
            -Message 'Installer.File is not specified' `
            -Expected 'Installer.File = "Setup.exe"' `
            -Fix 'Set the installer filename in Installer.File'
    }

    if ($Config.Installer.Arguments) {
        Add-Finding -Id 'PKG-043' -Severity 'Pass' -Component 'Installer' `
            -Message "Arguments configured: $($Config.Installer.Arguments)"
    }
    else {
        Add-Finding -Id 'PKG-043' -Severity 'Warning' -Component 'Installer' `
            -Message 'No installer arguments configured' `
            -Expected 'Silent install arguments (e.g. /quiet /norestart)' `
            -Fix 'Set Installer.Arguments for silent installation'
    }

    if ($installerType -eq 'MSI') {
        if ($Config.Installer.ProductCode) {
            Add-Finding -Id 'PKG-044' -Severity 'Pass' -Component 'Installer' `
                -Message "MSI ProductCode: $($Config.Installer.ProductCode)"
        }
        else {
            Add-Finding -Id 'PKG-044' -Severity 'Error' -Component 'Installer' `
                -Message 'MSI installer requires ProductCode' `
                -Expected 'Installer.ProductCode = "{GUID}"' `
                -Fix 'Add the MSI product code GUID to Installer.ProductCode'
        }
    }
}
else {
    Add-Finding -Id 'PKG-040' -Severity 'Error' -Component 'Installer' `
        -Message 'Installer section missing from configuration' `
        -Expected 'Installer = @{ Type = "EXE"; File = "Setup.exe"; Arguments = "/quiet" }' `
        -Fix 'Add Installer section to Configuration.psd1'
}

# =========================================================================
# 6. UNINSTALLER
# =========================================================================
Write-Host ""
Write-Host "Uninstaller" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Uninstaller) {
    $validUninstallTypes = @('Executable', 'MSI', 'Registry', 'Custom')
    $uninstallType = if ($Config.Uninstaller.Type) { $Config.Uninstaller.Type } else { 'Executable' }

    if ($uninstallType -in $validUninstallTypes) {
        Add-Finding -Id 'PKG-050' -Severity 'Pass' -Component 'Uninstaller' `
            -Message "Type: $uninstallType"
    }
    else {
        Add-Finding -Id 'PKG-050' -Severity 'Error' -Component 'Uninstaller' `
            -Message "Invalid uninstaller type: $uninstallType" `
            -Expected "One of: $($validUninstallTypes -join ', ')" `
            -Fix 'Set Uninstaller.Type to a supported value'
    }

    switch ($uninstallType) {
        'MSI' {
            if ($Config.Uninstaller.ProductCode -or ($Config.Detection.Type -eq 'MSI' -and $Config.Detection.ProductCode)) {
                Add-Finding -Id 'PKG-051' -Severity 'Pass' -Component 'Uninstaller' `
                    -Message 'MSI ProductCode available for uninstall'
            }
            else {
                Add-Finding -Id 'PKG-051' -Severity 'Error' -Component 'Uninstaller' `
                    -Message 'MSI uninstall requires ProductCode' `
                    -Expected 'ProductCode in Uninstaller or Detection config' `
                    -Fix 'Set Uninstaller.ProductCode or ensure Detection has ProductCode for MSI type'
            }
        }
        'Executable' {
            if ($Config.Uninstaller.File) {
                Add-Finding -Id 'PKG-051' -Severity 'Pass' -Component 'Uninstaller' `
                    -Message "Executable: $($Config.Uninstaller.File)"
            }
            else {
                Add-Finding -Id 'PKG-051' -Severity 'Error' -Component 'Uninstaller' `
                    -Message 'Executable uninstall requires File' `
                    -Expected 'Uninstaller.File = "uninstall.exe"' `
                    -Fix 'Set the uninstaller executable path'
            }
        }
        'Registry' {
            $displayName = $Config.Uninstaller.DisplayName
            if (-not $displayName -and $Config.Application) { $displayName = $Config.Application.Name }
            if ($displayName) {
                Add-Finding -Id 'PKG-051' -Severity 'Pass' -Component 'Uninstaller' `
                    -Message "Registry lookup: '$displayName'"
            }
            else {
                Add-Finding -Id 'PKG-051' -Severity 'Warning' -Component 'Uninstaller' `
                    -Message 'Registry uninstall without DisplayName or Application.Name' `
                    -Expected 'Uninstaller.DisplayName or Application.Name' `
                    -Fix 'Set Uninstaller.DisplayName to the registry display name'
            }
        }
        'Custom' {
            if ($Config.Uninstaller.Command) {
                Add-Finding -Id 'PKG-051' -Severity 'Pass' -Component 'Uninstaller' `
                    -Message "Custom command: $($Config.Uninstaller.Command)"
            }
            else {
                Add-Finding -Id 'PKG-051' -Severity 'Error' -Component 'Uninstaller' `
                    -Message 'Custom uninstall requires Command' `
                    -Expected 'Uninstaller.Command = "path\to\uninstaller.exe"' `
                    -Fix 'Set the custom uninstall command'
            }
        }
    }
}
else {
    Add-Finding -Id 'PKG-050' -Severity 'Warning' -Component 'Uninstaller' `
        -Message 'Uninstaller section missing - uninstall may not work' `
        -Expected 'Uninstaller = @{ Type = "Registry"; ... }' `
        -Fix 'Add Uninstaller section to Configuration.psd1'
}

# =========================================================================
# 7. DETECTION
# =========================================================================
Write-Host ""
Write-Host "Detection" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Detection) {
    $validDetectionTypes = @('File', 'Registry', 'MSI', 'Service', 'Custom')

    if ($Config.Detection.Type -in $validDetectionTypes) {
        Add-Finding -Id 'PKG-060' -Severity 'Pass' -Component 'Detection' `
            -Message "Type: $($Config.Detection.Type)"
    }
    else {
        Add-Finding -Id 'PKG-060' -Severity 'Error' -Component 'Detection' `
            -Message "Invalid detection type: $($Config.Detection.Type)" `
            -Expected "One of: $($validDetectionTypes -join ', ')" `
            -Fix 'Set Detection.Type to a supported value'
    }

    if ($Config.Detection.VersionComparison) {
        $validComparisons = @('Equal', 'GreaterThan', 'GreaterThanOrEqual', 'LessThan', 'LessThanOrEqual')
        if ($Config.Detection.VersionComparison -in $validComparisons) {
            Add-Finding -Id 'PKG-061' -Severity 'Pass' -Component 'Detection' `
                -Message "VersionComparison: $($Config.Detection.VersionComparison)"
        }
        else {
            Add-Finding -Id 'PKG-061' -Severity 'Error' -Component 'Detection' `
                -Message "Invalid VersionComparison: $($Config.Detection.VersionComparison)" `
                -Expected "One of: $($validComparisons -join ', ')" `
                -Fix 'Use a valid comparison operator'
        }
    }

    switch ($Config.Detection.Type) {
        'File' {
            if ($Config.Detection.Path) {
                Add-Finding -Id 'PKG-062' -Severity 'Pass' -Component 'Detection' `
                    -Message "Path: $($Config.Detection.Path)"
                if ($Config.Detection.FileName) {
                    Add-Finding -Id 'PKG-063' -Severity 'Pass' -Component 'Detection' `
                        -Message "FileName: $($Config.Detection.FileName)"
                }
            }
            else {
                Add-Finding -Id 'PKG-062' -Severity 'Error' -Component 'Detection' `
                    -Message 'File detection requires Path' `
                    -Expected 'Detection.Path = "C:\Program Files\App"' `
                    -Fix 'Set the detection path where the application installs'
            }
        }
        'MSI' {
            if ($Config.Detection.ProductCode) {
                Add-Finding -Id 'PKG-062' -Severity 'Pass' -Component 'Detection' `
                    -Message "ProductCode: $($Config.Detection.ProductCode)"
            }
            else {
                Add-Finding -Id 'PKG-062' -Severity 'Error' -Component 'Detection' `
                    -Message 'MSI detection requires ProductCode' `
                    -Expected 'Detection.ProductCode = "{GUID}"' `
                    -Fix 'Set the MSI product code GUID'
            }
        }
        'Service' {
            if ($Config.Detection.ServiceName) {
                Add-Finding -Id 'PKG-062' -Severity 'Pass' -Component 'Detection' `
                    -Message "ServiceName: $($Config.Detection.ServiceName)"
            }
            else {
                Add-Finding -Id 'PKG-062' -Severity 'Error' -Component 'Detection' `
                    -Message 'Service detection requires ServiceName' `
                    -Expected 'Detection.ServiceName = "MyService"' `
                    -Fix 'Set the Windows service name to detect'
            }
        }
        'Custom' {
            if ($Config.Detection.CustomScript) {
                Add-Finding -Id 'PKG-062' -Severity 'Pass' -Component 'Detection' `
                    -Message 'CustomScript configured'
            }
            else {
                Add-Finding -Id 'PKG-062' -Severity 'Error' -Component 'Detection' `
                    -Message 'Custom detection requires CustomScript' `
                    -Expected 'Detection.CustomScript = "Test-Path ..."' `
                    -Fix 'Provide a scriptblock string that returns $true/$false'
            }
        }
        'Registry' {
            if ($Config.Detection.RegistryPath -or $Config.Detection.DisplayName) {
                Add-Finding -Id 'PKG-062' -Severity 'Pass' -Component 'Detection' `
                    -Message "Registry detection configured"
            }
            else {
                Add-Finding -Id 'PKG-062' -Severity 'Error' -Component 'Detection' `
                    -Message 'Registry detection requires RegistryPath or DisplayName' `
                    -Expected 'Detection.RegistryPath or Detection.DisplayName' `
                    -Fix 'Set RegistryPath for direct lookup or DisplayName for search'
            }
        }
    }
}
else {
    Add-Finding -Id 'PKG-060' -Severity 'Error' -Component 'Detection' `
        -Message 'Detection section missing - Intune requires detection rules' `
        -Expected 'Detection = @{ Type = "File"; Path = "..."; FileName = "..." }' `
        -Fix 'Add Detection section to Configuration.psd1'
}

# =========================================================================
# 8. REQUIREMENTS
# =========================================================================
Write-Host ""
Write-Host "Requirements" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Requirements) {
    if ($Config.Requirements.Architecture) {
        if ($Config.Requirements.Architecture -is [array]) {
            Add-Finding -Id 'PKG-070' -Severity 'Pass' -Component 'Requirements' `
                -Message "Architecture: $($Config.Requirements.Architecture -join ', ') (array format)"
        }
        else {
            Add-Finding -Id 'PKG-070' -Severity 'Warning' -Component 'Requirements' `
                -Message "Architecture should be an array" `
                -Expected "@('$($Config.Requirements.Architecture)')" `
                -Fix "Use array syntax: Architecture = @('x64')"
        }
    }

    if ($Config.Requirements.MinimumWindowsVersion) {
        try {
            [version]$Config.Requirements.MinimumWindowsVersion | Out-Null
            Add-Finding -Id 'PKG-071' -Severity 'Pass' -Component 'Requirements' `
                -Message "MinimumWindowsVersion: $($Config.Requirements.MinimumWindowsVersion)"
        }
        catch {
            Add-Finding -Id 'PKG-071' -Severity 'Error' -Component 'Requirements' `
                -Message "Invalid MinimumWindowsVersion format: $($Config.Requirements.MinimumWindowsVersion)" `
                -Expected 'Valid version string (e.g. 10.0)' `
                -Fix 'Use a valid version format'
        }
    }

    if ($Config.Requirements.MinimumDiskSpaceGB) {
        Add-Finding -Id 'PKG-072' -Severity 'Pass' -Component 'Requirements' `
            -Message "MinimumDiskSpaceGB: $($Config.Requirements.MinimumDiskSpaceGB)"
    }

    if ($Config.Requirements.MinimumRAMGB) {
        Add-Finding -Id 'PKG-073' -Severity 'Pass' -Component 'Requirements' `
            -Message "MinimumRAMGB: $($Config.Requirements.MinimumRAMGB)"
    }
}
else {
    Add-Finding -Id 'PKG-070' -Severity 'Pass' -Component 'Requirements' `
        -Message 'No requirements configured (all systems accepted)'
}

# =========================================================================
# 9. RETURN CODES
# =========================================================================
Write-Host ""
Write-Host "Return Codes" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.ReturnCodes) {
    if ($Config.ReturnCodes.Success -contains 0) {
        Add-Finding -Id 'PKG-080' -Severity 'Pass' -Component 'ReturnCodes' `
            -Message "Success codes: $($Config.ReturnCodes.Success -join ', ')"
    }
    else {
        Add-Finding -Id 'PKG-080' -Severity 'Warning' -Component 'ReturnCodes' `
            -Message 'Success codes do not include 0' `
            -Expected 'Success = @(0)' `
            -Fix 'Most installers return 0 on success'
    }

    if ($Config.ReturnCodes.SuccessWithReboot) {
        Add-Finding -Id 'PKG-081' -Severity 'Pass' -Component 'ReturnCodes' `
            -Message "Reboot codes: $($Config.ReturnCodes.SuccessWithReboot -join ', ')"
    }
}
else {
    Add-Finding -Id 'PKG-080' -Severity 'Warning' -Component 'ReturnCodes' `
        -Message 'ReturnCodes section missing' `
        -Expected 'ReturnCodes = @{ Success = @(0); SuccessWithReboot = @(3010, 1641) }' `
        -Fix 'Add ReturnCodes section (3010 and 1641 are standard reboot codes)'
}

# =========================================================================
# 10. ENVIRONMENT
# =========================================================================
Write-Host ""
Write-Host "Environment & Associations" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Environment) {
    if ($Config.Environment.AddToMachinePath -and $Config.Environment.AddToMachinePath.Count -gt 0) {
        Add-Finding -Id 'PKG-090' -Severity 'Pass' -Component 'Environment' `
            -Message "AddToMachinePath: $($Config.Environment.AddToMachinePath.Count) entries"
        foreach ($pathEntry in $Config.Environment.AddToMachinePath) {
            if ($pathEntry -and -not [System.IO.Path]::IsPathRooted($pathEntry)) {
                Add-Finding -Id 'PKG-091' -Severity 'Warning' -Component 'Environment' `
                    -Message "PATH entry is not absolute: $pathEntry" `
                    -Expected 'Absolute path (e.g. C:\Program Files\App\bin)' `
                    -Fix 'Use fully qualified paths for Machine PATH entries'
            }
        }
    }
    if ($Config.Environment.Variables -and $Config.Environment.Variables.Count -gt 0) {
        Add-Finding -Id 'PKG-092' -Severity 'Pass' -Component 'Environment' `
            -Message "Environment variables: $($Config.Environment.Variables.Count)"
    }
}

# File associations
if ($Config.FileAssociations) {
    $validModes = @('Installer', 'Framework', 'None')
    if ($Config.FileAssociations.Mode -in $validModes) {
        Add-Finding -Id 'PKG-095' -Severity 'Pass' -Component 'FileAssociations' `
            -Message "Mode: $($Config.FileAssociations.Mode)"
    }
    else {
        Add-Finding -Id 'PKG-095' -Severity 'Error' -Component 'FileAssociations' `
            -Message "Invalid Mode: $($Config.FileAssociations.Mode)" `
            -Expected "One of: $($validModes -join ', ')" `
            -Fix "Set FileAssociations.Mode to Installer, Framework, or None"
    }

    if ($Config.FileAssociations.Mode -eq 'Framework') {
        if ($Config.FileAssociations.Associations -and $Config.FileAssociations.Associations.Count -gt 0) {
            Add-Finding -Id 'PKG-096' -Severity 'Pass' -Component 'FileAssociations' `
                -Message "Framework associations: $($Config.FileAssociations.Associations.Count) extension(s)"
            foreach ($ext in $Config.FileAssociations.Associations.Keys) {
                if (-not $ext.StartsWith('.')) {
                    Add-Finding -Id 'PKG-097' -Severity 'Warning' -Component 'FileAssociations' `
                        -Message "Extension key '$ext' should start with a dot" `
                        -Expected '".ext" = "C:\path\to\app.exe"' `
                        -Fix 'Prefix extension keys with a dot'
                }
            }
        }
        else {
            Add-Finding -Id 'PKG-096' -Severity 'Warning' -Component 'FileAssociations' `
                -Message 'Mode is Framework but no Associations defined' `
                -Expected 'Associations hashtable with extension mappings' `
                -Fix 'Add associations or set Mode to None'
        }
    }
}

# =========================================================================
# 11. REGISTRY / SHORTCUTS / POSTINSTALL / USEREXPERIENCE / UPGRADE
# =========================================================================
Write-Host ""
Write-Host "Optional Sections" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

if ($Config.Registry) {
    $regAddCount = if ($Config.Registry.Add) { $Config.Registry.Add.Count } else { 0 }
    $regRemCount = if ($Config.Registry.Remove) { $Config.Registry.Remove.Count } else { 0 }
    Add-Finding -Id 'PKG-100' -Severity 'Pass' -Component 'Registry' `
        -Message "Add: $regAddCount, Remove: $regRemCount"
}

if ($Config.Shortcuts) {
    $scCreateCount = if ($Config.Shortcuts.Create) { $Config.Shortcuts.Create.Count } else { 0 }
    $scRemoveCount = if ($Config.Shortcuts.Remove) { $Config.Shortcuts.Remove.Count } else { 0 }
    Add-Finding -Id 'PKG-101' -Severity 'Pass' -Component 'Shortcuts' `
        -Message "Create: $scCreateCount, Remove: $scRemoveCount"
}

if ($Config.PostInstall) {
    $actionCount = if ($Config.PostInstall.Actions) { $Config.PostInstall.Actions.Count } else { 0 }
    Add-Finding -Id 'PKG-102' -Severity 'Pass' -Component 'PostInstall' `
        -Message "Validate: $($Config.PostInstall.Validate), Actions: $actionCount"

    if ($Config.PostInstall.Actions) {
        $validActionTypes = @('RunCommand', 'RunPowerShell', 'RestartService', 'CopyFile')
        foreach ($action in $Config.PostInstall.Actions) {
            if ($action.Type -and $action.Type -notin $validActionTypes) {
                Add-Finding -Id 'PKG-103' -Severity 'Error' -Component 'PostInstall' `
                    -Message "Invalid action type: $($action.Type)" `
                    -Expected "One of: $($validActionTypes -join ', ')" `
                    -Fix 'Use a supported post-install action type'
            }
        }
    }
}

if ($Config.UserExperience) {
    Add-Finding -Id 'PKG-104' -Severity 'Pass' -Component 'UserExperience' `
        -Message "StartMenu=$($Config.UserExperience.CreateStartMenuShortcut), Desktop=$($Config.UserExperience.CreateDesktopShortcut)"
}

if ($Config.Upgrade) {
    Add-Finding -Id 'PKG-105' -Severity 'Pass' -Component 'Upgrade' `
        -Message "RemovePrevious=$($Config.Upgrade.RemovePreviousVersion), AllowDowngrade=$($Config.Upgrade.AllowDowngrade)"
}

if ($Config.Logging) {
    Add-Finding -Id 'PKG-106' -Severity 'Pass' -Component 'Logging' `
        -Message "Enabled=$($Config.Logging.Enabled)"
}

# =========================================================================
# 12. TESTING SECTION
# =========================================================================
if ($Config.Testing) {
    Add-Finding -Id 'PKG-110' -Severity 'Pass' -Component 'Testing' `
        -Message "AllowNonSystem=$($Config.Testing.AllowNonSystemExecution), DebugLog=$($Config.Testing.EnableDebugLogging)"

    if ($Config.Testing.AllowNonSystemExecution -eq $true) {
        Add-Finding -Id 'PKG-111' -Severity 'Warning' -Component 'Testing' `
            -Message 'AllowNonSystemExecution is $true - ensure this is $false for production deployment' `
            -Expected 'AllowNonSystemExecution = $false for Intune deployment' `
            -Fix 'Set to $false before packaging for Intune'
    }
}

# =========================================================================
# 13. SECURITY CHECK
# =========================================================================
Write-Host ""
Write-Host "Security" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

$configContent = Get-Content $configPath -Raw
$secretPatterns = @('password', 'secret', 'token', 'apikey', 'api_key', 'credential')
$secretFound = $false
foreach ($pattern in $secretPatterns) {
    if ($configContent -match "(?i)$pattern\s*=\s*['""](?!null)[^'""]+") {
        Add-Finding -Id 'PKG-120' -Severity 'Warning' -Component 'Security' `
            -Message "Configuration may contain sensitive data (matched: $pattern)" `
            -Expected 'No secrets in configuration files' `
            -Fix 'Remove secrets - use environment variables or secure vaults instead'
        $secretFound = $true
    }
}
if (-not $secretFound) {
    Add-Finding -Id 'PKG-120' -Severity 'Pass' -Component 'Security' `
        -Message 'No potential secrets detected'
}

# =========================================================================
# 14. FILES DIRECTORY
# =========================================================================
Write-Host ""
Write-Host "Package Contents" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

$filesDir = Join-Path $PackagePath 'Files'
if (Test-Path $filesDir) {
    $files = Get-ChildItem -Path $filesDir -Recurse -File
    $totalSize = 0
    if ($files.Count -gt 0) {
        $totalSize = [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
    }
    Add-Finding -Id 'PKG-130' -Severity 'Pass' -Component 'PackageContents' `
        -Message "Files directory: $($files.Count) file(s), $totalSize MB"

    if ($totalSize -gt 8192) {
        Add-Finding -Id 'PKG-131' -Severity 'Warning' -Component 'PackageContents' `
            -Message "Package exceeds 8 GB ($totalSize MB)" `
            -Expected 'Under 8 GB for Intune Win32 packages' `
            -Fix 'Reduce package size or verify Intune limits for your tenant'
    }
}
else {
    Add-Finding -Id 'PKG-130' -Severity 'Warning' -Component 'PackageContents' `
        -Message 'Files directory not found' `
        -Expected 'Files\ directory containing installer' `
        -Fix 'Create Files\ and place installer files inside'
}

# =========================================================================
# 15. SCRIPT SYNTAX CHECK
# =========================================================================
Write-Host ""
Write-Host "Script Syntax" -ForegroundColor White
Write-Host ("-" * 40) -ForegroundColor White

$scripts = @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1', 'Validation.ps1', 'Logging.ps1', 'Requirements.ps1', 'Helpers.ps1')
$syntaxIndex = 140
foreach ($scriptName in $scripts) {
    $scriptPath = Join-Path $PackagePath $scriptName
    $pkgId = "PKG-$syntaxIndex"
    $syntaxIndex++

    if (Test-Path $scriptPath) {
        $syntaxErrors = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content $scriptPath -Raw), [ref]$syntaxErrors)
        if ($syntaxErrors.Count -eq 0) {
            Add-Finding -Id $pkgId -Severity 'Pass' -Component 'Syntax' `
                -Message "$scriptName syntax OK"
        }
        else {
            Add-Finding -Id $pkgId -Severity 'Error' -Component 'Syntax' `
                -Message "$scriptName has syntax errors: $($syntaxErrors[0].Message)" `
                -Expected 'No syntax errors' `
                -Fix "Fix syntax error at line $($syntaxErrors[0].Token.StartLine) in $scriptName"
        }
    }
}

# =========================================================================
# SUMMARY
# =========================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  VALIDATION SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

$errors   = @($script:Findings | Where-Object { $_.Severity -eq 'Error' })
$warnings = @($script:Findings | Where-Object { $_.Severity -eq 'Warning' })
$passes   = @($script:Findings | Where-Object { $_.Severity -eq 'Pass' })

Write-Host ""
Write-Host "  Passed   : $($passes.Count)" -ForegroundColor Green
Write-Host "  Warnings : $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "  Errors   : $($errors.Count)" -ForegroundColor $(if ($errors.Count -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($errors.Count -gt 0) {
    Write-Host "  Errors:" -ForegroundColor Red
    foreach ($e in $errors) {
        Write-Host "    [$($e.Id)] $($e.Component): $($e.Message)" -ForegroundColor Red
        if ($e.Expected) { Write-Host "           Expected: $($e.Expected)" -ForegroundColor Gray }
        if ($e.Fix)      { Write-Host "           Fix:      $($e.Fix)" -ForegroundColor Gray }
    }
    Write-Host ""
}

if ($warnings.Count -gt 0) {
    Write-Host "  Warnings:" -ForegroundColor Yellow
    foreach ($w in $warnings) {
        Write-Host "    [$($w.Id)] $($w.Component): $($w.Message)" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "  Package is VALID and ready for packaging." -ForegroundColor Green
}
elseif ($errors.Count -eq 0) {
    Write-Host "  Package is VALID with $($warnings.Count) warning(s)." -ForegroundColor Yellow
}
else {
    Write-Host "  Package FAILED validation: $($errors.Count) error(s), $($warnings.Count) warning(s)." -ForegroundColor Red
}

Write-Host ""
if ($errors.Count -eq 0) {
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "    1. Run: .\Test-Local.ps1 -Diagnostics" -ForegroundColor Gray
    Write-Host "    2. Run: .\Test-Local.ps1 -Install -Force (elevated)" -ForegroundColor Gray
    Write-Host "    3. Package with IntuneWinAppUtil.exe:" -ForegroundColor Gray
    Write-Host "       IntuneWinAppUtil.exe -c `"$PackagePath`" -s Install.ps1 -o `"<output>`"" -ForegroundColor Gray
    Write-Host ""
}

exit $errors.Count
