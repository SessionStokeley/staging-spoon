# Rebuild Audit

Audit of the existing application before the rebuild into **Intune Package
Builder**, per section 2 of the rebuild instructions.

Nothing was modified to produce this document.

---

## 1. Current architecture

One PowerShell application, 14,384 lines across 20 `.ps1` files, in `IntuneApp\`.

```
IntuneApp\
├── New-IntuneApp.ps1          326   Entry point: Wizard/Gui/Analyze/Validate/
│                                     Preview/Summary/DryRun/Run/Build
├── Install.ps1                296   Deployment wrapper (13 numbered stages)
├── Uninstall.ps1              231   Removal wrapper (7 numbered stages)
├── Detection.ps1              141   Intune detection contract
├── Configuration.psd1         232   The package configuration
├── Test-Local.ps1             553   11 local test modes
├── Helpers\
│   ├── Environment.ps1       1451   PATH and environment variables
│   ├── WindowsIntegration.ps1 1398  Shortcuts, context menus, associations,
│   │                                 services, scheduled tasks
│   ├── InstallerArguments.ps1 446   ArgumentSource resolution, command building
│   └── ConfigLoader.ps1       449   5.1-safe .psd1 loading, custom detection
├── Studio\                   3924   Configuration generator: console wizard,
│                                     WPF GUI, analyzer, validator, preview,
│                                     psd1 serializer, approval gate
└── Tests\                    3612   9 suites, 467 assertions
```

**Execution model.** `Configuration.psd1` is the source of truth. The three
engine scripts are generic and read it at runtime; the Studio only writes that
file. Analysis and configuration are separated from execution by an approval
gate, enforced by a test that inspects the generator's source for execution
calls.

**Package shape.** The `.intunewin` contains the whole `IntuneApp\` tree —
engine scripts, `Helpers\`, `Studio\`, `Tests\` and `Files\<installer>`.

---

## 2. Current packaging workflow

```
Select installer → Analyze → Questions → Configuration.psd1
  → Review → Validate → Approve → Run → Validate → Build
