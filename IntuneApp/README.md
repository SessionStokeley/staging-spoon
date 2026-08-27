# Intune Win32 Application Deployment Framework

A reusable, configuration-driven PowerShell framework for deploying any Windows application through Microsoft Intune as a Win32 app.

## Quick Start

1. Place your installer in `Files\`
2. Edit `Configuration.psd1` with your application settings
3. Run `.\Validate-Package.ps1` to verify the package
4. Run `.\Test-Local.ps1 -Test All -EnableTestMode` for local testing
5. Package with the Microsoft Win32 Content Prep Tool
6. Upload to Intune

## Directory Structure

```
IntuneApp\
├── Install.ps1           # Generic installer (do not modify)
├── Uninstall.ps1         # Generic uninstaller (do not modify)
├── Detection.ps1         # Generic detection script (do not modify)
├── Requirements.ps1      # Generic requirements validation (do not modify)
├── Validation.ps1        # Generic validation framework (do not modify)
├── Logging.ps1           # Centralized logging (do not modify)
├── Configuration.psd1    # APPLICATION-SPECIFIC - Edit this
├── Validate-Package.ps1  # Package validation tool
├── Test-Local.ps1        # Local testing framework
├── Files\                # APPLICATION-SPECIFIC - Place installers here
│   └── Setup.exe
└── Logs\                 # Local log output (not packaged)
```

Only `Configuration.psd1` and `Files\` change between applications.

## Configuration Architecture

```
Install.ps1 / Uninstall.ps1
      │
      ▼
Configuration.psd1
      │
      ├── Installer (Type, File, Arguments, SHA256)
      ├── Uninstaller (Type, DisplayName, ProductCode)
      ├── Detection (Type, Path, VersionComparison)
      ├── Requirements (Architecture[], OS, Disk, RAM)
      ├── ProcessManagement (Processes, Services, ForceStop)
      ├── Upgrade (RemovePreviousVersion, AllowDowngrade)
      ├── Logging (RootPath, Rotation, Transcript)
      ├── Execution (RequireSystem, AllowInteractive)
      ├── Environment (Variables)
      └── Testing (SkipDetection, SkipValidation, Debug)
```

## Packaging for Intune

### Prerequisites

Download the [Microsoft Win32 Content Prep Tool](https://github.com/Microsoft/Microsoft-Win32-Content-Prep-Tool).

### Create the .intunewin Package

```cmd
IntuneWinAppUtil.exe -c "C:\Packages\MyApp" -s Install.ps1 -o "C:\Output"
```

- `-c` = Source folder (your IntuneApp directory)
- `-s` = Setup file (always `Install.ps1`)
- `-o` = Output folder for the .intunewin file

## Intune Configuration

### Add Win32 App

1. Go to **Microsoft Intune admin center** > **Apps** > **All apps** > **Add**
2. Select **Windows app (Win32)**
3. Upload the `.intunewin` file

### Program

| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Uninstall.ps1` |
| Install behavior | **System** |
| Device restart behavior | Based on return codes |

### Detection Rules

| Field | Value |
|---|---|
| Rules format | **Use a custom detection script** |
| Script file | Upload `Detection.ps1` |
| Run script as 32-bit process | No |
| Enforce script signature check | No |

### Return Codes

| Return Code | Code Type |
|---|---|
| 0 | Success |
| 1707 | Success |
| 3010 | Soft reboot |
| 1641 | Hard reboot |
| 1618 | Retry |

### Assignments

**Required Deployment:**
- Add group > Select device or user group
- End user notifications: Hide all toast notifications (or as desired)

**Available Deployment (Company Portal):**
- Add group > Select user group
- End user notifications: Show all toast notifications

**Uninstall Assignment:**
- Add group > Select device or user group for uninstall

### Supersedence

To supersede an older version:
1. In the new app, go to **Supersedence**
2. **Add** > Select the older app
3. Choose **Update** (installs new over old) or **Replace** (uninstalls old first)

## Configuration Examples

### EXE Installer (e.g., IntelliJ IDEA)

