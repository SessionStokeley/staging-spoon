# Debugging Log

Running record of defects found in this project. Newest first.
Entries are kept after they are closed so the history is not lost.

Severity: **Critical** (data loss / security) · **High** (feature broken) ·
**Medium** (works but wrong in cases) · **Low** · **Informational**

---

## BUG-011 — A Custom detection configuration could not load on PowerShell 5.1

- **DATE:** 2026-09-17
- **SEVERITY:** High (the whole configuration failed to load, not just detection)
- **STATUS:** Fixed

**SYMPTOM**
A `Configuration.psd1` containing `Detection.ScriptBlock = { ... }` fails to load
under Windows PowerShell 5.1. Because the failure is in the *loader*, it takes
the entire configuration with it: install, uninstall and detection all stop,
not just custom detection. Intune's Management Extension runs 5.1, so this is
exactly where it breaks.

**REPRODUCTION**
On Windows PowerShell 5.1:
```powershell
Import-PowerShellDataFile .\Configuration.psd1   # throws on the script block
```

**ROOT CAUSE**
`Import-PowerShellDataFile` evaluates a `.psd1` through
`ScriptBlockAst.SafeGetValue()`. PowerShell 7 added script-block support to that
evaluator; 5.1 has no such case and rejects the literal outright. This was
OPEN-1, recorded as unverified because the project had no 5.1 to test on.

**AFFECTED FILES**
- `IntuneApp/Helpers/ConfigLoader.ps1` (new)
- `IntuneApp/Detection.ps1`, `Install.ps1`, `Uninstall.ps1`
- `IntuneApp/Studio/ConfigModel.ps1`, `Studio/ConfigValidator.ps1`
- `IntuneApp/Tests/Test-PS51Compat.ps1` (new)

**FIX**
Two parts.

1. Custom detection now has two forms that are ordinary `.psd1` literals and
   need no special loader support: `Detection.Script` (inline PowerShell as a
   string) and `Detection.ScriptFile` (a `.ps1` shipped in the package).

2. Existing script-block configurations keep working. When the native loader
   refuses a file, `Import-PackageConfiguration` re-reads it from the syntax
   tree and converts each script-block literal to its source text. The fallback
   parses; it never executes, so a configuration still cannot run code merely by
   being loaded.

`Set-StrictMode` is deliberately **not** set in the new helper. Dot-sourcing
applies it to the caller's scope, and an earlier draft that set it broke
`Detection.ps1` on a legitimately absent `Detection.MinimumVersion`. The engine
helpers all follow that rule; the Studio modules set it because their entry
points expect it.

**TEST**
`Test-PS51Compat.ps1` (new, 21 checks). Three parts, kept separate so it is
never ambiguous which ran:

- A syntax audit that walks every shipped script's AST and fails on ternaries,
  `??`, `??=`, `?.`, `?[]`, `&&`/`||`, Core-only automatic variables, and
  PowerShell 7-only cmdlets. Verified to have teeth by injecting each construct
  in turn and confirming the suite fails.
- The 5.1 loader path executed for real via `-Strict`, including `Detection.ps1`
  driven end to end through it.
- A live `powershell.exe` 5.1 run, which reports `[SKIP]` off Windows.

**RESULT**
20 pass, 1 skip on Linux. The skip is the live 5.1 run and nothing else; the
5.1 *code path* is executed in full on any platform.

**REGRESSION RISK**
Low. The native loader still runs first and is unchanged wherever it succeeds,
so behaviour on PowerShell 7 is identical.

**NOTE**
Two bare `$IsWindows` references were removed as part of the audit. Both were
guarded by an edition check and so were safe through short-circuiting, but the
rule "never reference a Core-only variable directly" is one a test can enforce,
and "safe because of evaluation order" is not.

---

## BUG-010 — Custom detection reported every application as installed

- **DATE:** 2026-09-17
- **SEVERITY:** Critical (silent false positive)
- **STATUS:** Fixed

**SYMPTOM**
With `Detection.Type = 'Custom'`, `Detection.ps1` exited 0 — "installed" — no
matter what the detection script checked, including for an application that was
definitely not present.

**REPRODUCTION**
```powershell
# Configuration.psd1
@{ Detection = @{ Type = 'Custom'; ScriptBlock = { Test-Path '/definitely/not/here' } } }
```
```
pwsh -File Detection.ps1
Detected via custom check
exit 0          # expected 1
```

