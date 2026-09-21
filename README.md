# staging-spoon

Intune deployment validation and failure-proofing layer.

A package is not successful because the `.intunewin` was created. It is
successful only when the exact Intune execution path has been proven:

```
Installation succeeds
  AND Detection succeeds
  AND Uninstallation succeeds
  AND Detection becomes false after uninstall
```

Anything less is **NOT PRODUCTION READY**.

## Getting started

You need three things: a source folder, a config file, and one command.

### 1. Build the source folder

This is what becomes the `.intunewin` payload. Copy the templates in and edit
them for your application.

```
source\
  Setup.exe          your vendor installer
  Install.ps1        from templates\ - set $InstallerName and $InstallerArguments
  Uninstall.ps1      from templates\ - set $DisplayName or $ProductCode
  Detection.ps1      from templates\ - set $DisplayName and $ExpectedVersion
```

The templates already resolve payload from `$PSScriptRoot`, preserve vendor
exit codes and implement Intune's detection contract. Editing the variables at
the top of each is usually all that is required.

### 2. Write the config

Copy `examples/package.example.json` to `package.json` and edit it. The install
and uninstall commands you put here are the strings that go into Intune, and
the same strings are what gets tested — they are never generated separately.

### 3. Run the build

```powershell
.\src\Build\Build-IntunePackage.ps1 `
    -SourcePath .\source `
    -ConfigPath .\package.json `
    -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe `
    -SystemContext
```

Run this elevated. `-SystemContext` executes every stage as
`NT AUTHORITY\SYSTEM`, which is how Intune runs a System-context app — working
as Administrator does not prove that.

Validation runs **before** packaging. If the package cannot install, detect,
uninstall and un-detect, no `.intunewin` is produced. The script exits 0 for
production ready, 1 otherwise.

### 4. Enter the values in Intune

Open `build\IntuneConfiguration.md`. It contains the exact values for each
field of the Intune app, and a sanity check confirming they match what was
actually tested. Upload `build\*.intunewin` and copy the values across.

If it says anything other than `PRODUCTION READY`, do not ship it.

## What you get

| File | Contents |
| --- | --- |
| `IntuneConfiguration.md` | The values to enter in Intune, human-readable |
| `IntuneConfiguration.json` | Same values, machine-readable |
| `IntuneValidationReport.html` | Full validation evidence |
| `PackageManifest.json` | Authoritative description of what was packaged |
| `InstallCommand.txt` | Exact string to enter in Intune |
| `UninstallCommand.txt` | Exact string to enter in Intune |
| `DetectionCommand.txt` | Exact detection invocation |
| `PackageHash.txt` | SHA256 of the `.intunewin` |
| `TestResults/ValidationResult.json` | Per-stage results |
| `TestResults/InstallDelta.json` | What actually changed on the machine |
| `TestResults/FailureReport.md` | Written only on failure |

## Test without building

To validate a package you already have, skip the orchestrator:

```powershell
.\src\Testing\Test-IntunePackage.ps1 `
    -SourcePath .\source `
    -ManifestPath .\source\PackageManifest.json `
    -SystemContext
```

The package is copied to a random directory under `%SystemRoot%\Temp` before
execution, so any dependency on its build location fails here rather than on a
device.

## Step-by-step usage

### Phase 1: Prepare your source folder

Copy the templates from `templates/` into a new folder called `source/`:

```
source/
  Setup.exe          ← your vendor installer (rename to match SourceInstaller)
  Install.ps1        ← copy from templates/, edit the variables at the top
  Uninstall.ps1      ← copy from templates/, edit the variables at the top
  Detection.ps1      ← copy from templates/, edit the variables at the top
```

Edit each script to set the application-specific variables:
- **Install.ps1**: Set `$InstallerName` to the name of your vendor installer and `$InstallerArguments` to the flags it needs.
- **Uninstall.ps1**: Set `$DisplayName` or `$ProductCode` to match what the installer registers.
- **Detection.ps1**: Set `$DisplayName` and `$ExpectedVersion` to identify your installed application.

### Phase 2: Write your config

Copy `examples/package.example.json` to `package.json` at the root of your repo and edit it:

```json
{
  "ApplicationName": "Your App",
  "ApplicationVersion": "1.0.0",
  "PackageVersion": "1.0.0",
  "InstallerType": "EXE",
  "SourceInstaller": "Setup.exe",
  "InstallCommand": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \".\\Install.ps1\"",
  "UninstallCommand": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \".\\Uninstall.ps1\"",
  "DetectionMethod": "Script",
  "DetectionScript": "Detection.ps1",
  "InstallBehavior": "System",
  "Architecture": "x64",
  "ExpectedExitCodes": [0, 1641, 3010],
  "RebootBehavior": "BasedOnReturnCode",
  "PostInstallExpectation": {
    "File": ["C:\\Program Files\\YourVendor\\App\\App.exe"],
    "UninstallDisplayName": ["Your App*"],
    "RegistryKey": ["HKLM:\\SOFTWARE\\YourVendor\\App"]
  }
}
```

The **InstallCommand** and **UninstallCommand** you enter here are the exact strings that will be tested and later pasted into Intune. They are not generated — write them once, test them once, use them everywhere.

### Phase 3: Run the build

Run this PowerShell command from the repository root:

```powershell
.\src\Build\Build-IntunePackage.ps1 `
    -SourcePath .\source `
    -ConfigPath .\package.json `
    -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe `
    -SystemContext
