# Intune Win32 Packaging Framework

Configuration-driven Microsoft Intune Win32 application packaging. Supports EXE and MSI installers with optional PATH and environment variable management.

## Structure

```
IntuneApp\
├── Install.ps1              # Installation script
├── Uninstall.ps1            # Uninstallation script
├── Detection.ps1            # Detection script (used by Intune)
├── Configuration.psd1       # All app-specific settings
├── Test-Local.ps1           # Local testing helper
├── Helpers\
│   └── Environment.ps1      # PATH and environment variable helpers
├── Tests\
│   └── Test-Environment.ps1 # Automated tests
└── Files\
    └── <installer>          # Your EXE or MSI
```

## Quick Start

1. Place your installer in `IntuneApp\Files\`
2. Edit `Configuration.psd1` with your application details
3. Validate: `.\Test-Local.ps1 -Mode Validate`
4. Test locally as Administrator: `.\Test-Local.ps1 -Mode Install`
5. Package with `IntuneWinAppUtil.exe -c IntuneApp -s Install.ps1 -o Output`

## Intune Configuration

| Setting | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1` |
| Install behavior | System |
| Detection | Custom script: `Detection.ps1` |

## Configuration.psd1

All application-specific settings live in one file. The scripts are generic.

### Installer

```powershell
Installer = @{
    Type      = "EXE"         # EXE or MSI
    File      = "Setup.exe"   # Filename in Files\ directory
    Arguments = "/quiet /norestart"
}
```

For MSI, the framework runs `msiexec.exe /i <file> <arguments>`.

### Uninstaller

```powershell
# EXE uninstaller (supports absolute paths for registry-discovered uninstallers)
Uninstaller = @{
    Type      = "EXE"
    File      = "C:\Program Files\App\uninstall.exe"
    Arguments = "/quiet /norestart"
}

# MSI uninstaller
Uninstaller = @{
    Type        = "MSI"
    ProductCode = "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
}
```

### Detection Methods

**File** — verify an executable exists with optional version check:
```powershell
Detection = @{
    Type           = "File"
    Path           = "C:\Program Files\Example"
    FileName       = "Example.exe"
    MinimumVersion = "1.0.0.0"   # Optional
}
```

**Registry** — verify a registry value exists:
```powershell
Detection = @{
    Type          = "Registry"
    RegistryPath  = "HKLM:\SOFTWARE\Company\Example"
    ValueName     = "InstalledVersion"
    ExpectedValue = "1.0.0"      # Optional
}
```

**MSI** — verify a ProductCode is registered:
```powershell
Detection = @{
    Type        = "MSI"
    ProductCode = "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
}
```

**Custom** — PowerShell scriptblock fallback:
```powershell
Detection = @{
    Type        = "Custom"
    ScriptBlock = { Test-Path "C:\Program Files\Example\Example.exe" }
}
```

### Exit Codes

```powershell
SuccessExitCodes = @(0, 3010)   # 3010 = success, reboot required
```

## Environment & PATH Management

Enable PATH and environment variable configuration by setting `Environment.Enabled = $true` in Configuration.psd1.

### System PATH

Adds directories to the machine-wide PATH (applies to all users):
```powershell
Environment = @{
    Enabled = $true
    SystemPath = @{
        Enabled           = $true
        Entries           = @(
            "C:\Program Files\Example\bin"
            "C:\Program Files\Example\tools"
        )
        AddIfMissing      = $true
        RemoveOnUninstall = $true
    }
}
```

### User PATH

Adds directories to the current user's PATH:
```powershell
UserPath = @{
    Enabled           = $true
    Entries           = @("C:\Program Files\Example\bin")
    AddIfMissing      = $true
    RemoveOnUninstall = $true
}
```

**Warning:** When Intune runs as SYSTEM, User PATH changes only affect the Default user profile, not existing user accounts. The framework logs this warning during installation.

### Environment Variables

```powershell
Variables = @(
    @{
        Name              = "JAVA_HOME"
        Value             = "C:\Program Files\Java\jdk-21"
        Scope             = "Machine"      # Machine or User
        Expandable        = $false
        RemoveOnUninstall = $true
    }
)
```

### How It Works

- Uses Windows registry APIs with `ExpandString` type (not `setx`) to preserve `%SystemRoot%`, `%ProgramFiles%`, and other expandable variables
- Compares paths case-insensitively with trailing slash normalization to prevent duplicates
- Broadcasts `WM_SETTINGCHANGE` after modification so running applications detect the change
- Tracks which entries were added in `C:\ProgramData\IntunePackagingStudio\State\<AppName>\environment-state.json`
- Uninstall only removes entries the package added; pre-existing entries are never touched
- All operations are idempotent

### Install Workflow

```
Install Application
    -> Verify Installation (Detection)
    -> Configure System PATH
    -> Configure User PATH
    -> Set Environment Variables
    -> Broadcast Environment Change
    -> Validate PATH Registration
    -> Complete
```

PATH failures log a warning but do not fail the install. The application itself is the primary success criterion.

### Uninstall Workflow

```
Clean Up PATH Entries (package-owned only)
    -> Clean Up Environment Variables
    -> Broadcast Environment Change
    -> Run Uninstaller
    -> Verify Removal (Detection)
    -> Remove State Tracking File
    -> Complete
```

## Local Testing

Test-Local.ps1 supports these modes:

| Mode | Description |
|---|---|
| `Validate` | Check package structure, config, and script syntax |
| `Install` | Run Install.ps1 |
| `Uninstall` | Run Uninstall.ps1 |
| `Detection` | Run Detection.ps1 |
| `Environment` | Validate PATH entries, env vars, duplicates, and state tracking |
| `DetectPaths` | Scan install directory for CLI executable candidates |
| `TestCommand` | Resolve and run a command through PATH |

### Examples

```powershell
# Validate package before building
.\Test-Local.ps1 -Mode Validate

# Install and test
.\Test-Local.ps1 -Mode Install
.\Test-Local.ps1 -Mode Detection

# Discover CLI directories after installation
.\Test-Local.ps1 -Mode DetectPaths -InstallPath "C:\Program Files\Example"

# Verify PATH was configured
.\Test-Local.ps1 -Mode Environment

# Test command resolution
.\Test-Local.ps1 -Mode TestCommand -Command "example-cli --version"

# Uninstall and verify cleanup
.\Test-Local.ps1 -Mode Uninstall
.\Test-Local.ps1 -Mode Detection
```

Test-Local.ps1 sets `$env:INTUNE_LOCAL_TEST` to suppress SYSTEM account warnings during local testing. Production Intune deployments run as SYSTEM.

## Automated Tests

```powershell
# Run from IntuneApp directory
powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Environment.ps1
```

Tests cover path normalization, case-insensitive comparison, duplicate detection, state tracking, CLI discovery, expandable variable preservation, idempotency, and backward compatibility. PATH modification tests require Administrator elevation and skip gracefully otherwise.

## Packaging

```powershell
IntuneWinAppUtil.exe -c C:\Build\IntuneApp -s Install.ps1 -o C:\Build\Output
```

Upload the resulting `.intunewin` file to Intune.

## Backward Compatibility

Existing configurations without an `Environment` section continue to work unchanged. The feature is disabled by default (`Environment.Enabled = $false`).
