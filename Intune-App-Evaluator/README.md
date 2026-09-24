# Intune Application Evaluator

A side project whose only job is to **inspect an installed Windows application**
and produce the information needed to build an Intune Win32 package. It
investigates; [staging-spoon](../README.md) packages. The only coupling is the
`package.json` this tool exports, which staging-spoon's
`Build-IntunePackage.ps1` reads unchanged.

It evaluates the **actual installed application** — the Add/Remove Programs
registration, the files on disk, the live PATH, the shortcuts, the registry —
not just the installer file.

## What it produces

- A `package.json` ready for staging-spoon.
- A human-readable evaluation report, grouped and colour-coded by status.
- An `evaluation.json` with **evidence for every value**: its source, a
  confidence, and whether it was verified against the live system.

Nothing inferred is ever presented as verified. Values that still need a
person — a silent switch guessed from the installer toolkit, a per-user
install's SYSTEM behaviour — are marked *requires confirmation* and block
export unless you pass `-Force` or correct them.

## Usage

```powershell
# Review only
.\Invoke-AppEvaluation.ps1 -Name 'IntelliJ IDEA*'

# Review with the evidence for each value
.\Invoke-AppEvaluation.ps1 -Name 'IntelliJ IDEA*' -ShowEvidence

# Also point at the installer so it can report the installer type and a
# suggested silent switch (still flagged for confirmation)
.\Invoke-AppEvaluation.ps1 -Name 'IntelliJ IDEA*' -InstallerPath .\ideaIU-2024.1.exe

# Export package.json (blocked while anything needs confirmation)
.\Invoke-AppEvaluation.ps1 -Name 'IntelliJ IDEA*' -Export -OutputPath .\out
```

Run it on the machine where the application is installed. The report prints a
status per value:

```
[+] detected (observed on the system)   [*] confirmed (you set it)
[~] inferred (from metadata/heuristic)   [?] requires confirmation
```

## The workflow

```
Intune-App-Evaluator
        |  evaluate the installed application
        v
   Review / Correct           (edit anything before exporting)
        |  export
        v
   package.json  ---------->  staging-spoon
                              Build-IntunePackage.ps1
```

## What it discovers

- **Application** — display name, publisher, version, architecture, install
  location, main executable, uninstaller, uninstall command, MSI product code.
- **Install behaviour** — installer type, silent arguments (from the installer
  when supplied), whether it appears to require elevation, whether it looks
  SYSTEM-compatible.
- **PATH** — whether the application is already on the machine or user PATH,
  which directory, and — when it is not — the recommended entry, marked as
  needing confirmation that it is actually required.
- **Integrations** — desktop and Start-Menu shortcuts, context-menu
  registrations, and file associations whose target is the application, each
  attributed by directory/executable rather than by name alone, so an unrelated
  handler is never captured.

Observed integrations are exported as `VALIDATE` (the vendor installer creates
them; staging-spoon should verify, not duplicate). Change any to `MANAGE` in
review to have staging-spoon create and own it instead.

## Capture (before/after)

Better evidence than reading an installer: snapshot the machine, install,
snapshot again, diff, and keep the changes that belong to the application.

```
1. New-SystemStateSnapshot        (before)
2. install the application
3. New-SystemStateSnapshot        (after)
4. Compare-SystemStateSnapshot    (what appeared)
5. Select-ApplicationChanges      (what appeared and is the app's)
```

## Layout

```
src/EvidenceModel.ps1     Fields with source / confidence / verified / status
src/SystemInspector.ps1   Pure selectors + live registry/PATH/COM readers
src/Capture.ps1           Before/after snapshot, diff, attribution
src/Evaluator.ps1         Orchestration into an evidenced result
src/PackageExport.ps1     Export to staging-spoon package.json + report
Invoke-AppEvaluation.ps1  Entry point
tests/                    Unit tests + a staging-spoon interop check
examples/                 A worked IntelliJ export
```

## Design

The selection, attribution, evidence and export logic is kept separate from the
operating-system reads — the uninstall registry, the machine PATH, `.lnk` files
through COM — so the test suite can drive the orchestration with injected
fixtures and assert the logic directly, while the live-inspection test reads the
real machine.

This tool has no dependency on staging-spoon; the interop test dot-sources
staging-spoon's validators only to prove the exported `package.json` is accepted
by them.
