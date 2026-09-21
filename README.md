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

**Step 1a: Get your vendor installer**

Copy your application's installer into the `source/` folder. Name it to match what you'll set in `package.json` as `SourceInstaller`. Common names:
- `Setup.exe` - standard Windows installer
- `ApplicationName.msi` - MSI installer
- `ApplicationName-installer.exe` - vendor-specific name

Make sure:
- The installer runs silently with the flags you plan to use
- The installer is for the architecture you're targeting (x86 or x64)
- The installer is complete and not a stub downloader

**Step 1b: Copy and edit Install.ps1**

Copy `templates/Install.ps1` to `source/Install.ps1` and edit these variables at the top:

```powershell
$InstallerName = 'Setup.exe'                    # Match your installer filename
$InstallerArguments = @('/S', '/norestart')     # Silent install flags for your installer
```

Common installer arguments:
- MSI: `/qn /norestart` (quiet, no restart prompt)
- Inno Setup: `/S /NORESTART`
- NSIS: `/S /NORESTART`
- Nullsoft: `/S`
- Custom EXE: Check vendor documentation

The template already handles:
- Resolving the installer from the same folder as the script
- Waiting for child processes (msiexec, setup.exe, etc.)
- Preserving the vendor's exit code
- Logging to `%ProgramData%\IntuneDeployment\Logs`

**Step 1c: Copy and edit Uninstall.ps1**

Copy `templates/Uninstall.ps1` to `source/Uninstall.ps1` and edit one of these at the top:

```powershell
# Option 1: Uninstall by display name (registry-based)
$DisplayName = 'MyApplication*'                 # Wildcard pattern to match Add/Remove Programs

# Option 2: Uninstall by product code (MSI-based)
$ProductCode = '{12345678-1234-1234-1234-123456789012}'  # GUID from MSI
```

The template handles:
- Looking in both 32-bit and 64-bit registry hives
- Finding the uninstall command (either MsiExec or UninstallString)
- Running the uninstall silently
- Preserving the exit code

To find your uninstall details:
- Open `regedit`, go to `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
- Look for your application name in the `DisplayName` column
- Copy the exact `DisplayName` or find the `ProductCode` (GUID)

**Step 1d: Copy and edit Detection.ps1**

Copy `templates/Detection.ps1` to `source/Detection.ps1` and edit these variables:

```powershell
$DisplayName = 'MyApplication'                  # Application name to search for in registry
$ExpectedVersion = '4.2.1'                      # Exact version or version pattern
```

The template handles:
- Querying the registry for installed applications
- Comparing versions
- Writing output to STDOUT (required by Intune)
- Never throwing exceptions (unhandled exceptions trigger reinstall loops)
- Exit code 0 = installed, non-zero = not installed

**Pre-flight check for Phase 1:**

Before moving to Phase 2, verify:
- [ ] `source/Setup.exe` (or your installer name) exists and is readable
- [ ] `source/Install.ps1` has `$InstallerName` and `$InstallerArguments` set
- [ ] `source/Uninstall.ps1` has either `$DisplayName` or `$ProductCode` set
- [ ] `source/Detection.ps1` has `$DisplayName` and `$ExpectedVersion` set
- [ ] You can run `.\source\Install.ps1` manually and it installs (optional, but recommended)

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
  "MinimumOS": "W10_1809",
  "ExpectedExitCodes": [0, 1641, 3010],
  "RebootBehavior": "BasedOnReturnCode",
  "PostInstallExpectation": {
    "File": ["C:\\Program Files\\YourVendor\\App\\App.exe"],
    "UninstallDisplayName": ["Your App*"],
    "RegistryKey": ["HKLM:\\SOFTWARE\\YourVendor\\App"]
  }
}
```

**Field-by-field explanation:**

| Field | Purpose | Example |
|-------|---------|---------|
| `ApplicationName` | Display name in Intune | `"Contoso Reader"` |
| `ApplicationVersion` | Version of the app being packaged | `"4.2.1"` — must match `Detection.ps1` `$ExpectedVersion` |
| `PackageVersion` | Version of this package (increment on rebuild) | `"1.0.0"`, then `"1.0.1"` if you rebuild it |
| `InstallerType` | Type of installer | `"EXE"` or `"MSI"` |
| `SourceInstaller` | Filename of the vendor installer in `source/` | `"Setup.exe"` — must match filename |
| `InstallCommand` | **Exact command Intune will run** | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\\Install.ps1"` — do not change this |
| `UninstallCommand` | **Exact command Intune will run** | Same pattern as install |
| `DetectionMethod` | Type of detection | `"Script"` (only option currently) |
| `DetectionScript` | Detection script filename | `"Detection.ps1"` — must be in `source/` |
| `InstallBehavior` | How Intune treats the installation | `"System"` (runs as SYSTEM) or `"User"` (runs as logged-in user) |
| `Architecture` | Target architecture | `"x64"` or `"x86"` |
| `MinimumOS` | Minimum Windows version | `"W10_1809"` (Windows 10 1809+) — optional |
| `ExpectedExitCodes` | Exit codes that mean success | `[0, 1641, 3010]` — 1641 and 3010 are reboot codes |
| `RebootBehavior` | How Intune handles reboot codes | `"BasedOnReturnCode"` (respects 1641/3010) or `"NoAction"` (treat all codes as success) |
| `PostInstallExpectation` | Files/registry to verify installation | Paths that should exist after install succeeds |

