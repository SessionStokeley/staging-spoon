# staging-spoon

Production-quality Microsoft Intune Win32 application deployment package for Oracle JDK.

## Architecture

```
Install.ps1      <- Intune install command entry point
Uninstall.ps1    <- Intune uninstall command entry point
Detect.ps1       <- Intune detection script (self-contained, product-only)
Config.ps1       <- Centralized deployment configuration
Helpers.ps1      <- Shared utility functions (logging, PATH management, validation)
```

## Features

- **Dynamic path discovery** -- registry query + multi-directory filesystem fallback, no hardcoded versions
- **REG_EXPAND_SZ-safe PATH writes** -- reads/writes PATH via registry API directly, preserving `%SystemRoot%` and other variable references (avoids the `[Environment]::SetEnvironmentVariable` `REG_SZ` corruption bug)
- **WM_SETTINGCHANGE broadcast** -- notifies running processes of environment changes after registry writes
- **GUID-based uninstall** -- queries the uninstall registry for the product GUID rather than relying on the MSI file
- **Product-only detection** -- detection script checks product installation, not environment configuration (prevents Intune retry loops on partial env-var failures)
- **Safe PATH manipulation** -- case-insensitive deduplication, trailing-slash normalization, expanded-form comparison
- **Upgrade handling** -- removes obsolete JDK PATH entries matching `VendorPathPattern` before adding the current version
- **Idempotent** -- safe to run repeatedly without creating duplicate PATH entries
- **Comprehensive logging** -- all environment modifications logged to `%ProgramData%\IntuneApps\OracleJDK\deployment.log`
- **Post-install validation** -- verifies JAVA_HOME, PATH, `java.exe` existence, and `java -version` output

## Intune Configuration

| Setting | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1` |
| Detection | Custom script: `Detect.ps1` |
| Install behavior | System |
| Return codes | 0 = Success, 1 = Failed, 3010 = Soft reboot |

## Packaging

1. Place the JDK MSI installer alongside the scripts (filename must match `Config.ps1 > MsiFileName`)
2. Use [IntuneWinAppUtil](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) to create the `.intunewin` package:
   ```
   IntuneWinAppUtil.exe -c <source-folder> -s Install.ps1 -o <output-folder>
   ```
3. Upload the `.intunewin` file to Intune and configure per the table above

## Configuration

Edit `Config.ps1` to adjust:
- `MsiFileName` -- name of the JDK MSI file included in the package
- `VendorPathPattern` -- regex matching managed JDK PATH entries for cleanup
- `InstallParentDirs` -- expected JDK installation parent directories
- `JdkRegistryPath` -- registry location for JDK version discovery
- `ProductNamePattern` -- DisplayName pattern for product GUID lookup
- `UninstallRegistryPaths` -- registry locations to search for uninstall GUIDs

## Environment Notes

Machine-level environment changes take effect for new processes only. The install script broadcasts `WM_SETTINGCHANGE` to notify running applications, but most will not re-read their environment until restarted.