**ROOT CAUSE**
`Import-PowerShellDataFile` does not return the script block that was written.
It returns one *wrapping* it, whose entire body is the literal text `{ ... }`.
Invoking it therefore yields **another `ScriptBlock` object** rather than running
the check. A `ScriptBlock` is always truthy, so `if ($result)` was always true.

Detection never actually ran. It reported success because it had an object in
its hand, and nothing ever looked at what kind of object.

**CONSEQUENCE**
Worse than the reinstall loop of BUG-007. Intune believes the application is
installed when it is not, so the install never runs — or an uninstall is
reported successful while the application is still on the machine. Nothing in
the log looks wrong.

**AFFECTED FILES**
- `IntuneApp/Detection.ps1`
- `IntuneApp/Helpers/ConfigLoader.ps1`

**FIX**
`Resolve-DetectionScript` rebuilds the script block from its unwrapped source.
The unwrapping is done through the syntax tree, not by trimming braces:
`'{@{Type=1}}'.Trim('{','}')` strips both closing braces and produces
unbalanced source.

The verdict is now the **last** value the script emits rather than the whole
collection, so a script that prints progress before deciding is read correctly.
Previously any script emitting two or more objects was truthy regardless of what
it concluded.

**TEST**
`Test-PS51Compat.ps1` asserts that an absent application is not detected through
*both* loaders, and `Test-Detection.ps1` covers the exit-code contract. The
matrix — script block / `Script` / `ScriptFile`, present / absent, silent /
chatty — was confirmed by execution, not inspection.

**RESULT**
Fixed. An absent application now exits 1 in every form.

**REGRESSION RISK**
Low in mechanism, but note that detection results **change** for anyone using
custom detection: it starts reporting the truth. A package that appeared to
deploy cleanly may now correctly report "not installed" and reinstall. That is
the defect surfacing, not a new one.

**NOTE**
This had been shipped for the entire life of the feature and no test caught it,
because no test ever ran custom detection against an application that was
absent. Every test asserted the positive case, which is the one path where a
wrong answer looks right.

---

## BUG-009 — Studio GUI failed to open, and invented a blank PATH entry

- **DATE:** 2026-09-08
- **SEVERITY:** High (the GUI was entirely unusable)
- **STATUS:** Fixed

**SYMPTOM**
`New-IntuneApp.ps1 -Mode Gui` failed with "The property 'Count' cannot be found
on this object. Verify that the property exists." The window never appeared.

**REPRODUCTION**
Launch the GUI. The failure is on the startup path, before the window is shown,
with every text box still empty.

**ROOT CAUSE**
Two defects, both from PowerShell collapsing empty and single-element
collections, and both hidden because nothing had ever executed this code.

1. `Split-Lines` ended with `return @(...)`. A `return` unrolls, so an empty
   text box produced `$null` and a single line produced a bare `String`.
   `Read-ModelFromForm` then evaluated `$entries.Count`, which throws under
   `Set-StrictMode -Version Latest`. Startup calls `Update-Psd1Text`, so the
   Studio could not open at all.

2. `X = if (...) { $entries } else { @() }` assigns `$null`, because a block
   whose only output is `@()` emits nothing. The inactive PATH scope was
   therefore `$null` rather than an empty list, and `@($null)` reads as one
   blank element — so validation reported "A PATH entry is empty" against a
   form that was perfectly valid.

**AFFECTED FILES**
- `IntuneApp/Studio/Studio.ps1`
- `IntuneApp/Tests/Test-Gui.ps1` (new)

**FIX**
`Split-Lines` emits to the pipeline instead of returning `@(...)`, and every
call site wraps in `@()` so counts are reliable either way. Both `Entries`
assignments are wrapped in `@( )` so an inactive scope stores an empty array.

**TEST**
`Test-Gui.ps1` (new, 19 assertions). The GUI's model-to-form functions are
nested inside `Show-PackagingStudio` and cannot be dot-sourced, so the test
extracts their definitions from `Studio.ps1` with the PowerShell parser and runs
them against mock controls. The functions under test are the real ones; only WPF
is absent. Reverting either fix was confirmed to fail the suite.

**RESULT**
19/19 pass. The XAML and control-binding check is still clean.

**REGRESSION RISK**
Low. `Split-Lines` returns the same values for multi-line input, which is what
every previous run produced; only the empty and single-line cases change, and
those were broken.

