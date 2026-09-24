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

> **Using the tool?** See [INSTRUCTION.md](INSTRUCTION.md) — the operating guide
> for administrators. This file covers the project itself: architecture,
> configuration model, testing and development.

## Purpose

Win32 packaging fails in production for reasons that never appear on the
packager's desk: the app runs as SYSTEM rather than as a user, from a random
temp directory rather than the build folder, with no desktop, no user profile
and no mapped drives. This project makes those conditions the default during
validation, and refuses to mark a package production ready until it has
survived them.

Two things follow from that:

1. **The tested command and the production command are the same string.**
   Commands are generated once from a structured model and never re-derived, so
   there is no opportunity for the validated command and the one entered in
   Intune to diverge. A drift check enforces it.
2. **Evidence, not assertion.** Every stage records its exact command, exit
   code, output and the machine state it changed. A pass is a claim backed by
   an artifact.

## Architecture

Two layers, independently usable.

```
                    Information intelligence layer
                    (what do we know, what must we ask)
                                  |
                        package.json / manifest
                                  |
                       Validation pipeline
                (prove it, then and only then package it)
```

### Validation pipeline

`src/Build/Build-IntunePackage.ps1` orchestrates ten phases and exits non-zero
if any gate fails:

| Phase | Gate |
| --- | --- |
| `CLEAN BUILD` | Output directory is reset, so no stale artifact can be shipped |
| `MANIFEST` | Config is converted to a manifest and schema-validated |
| `EXACT COMMANDS` | Install/uninstall/detection strings written to disk as the single source |
| `PRE-BUILD VALIDATION` | Static checks; blocks packaging on failure |
| `DEPLOYMENT VALIDATION` | The real install/detect/uninstall/un-detect cycle |
| `CREATE .INTUNEWIN` | Only reached if validation passed |
| `VERIFY PACKAGE` | Package exists; SHA256 computed |
| `INTUNE CONFIGURATION` | Exports the values to enter, plus a tested-vs-production drift check |
| `REPORT` | HTML evidence report |
| `FINAL VALIDATION` | Every gate re-asserted before exit 0 |

The pre-build checklist is generated from the manifest, so its length varies —
a standard EXE package with script detection produces 24 checks. It covers the
installer's existence and readability, the presence of each wrapper script,
whether the install wrapper targets the packaged installer, whether the
detection and uninstall criteria are still the template's example values,
whether every command resolves to a file inside the package, interactive and
duplicate arguments, absolute-path hygiene, working-directory assumptions,
unreviewed user-profile dependencies, `$PSScriptRoot` usage, nested
`.intunewin` files, stale build artifacts, stray log directories, and manifest
completeness.

`src/Testing/Test-IntunePackage.ps1` runs the deployment validation alone. Its
stages are `Package staging`, `Install`, `Detection after install`,
`Integration validation`, `Post-install validation`, `Uninstall`,
`Detection after uninstall`, `Integration cleanup`.

Staging copies the package to a random directory under `%SystemRoot%\Temp`
before execution, so any dependency on the build location fails during
validation rather than on a device. With `-SystemContext`, every stage runs as
`NT AUTHORITY\SYSTEM` via a scheduled task — no interactive desktop, no user
profile, no mapped drives.

`src/Testing/Invoke-PackageCommand.ps1` runs one of those commands on its own,
printing the exit code and both streams in full. It exists because a full cycle
is a slow way to find out that an install command is one switch short, and
because a stage that reports only an exit code leaves nothing to work from. It
produces no package.

### Information intelligence layer

`src/Information/` decides what the platform needs to know, discovers what it
can, and asks for the rest. Dot-source `Load.ps1` to bring it into scope.

Every value carries its source, confidence, state and full change history.
Before anything is asked, sources are tried in precedence order:

```
USER_ENTERED  >  USER_SELECTED  >  CAPTURED  >  INSTALLED_SYSTEM
  >  INSTALLER_METADATA  >  REGISTRY  >  FILESYSTEM  >  INTUNE_METADATA
  >  PREVIOUS_BUILD  >  PROJECT  >  CONFIGURATION  >  DERIVED  >  AUTO_DISCOVERED
```

Four invariants make this more than a form cache:

