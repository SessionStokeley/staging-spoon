# staging-spoon

Production-quality Microsoft Intune Win32 application deployment package for Oracle JDK.

## Architecture

```
Install.ps1      <- Intune install command entry point
Uninstall.ps1    <- Intune uninstall command entry point
Detect.ps1       <- Intune detection script (self-contained)
Config.ps1       <- Centralized deployment configuration
Helpers.ps1      <- Shared utility functions (logging, PATH management, validation)
```

## Features

- **Dynamic path discovery** -- determines actual JDK installation path via registry and filesystem, no hardcoded versions
- **Safe PATH management** -- uses `[Environment]::SetEnvironmentVariable` (not `setx`), case-insensitive deduplication, trailing-slash normalization
- **Upgrade handling** -- removes obsolete JDK PATH entries matching `VendorPathPattern` before adding the current version
- **Idempotent** -- safe to run repeatedly without creating duplicate PATH entries
- **Comprehensive logging** -- all environment modifications logged to `%ProgramData%\IntuneApps\OracleJDK\deployment.log`
- **Post-install validation** -- verifies JAVA_HOME, PATH, and `java.exe` existence after configuration
- **Clean uninstall** -- removes JAVA_HOME and all managed PATH entries

## Intune Configuration

| Setting | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1` |
| Detection | Custom script: `Detect.ps1` |
| Install behavior | System |
| Return codes | 0 = Success, 1 = Failed, 3010 = Soft reboot |

## Configuration

Edit `Config.ps1` to adjust:
- `MsiFileName` -- name of the JDK MSI file included in the package
- `VendorPathPattern` -- regex matching managed JDK PATH entries for cleanup
- `InstallParentDir` -- expected JDK installation parent directory
- `RegistryPath` -- registry location for JDK version discovery

## Environment Notes

Machine-level environment changes take effect for new processes only. Already-running applications will not see the updated PATH or JAVA_HOME until restarted.