```

`.intunewin` generation is `Studio\Runner.ps1`:
`Find-IntuneWinAppUtil` searches PATH then four fixed locations, then
`IntuneWinAppUtil.exe -c <PackageRoot> -s Install.ps1 -o <Output> -q`.

---

## 3. Problems discovered

### 3.1 The stated rebuild premise is already fixed

The instructions open with "installer arguments may be duplicated or handled in
multiple places" as the critical problem. That was found and fixed earlier in
this session.

`Installer.ArgumentSource` (`Configuration` / `Intune` / `None`) makes exactly
one source authoritative per execution. Arguments are never merged and a
configuration that asks for one source while supplying the other is refused
rather than guessed at. `Resolve-InstallerArguments` and
`New-InstallerCommandLine` are the only places a command line is built.
62 assertions cover it, including all type/source combinations asserted against
the effective command rather than the variables feeding it; injecting a silent
merge fails 6 of them.

**This means the rebuild is not fixing the problem it was written to fix.** It
is worth stating plainly before discarding the code that fixes it.

### 3.2 Local testing does not run as SYSTEM — a real gap

`Test-Local.ps1 -Mode Install` runs the generated `Install.ps1` as the
*current administrator*. Intune runs it as `NT AUTHORITY\SYSTEM`.

The two differ in ways that produce precisely the reported symptom — passes
locally, fails through Company Portal:

| | Administrator | SYSTEM |
|---|---|---|
| `HKCU` | the admin's hive | `.DEFAULT`, not any real user |
| `%USERPROFILE%` | the admin's profile | `C:\Windows\system32\config\systemprofile` |
| User Desktop / Start Menu | the admin's | the system profile's, which no one sees |
| Mapped drives | present | absent |
| User PATH | the admin's | the system profile's |

The framework warns when it is not SYSTEM but cannot *become* SYSTEM. This is
the single most plausible cause of the symptom in the instructions, and it is
unaddressed by the current code.

**Carry into the rebuild as a first-class feature.**

### 3.3 Nothing invalidates a stale test result

`-Mode Build` runs validation but has no notion of "has this configuration been
tested since it last changed". A configuration can be tested, edited, and
packaged without retesting. Section 23 of the instructions asks for this;
it does not exist today.

### 3.4 The package ships the whole toolchain

The `.intunewin` contains `Studio\` (3,924 lines of WPF GUI, wizard, analyzer)
and `Tests\` (3,612 lines), none of which any endpoint executes.
`IntuneWinAppUtil -c` packages everything under the folder it is pointed at, so
roughly 7,500 lines of build-time-only code is delivered to every managed
machine. Section 10 asks for a flat package of five files.

### 3.5 Duplicated policy across the module boundary

`Resolve-IntegrationMode` (engine) is mirrored by hand in
`ConfigValidator.ps1` and `Preview.ps1`, because the Studio is deliberately
kept free of any dependency on the execution engine. The duplication is
documented in all three places, but it is duplication, and the rule can drift.

### 3.6 Feature surface beyond the stated scope

`WindowsIntegration` implements services and scheduled tasks. Section 6 lists
neither. The user's own capture-reliability table rates both "detect, don't
automatically replay". They are covered by 83 assertions but are scope the
rebuild does not ask for.

### 3.7 Configuration schema is deep

Current: `Installer.Arguments`, `Environment.SystemPath.Entries`,
`WindowsIntegration.DesktopShortcut.Mode`. Section 11 wants
`InstallArguments`, `Path.Value`, `Shortcuts[]`. The two are not compatible.

---

## 4. Code that can be reused

Reusable as logic even though the files are replaced. These carry hard-won
behaviour that took real defects to find:

| Source | What is worth keeping | Why |
|---|---|---|
| `Environment.ps1` | Raw `REG_EXPAND_SZ` read/write | BUG-001: reading PATH with `Get-ItemProperty` expands it, and writing it back destroys every `%VAR%` on the machine |
| `Environment.ps1` | Path comparison ignoring case and trailing slash, treating `%VAR%` as its expansion | Prevents duplicate PATH entries under two spellings |
| `Environment.ps1` | Ownership-driven removal | BUG-006/008: without recorded ownership, uninstall deleted pre-existing variables |
| `WindowsIntegration.ps1` | `call`-prefixed shortcut/verb creation, `Join-WindowsPath` | Provider-aware cmdlets mangle Windows paths |
| `WindowsIntegration.ps1` | Never overwrite an existing verb; never delete a shared parent key | Protects other products' shell integration |
| `InstallerArguments.ps1` | `ArgumentSource`, base64 argument transport, redaction | Section 9's rule, already implemented and tested |
| `InstallerArguments.ps1` | Omit `-ArgumentList` when empty | BUG-012: 5.1 rejects an empty one |
| `ConfigLoader.ps1` | Syntax-tree `.psd1` reader | BUG-011: 5.1 cannot load a script-block literal |
| `ConfigLoader.ps1` | Unwrap a data-file script block before invoking | BUG-010: otherwise custom detection reports every application installed |
| `Detection.ps1` | Exit-code contract, errors to stderr | BUG-007: a silent failure is indistinguishable from "not installed" |
| `Analyzer.ps1` | PE/MSI metadata, installer technology detection | Directly reusable for capture and for the new UI |
| `Tests\` | Substituting machine primitives so orchestration runs anywhere | The only reason 467 assertions run on a non-Windows host |

**Every one of these is a fix for a defect that was found the hard way. They
must be carried forward deliberately, not rediscovered.**

---

## 5. Code that should be removed

| Item | Reason |
|---|---|
| `Studio\` from the shipped package | Build-time only; section 10 |
| `Tests\` from the shipped package | Build-time only |
| `Helpers\` from the shipped package | Section 10 is flat; generated scripts must be self-contained |
| Services and scheduled tasks | Outside section 6's scope |
| The mirrored `Resolve-IntegrationMode` copies | One implementation after the rebuild |
| `-Mode Run` / `Test-PackageWorkflow` | Superseded by SYSTEM-context testing |
| Old branding: `IntunePackagingStudio`, `IntuneApp`, "Studio" | Section 1 |

---

## 6. Code that should be rewritten

| Area | Change |
|---|---|
| Configuration schema | Deep → flat (section 11) |
| `Install.ps1` | Generic runtime engine → generated, self-contained script |
| `Uninstall.ps1` | Same |
| `Detection.ps1` | Exit-code-only → also a readable diagnostic report (section 20) |
| Local testing | Administrator → SYSTEM context (section 21) |
| Build | Add test-state invalidation (section 23) |
| UI | Nine console modes + one WPF window → the navigation in section 31 |

---

## 7. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| 1 | **State path change orphans deployed machines.** State lives at `C:\ProgramData\IntunePackagingStudio\State\<App>\`. Renaming moves it. A machine that installed under the old path has an uninstall that can no longer find what it owns, so it removes nothing — PATH entries and shortcuts are left behind permanently. | **High** | New scripts read the old path as a fallback when the new one is absent. Cheap, and the alternative is silent orphaning. |
| 2 | **Schema break.** Every existing `Configuration.psd1` stops loading. | **High** | Ship a converter from the old schema to the new one, or accept and document the break. |
| 3 | **Losing defect fixes.** Twelve logged bugs live in code being replaced. A from-scratch rewrite reintroduces them unless each is carried deliberately. | **High** | Section 4 is the checklist. Port the tests that prove each one first, then make them pass. |
| 4 | **467 assertions discarded.** The new code starts at zero coverage. | **High** | Port the suites that still apply before the code they cover. |
| 5 | **SYSTEM-context testing needs a mechanism.** No PsExec here; a scheduled task running as SYSTEM is the portable route, and it is fiddly. | Medium | Task Scheduler with `-User SYSTEM -RunLevel Highest`, results marshalled through a file. |
| 6 | **Generated self-contained scripts duplicate logic.** Emitting PATH handling into every package means the fix for a PATH bug ships only in packages generated afterwards. | Medium | Generate from a single reviewed template; stamp the generator version into each package. |
| 7 | **No Windows here.** SYSTEM testing, real snapshots, registry and WPF cannot be verified in this environment. | Medium | Windows-only paths report SKIP with a reason and are never counted as passing, as they are today. |

---

## 8. Recommended new architecture

```
IntunePackageBuilder\                 the tool (never shipped to an endpoint)
├── New-IntunePackage.ps1             entry point
├── Builder\
│   ├── PackageConfig.ps1             flat schema, load/save
│   ├── Generator.ps1                 emits the self-contained package scripts
│   ├── Templates\                    Install / Uninstall / Detection sources
│   ├── Validation.ps1                section 25
│   ├── LocalTest.ps1                 section 21, SYSTEM context
│   ├── Packaging.ps1                 .intunewin + test-state invalidation
│   ├── Preview.ps1                   section 24
│   ├── History.ps1                   section 32
│   └── Ui.ps1                        section 31
├── Capture\
│   ├── Snapshot.ps1                  PATH, shells, Classes, install dirs
│   ├── Diff.ps1
│   ├── Classify.ps1                  Safe / Review / Ignore
│   └── Capture.ps1                   orchestration, System and User contexts
└── Tests\

PackageSource\                        generated; this is what ships
├── <Installer>
├── Install.ps1                       self-contained
├── Uninstall.ps1                     self-contained
├── Detection.ps1                     self-contained
└── Configuration.psd1
```

**Installation Capture is discovery, not replay.** Capture proposes; the
administrator approves; the generated package stays deterministic and simple.

---

## 9. Conclusion

The rebuild is proceeding at the user's explicit direction after these findings
were put to them.

Two things in this audit should shape it regardless of scope:

1. **The argument duplication the rebuild was written to fix no longer exists.**
   The rebuild's value is therefore simplification and the SYSTEM-context gap,
   not that defect.
2. **Section 3.2 is the more likely cause of "works locally, fails in Company
   Portal"**, and no amount of restructuring fixes it by itself. SYSTEM-context
   local testing is the change most likely to address the original complaint.