**NOTE**
This was OPEN-3 — the WPF Studio had been shipped structurally verified but
never executed. Static checks confirmed the XAML parsed and all 77 controls
bound, and none of that could catch a runtime type collapse. The lesson matches
BUG-008: inspection is not verification.

---

## BUG-008 — Uninstall without state deleted a replaced variable

- **DATE:** 2026-09-08
- **SEVERITY:** Critical (data loss)
- **STATUS:** Fixed

**SYMPTOM**
Found while double-checking the BUG-006 fix, which was incomplete. With no
install state, uninstalling deleted `JAVA_HOME` outright even though it had
existed beforehand with a different value.

**REPRODUCTION**
Machine has `JAVA_HOME=C:\Existing\jdk`. Install a package whose configuration
sets `JAVA_HOME=C:\App\jdk` in `Set` mode. Delete the state file. Uninstall.
The variable is gone rather than restored.

**ROOT CAUSE**
The conservative path added by BUG-006 deleted a `Set`-mode variable when it
still held the value the package had written. That test is wrong: holding this
package's value proves the package *wrote* the variable, not that it *created*
it. `Set` also replaces a value that was already on the machine, and the
replaced value is recorded only in the state file. Without that record,
"created" and "replaced" are indistinguishable.

**AFFECTED FILES**
- `IntuneApp/Helpers/Environment.ps1`
- `IntuneApp/Tests/Test-Environment.ps1`
- `IntuneApp/Tests/Test-Lifecycle.ps1` (new)

**FIX**
`Set` mode with unknown ownership now never deletes. It leaves the value in
place and logs that the package cannot prove it created the variable, naming it
so it can be removed by hand. Leaving a stale value is recoverable; deleting
another product's variable is not.

**TEST**
`Test-Lifecycle.ps1` (new, 27 assertions) runs the real install and uninstall
orchestration against an in-memory stand-in for the registry, so the ownership
branching executes on any platform instead of only on elevated Windows. It
asserts a pre-existing `JAVA_HOME` and `CLASSPATH` survive an uninstall with no
state file.

**RESULT**
27/27 pass. The with-state path is unchanged and still restores the replaced
value and deletes the package-created one.

**REGRESSION RISK**
Low, and in the safe direction: uninstall without state now leaves more behind
than it did. That residue is logged by name.

**NOTE**
The BUG-006 fix was reported as verified on the strength of a unit test of the
field-resolution helper. That test was passing and the underlying behavior was
still wrong. The lifecycle harness exists so this class of gap is covered by
execution rather than by inspection.

---

## BUG-007 — Detection cannot be told apart from a broken configuration

- **DATE:** 2026-09-08
- **SEVERITY:** High
- **STATUS:** Fixed

**SYMPTOM**
A configuration error made `Detection.ps1` exit 1 with no output at all, which
is byte-for-byte what "the application is not installed" looks like to Intune.
Intune reinstalls, the install succeeds, detection fails again, and the cycle
repeats with nothing to diagnose.

**REPRODUCTION**
Point `Detection.ps1` at a `Configuration.psd1` that does not parse, or that has
no `Detection` section. Observe exit code 1 and completely empty stdout/stderr.

**ROOT CAUSE**
The top-level handler was `catch { exit 1 }` — it discarded the exception
entirely. Two secondary cases were also silent: a `Custom` type with no
`ScriptBlock`, and a missing `Detection` section, which surfaced only as
"you cannot call a method on a null-valued expression".

**AFFECTED FILES**
- `IntuneApp/Detection.ps1`

**FIX**
The exit-code contract is unchanged, because Intune's is binary and exit 0 must
keep meaning "installed". What changed is that a failure now says why, on
stderr, where it cannot be mistaken for the stdout that signals detection.
Written with `[Console]::Error.WriteLine` rather than `Write-Error`, which wraps
the text in a multi-line block that reads badly in an agent log. Added explicit
guards naming a missing `Detection` section or `Detection.Type`.

**TEST**
`IntuneApp/Tests/Test-Detection.ps1` (new, 18 assertions) covers the exit-code
contract in both directions and asserts that each broken-configuration case
exits non-zero *and* explains itself.

**RESULT**
18/18 pass. A genuinely absent application stays silent on stderr, since that is
a normal outcome rather than an error.

**REGRESSION RISK**
Low. No control flow changed; only diagnostics were added. The positive
detection path is asserted to write nothing to stderr, so nothing new can leak
into the stream Intune reads.

