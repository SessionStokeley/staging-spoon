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

## Layout

```
src/Core/          Manifest, path/command validation, state snapshots, failure classification
src/Testing/       Intune simulation engine and SYSTEM-context executor
src/Reporting/     HTML validation report and Intune configuration export
src/Build/         Workflow orchestrator
templates/         Reference Install / Uninstall / Detection scripts
examples/          Example package configuration
```

## Build a package

```powershell
.\src\Build\Build-IntunePackage.ps1 `
    -SourcePath .\source `
    -ConfigPath .\package.json `
    -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe `
    -SystemContext
```

Validation runs **before** packaging. If the package cannot install, detect,
uninstall and un-detect, no `.intunewin` is produced.

Phases: clean build → manifest → exact commands → pre-build validation →
deployment validation → create `.intunewin` → verify + hash → Intune
configuration → report → final validation.

## Test an existing package

```powershell
.\src\Testing\Test-IntunePackage.ps1 `
    -SourcePath .\source `
    -ManifestPath .\source\PackageManifest.json `
    -SystemContext
```

The package is copied to a random directory under `%SystemRoot%\Temp` before
execution, so any dependency on its build location fails here rather than on a
device. `-SystemContext` runs every stage as `NT AUTHORITY\SYSTEM` via a
scheduled task: no interactive desktop, no user profile, no mapped drives.

## Build output

| File | Contents |
| --- | --- |
| `PackageManifest.json` | Authoritative description of what was packaged |
| `InstallCommand.txt` | Exact string to enter in Intune |
| `UninstallCommand.txt` | Exact string to enter in Intune |
| `DetectionCommand.txt` | Exact detection invocation |
| `IntuneConfiguration.json` / `.md` | Machine- and human-readable Intune settings |
| `IntuneValidationReport.html` | Full validation evidence |
| `PackageHash.txt` | SHA256 of the `.intunewin` |
| `TestResults/InstallDelta.json` | What actually changed on the machine |
| `TestResults/FailureReport.md` | Written only on failure |

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

## Requirements

- Windows with PowerShell 5.1 or later for deployment validation
- Elevation for `-SystemContext`
- `IntuneWinAppUtil.exe` to produce the `.intunewin`

The validation modules (path, command, manifest, classification, reporting)
are platform-independent and run under PowerShell 7 on Linux for CI.