**Critical rule:** The `InstallCommand` and `UninstallCommand` are the exact strings that Intune will execute. Write them once, test them here, and paste them into Intune unchanged. Do not generate them or change them later.

**PostInstallExpectation fields:**
- `File`: List of absolute paths that should exist after installation
- `UninstallDisplayName`: Patterns that match entries in Add/Remove Programs (use `*` wildcards)
- `RegistryKey`: Registry keys that should be created by the installer

Example:
```json
"PostInstallExpectation": {
  "File": [
    "C:\\Program Files\\Contoso\\Reader\\Reader.exe",
    "C:\\Program Files\\Contoso\\Reader\\config.xml"
  ],
  "UninstallDisplayName": ["Contoso Reader*"],
  "RegistryKey": ["HKLM:\\SOFTWARE\\Contoso\\Reader"]
}
```

**Pre-flight check for Phase 2:**

Before moving to Phase 3, verify:
- [ ] `package.json` exists in the repository root (same level as README.md)
- [ ] `ApplicationVersion` matches `$ExpectedVersion` in `source/Detection.ps1`
- [ ] `SourceInstaller` matches the actual filename in `source/`
- [ ] `InstallCommand` and `UninstallCommand` use the PowerShell wrapper pattern
- [ ] `PostInstallExpectation` lists actual files/registry entries your app creates
- [ ] `ExpectedExitCodes` includes all codes your installer might return

**Optional: Use the evaluator**

Run this to validate your package.json before building:

```powershell
.\src\Build\Evaluate-Package.ps1 -ConfigPath .\package.json -SourcePath .\source
```

This checks:
- All required fields are present
- Files and registry keys in PostInstallExpectation are absolute paths
- Source files referenced in config exist
- Commands are properly formatted

### Phase 3: Run the build

**Step 3a: Check prerequisites**

Before building, verify you have everything:

```powershell
# 1. Check that you're on Windows
$IsWindows  # Should return $true

# 2. Check PowerShell version (5.1+)
$PSVersionTable.PSVersion  # Should be 5.1 or higher

# 3. Check that you're elevated (Administrator)
[Security.Principal.WindowsIdentity]::GetCurrent().Groups -contains 'S-1-5-32-544'  # Should return $true

# 4. Check that IntuneWinAppUtil.exe exists
Test-Path .\tools\IntuneWinAppUtil.exe  # Should return $true

# 5. Check that your source folder exists
Test-Path .\source\  # Should return $true
Test-Path .\package.json  # Should return $true
```

**Step 3b: Run the build**

From the repository root, run:

```powershell
.\src\Build\Build-IntunePackage.ps1 `
    -SourcePath .\source `
    -ConfigPath .\package.json `
    -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe `
    -SystemContext
```

**Important:** Run this in an **elevated PowerShell window** (right-click → "Run as Administrator"). The `-SystemContext` flag is mandatory — it executes the validation as `NT AUTHORITY\SYSTEM`, which is how Intune actually runs the package. Running as a regular Administrator user does not prove the package will work in production.

**What happens during the build:**

1. **Pre-build validation** (30 seconds)
   - Checks configuration format
   - Validates paths in PostInstallExpectation
   - Verifies source files exist
   - Flags absolute paths, UNC references, working-directory assumptions
   - Checks for interactive install flags

2. **Install stage** (typically 1-5 minutes)
   - Stages your package to a random temp directory
   - Runs as SYSTEM via scheduled task
   - Executes the install command
   - Captures exit code and output
   - Takes a snapshot of system state (files, registry, services)

3. **Detection after install** (10 seconds)
   - Runs your detection script as SYSTEM
   - Verifies it exits 0 and writes to STDOUT
   - Confirms installation was detected

4. **Uninstall stage** (1-5 minutes)
   - Runs the uninstall command as SYSTEM
   - Captures exit code and output

