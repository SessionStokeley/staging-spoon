# Change Log

Application-development change log for **Intune Package Builder**.

This records changes to the tool itself. Logs written by a generated package
are a separate thing and live under
`C:\ProgramData\IntunePackageBuilder\Logs\`.

---

## 2026-09-21 — Rebuild begins

### Architecture

- Started the ground-up rebuild into **Intune Package Builder**, replacing the
  previous `IntuneApp` framework. Proceeding at the user's explicit direction
  after `REBUILD_AUDIT.md` put the findings below to them.
- Adopted the flat configuration schema from section 11 of the rebuild
  instructions, replacing the previous nested schema
  (`Installer.Arguments`, `Environment.SystemPath.Entries`,
  `WindowsIntegration.DesktopShortcut.Mode`). The two are not compatible.
- Decided the generated package is produced by **copying one reviewed
  template**, not by generating code per package. The template is
  self-contained and reads `Configuration.psd1` at runtime.

  A generator that emits bespoke script text per package means a fix for a PATH
  bug reaches only packages built afterwards, and every package is a slightly
  different program to debug. One template keeps the shipped script reviewable
  and identical everywhere, while still satisfying section 10's flat package
  and section 12's self-contained wrapper.
- Established that `Install.ps1`, `Uninstall.ps1` and `Detection.ps1` carry
  their own helpers inline. The shipped package has no `Helpers\` directory.

### Added

- `REBUILD_AUDIT.md` — architecture, workflow, problems, reusable code,
  removals, rewrites, risks and the recommended new architecture.
- `CHANGELOG.md` — this file.

### Removed from scope

- **Services and scheduled tasks.** Section 6 lists neither, and the capture
  reliability table rates both "detect, don't automatically replay". The
  previous framework implemented them with 83 assertions behind it; that
  capability is being dropped, not carried forward.
- **`Installer.ArgumentSource`.** Section 9 requires that Intune's command line
  only launch the wrapper, so the configuration is the single authoritative
  source of installer arguments and nothing is passed in from the Program
  command.

  This is a deliberate reversal of a feature added earlier in this session at
  the user's request, in which `ArgumentSource = "Intune"` let the Program
  command supply arguments instead. It is recorded here rather than dropped
  quietly, because it is the one place the rebuild instructions and a previous
  instruction disagree outright. Say the word and it comes back.

### Carried forward deliberately

Each of these is a fix for a logged defect. They are being ported into the new
code with their tests, not left behind:

- Raw `REG_EXPAND_SZ` PATH read/write, so `%VAR%` tokens survive (BUG-001).
- Path comparison ignoring case and trailing slash, treating `%VAR%` as its
  expansion, so an entry is never added twice under two spellings.
- Ownership-recorded removal, so uninstall never deletes something the package
  did not create (BUG-006, BUG-008).
- Never overwrite an existing shell verb; never delete a shared parent key.
- `-ArgumentList` omitted rather than passed empty, which 5.1 rejects
  (BUG-012).
- Syntax-tree `.psd1` reading, because 5.1 cannot load a script-block literal
  (BUG-011), and unwrapping a data-file script block before invoking it
  (BUG-010).
- Detection's exit-code contract, with failures explained on stderr so a broken
  configuration is never mistaken for "not installed" (BUG-007).
- Windows paths joined as text, because provider-aware cmdlets mangle them.

### Findings recorded during the audit

- **The problem the rebuild was written to fix no longer exists.** Duplicated
  installer arguments were found and fixed earlier in this session; the
  rebuild's value is simplification and the gap below, not that defect.
- **Local testing has never run as SYSTEM.** It runs as the current
  administrator, which differs from Intune's SYSTEM context in `HKCU`,
  `%USERPROFILE%`, the user Desktop and Start Menu, mapped drives and user
  PATH. This is the most plausible cause of "passes locally, fails in Company
  Portal", and no amount of restructuring addresses it on its own. Section 21
  is therefore a first-class feature of the rebuild.
- **Nothing invalidated a stale test result.** A configuration could be tested,
  edited and packaged without retesting. Section 23 addresses this.
- **The old package shipped the whole toolchain** — roughly 7,500 lines of GUI,
  wizard and tests delivered to every managed machine, because
  `IntuneWinAppUtil -c` packages everything beneath the folder it is given.

### Added (implementation)

- `Builder\Psd1.ps1` — reading and writing the configuration, with the
  syntax-tree fallback that lets a `.psd1` load on Windows PowerShell 5.1.
- `Builder\PackageConfig.ps1` — the flat schema, its defaults, and the entry
  constructors for associations, context menus and shortcuts.
- `Builder\Templates\_Runtime.ps1` — the package runtime: logging, 5.1-safe
  configuration loading, installer command construction for EXE/MSI/BAT, PATH
  with `REG_EXPAND_SZ` preserved, shortcuts, registry helpers and ownership
  tracking.
- `Builder\Templates\Install.ps1`, `Uninstall.ps1`, `Detection.ps1` — the
  three shipped scripts, each carrying a `#<RUNTIME>` marker.
- `Builder\Generator.ps1` — splices the runtime into each template and writes
  the package source directory.

### Fixed

- `Merge-PackageConfig` returned a collection directly, which PowerShell
  unrolls, so a list holding exactly one entry — one shortcut, one association
  — came back as the bare entry rather than a list. Indexing it then yielded
  `$null` and the caller read a property off nothing. Returns with the comma
  operator now. Same class as BUG-009 in the previous framework.
- The generator spliced the runtime with `-replace`, which reads its
  replacement as a regex pattern: every backslash in a Windows path and every
  `$` in a variable name is a substitution directive there. Uses
  `String.Replace`, which has no such reading of its input.

### Testing

- The previous suite of 467 assertions across 9 files covers code being
  replaced. Suites that still apply are being ported ahead of the code they
  cover, so the new implementation does not start at zero coverage.
- Generation verified end to end: five files and nothing else, all three
  scripts parse and contain the runtime, backslashes and `$PID` survive the
  splice, exactly one `#Requires` line per script, and `Detection.ps1` reports
  correctly in both verdict and `-Report` modes.