- **A user-confirmed value is never overwritten by discovery.** Equal-ranked
  sources that disagree produce `CONFLICT` rather than a silent winner.
- **Facts and decisions are separate collections.** Recording that the
  deployment should not reproduce a PATH change never erases the observation
  that the installer makes one.
- **`UNKNOWN` is a real state.** It is never read as "no" and never replaced by
  a default; it either prompts or blocks.
- **An override preserves what was discovered**, so a reset always has a target.

| Module | Responsibility |
| --- | --- |
| `FieldModel.ps1` | Values with source, confidence, state, override history |
| `FieldRegistry.ps1` | The catalog of every field and which operation needs it |
| `PathResolver.ps1` | Canonical paths, project-relative storage, anchors |
| `ResourceResolver.ps1` | File identity and missing-resource recovery |
| `EvidenceStore.ps1` | Facts, decisions and the audit trail |
| `ProjectState.ps1` | The single source of truth, and its persistence |
| `DiscoveryEngine.ps1` | Installer metadata, name/version derivation, installed-machine lookup |
| `InstallerEvaluator.ps1` | Evaluates EXE/MSI/MSIX and BAT/CMD/PS1 wrappers into a reviewable proposal |
| `CaptureIntegration.ps1` | Turns an install delta into answers and policy questions |
| `ConflictResolver.ps1` | Sources that disagree |
| `RequirementEngine.ps1` | What an operation needs and how complete it is |
| `PromptEngine.ps1` | Which questions are worth asking, and never twice |
| `CommandModel.ps1` | Commands as structure rather than strings |
| `InformationManager.ps1` | The facade every feature calls |
| `Show-InformationPrompt.ps1` | Console rendering of prompts, review and inventory |

Prompt descriptors are data. `Show-InformationPrompt.ps1` renders them for a
console; a different front end can consume the same descriptors without
reimplementing any of the logic that decided to ask.

## Technology stack