---

## BUG-006 — Uninstall could delete a pre-existing environment variable

- **DATE:** 2026-09-08
- **SEVERITY:** Critical (data loss)
- **STATUS:** Fixed

**SYMPTOM**
When no install state file was present, uninstall deleted an entire environment
variable — including entries the package never added. A pre-existing `CLASSPATH`
could be destroyed by uninstalling an unrelated application.

**REPRODUCTION**
```powershell
$fromPsd1 = @{ Name='CLASSPATH'; Value='C:\App\lib'; Scope='Machine'; Mode='Append' }
$fromPsd1.PSObject.Properties.Name          # IsReadOnly, IsFixedSize, Keys, Values, Count ...
$fromPsd1.PSObject.Properties.Name -contains 'Value'   # False, though the key exists
```

**ROOT CAUSE**
Two faults compounding.

1. Variable records reach uninstall from two sources with different shapes: the
   JSON state file (`PSCustomObject`, via `ConvertFrom-Json`) and the `.psd1`
   fallback (`Hashtable`, via `Import-PowerShellDataFile`). The code probed for
   fields with `$var.PSObject.Properties.Name -contains 'Value'`. A hashtable's
   *keys* are not PSObject *properties*, so that probe is always false for the
   `.psd1` shape and `Value`, `Existed` and `PreviousValue` all resolved to
   `$null`.

2. `Existed = $false` is also what "this package created the variable" looks
   like, so the null routed straight into the delete-the-whole-variable branch.
   Absence of evidence was being treated as evidence of ownership.

**AFFECTED FILES**
- `IntuneApp/Helpers/Environment.ps1`
- `IntuneApp/Tests/Test-Environment.ps1`

**FIX**
Added `Get-EntryField`, which reads dictionaries by key and objects by property,
and used it at the call site. Separately, uninstall now distinguishes *unknown*
ownership from *known-not-owned*: with no state record it passes
`-OwnershipUnknown`, and removal only takes back what it can positively identify
— un-appending its own entry from a list, and for `Set` deleting only when the
variable still holds exactly the value the package wrote.

> **Superseded by BUG-008.** That `Set` rule was still wrong: holding this
> package's value does not prove the package created the variable. `Set` with
> unknown ownership no longer deletes at all.

**TEST**
11 assertions for `Get-EntryField` across hashtable, `PSCustomObject`, ordered
dictionary, missing fields, and falsey-but-present values (a `$false` must not
be mistaken for absent). 8 further assertions for the conservative removal path.

**RESULT**
Field-resolution tests pass and run on any platform. The ownership tests need an
elevated Windows session and are skipped elsewhere.

**REGRESSION RISK**
Medium — uninstall behavior changed. With a state file present the path is
unchanged. Without one, uninstall is now deliberately more cautious and may
leave a variable in place that it previously deleted; that is the intended
trade, since the previous behavior destroyed unrelated data.

---

## BUG-005 — Environment variables overwritten instead of appended

- **DATE:** 2026-09-04
- **SEVERITY:** Critical (data loss)
- **STATUS:** Fixed

**SYMPTOM**
Setting a variable wrote straight over any existing value, so an install that
configured `CLASSPATH` or `PSModulePath` destroyed what was already there.
Uninstall then deleted the whole variable.

**ROOT CAUSE**
`Add-EnvironmentVariable` only ever did a replace. There was no notion of a
`;`-separated list, and no record of whether the package created a variable or
merely added to one.

**AFFECTED FILES**
`Helpers/Environment.ps1`, `Studio/ConfigModel.ps1`, `Studio/ConfigValidator.ps1`,
`Studio/Preview.ps1`, `Studio/Wizard.ps1`, both test suites, `README.md`

**FIX**
Added `Mode` = `Append` / `Prepend` / `Set`. Append and prepend go through the
same list primitives as PATH (`Add-ValueToList`, `Remove-ValueFromList`) rather
than a second implementation. Install records what it changed, so uninstall
un-appends its own entry, deletes only variables it created, and restores a
value it replaced.

**TEST** 14 list-semantics assertions (platform-independent) plus registry
round-trips gated on elevated Windows.

**RESULT** Passing.

**REGRESSION RISK** Low — `Set` remains the schema default, so existing
configurations behave as before.

---

## BUG-004 — `Write-Log` undefined outside Install/Uninstall

