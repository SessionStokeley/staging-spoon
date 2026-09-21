# Package Builder Test Troubleshooting

## Silent Installation Fails (Exit Code ≠ 0)

Check:
- `InstallArguments` match your installer's real silent switches
- `InstallerFile` name matches the file in the package
- The installer actually supports silent mode

## Application Detection Fails After Install

The installer ran but didn't create what Detection.ps1 expects.

**For File detection:**
```powershell
Detection = @{
    Type = 'File'
    Path = 'C:\Program Files\YourApp\YourApp.exe'  # Must exist after install
}
```
Verify: Does the installer actually create this file?

**Simpler: Folder detection**
```powershell
Detection = @{
    Type = 'Folder'  
    Path = 'C:\Program Files\YourApp'  # Must exist after install
}
```

**Easiest for testing: Use a marker file**
Update your installer to create a marker:
```batch
REM In your installer batch/script
mkdir C:\temp\app-installed-marker
```

Then:
```powershell
Detection = @{
    Type = 'Folder'
    Path = 'C:\temp\app-installed-marker'
}
```

## Uninstall Fails

If detection still shows "Installed" after Uninstall.ps1 runs, check:
- `UninstallArguments` are correct for your installer
- For MSI: `ProductCode` is correct
- The installer actually supports silent uninstall
- Uninstall log for actual errors

## How to Debug

1. Run the test with detailed output:
   ```powershell
   New-IntunePackage.ps1 -Mode Test -Path C:\Packages\YourApp
   ```

2. Check the log files it creates:
   - `PackageSource\.testresult.json` — test result and failure reason
   - `LastTest-Install.log` — Install.ps1 output and logs
   - `LastTest-Uninstall.log` — Uninstall.ps1 output and logs

3. For C:\ProgramData\IntunePackageBuilder\Logs\ — full package logs

## Test with a Known-Good Installer

If your vendor installer is complex, test with a simple proof-of-concept:
```batch
@echo off
mkdir C:\temp\test-marker
exit /b 0
```

Configure detection to find that folder. If the test passes, your configuration is sound; if not, there's an issue with the detection parsing.
