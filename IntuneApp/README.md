# Intune Win32 Application Deployment Framework

A reusable, configuration-driven PowerShell framework for deploying any Windows application through Microsoft Intune as a Win32 app. Only `Configuration.psd1` and the `Files\` directory change between applications -- the framework scripts are universal.

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
├── Install.ps1           # Universal installer engine (do not modify)
├── Uninstall.ps1         # Universal uninstaller engine (do not modify)
├── Detection.ps1         # Detection script (do not modify)
├── Requirements.ps1      # Requirements validation (do not modify)
├── Validation.ps1        # Pre/post-install validation (do not modify)
├── Logging.ps1           # Centralized logging (do not modify)
├── Helpers.ps1           # Shared helper functions (do not modify)
├── Configuration.psd1    # APPLICATION-SPECIFIC - Edit this
├── Validate-Package.ps1  # Package validation tool
├── Test-Local.ps1        # Local testing framework
├── Files\                # APPLICATION-SPECIFIC - Place installers here
│   └── Setup.exe
└── Logs\                 # Local log output (not packaged)
```

## Architecture

The framework is a universal deployment engine. `Configuration.psd1` is the single source of truth for everything that varies between applications.

```
Install.ps1 / Uninstall.ps1
      │
      ├── Logging.ps1        (log management, rotation, transcripts)
      ├── Detection.ps1      (application detection)
      ├── Validation.ps1     (pre/post-install validation)
      ├── Requirements.ps1   (system requirements)
      ├── Helpers.ps1        (shared helper functions)
      │
      └── Configuration.psd1 (the only file you edit)
            │
            ├── Application        (Name, Version, Publisher, Architecture)
            ├── CompanyName        (deploying organization)
            ├── Privileges         (InstallAsSystem, RequireElevation)
            ├── Installer          (Type, File, Arguments, SHA256)
            ├── Uninstaller        (Type, DisplayName, ProductCode)
            ├── Detection          (Type, Path, VersionComparison)
            ├── Requirements       (Architecture[], OS, Disk, RAM)
            ├── ProcessesToStop    (flat array of process names)
            ├── ServicesToStop     (flat array of service names)
            ├── Environment        (AddToMachinePath, Variables)
            ├── FileAssociations   (Mode, Associations)
            ├── Registry           (Add, Remove)
            ├── Shortcuts          (Create, Remove)
            ├── PostInstall        (Validate, Actions)
            ├── UserExperience     (StartMenu, Desktop, LaunchAfterInstall)
            ├── Upgrade            (RemovePreviousVersion, AllowDowngrade)
            ├── ReturnCodes        (Success, SuccessWithReboot)
            ├── Logging            (RootPath, Rotation, Transcript)
            └── Testing            (SkipDetection, SkipValidation, Debug)
```

### Install Phase Flow