- **DATE:** 2026-09-04
- **SEVERITY:** High
- **STATUS:** Fixed

**SYMPTOM** Dot-sourcing `Helpers/Environment.ps1` from anywhere other than
`Install.ps1`/`Uninstall.ps1` and calling the orchestrators aborted the whole
environment step.

**ROOT CAUSE** The helper called `Write-Log`, which only those two scripts
defined.

**AFFECTED FILES** `IntuneApp/Helpers/Environment.ps1`

**FIX** The helper defines a fallback `Write-Log` when none is already in scope.

**RESULT** Fixed. **REGRESSION RISK** None — the existing definitions still win.

---

## BUG-003 — A failed PATH write reported success

- **DATE:** 2026-09-04
- **SEVERITY:** High
- **STATUS:** Fixed

**ROOT CAUSE** `Set-PersistentPath` never confirmed the write landed.

**FIX** Reads back and throws on mismatch; converts access-denied into a message
naming the rights required; refuses a value over the 32767-character registry
limit instead of letting Windows truncate the PATH.

**RESULT** Fixed. **REGRESSION RISK** Low — failures that were silent now raise.

---

## BUG-002 — `-AddIfMissing:$false` silently skipped the write

- **DATE:** 2026-09-04
- **SEVERITY:** High
- **STATUS:** Fixed

**ROOT CAUSE** The gate `$AddIfMissing -or (-not $AddIfMissing.IsPresent)` is
false whenever the switch is explicitly passed as `$false`. Nothing was written,
yet `Action` stayed `None` and `Success` stayed `$true`; validation then
reported the entry unregistered with no reason logged.

**FIX** Removed the gate. The duplicate check above it already means "add only
if missing", so reaching that point means the entry is absent and must be added.

**RESULT** Fixed, with a regression test. **REGRESSION RISK** Low.

---

## BUG-001 — PATH read expanded, then written back expanded

- **DATE:** 2026-09-04
- **SEVERITY:** Critical (data loss)
- **STATUS:** Fixed

**SYMPTOM** Adding one PATH entry permanently stripped every `%VAR%` from the
machine PATH: `%SystemRoot%\system32` became `C:\Windows\system32`.

**ROOT CAUSE** `Get-ItemProperty` expands `REG_EXPAND_SZ`. The expanded text was
then written back as the new PATH.

**FIX** Reads through the `RegistryKey` API with
`DoNotExpandEnvironmentNames`; writes preserve the existing value kind and never
downgrade `REG_EXPAND_SZ` to `REG_SZ`.

**TEST** Asserts the raw read differs from the expanded read, that every `%VAR%`
token survives a write, and that add-then-remove restores the PATH byte-for-byte.
Requires elevated Windows.

**RESULT** Fixed. **REGRESSION RISK** Low.

---

# Open items

Findings not yet fixed, recorded so they are not lost.

| ID | Severity | Item |
|---|---|---|
| OPEN-3 | Low | **The WPF Studio's window has still not been shown by a human.** `Test-WpfSmoke.ps1` now parses the XAML, cross-checks all 77 named controls against the code three ways, and — on Windows — builds the real window, resolves every control, fires an event handler, saves and reloads a configuration, and closes cleanly. What remains is only what automation cannot reach: `ShowDialog` blocks and the file dialogs are modal, so they are constructed but never shown. The manual checklist is printed at the end of that suite. |
| OPEN-4 | Informational | **Windows-only checks do not run in this environment.** 22 assertions across four suites skip on Linux: 9 elevated primitives (`Test-Elevated.ps1`), 7 registry round-trips (`Test-Environment.ps1`), 5 live-WPF checks (`Test-WpfSmoke.ps1`) and 1 live PowerShell 5.1 run (`Test-PS51Compat.ps1`). Every one reports `[SKIP]` with its reason and is never counted as a pass. The logic above those primitives runs on any platform through in-memory stand-ins, so the gap is now the primitives themselves — `Get-`/`Set-PersistentPath`, the persistent-variable pair, the shortcut and registry-verb primitives, and WPF. An elevated Windows run closes it. |

Closed since the last revision: **OPEN-1** (see BUG-011 — custom detection is
now 5.1-safe, with a syntax audit and an executed 5.1 loader path) and
**OPEN-2** (`WindowsIntegration` is executed rather than merely recorded, with
per-feature DISABLED / VALIDATE / MANAGE modes and ownership-driven removal).