- **Windows PowerShell 5.1 and PowerShell 7+.** 5.1 is the floor because that
  is what a packaging workstation has. See [compatibility](#compatibility).
- **No external modules.** Everything uses in-box cmdlets and .NET types.
- **`IntuneWinAppUtil.exe`** (Microsoft Win32 Content Prep Tool) for packaging.
- **JSON** for every persisted artifact.
- **COM (`WindowsInstaller.Installer`)** for the MSI property table.

## Repository structure

```
src/Core/          Manifest, path/command validation, state snapshots,
                   failure classification, platform probing
src/Information/   Information intelligence layer
src/Testing/       Intune simulation engine and SYSTEM-context executor
src/Reporting/     HTML validation report and Intune configuration export
src/Build/         Workflow orchestrator, project wizard, pre-build evaluator
templates/         Reference Install / Uninstall / Detection scripts,
                   plus Apply-/Remove-Integrations wrappers
examples/          Example configuration files
tests/             Test suites
Intune-App-Evaluator/  Sibling tool: inspects an installed application and
                   exports a package.json for this packager (see its README)
```

Entry points:

| Script | Role |
| --- | --- |
| `src/Build/Evaluate-Installer.ps1` | Evaluates an installer into a reviewable configuration proposal |
| `src/Build/New-PackageProject.ps1` | Discovery and prompting; produces `package.json` |
| `src/Build/Build-IntunePackage.ps1` | Full validate-then-package pipeline |
| `src/Testing/Test-IntunePackage.ps1` | Deployment validation only |
| `src/Testing/Invoke-PackageCommand.ps1` | One of the package's commands, with both streams shown |
| `src/Build/Evaluate-Package.ps1` | Static check of a hand-written config |

## Windows integrations

A package can establish, verify and remove four Windows integrations as owned
resources: a **PATH/environment** entry, a **desktop shortcut**, a
**context-menu** action, and a **file association**. They are declared in
`package.json` under `Integrations`, carried through the manifest, staged into
the package, applied by `Install.ps1`, verified by `Test-IntunePackage.ps1`,
and removed by `Uninstall.ps1`. `examples/package.intellij-integrations.json`
is a full IntelliJ IDEA example.

Each integration runs in one of three **modes**:

| Mode | Meaning |
| --- | --- |
| `DISABLED` | The package does nothing with it. |
| `VALIDATE` | The vendor installer owns it; the package only verifies it exists and is correct, and never creates or removes it. |
| `MANAGE` | The package creates it, records that it owns it, and removes only what it recorded during uninstall. |

**Ownership, not filenames, drives removal.** `Apply-Integrations.ps1` records
each resource it creates — the PATH entry it added, the `.lnk` it wrote, the
registry keys it created — in `%ProgramData%\IntuneDeployment\State\<app>\integration-state.json`.
`Remove-Integrations.ps1` removes exactly those, so a pre-existing PATH entry,
an unrelated shortcut of the same name, or a vendor-created (VALIDATE)
association is never touched. A PATH entry is matched case- and
trailing-slash-insensitively, so it is never added twice.

**SYSTEM is not the signed-in user.** Under SYSTEM (the Intune norm) a
device-wide integration must use machine scope: the Public desktop, `HKLM\SOFTWARE\Classes`,
the machine PATH. A request for a per-user (`HKCU`, user PATH, user desktop)
integration from SYSTEM is reported as not reaching the intended users rather
than silently claiming success.

The engine, `src/Core/Integrations.ps1`, is self-contained so it can be staged
into the package. Its decision logic — PATH add/deduplicate/remove and
preserve-others, ownership selection, the registry command and ProgID
generation, mode and scope resolution, and capture that identifies only
application-relevant associations — is kept separate from the operating-system
calls it drives (COM `.lnk`, the live registry, the machine PATH), which
`Test-IntunePackage.ps1` verifies against real machine state after install.

## Configuration architecture

Three representations, in order of authority:

```
package.json            what the operator declared
      |
      v
PackageManifest.json    the validated, schema-checked description of the build
      |
      v
.project/               everything known, with provenance
```

**`package.json`** is the operator-facing config. It can be hand-written or
generated by `New-PackageProject.ps1`. `src/Core/PackageManifest.ps1` defines
the schema: required fields, enum-valid values for installer type, install
behaviour, architecture, detection method and reboot behaviour.

**`PackageManifest.json`** is the authoritative description of what was
packaged, written into both the source and the build output so the validated
content and the packaged content are provably the same.

**`.project/`** is the information layer's store:

```
.project/
    project.json      fields, resources and anchors
    evidence.json     every observation with its source, plus the audit trail
    facts.json        what was observed
    decisions.json    what was chosen
    captures/
    builds/
```

Paths inside a project are stored relative to the project root, and files are
referenced by name, size, SHA256 and version rather than by absolute path — so
a project keeps working when it is moved, and a file that moved inside the
project is recovered by identity rather than reported missing.

## Implementation invariants

Things that will look like details and are not.

**Detection contract.** Intune treats a custom detection script as detected
only when it writes to STDOUT **and** exits 0. Output with a non-zero exit does
not count; a zero exit with no output does not count. `templates/Detection.ps1`
implements both halves and never throws, because an unhandled exception is a
non-zero exit that reads as "not installed" and silently triggers a reinstall
loop.

**Exit code preservation.** The vendor installer's exit code is returned
unchanged, never replaced with 0 because the PowerShell wrapper completed.
Reboot codes (1641, 3010) are preserved by default; translating them is an
explicit choice.

**Completion is the installer's own exit.** `Install.ps1` waits for the
installer process and nothing else. A resident helper or updater is normal
behaviour, not an unfinished installation, and waiting for one that never exits
stalls the deployment until the timeout. Nothing is matched by process name:
`msiexec` is also the long-lived Windows Installer service.

**A detection script cannot fail in a way that looks like an answer.** Nothing
in `templates/Detection.ps1` runs outside its error handling, so a value that
cannot be resolved on the target machine produces "not detected" rather than a
non-zero exit. The validation harness keeps the two apart as well: a non-zero
exit is reported as a script that did not complete, never as proof the
application is absent.

**"Not detected" states its reasoning.** When the template finds nothing it
writes what it checked, and the registered names resembling the one it was
given, to STDERR — which Intune ignores and the harness records. A detection
script that reports absence with no reasoning is why these failures take days:
the usual cause is a `$DisplayName` that does not match what the installer
registered, and that is invisible until something names the alternatives.
Pre-build validation separately blocks a package whose criteria are still the
template's example values.

**Command rendering happens once.** `CommandModel.ps1` holds commands as an
executable plus an argument list and renders the string at the end. Re-parsing
a command string is where quoting bugs and duplicated switches come from.

**One source for the installer name and switches.** They live in `package.json`
(`installer.fileName` and `installer.silentArguments`). `CommandModel.ps1` puts
them into the generated install command — `-InstallerName` for the file, the
silent switches as trailing arguments — and `Install.ps1` takes them as
parameters. The template hard-codes neither, so the configured values apply
exactly once, on both the normal and the SYSTEM-context execution paths, rather
than being restated inside the wrapper where they could drift.

**One canonical path format, converted only at the edge.** Every stored and
displayed path uses forward slashes, on every platform. A single form means a
path reads identically in `project.json`, the manifest, the HTML report and the
console, and never acquires the doubled backslashes a Windows path picks up the
moment it is serialised to JSON. Windows accepts forward slashes throughout its
filesystem APIs, so this costs nothing at runtime.

```
ConvertTo-CanonicalPath   any spelling in  ->  C:/Users/Example/App
ConvertTo-NativePath      canonical in     ->  C:\Users\Example\App  (on Windows)
```

`ConvertTo-NativePath` is the execution boundary and is called only where a raw
.NET API or an external process argument genuinely needs the host's spelling.
`Resolve-Path` serves the same purpose where the provider is already involved.
Converting at arbitrary points is how a codebase ends up with two
representations and no rule about which is which, so everything between the
boundaries stays canonical.

Normalisation is applied only to values the field catalog declares to be a
`Path` or a `Directory`. Registry keys, command lines, URLs and regular
expressions all legitimately contain backslashes, and rewriting separators in
arbitrary strings corrupts them. A project saved in the older format repairs
itself on load through `Update-ProjectPathFormat`.

`System.IO.Path` honours only the running platform's separator, so
`PathResolver.ps1` provides `Split-CanonicalPath`, `Get-CanonicalLeaf`,
`Get-CanonicalExtension` and `Get-CanonicalBaseName`. Using the framework
methods on a canonical path silently returns empty.

**One execution layer, and it always returns.** Install, detection and uninstall
all run through `Invoke-ProcessWithTimeout`. Two implementations of "run a
process and wait" drift, and the one that is harder to test is the one that
breaks.

Output is captured through events rather than by reading the redirected streams
to their end. Reading to the end waits for EOF, and EOF arrives only when every
handle to the pipe's write end is closed — including the copies an installer
passes to a helper or updater that deliberately outlives it. That wait is not
covered by any process timeout, so a successful install whose updater stays
resident blocks the caller permanently. The *process* wait is what is bounded;
trailing output gets a short grace period it can never exceed.

Every call returns one of `COMPLETED`, `TIMED_OUT`, `CANCELLED` or `FAILED`,
carrying the pid, command line, start time, exit code, both streams and elapsed
time. Cancellation is a watched sentinel file, so a stuck stage can be released
without terminating the session.

**Evidence populates, absence reports.** `InstallerEvaluator.ps1` reads file
metadata, the MSI property table, the lines of a wrapper script, the uninstall
registry and an installation capture. A value it cannot source stays empty and
is reported as requiring the administrator.

Silent switches are the case that matters. They are populated from a wrapper
script that passes them, from Windows Installer semantics for an MSI, or from a
recognised installer toolkit's documented switches - never because a switch is
common. A guessed switch produces a package that installs interactively on
every device, which is the failure the whole project exists to prevent. The
same rule governs uninstall commands, install locations and detection rules.

Detection is proposed from the strongest evidence available - MSI product code,
then primary executable, then uninstall registration, then install folder - and
a folder-only rule is marked unreliable because folders commonly survive an
uninstall.

Evaluation writes through the same field model as everything else, so each
proposed value carries its source and confidence and can be reviewed,
overridden or reset. Generation is separate: approved facts become Install.ps1,
Uninstall.ps1 and Detection.ps1 afterwards.

**Completion is the installer's own exit, and nothing else.** The wrappers run
the vendor installer the way a command prompt would - no shell, no redirection
- and wait for that process alone.

Two things they deliberately do not do. `Start-Process -Wait` is not used: on
Windows it waits for the process *and its descendants*, so an installer that
leaves a helper or updater resident never lets the wait return. Nor is any
process waited on by name: `msiexec` is also the long-lived Windows Installer
service, so a machine-wide name match never goes quiet. Both stalled a
successful install until its timeout fired. Processes the installer leaves
behind are left alone, never waited on and never terminated.

`tests/Run-Tests.ps1` asserts both, by scanning the wrapper source and by
running one against an installer that deliberately leaves a helper resident.

**Failure classification.** `src/Core/FailureClassifier.ps1` maps a failure to
one of fourteen classifications (`SYSTEM_CONTEXT_FAILURE`, `DETECTION_FAILURE`,
`RETURN_CODE_FAILURE`, …) from stage, exit code, output text, detection result
and execution context, and emits a reproduction guide.

## Development setup

```bash
git clone <repo>
cd staging-spoon
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

The tool targets Windows and runs on Windows PowerShell 5.1 (the in-box
edition) and on PowerShell 7. Deployment validation additionally needs
elevation and a disposable machine — it genuinely installs and uninstalls
software.

To work with the information layer interactively:

```powershell
. ./src/Core/PackageManifest.ps1
. ./src/Information/Load.ps1

$project = Initialize-InformationProject -Root .
Select-ProjectInstaller -Project $project -Path ./source/Setup.exe
Get-InformationInventory -Project $project | Format-Table
```

## Testing architecture

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-InformationTests.ps1
pwsh -NoProfile -File .\tests\Run-CompatibilityTests.ps1
pwsh -NoProfile -File .\tests\Run-IntegrationTests.ps1
```

| Suite | Covers |
| --- | --- |
| `Run-Tests.ps1` | Command parsing, path classification, manifest validation, failure classification, the pre-build gate against clean and deliberately dirty packages, Intune config export including drift detection, HTML report encoding |
| `Run-InformationTests.ps1` | Field model and source arbitration, facts versus decisions, resource identity and recovery, filename derivation, the command model, capture integration, requirement calculation, and an end-to-end acceptance scenario |
| `Run-IntegrationTests.ps1` | The four Windows integrations, the three modes, ownership-driven removal, and the real-state checks against COM shortcuts and the registry |
| `Run-CompatibilityTests.ps1` | Static scan for constructs that work in PowerShell 7 but break on Windows PowerShell 5.1 |

The acceptance scenario in `Run-InformationTests.ps1` is the important one. It
asserts the behaviour the information layer exists to provide: after an
installer is selected and a capture imported, nothing already discovered is
asked for, only policy decisions remain, answering them once is enough, and
reopening the project asks nothing.

### Compatibility

The target is Windows on both PowerShell editions. `Run-CompatibilityTests.ps1`
guards against constructs that work in PowerShell 7 but break on Windows
PowerShell 5.1: it scans the source for `$IsWindows` and the other automatic
platform variables, `[System.Text.Encoding]::Latin1`, `??`, `&&`, `-Parallel`,
`-AsHashtable`, non-ASCII console output, and `int + "string"` concatenation.

Use `Get-Latin1Encoding` from `src/Core/Platform.ps1` rather than
`[System.Text.Encoding]::Latin1`, which is .NET 5 and later only. The automatic
`$Is*` variables do not exist on 5.1 and, under `Set-StrictMode`, reading one
throws rather than returning false, so the code does not reference them.

All source files set `Set-StrictMode -Version Latest`. Functions that may
return an empty collection are wrapped in `@()` at the call site, because
strict mode makes property access on an unrolled `$null` an error.

## Contributing

- Add tests with behaviour changes. The three suites must stay green.
- Prefer extending `FieldRegistry.ps1` over adding a bespoke prompt. A field
  declared there is automatically discovered, prompted, prioritised, grouped
  and reported.
- Never widen a field's `RequiredFor` without checking the effect on
  `Get-OperationReadiness` — required fields block the build.
- Keep console output ASCII.
- **Update [INSTRUCTION.md](INSTRUCTION.md) in the same change as any
  user-facing behaviour change.** A new prompt, a renamed output file, a new
  switch or a changed workflow is not finished until the operating guide
  matches. INSTRUCTION.md must describe only behaviour that exists.

## Requirements

- Windows with PowerShell 5.1 or later for deployment validation
- Elevation for `-SystemContext`
- `IntuneWinAppUtil.exe` to produce the `.intunewin`