5. **Detection after uninstall** (10 seconds)
   - Runs detection script again
   - Verifies it does NOT exit 0 (not installed)

6. **Package creation** (15 seconds)
   - Creates the `.intunewin` file only if all 5 stages passed
   - Computes SHA256 hash

7. **Report generation** (10 seconds)
   - Creates HTML validation report
   - Exports Intune configuration
   - Writes command strings to text files

**Exit code:** 
- **0** = PRODUCTION READY (all stages passed, `.intunewin` created)
- **1** = Validation failed (no `.intunewin` created, check `build/FailureReport.md`)

**Common issues and fixes:**

| Problem | Cause | Fix |
|---------|-------|-----|
| "not running elevated" | Forgot to run as Administrator | Right-click PowerShell → "Run as Administrator" |
| "IntuneWinAppUtil.exe not found" | Missing tools folder | Download from Microsoft's Intune toolkit |
| "Access denied" | Missing permissions or scheduled task issues | Run as local Administrator; ensure local admin group membership |
| Install fails with exit code 1603 | Generic installer error | Check `build/FailureReport.md` for installer output |
| Install succeeds but detection fails | Detection script problem | Test `.\source\Detection.ps1` manually; check `$DisplayName` and `$ExpectedVersion` |
| Uninstall fails | Uninstall command not found | Verify `$DisplayName` or `$ProductCode` in `source/Uninstall.ps1` |

**Optional: Dry-run without SYSTEM context**

To test without the complexity of SYSTEM context execution:

```powershell
.\src\Build\Build-IntunePackage.ps1 `
    -SourcePath .\source `
    -ConfigPath .\package.json `
    -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe
    # (omit -SystemContext)
