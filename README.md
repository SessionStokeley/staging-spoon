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

## Driving the build from Python

Everything the build produces is JSON, so a pipeline can write the config, run
the build and act on the result. This is the usual approach when packaging many
applications from one source of truth, or when the build runs in CI.

```python
#!/usr/bin/env python3
"""Build an Intune package and report the result."""

import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent
BUILD = REPO / "build"

CONFIG = {
    "ApplicationName": "Contoso Reader",
    "ApplicationVersion": "4.2.1",
    "PackageVersion": "1.0.0",
    "InstallerType": "EXE",
    "SourceInstaller": "Setup.exe",
    "InstallCommand": 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\\Install.ps1"',
    "UninstallCommand": 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\\Uninstall.ps1"',
    "DetectionMethod": "Script",
    "DetectionScript": "Detection.ps1",
    "InstallBehavior": "System",
    "Architecture": "x64",
    "ExpectedExitCodes": [0, 1641, 3010],
    "RebootBehavior": "BasedOnReturnCode",
}


def read_json(path):
    # PowerShell writes a BOM, so decode with utf-8-sig.
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8-sig"))


def build(source, config):
    powershell = shutil.which("pwsh") or shutil.which("powershell")
    if powershell is None:
        sys.exit("PowerShell not found.")

    config_path = REPO / "package.json"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    completed = subprocess.run([
        powershell, "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(REPO / "src" / "Build" / "Build-IntunePackage.ps1"),
        "-SourcePath", str(source),
        "-ConfigPath", str(config_path),
        "-OutputPath", str(BUILD),
        "-SystemContext",
    ], cwd=REPO)

    return (
        completed.returncode,
        read_json(BUILD / "TestResults" / "ValidationResult.json"),
        read_json(BUILD / "IntuneConfiguration.json"),
    )


exit_code, validation, intune = build(REPO / "source", CONFIG)

if validation:
    for stage in validation["Stages"]:
        print(f"  {stage['Result']:<10} {stage['Name']}")

if exit_code == 0 and intune:
    program = intune["ProgramInformation"]
    print("\nPRODUCTION READY - enter these values in Intune:")
    print(f"  Install command   : {program['InstallCommand']}")
    print(f"  Uninstall command : {program['UninstallCommand']}")
    print(f"  Install behavior  : {program['InstallBehavior']}")
    print(f"  Restart behavior  : {program['DeviceRestartBehavior']}")
    print(f"  SHA256            : {intune['Package']['PackageHash']}")
else:
    print("\nNOT PRODUCTION READY")
    if validation and validation.get("Classification"):
        print(f"  {validation['Classification']['Classification']}")
        print(f"  {validation['Classification']['Reason']}")

sys.exit(exit_code)
```

Output on success:

```
  PASS       Install
  PASS       Detection after install
  PASS       Uninstall
  PASS       Detection after uninstall

PRODUCTION READY - enter these values in Intune:
  Install command   : powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"
  Uninstall command : powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall.ps1"
  Install behavior  : System
  Restart behavior  : basedOnReturnCode
  SHA256            : 9F2C1AD4E7B8
```

A fuller version, including failure-report handling, is in
`examples/build_package.py`.

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