```powershell
@{
    ApplicationName    = "IntelliJ IDEA"
    ApplicationVersion = "2026.2.1"
    Publisher          = "JetBrains"
    CompanyName        = "Contoso"

    Installer = @{
        Type             = "EXE"
        File             = "ideaIU-2026.2.1.exe"
        Arguments        = "/S"
        WorkingDirectory = "Files"
        TimeoutSeconds   = 3600
        ProductCode      = $null
        InstallArguments = $null
        SHA256           = $null
    }

    InstallScope = "Machine"

    Uninstaller = @{
        Type           = "Registry"
        DisplayName    = "IntelliJ IDEA"
        File           = $null
        Arguments      = "/S"
        Command        = $null
        ProductCode    = $null
        TimeoutSeconds = 3600
    }

    Detection = @{
        Type              = "File"
        Path              = "C:\Program Files\JetBrains\IntelliJ IDEA\bin"
        FileName          = "idea64.exe"
        MinimumVersion    = "2026.2.1.0"
        VersionComparison = "GreaterThanOrEqual"
        RegistryPath      = $null
        ValueName         = $null
        ProductCode       = $null
        ServiceName       = $null
        CustomScript      = $null
    }

    Requirements = @{
        MinimumWindowsVersion = "10.0"
        WindowsEdition        = $null
        Architecture          = @("x64")
        MinimumDiskSpaceGB    = 5
        MinimumRAMGB          = 8
        CPUArchitecture       = $null
        DeviceType            = $null
        CustomRequirements    = @()
    }

    ProcessManagement = @{
        Enabled                    = $true
        Processes                  = @("idea64")
        Services                   = @()
        ForceStop                  = $false
        GracefulStopTimeoutSeconds = 30
    }

    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
    }

    PostInstallValidation = @{
        Enabled = $true
        ExpectedFiles = @(
            "C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe"
        )
        ExpectedRegistryEntries = @()
        ValidateVersion = $true
    }

    Upgrade = @{
        RemovePreviousVersion = $true
        PreviousVersions      = @("2026.1", "2026.2")
        AllowDowngrade         = $false
    }

    Logging = @{
        Enabled           = $true
        RootPath          = $null
        IncludeTranscript = $true
        MaximumLogSizeMB  = 10
        RetainLogFiles    = 10
    }

    Environment = @{ Variables = @{} }
    Execution = @{
        RequireSystem    = $true
        AllowInteractive = $false
        AllowUserProfile = $false
    }
    Testing = @{
        AllowNonSystemExecution = $false
        EnableDebugLogging      = $false
        SkipRequirementChecks   = $false
        SkipDetection           = $false
        SkipValidation          = $false
    }
}
```

### MSI Installer (e.g., 7-Zip)

```powershell
@{
    ApplicationName    = "7-Zip"
    ApplicationVersion = "23.01"
    Publisher          = "Igor Pavlov"
    CompanyName        = "Contoso"

    Installer = @{
        Type             = "MSI"
        File             = "7z2301-x64.msi"
        Arguments        = $null
        WorkingDirectory = "Files"
        TimeoutSeconds   = 3600
        ProductCode      = "{23170F69-40C1-2702-2301-000001000000}"
        InstallArguments = "/qn /norestart ALLUSERS=1"
        SHA256           = $null
    }

    InstallScope = "Machine"

    Uninstaller = @{
        Type           = "MSI"
        DisplayName    = $null
        File           = $null
        Arguments      = $null
        Command        = $null
        ProductCode    = "{23170F69-40C1-2702-2301-000001000000}"
        TimeoutSeconds = 3600
    }

    Detection = @{
        Type              = "MSI"
        Path              = $null
        FileName          = $null
        MinimumVersion    = $null
        VersionComparison = $null
        RegistryPath      = $null
        ValueName         = $null
        ProductCode       = "{23170F69-40C1-2702-2301-000001000000}"
        ServiceName       = $null
        CustomScript      = $null
    }

    Requirements = @{
        MinimumWindowsVersion = "10.0"
        WindowsEdition        = $null
        Architecture          = @("x64")
        MinimumDiskSpaceGB    = 1
        MinimumRAMGB          = 2
        CPUArchitecture       = $null
        DeviceType            = $null
        CustomRequirements    = @()
    }

    ProcessManagement = @{
        Enabled                    = $true
        Processes                  = @("7zFM", "7zG")
        Services                   = @()
        ForceStop                  = $false
        GracefulStopTimeoutSeconds = 15
    }

    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
    }

    PostInstallValidation = @{
        Enabled = $true
        ExpectedFiles = @("C:\Program Files\7-Zip\7z.exe")
        ExpectedRegistryEntries = @()
        ValidateVersion = $false
    }

    Upgrade = @{
        RemovePreviousVersion = $false
        PreviousVersions      = @()
        AllowDowngrade         = $false
    }

    Logging = @{
        Enabled           = $true
        RootPath          = $null
        IncludeTranscript = $false
        MaximumLogSizeMB  = 10
        RetainLogFiles    = 10
    }

    Environment = @{ Variables = @{} }
    Execution = @{
        RequireSystem    = $true
        AllowInteractive = $false
        AllowUserProfile = $false
    }
    Testing = @{
        AllowNonSystemExecution = $false
        EnableDebugLogging      = $false
        SkipRequirementChecks   = $false
        SkipDetection           = $false
        SkipValidation          = $false
    }
}
```

