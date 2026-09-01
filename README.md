# staging-spoon

Production-quality Microsoft Intune Win32 application deployment package supporting both MSI and EXE installers.

## Architecture

```
Install.ps1        <- Intune install command entry point
Uninstall.ps1      <- Intune uninstall command entry point
Detect.ps1         <- Intune detection script (self-contained, product-only)
Config.ps1         <- Centralized deployment configuration
Helpers.ps1        <- Shared utility functions
Test-Package.ps1   <- Local validation and lifecycle testing
```

## Installer Support

### MSI Configuration

```powershell
InstallerType      = 'MSI'
InstallerFileName  = 'application.msi'
InstallerArguments = '/qn /norestart'
UninstallType      = 'MSI'
```

MSI uninstall uses product GUID from the registry automatically. Falls back to the MSI file if the GUID is not found.

### EXE Configuration

```powershell
InstallerType      = 'EXE'
InstallerFileName  = 'ApplicationSetup.exe'
InstallerArguments = '/S'
UninstallType      = 'EXE'
UninstallFileName  = 'uninstall.exe'
UninstallArguments = '/S'
```

EXE silent-install switches are vendor-specific and must be supplied by the package maintainer. Common examples:

| Vendor Pattern | Silent Arguments |
|---|---|
| NSIS | `/S` |
| Inno Setup | `/VERYSILENT /SUPPRESSMSGBOXES` |
| InstallShield | `/s /v"/qn"` |
| Generic | `/quiet /norestart` or `--silent` |

EXE uninstall uses `QuietUninstallString` from the registry when available. Falls back to `UninstallString` with configured silent arguments, then to the configured `UninstallFileName`.

## Features

- **MSI and EXE support** -- same framework handles both installer types
- **Dynamic path discovery** -- registry query + filesystem fallback, no hardcoded versions
- **REG_EXPAND_SZ-safe PATH writes** -- preserves `%SystemRoot%` and other variable references
- **WM_SETTINGCHANGE broadcast** -- notifies running processes of environment changes
- **GUID-based MSI uninstall** -- queries uninstall registry for product GUID
- **Registry-based EXE uninstall** -- uses QuietUninstallString with safe command parsing
- **Configurable detection** -- Registry, File, or Both detection methods
- **Product-only detection** -- prevents Intune retry loops on env-var failures
- **Safe PATH manipulation** -- case-insensitive deduplication, trailing-slash normalization
- **Upgrade handling** -- removes obsolete PATH entries matching VendorPathPattern
- **Idempotent** -- safe to run repeatedly
- **Comprehensive logging** -- all modifications logged
- **Post-install validation** -- verifies environment configuration
- **Local testing** -- Test-Package.ps1 validates config and runs lifecycle tests

## Intune Configuration

| Setting | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1` |
| Detection | Custom script: `Detect.ps1` |
| Install behavior | System |
| Return codes | 0 = Success, 1 = Failed, 3010 = Soft reboot |

## Packaging

1. Place the installer file alongside the scripts (filename must match `Config.ps1 > InstallerFileName`)
2. Configure `Config.ps1` for your application
3. Run `.\Test-Package.ps1` to validate configuration
4. Use [IntuneWinAppUtil](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool):
   ```
   IntuneWinAppUtil.exe -c <source-folder> -s Install.ps1 -o <output-folder>
   ```
5. Upload the `.intunewin` file to Intune and configure per the table above

## Local Testing

```powershell
# Syntax and configuration validation only
.\Test-Package.ps1

# Full lifecycle: install, detect, validate
.\Test-Package.ps1 -RunInstall

# Full lifecycle including uninstall
.\Test-Package.ps1 -RunInstall -RunUninstall
```

## Configuration Reference

Edit `Config.ps1` to adjust:

| Key | Description |
|---|---|
| `InstallerType` | `MSI` or `EXE` |
| `InstallerFileName` | Installer filename (must match type extension) |
| `InstallerArguments` | Silent install arguments |
| `UninstallType` | `MSI` or `EXE` |
| `UninstallFileName` | EXE uninstall executable (absolute or relative path) |
| `UninstallArguments` | EXE uninstall silent arguments |
| `SuccessExitCodes` | Array of exit codes treated as success |
| `RebootExitCodes` | Subset of success codes that indicate reboot needed |
| `DetectionMethod` | `Registry`, `File`, or `Both` |
| `ProductNamePattern` | Wildcard pattern for registry DisplayName matching |
| `DetectionFilePath` | Explicit file path for file-based detection |
| `ConfigureEnvironment` | `$true` to enable PATH/JAVA_HOME management |
| `VendorPathPattern` | Regex for managed PATH entry cleanup |
| `PathSubdirectory` | Subdirectory under install root to add to PATH |
| `LogDirectory` | Log file location |

## Environment Notes

Machine-level environment changes take effect for new processes only. The install script broadcasts `WM_SETTINGCHANGE` to notify running applications, but most will not re-read their environment until restarted.