```

This runs the build as the current user. Still requires elevation, but faster to iterate. Once everything passes, add `-SystemContext` for the production build.

### Phase 4: Review the output

After the build completes, check these files in the `build/` folder:

**build/IntuneConfiguration.md** (Human-readable summary)

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

Copy the values under "Result" section directly into Intune.

**Build output files:**

| File | Purpose |
|------|---------|
| `IntuneConfiguration.json` | Machine-readable config (for CI/CD pipelines) |
| `IntuneValidationReport.html` | Full HTML report with all stage details (open in browser) |
| `PackageManifest.json` | Authoritative description of what was packaged |
| `InstallCommand.txt` | Exact install string (copy to Intune) |
| `UninstallCommand.txt` | Exact uninstall string (copy to Intune) |
| `DetectionCommand.txt` | Detection invocation for reference |
| `PackageHash.txt` | SHA256 hash of the .intunewin file |
| `*.intunewin` | The packaged application (ready to upload to Intune) |

**TestResults/ folder:**

| File | Purpose |
|------|---------|
| `ValidationResult.json` | Per-stage pass/fail results and execution context |
| `InstallDelta.json` | What changed on the system after installation (files, registry, services) |
| `FailureReport.md` | Detailed failure report (only created if validation failed) |

**Interpreting the validation result:**

Open `build/TestResults/ValidationResult.json` and check the `"IsProductionReady"` field:

```json
{
  "ApplicationName": "Contoso Reader",
  "ExecutionContext": "NT AUTHORITY\SYSTEM",
  "IsProductionReady": true,
  "Stages": [
    { "Name": "Install", "Result": "PASS", "ExitCode": 0 },
    { "Name": "Detection after install", "Result": "PASS", "ExitCode": 0 },
    { "Name": "Uninstall", "Result": "PASS", "ExitCode": 0 },
    { "Name": "Detection after uninstall", "Result": "PASS", "ExitCode": 0 }
  ]
}
```

**If IsProductionReady is false:**

All four stages must pass for production readiness. Check which stage failed:

- **Install failed**: Check `build/FailureReport.md` for the installer error. Common causes:
  - Installer exit code not in `ExpectedExitCodes`
  - Installer output indicates it cannot run silently
  - File permissions or path issues
  - Unmet dependencies (runtime libraries, Windows components)

- **Detection after install failed**: 
  - Your detection script isn't finding the installed application
  - Check `$DisplayName` in `source/Detection.ps1` — must exactly match registry entry
  - Run detection manually: `.\source\Detection.ps1` (should output a version string)
  - Check `build/TestResults/InstallDelta.json` to see what was actually installed

- **Uninstall failed**:
  - The uninstall command didn't work
  - Check `$DisplayName` or `$ProductCode` in `source/Uninstall.ps1`
  - Verify the application appears in Add/Remove Programs
  - Run uninstall manually to test

- **Detection after uninstall failed**:
  - Your detection script still reports installed after uninstalling
  - Check if uninstall actually removed all files/registry entries
  - Detection script might be too permissive (checking for a folder that's recreated)

**Open the HTML report:**

Open `build/IntuneValidationReport.html` in a browser for a visual overview:
- Timestamps and duration of each stage
- Exact command executed
- Full output from each stage (for debugging)
- Environment details (Windows version, PowerShell version, execution context)
- Installation delta (files added, registry keys created)
- Failure classification (if applicable)

**The InstallDelta is your evidence:**

`build/TestResults/InstallDelta.json` shows exactly what changed:

```json
{
  "Applications": [
    { "Name": "Contoso Reader", "Version": "4.2.1", "InstallDate": "2025-09-21" }
  ],
  "Files": {
    "Added": ["C:\\Program Files\\Contoso\\Reader\\Reader.exe"],
    "Deleted": [],
    "Modified": []
  },
  "Registry": {
    "Added": ["HKLM\\SOFTWARE\\Contoso\\Reader"],
    "Deleted": [],
    "Modified": []
  }
}
```

This proves that your installation actually changed the system state, matching what you declared in `PostInstallExpectation`.

### Phase 5: Enter values in Intune

**Step 5a: Upload the package**

1. Log in to Microsoft Intune admin center (https://intune.microsoft.com)
2. Go to **Apps** → **All apps** → **+ Add**
3. Select **Windows app (Win32)**
4. Click **Select app package file**
5. Upload `build/*.intunewin` file

**Step 5b: Fill in application information**

| Intune field | Value from IntuneConfiguration.md |
|---|---|
| **Name** | ApplicationName |
| **Description** | (optional) |
| **Publisher** | (your organization) |
| **App version** | ApplicationVersion |

**Step 5c: Enter installation commands**

1. **Install command**: Copy the exact text from `build/InstallCommand.txt`
   - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"`

2. **Uninstall command**: Copy the exact text from `build/UninstallCommand.txt`
   - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall.ps1"`

3. **Install behavior**:
   - Select from IntuneConfiguration.md (usually "System")
   - This was tested as SYSTEM context in the build

4. **Restart behavior**:
   - Select from IntuneConfiguration.md (usually "Based on return code")
   - Respects reboot codes 1641 and 3010 if selected

**Step 5d: Configure detection rules**

1. **Detection method**: Script
2. **Run script as 32-bit process**: Set based on your app (usually "No" for x64)
3. **Run with administrative credentials**: Yes (required)
4. **Script content**: Copy-paste the content of `source/Detection.ps1`
   - Open `source/Detection.ps1` in a text editor
   - Copy all the text
   - Paste into the "Script content" field

**Step 5e: Scope and assignments**

1. **Scope tags** (optional): Add your organization's tags
2. **Assignments**: 
   - Click **Add group**
   - Select device groups to receive this app
   - Set deployment intent (e.g., "Available" for optional, "Required" for mandatory)

**Step 5f: Review and create**

1. Review all settings
2. Verify the commands match exactly what's in `build/IntuneConfiguration.md`
3. Click **Create**

**Sanity check before deploying to production:**

Open `build/IntuneConfiguration.md` one more time and verify:

```
Result: PRODUCTION READY
```

If it says anything else, **DO NOT** proceed to step 5e (assignments). Go back to Phase 4 and fix the issues.

**Step 5g: Monitor deployment**

Once assigned:
1. Go to **Devices** → **Device compliance** (or **Manage devices**)
2. Select a test device
3. Check **Intune compliance** or **App status**
4. Wait for the app to show as "Installed" or review failure logs if it fails
5. Verify by connecting to the device and checking Add/Remove Programs

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

## Pre-build checklist and validator

Before running the full build, use the evaluator to catch configuration errors early:

```powershell
.\src\Build\Evaluate-Package.ps1 -ConfigPath .\package.json -SourcePath .\source
```

This checks:
- All required fields are present in `package.json`
- Version numbers are in semantic format
- All source files (installer, scripts) exist and are readable
- File paths in PostInstallExpectation are absolute
- Registry paths start with HKLM:\ or HKCU:\
- Commands reference the correct scripts
- Exit codes and behaviors are valid

Fix any errors reported before proceeding to Phase 3.

## Layout

```
src/Core/          Manifest, path/command validation, state snapshots, failure classification
src/Testing/       Intune simulation engine and SYSTEM-context executor
src/Reporting/     HTML validation report and Intune configuration export
src/Build/         Workflow orchestrator and pre-build evaluator
templates/         Reference Install / Uninstall / Detection scripts
examples/          Example configuration file
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