### Multi-Architecture App (e.g., VPN Client)

```powershell
Requirements = @{
    Architecture = @("x64", "ARM64")
    # ...
}
```

## Logging

All logs are written to:

```
C:\ProgramData\<CompanyName>\IntuneApps\<ApplicationName>\
```

Or a custom path via `Logging.RootPath`.

Log files:
- `Install.log` - Installation activity
- `Uninstall.log` - Uninstallation activity
- `DeploymentSummary.log` - Summary of each deployment action
- `*.transcript.log` - Full PowerShell transcript (when enabled)

Log rotation: when a log exceeds `MaximumLogSizeMB`, it is archived with a timestamp and old archives beyond `RetainLogFiles` are pruned.

## Detection Version Comparison

The `VersionComparison` field supports:

| Value | Behavior |
|---|---|
| `Equal` | Exact version match |
| `GreaterThan` | Installed version must be strictly newer |
| `GreaterThanOrEqual` | Installed version must be same or newer (default) |
| `LessThan` | Installed version must be older |
| `LessThanOrEqual` | Installed version must be same or older |

## Upgrade / Supersedence Awareness

```powershell
Upgrade = @{
    RemovePreviousVersion = $true
    PreviousVersions      = @("2026.1", "2026.2")
    AllowDowngrade         = $false
}
```

- `RemovePreviousVersion` - When `$true` and an existing version is detected, the installer proceeds (upgrade over existing). When `$false`, the framework reports success without reinstalling.
- `AllowDowngrade` - When `$false`, pre-install validation rejects deploying an older version over a newer one.
- `PreviousVersions` - Tracked for logging/reporting purposes.

## Local Testing

### As Current User (Test Mode)

```powershell
.\Test-Local.ps1 -Test All -EnableTestMode
```

### As SYSTEM (Using PsExec)

```powershell
PsExec.exe -s -i powershell.exe -ExecutionPolicy Bypass -File "C:\Packages\MyApp\Test-Local.ps1" -Test All
```

### Individual Tests

```powershell
.\Test-Local.ps1 -Test Detection
.\Test-Local.ps1 -Test Requirements
.\Test-Local.ps1 -Test Validation
.\Test-Local.ps1 -Test Package
.\Test-Local.ps1 -Test Logging
.\Test-Local.ps1 -Test Install -EnableTestMode
.\Test-Local.ps1 -Test Uninstall -EnableTestMode
```

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|---|---|---|
| Detection fails | Wrong path/version in config | Verify Detection settings; check VersionComparison |
| Install runs but app missing | Silent switch incorrect | Check installer docs for correct silent arguments |
| Exit code 1603 | MSI installation error | Check MSI log and Windows Event Log |
| Exit code 1618 | Another install in progress | Wait; Intune will retry automatically |
| Runs as user, not SYSTEM | Install behavior set to User | Set Install behavior to **System** in Intune |
| UAC prompt appears | Script tries to elevate | Framework never elevates; ensure Install behavior is System |
| SHA256 mismatch | Installer file corrupted/changed | Regenerate hash or re-download installer |
| Downgrade rejected | AllowDowngrade is false | Set Upgrade.AllowDowngrade = $true or deploy newer version |

### Log Locations

- **Framework logs:** `C:\ProgramData\<CompanyName>\IntuneApps\<AppName>\`
- **Intune Management Extension logs:** `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`
- **MSI logs (if enabled):** `%TEMP%\MSI*.log`

### Enabling Verbose MSI Logging

Add to MSI install arguments:
```
/l*v "C:\ProgramData\CompanyName\IntuneApps\AppName\MSI_Install.log"
```

## Security

- Never stores credentials, tokens, or secrets
- Never bypasses UAC or modifies security policy
- Never creates administrative accounts
- Executes only files contained in the Intune package
- Optional SHA256 integrity verification of installer files
- Validates SYSTEM context before privileged operations
- All paths resolved relative to the script, never from CWD or user profile
- Rejects unsupported InstallScope combinations
