# Intune Win32 Packaging Framework

Configuration-driven Microsoft Intune Win32 application packaging. Supports EXE and MSI installers.

## Structure

```
IntuneApp\
├── Install.ps1          # Installation script
├── Uninstall.ps1        # Uninstallation script
├── Detection.ps1        # Detection script (used by Intune)
├── Configuration.psd1   # All app-specific settings
├── Test-Local.ps1       # Local testing helper
└── Files\
    └── <installer>      # Your EXE or MSI
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

## Detection Methods

- **File** — file exists + optional version check
- **Registry** — registry value exists + optional expected value
- **MSI** — ProductCode registered in Windows Installer
- **Custom** — PowerShell scriptblock fallback
