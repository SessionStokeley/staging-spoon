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

### App Information

| Field | Value |
|---|---|
| Name | Your application name |
| Description | Your application description |
| Publisher | Your publisher name |

### Program

| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Uninstall.ps1` |
| Install behavior | **System** |
| Device restart behavior | Based on return codes |

### Requirements

| Field | Value |
|---|---|
| Operating system architecture | 64-bit (or as needed) |
| Minimum operating system | Windows 10 1607 (or as needed) |

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

### EXE Installer (e.g., Google Chrome)

```powershell
@{
    ApplicationName    = "Google Chrome"
    ApplicationVersion = "120.0.0"
    Publisher          = "Google LLC"
    CompanyName        = "Contoso"

    Installer = @{
        Type      = "EXE"
        File      = "GoogleChromeStandaloneEnterprise64.msi"
        Arguments = "/quiet /norestart"
        WorkingDirectory = "Files"
    }

    Uninstaller = @{
        Type = "Registry"
        DisplayName = "Google Chrome"
    }

    Detection = @{
        Type           = "File"
        Path           = "C:\Program Files\Google\Chrome\Application"
        FileName       = "chrome.exe"
        MinimumVersion = "120.0.0.0"
    }

    Requirements = @{
        MinimumWindowsVersion = "10.0"
        Architecture          = "x64"
        MinimumDiskSpaceGB    = 1
    }

    ProcessesToStop    = @("chrome")
    ServicesToStop     = @()
    ForceStopProcesses = $false
    GracefulStopTimeoutSeconds = 30

    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
    }

    PostInstallValidation = @{
        ExpectedFiles = @("C:\Program Files\Google\Chrome\Application\chrome.exe")
        ExpectedRegistryEntries = @()
        ValidateVersion = $true
    }

    Testing = @{ AllowNonSystemExecution = $false }
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
        InstallArguments = "/qn /norestart ALLUSERS=1"
        WorkingDirectory = "Files"
    }

    Uninstaller = @{
        Type        = "MSI"
        ProductCode = "{23170F69-40C1-2702-2301-000001000000}"
    }

    Detection = @{
        Type        = "MSI"
        ProductCode = "{23170F69-40C1-2702-2301-000001000000}"
    }

    Requirements = @{
        MinimumWindowsVersion = "10.0"
        Architecture          = "x64"
        MinimumDiskSpaceGB    = 1
    }

    ProcessesToStop    = @("7zFM", "7zG")
    ServicesToStop     = @()
    ForceStopProcesses = $false
    GracefulStopTimeoutSeconds = 15

    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
    }

    PostInstallValidation = @{
        ExpectedFiles = @("C:\Program Files\7-Zip\7z.exe")
        ExpectedRegistryEntries = @()
        ValidateVersion = $false
    }

    Testing = @{ AllowNonSystemExecution = $false }
}
```

## Logging

All logs are written to:

```
C:\ProgramData\<CompanyName>\IntuneApps\<ApplicationName>\
```

Log files:
- `Install.log` - Installation activity
- `Uninstall.log` - Uninstallation activity
- `DeploymentSummary.log` - Summary of each deployment action

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
.\Test-Local.ps1 -Test Install -EnableTestMode
.\Test-Local.ps1 -Test Uninstall -EnableTestMode
```

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|---|---|---|
| Detection fails | Wrong path/version in config | Verify Detection settings in Configuration.psd1 |
| Install runs but app missing | Silent switch incorrect | Check installer documentation for correct silent arguments |
| Exit code 1603 | MSI installation error | Check Windows Event Log and MSI log |
| Exit code 1618 | Another install in progress | Wait and retry; Intune will retry automatically |
| Runs as user, not SYSTEM | Install behavior set to User | Set Install behavior to **System** in Intune |
| UAC prompt appears | Script tries to elevate | Framework never elevates; ensure Install behavior is System |

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
- Validates SYSTEM context before privileged operations
- All paths resolved relative to the script, never from CWD or user profile
