# Debugging Log

Running record of defects found in this project. Newest first.
Entries are kept after they are closed so the history is not lost.

Severity: **Critical** (data loss / security) · **High** (feature broken) ·
**Medium** (works but wrong in cases) · **Low** · **Informational**

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
| OPEN-1 | Medium | **`Custom` detection may not load on Windows PowerShell 5.1.** `Import-PowerShellDataFile` evaluates the file through `SafeGetValue()`. PowerShell 7 accepts a `ScriptBlock` value; 5.1 is stricter and may reject it, which would make the whole configuration unloadable — not just custom detection. Intune runs 5.1. Verified working on 7.4.6; **not verified on 5.1**, which needs a Windows check. If it fails there, the fix is to express custom detection as a script path rather than an inline scriptblock. |
| OPEN-2 | Medium | **`WindowsIntegration` is recorded but never executed.** Shortcuts, file associations, context-menu entries, services and scheduled tasks are captured in the configuration and surfaced as an informational validation finding, but no engine code applies them. Intentional for now; listed so the gap is not mistaken for a defect. |
| OPEN-3 | Low | **The WPF Studio has never been executed.** Its XAML parses and all 77 named controls resolve against the code-behind, but WPF cannot run in the Linux dev container. Needs a smoke test on Windows. The console wizard is the fully exercised path. |
| OPEN-4 | Informational | **Elevated PATH and variable tests do not run in CI here.** 7 of 58 environment assertions require Windows and administrator rights and skip on Linux. They are the ones covering the actual registry round-trips, so a Windows run is needed before trusting BUG-001, BUG-002, BUG-003 and BUG-006 end to end. |