```

Requirements:
- **Run elevated** (as Administrator). The `-SystemContext` switch executes every stage as `NT AUTHORITY\SYSTEM`, which is how Intune runs a System-context app. Running as Administrator is not sufficient.
- **IntuneWinAppUtil.exe** must be available. Download it from Microsoft's Intune app packaging toolkit.
- **Windows with PowerShell 5.1 or later** (or PowerShell 7+).

The script will:
1. Validate your package configuration and scripts
2. Run the 10-stage deployment validation
3. Create the `.intunewin` file only if all stages pass
4. Generate configuration and report files in `build/`

Exit code: **0** means PRODUCTION READY, **1** means validation failed.

### Phase 4: Review the output

Check `build/IntuneConfiguration.md`:

```
ApplicationName       : Contoso Reader
ApplicationVersion    : 4.2.1
PackageVersion        : 1.0.0
InstallCommand        : powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"
UninstallCommand      : powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall.ps1"
DetectionScript       : Detection.ps1
InstallBehavior       : System
Restart Behavior      : basedOnReturnCode
PackageHash (SHA256)  : 9F2C1AD4E7B8
Result                : PRODUCTION READY
```

If the result is anything other than **PRODUCTION READY**, do not ship the package. Open `build/FailureReport.md` for details on what failed.

### Phase 5: Enter values in Intune

Copy the exact values from `IntuneConfiguration.md` into your Intune admin console:
- **Install command**: Copy from InstallCommand
- **Uninstall command**: Copy from UninstallCommand
- **Install behavior**: Copy from InstallBehavior
- **Restart behavior**: Copy from Restart Behavior
- **Detection script**: Copy the content of the Detection.ps1 script
- **Run as 32-bit**: Set based on your application's requirements

The `.intunewin` file is in `build/` ready to upload.

### Integrating with CI/CD

Everything the build produces is JSON (`build/IntuneConfiguration.json`, `build/TestResults/ValidationResult.json`), so your CI/CD pipeline can:
1. Write `package.json` from your application inventory
2. Invoke the PowerShell build script
3. Parse the JSON output to report results
4. Upload the `.intunewin` to your package repository

Example: write your config, invoke the build with `subprocess` or shell, then read `build/TestResults/ValidationResult.json` to check `IsProductionReady` (boolean) before proceeding.

## Detection contract

Intune treats a custom detection script as detected only when it **exits 0 and
writes to STDOUT**. Output with a non-zero exit does not count, and neither
does a zero exit with no output. `templates/Detection.ps1` implements this and
never throws, because an unhandled exception reads as "not installed" and
silently triggers a reinstall loop.

## Exit codes

The vendor installer's exit code is preserved, never replaced with 0 because
the PowerShell wrapper finished. Reboot codes (1641, 3010) are preserved by
default; translating them to 0 is an explicit choice, not an accident.

## On failure

A failed deployment produces `FailureReport.md` with a classification
(`PACKAGING_FAILURE`, `SYSTEM_CONTEXT_FAILURE`, `DETECTION_FAILURE`, …) and the
command, context and evidence needed to reproduce it.

Order of work: **reproduce first, fix second, rebuild third.**

## Layout

```
src/Core/          Manifest, path/command validation, state snapshots, failure classification
src/Testing/       Intune simulation engine and SYSTEM-context executor
src/Reporting/     HTML validation report and Intune configuration export
src/Build/         Workflow orchestrator
templates/         Reference Install / Uninstall / Detection scripts
examples/          Example configuration and Python build driver
tests/             Tests for the platform-independent modules
```

## Requirements

- Windows with PowerShell 5.1 or later for deployment validation
- Elevation for `-SystemContext`
- `IntuneWinAppUtil.exe` to produce the `.intunewin`
- Python 3.8+ only if you use the Python driver

The validation modules (path, command, manifest, classification, reporting) are
platform-independent. `pwsh -NoProfile -File ./tests/Run-Tests.ps1` runs them
on Linux for CI.