```
Load Configuration
      │
      ▼
Pre-Install Validation
      │
      ▼
Check Requirements
      │
      ▼
Pre-Install Detection (already installed?)
      │
      ▼
Stop Processes / Services
      │
      ▼
Execute Installer (EXE / MSI / MSIX / CMD / BAT / PS1)
      │
      ▼
Post-Install Phase
  ├── Machine PATH entries
  ├── Persistent environment variables
  ├── File associations (Framework mode)
  ├── Registry modifications
  ├── Shortcuts (Create / Remove)
  ├── UserExperience shortcuts
  └── PostInstall.Actions (RunCommand, RunPowerShell, RestartService, CopyFile)
      │
      ▼
Post-Install Validation + Detection
      │
      ▼
Log Result → Return to Intune
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
| Install behavior | **System** (or **User** if `Privileges.InstallAsSystem = $false`) |
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

## Configuration Reference

### Application

```powershell
Application = @{
    Name         = "Example Application"
    Version      = "1.0.0"
    Publisher    = "Example Vendor"
    Architecture = "x64"
}
CompanyName = "Contoso"
```

### Privileges

Controls the identity context for installation.

```powershell
Privileges = @{
    InstallAsSystem  = $true    # Expects NT AUTHORITY\SYSTEM
    RequireElevation = $true    # Requires administrative privileges
}
```

| InstallAsSystem | RequireElevation | Intune Install Behavior |
|---|---|---|
| `$true` | `$true` | System (most applications) |
| `$false` | `$false` | User (per-user installations) |
| `$false` | `$true` | System, but not SYSTEM identity |

### Installer

Supported types: `EXE`, `MSI`, `MSIX`, `CMD`, `BAT`, `PS1`

```powershell
Installer = @{
    Type             = "EXE"
    File             = "Setup.exe"           # Must be in Files\ directory
    Arguments        = "/quiet /norestart"
    TimeoutSeconds   = 3600
    ProductCode      = $null                 # MSI only
    InstallArguments = $null                 # MSI-specific msiexec arguments
    SHA256           = $null                 # Optional integrity verification
}
```

### Uninstaller

Supported types: `Executable`, `MSI`, `Registry`, `Custom`

```powershell
Uninstaller = @{
    Type           = "Registry"    # Discover uninstall command from Windows registry
    DisplayName    = "My App"      # Registry search key (falls back to Application.Name)
    File           = $null         # Executable type: path to uninstaller
    Arguments      = "/quiet /norestart"
    Command        = $null         # Custom type: command to run
    ProductCode    = $null         # MSI type: product code
    TimeoutSeconds = 3600
}
```

### Detection

Supported types: `File`, `Registry`, `MSI`, `Service`, `Custom`

```powershell
Detection = @{
    Type              = "File"
    Path              = "C:\Program Files\Example"
    FileName          = "Application.exe"
    MinimumVersion    = "1.0.0.0"
    VersionComparison = "GreaterThanOrEqual"
}
```

Version comparison operators: `Equal`, `GreaterThan`, `GreaterThanOrEqual`, `LessThan`, `LessThanOrEqual`

### Requirements

```powershell
Requirements = @{
    MinimumWindowsVersion = "10.0"
    Architecture          = @("x64")         # Array format: @("x64", "ARM64")
    MinimumDiskSpaceGB    = 5
    MinimumRAMGB          = 4
}
```

### Process and Service Management

Flat arrays of names. Processes are gracefully closed then force-stopped after 30 seconds.

```powershell
ProcessesToStop = @("myapp", "myapp-helper")
ServicesToStop  = @("MyAppService")
```

### Environment

Machine-level PATH entries and environment variables. Both are automatically removed on uninstall.

```powershell
Environment = @{
    AddToMachinePath = @(
        "C:\Program Files\Example\bin"
    )
    Variables = @{
        "JAVA_HOME"  = "C:\Program Files\Java\jdk"
        "MAVEN_HOME" = "C:\Program Files\Apache\Maven"
    }
}
```

### File Associations

Mode controls who manages file associations:

| Mode | Behavior |
|---|---|
| `Installer` | The application installer handles associations (framework does nothing) |
| `Framework` | The framework configures associations from the Associations table |
| `None` | Don't modify file associations |

```powershell
FileAssociations = @{
    Mode         = "Framework"
    Associations = @{
        ".txt" = "C:\Program Files\MyEditor\editor.exe"
        ".log" = "C:\Program Files\MyEditor\editor.exe"
    }
}
```

Use `Installer` when the application's own installer sets up associations correctly (e.g., IntelliJ, VS Code). Use `Framework` when the installer doesn't handle associations or you need specific overrides. Framework-managed associations are automatically removed on uninstall.

### Registry Modifications

Registry entries to add or remove after installation. `Add` entries are created during install and reversed during uninstall. `Remove` entries are deleted during install.

```powershell
Registry = @{
    Add = @(
        @{ Path = "HKLM:\Software\MyApp"; Name = "Setting"; Value = "Enabled"; Type = "String" }
        @{ Path = "HKLM:\Software\MyApp"; Name = "MaxRetries"; Value = 3; Type = "DWord" }
    )
    Remove = @(
        @{ Path = "HKLM:\Software\OldApp"; Name = "OldSetting" }
    )
}
```

### Shortcuts

Create or remove shortcuts in StartMenu or Desktop locations.

```powershell
Shortcuts = @{
    Create = @(
        @{ Name = "My Application"; TargetPath = "C:\Program Files\MyApp\app.exe"; Location = "StartMenu" }
        @{ Name = "My Application"; TargetPath = "C:\Program Files\MyApp\app.exe"; Location = "Desktop" }
    )
    Remove = @(
        @{ Name = "Old Application"; Location = "StartMenu" }
    )
}
```

### PostInstall

Validation and custom actions after installation.

```powershell
PostInstall = @{
    Validate = $true
    Actions  = @(
        @{ Type = "RunCommand"; Command = "app.exe"; Arguments = "/configure" }
        @{ Type = "RunPowerShell"; Script = "Set-Content -Path 'C:\config.ini' -Value 'data'" }
        @{ Type = "RestartService"; Service = "MyAppService" }
        @{ Type = "CopyFile"; Source = "config.template"; Destination = "C:\ProgramData\MyApp\config.ini" }
    )
}
```

Supported action types:

| Type | Parameters | Description |
|---|---|---|
| `RunCommand` | Command, Arguments | Execute a command with arguments |
| `RunPowerShell` | Script | Execute a PowerShell script block |
| `RestartService` | Service | Restart a Windows service |
| `CopyFile` | Source, Destination | Copy a file to a destination |

### UserExperience

Controls standard shortcut creation using the detected application executable as the target.

```powershell
UserExperience = @{
    CreateStartMenuShortcut = $true
    CreateDesktopShortcut   = $false
    LaunchAfterInstall      = $false
}
```

### Upgrade / Supersedence

```powershell
Upgrade = @{
    RemovePreviousVersion = $true
    PreviousVersions      = @("1.0", "1.1")
    AllowDowngrade        = $false
}
```

- `RemovePreviousVersion` - When `$true` and an existing version is detected, the installer proceeds (upgrade over existing). When `$false`, the framework reports success without reinstalling.
- `AllowDowngrade` - When `$false`, pre-install validation rejects deploying an older version over a newer one.

### Return Codes

```powershell
ReturnCodes = @{
    Success           = @(0)
    SuccessWithReboot = @(3010, 1641)
}
```

## Configuration Examples

### EXE Installer (e.g., IntelliJ IDEA)

```powershell
@{
    Application = @{
        Name         = "IntelliJ IDEA"
        Version      = "2026.2.1"
        Publisher    = "JetBrains"
        Architecture = "x64"
    }
    CompanyName = "Contoso"

    Installer = @{
        Type             = "EXE"
        File             = "ideaIU-2026.2.1.exe"
        Arguments        = "/S"
        TimeoutSeconds   = 3600
        ProductCode      = $null
        InstallArguments = $null
        SHA256           = $null
    }

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
    }

    Requirements = @{
        MinimumWindowsVersion = "10.0"
        Architecture          = @("x64")
        MinimumDiskSpaceGB    = 5
        MinimumRAMGB          = 8
    }

    Privileges = @{
        InstallAsSystem  = $true
        RequireElevation = $true
    }

    ProcessesToStop = @("idea64")
    ServicesToStop  = @()

    Environment = @{
        AddToMachinePath = @(
            "C:\Program Files\JetBrains\IntelliJ IDEA\bin"
        )
        Variables = @{
            "IDEA_HOME" = "C:\Program Files\JetBrains\IntelliJ IDEA"
        }
    }

    # IntelliJ handles its own file associations during install
    FileAssociations = @{
        Mode         = "Installer"
        Associations = @{}
    }

    Registry  = @{ Add = @(); Remove = @() }
    Shortcuts = @{ Create = @(); Remove = @() }

    PostInstall = @{
        Validate = $true
        Actions  = @()
    }

    UserExperience = @{
        CreateStartMenuShortcut = $true
        CreateDesktopShortcut   = $false
        LaunchAfterInstall      = $false
    }

    Upgrade = @{
        RemovePreviousVersion = $true
        PreviousVersions      = @("2026.1", "2026.2")
        AllowDowngrade        = $false
    }

    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
    }

    Logging = @{
        Enabled           = $true
        RootPath          = $null
        IncludeTranscript = $true
        MaximumLogSizeMB  = 10
        RetainLogFiles    = 10
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
    Application = @{
        Name         = "7-Zip"
        Version      = "23.01"
        Publisher    = "Igor Pavlov"
        Architecture = "x64"
    }
    CompanyName = "Contoso"

    Installer = @{
        Type             = "MSI"
        File             = "7z2301-x64.msi"
        Arguments        = $null
        TimeoutSeconds   = 3600
        ProductCode      = "{23170F69-40C1-2702-2301-000001000000}"
        InstallArguments = "/qn /norestart ALLUSERS=1"
        SHA256           = $null
    }

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
        ProductCode       = "{23170F69-40C1-2702-2301-000001000000}"
    }

    Requirements = @{
        MinimumWindowsVersion = "10.0"
        Architecture          = @("x64")
        MinimumDiskSpaceGB    = 1
        MinimumRAMGB          = 2
    }

    Privileges = @{
        InstallAsSystem  = $true
        RequireElevation = $true
    }

    ProcessesToStop = @("7zFM", "7zG")
    ServicesToStop  = @()

    Environment      = @{ AddToMachinePath = @(); Variables = @{} }
    FileAssociations = @{ Mode = "Installer"; Associations = @{} }
    Registry         = @{ Add = @(); Remove = @() }
    Shortcuts        = @{ Create = @(); Remove = @() }

    PostInstall = @{
        Validate = $true
        Actions  = @()
    }

    UserExperience = @{
        CreateStartMenuShortcut = $false
        CreateDesktopShortcut   = $false
        LaunchAfterInstall      = $false
    }

    Upgrade = @{
        RemovePreviousVersion = $false
        PreviousVersions      = @()
        AllowDowngrade        = $false
    }

    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
    }

    Logging = @{
        Enabled           = $true
        RootPath          = $null
        IncludeTranscript = $false
        MaximumLogSizeMB  = 10
        RetainLogFiles    = 10
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

### Framework-Managed File Associations

When the installer doesn't set up file associations, use Framework mode:

```powershell
FileAssociations = @{
    Mode         = "Framework"
    Associations = @{
        ".txt" = "C:\Program Files\MyEditor\editor.exe"
        ".log" = "C:\Program Files\MyEditor\editor.exe"
        ".cfg" = "C:\Program Files\MyEditor\editor.exe"
    }
}
```

### Multi-Architecture App

```powershell
Requirements = @{
    Architecture = @("x64", "ARM64")
}
```

## Intune Assignments

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

## Logging

All logs are written to:

```
C:\ProgramData\<CompanyName>\IntuneApps\<Application.Name>\
```

Or a custom path via `Logging.RootPath`.

Log files:
- `Install.log` - Installation activity
- `Uninstall.log` - Uninstallation activity
- `DeploymentSummary.log` - Summary of each deployment action
- `*.transcript.log` - Full PowerShell transcript (when enabled)

Log rotation: when a log exceeds `MaximumLogSizeMB`, it is archived with a timestamp and old archives beyond `RetainLogFiles` are pruned.

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|---|---|---|
| Detection fails | Wrong path/version in config | Verify Detection settings; check VersionComparison |
| Install runs but app missing | Silent switch incorrect | Check installer docs for correct silent arguments |
| Exit code 1603 | MSI installation error | Check MSI log and Windows Event Log |
| Exit code 1618 | Another install in progress | Wait; Intune will retry automatically |
| Runs as user, not SYSTEM | Privileges.InstallAsSystem is false | Set Install behavior to **System** in Intune |
| UAC prompt appears | Script tries to elevate | Framework never elevates; ensure Install behavior is System |
| SHA256 mismatch | Installer file corrupted/changed | Regenerate hash or re-download installer |
| Downgrade rejected | AllowDowngrade is false | Set `Upgrade.AllowDowngrade = $true` or deploy newer version |

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

- Never stores credentials, tokens, or secrets in Configuration.psd1
- Never bypasses UAC or modifies security policy
- Never creates administrative accounts
- Executes only files contained in the Intune package
- Optional SHA256 integrity verification of installer files
- Validates SYSTEM context before privileged operations
- All paths resolved relative to the script, never from CWD or user profile
- Remember: an Intune Win32 package is distributed to the endpoint -- anything in the package should be considered accessible to an administrator or sufficiently privileged user
