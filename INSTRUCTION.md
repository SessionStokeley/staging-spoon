# Operating Guide

How to package an application for Intune with this tool.

This guide is for the administrator doing the packaging. It assumes you know
Windows and Intune, and assumes nothing about the tool's internals. For project
architecture and development, see [README.md](README.md).

---

## Quick start

For a straightforward application, in an **elevated** PowerShell window:

```powershell
# 1. Put the vendor installer and the three wrapper scripts in one folder
mkdir source
copy Setup.exe source\
copy templates\Install.ps1, templates\Uninstall.ps1, templates\Detection.ps1 source\
#    edit the variables at the top of each of the three scripts

# 2. Let the tool read the installer and ask only what it cannot work out
.\src\Build\New-PackageProject.ps1 -Root . -InstallerPath .\source\Setup.exe

# 3. Validate for real, then package
.\src\Build\Build-IntunePackage.ps1 `
    -SourcePath .\source `
    -ConfigPath .\package.json `
    -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe `
    -SystemContext
```

Step 3 exits **0** only when the package installed, was detected, uninstalled,
and stopped being detected — all as `NT AUTHORITY\SYSTEM`. Any other exit code
means do not ship it.

Then open `build\IntuneConfiguration.md` and copy its values into Intune, and
upload `build\*.intunewin`.

---

## Before you start

### Required

| Item | Why |
| --- | --- |
| The vendor installer | The payload, and the source of most of the information the tool derives |
| A Windows machine with PowerShell 5.1 or later | The validation actually installs and uninstalls the application |
| Local administrator rights | SYSTEM-context validation creates a scheduled task |
| `IntuneWinAppUtil.exe` | Microsoft's Win32 Content Prep Tool, which produces the `.intunewin` |
| Intune permissions to create a Win32 app | To finish the deployment |

### Recommended

| Item | Why |
| --- | --- |
| A clean VM with a snapshot | Validation installs **and uninstalls** the application on the machine you run it on. Never use your own workstation |
| Vendor documentation for silent switches | The tool guesses from the installer toolkit; the vendor is authoritative |
| A previous build's `PackageManifest.json` | Packaging a new version then reuses the decisions you already made |

### Optional

| Item | Why |
| --- | --- |
| Licensing keys or config files | Only if the application needs them at install time |
| An `InstallDelta.json` from an earlier run | Lets the tool reuse what it observed instead of asking |

> **The validation is destructive on the machine that runs it.** It installs the
> application, then uninstalls it. Run it on a disposable VM you can roll back.

---

## The commands

The tool is a set of PowerShell commands. There is no graphical application to
launch.

| Command | What it is for |
| --- | --- |
| `src\Build\Evaluate-Installer.ps1` | Inspects an installer and proposes as much of the configuration as the evidence supports |
| `src\Build\New-PackageProject.ps1` | Works out the configuration and asks you only what it cannot determine. Produces `package.json`. |
| `src\Build\Build-IntunePackage.ps1` | Validates the package end to end and builds the `.intunewin`. The command you ship from. |
| `src\Testing\Test-IntunePackage.ps1` | Runs only the install/detect/uninstall validation against a package you already have. Useful while iterating. |

There is also `src\Build\Evaluate-Package.ps1`, which checks a hand-written
`package.json` for obvious mistakes without installing anything.

---

## The full workflow

### 1. Build the source folder

The source folder becomes the `.intunewin` payload. It holds the vendor
installer and three wrapper scripts:

```
source\
  Setup.exe          your vendor installer
  Install.ps1        from templates\
  Uninstall.ps1      from templates\
  Detection.ps1      from templates\
```

Copy the three scripts from `templates\`. They already resolve their payload
relative to themselves, preserve the vendor's exit code, write a log, and
implement Intune's detection contract. `Install.ps1` takes the installer name
and its silent switches as parameters from `package.json`, so it needs no
per-package edits; `Uninstall.ps1` and `Detection.ps1` have a few criteria to
set at the top, below.

| Script | What to set |
| --- | --- |
| `Install.ps1` | Nothing per package. The installer name and its silent switches come from `package.json` (`SourceInstaller` and the install command's `-InstallerName` and trailing switches), passed in when the wrapper runs. Set them once in `package.json`, not in the script. |
| `Uninstall.ps1` | `$DisplayName` **or** `$ProductCode`, matching what the installer registers |
| `Detection.ps1` | `$DisplayName` (matched against the registry with `-like`, so `Example App*` handles a version suffix), `$ExpectedVersion` (a **minimum**, not an exact match), `$ExpectedFile` (relative to Program Files), `$ProgramFilesVariable` (set it to `ProgramFiles(x86)` for a 32-bit application) |

To find the uninstall details, install the application manually once and look
in `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` (and the
`WOW6432Node` copy for 32-bit applications).

### 1a. Evaluate the installer first (optional, recommended)

Before writing anything, have the tool inspect the installer and report what it
can establish:

```powershell
.\src\Build\Evaluate-Installer.ps1 -Root . -Path .\source\Setup.exe
```

It handles EXE, MSI, MSIX and BAT/CMD/PS1 wrappers. Given a wrapper it reports
the installer that the script actually runs, the switches the script passes,
and any registry, environment or file work the script does — flagged for your
review rather than acted on.

Every value is shown with where it came from and how far it is to be trusted:

```
INSTALL
  Installer File Name        VendorSetup-5.2.1-x64.exe
                             MEDIUM
  Silent Install Arguments   /VERYSILENT /NORESTART
                             MEDIUM
  Install Context            NOT DETECTED - administrator input required
```

**Nothing is invented.** A silent switch is populated only when something was
actually read — a wrapper script that passes it, an MSI (where `/qn` is defined
by Windows Installer), or a recognised installer toolkit. An installer that
offers no such evidence reports `NOT DETECTED`, because a guessed switch makes
a package that stops for a user who is not there. The same applies to uninstall
commands, install locations and detection rules.

Detection is proposed from the strongest available evidence, in this order:

| Evidence | Confidence | Why |
| --- | --- | --- |
| MSI product code | HIGH | Identifies the product exactly |
| Primary executable (+ version) | HIGH | Proves the files are present |
| Uninstall registration | MEDIUM | Removed on uninstall, but does not prove files exist |
| Install folder | LOW | Folders commonly survive an uninstall — flagged as unable to prove removal |

Uninstall is proposed from `QuietUninstallString` first, then an MSI product
code. A bare `UninstallString` is reported for review rather than silently given
a silent switch the vendor may not accept.

The command exits 1 while anything required is missing and lists what it is.
Add `-Capture .\build\TestResults\InstallDelta.json` once you have run a
validation: what was observed outranks anything read statically.

### 2. Let the tool read the installer

```powershell
.\src\Build\New-PackageProject.ps1 -Root . -InstallerPath .\source\Setup.exe
```

If you omit `-InstallerPath`, the tool scans the project. One installer is
selected automatically; several are listed for you to pick from.

It reports what it worked out and where each value came from:

```
Analysed ContosoReader-4.2.1-x64.exe
  Installer toolkit: NSIS

Discovered automatically
  Application Name           Contoso Reader
                             Derived from the installer file name
  Version                    4.2.1
  Architecture               x64
  Silent Install Arguments   /S
                             Standard silent switches for NSIS
```

### 3. Answer what is left

Only questions the tool could not settle are asked, and each states why:

```
  Install Context  [required]
    Why: Intune runs a package as SYSTEM or as the signed-in user. The wrong
         choice installs to the wrong place or fails outright.
    Automatic discovery could not resolve this.

    [1] System
    [2] User
    [s] Skip for now
    Choose:
```

Answers are saved in `.project\`. **Run the command again and it asks nothing.**

When it finishes it writes `package.json` and prints the build command to run
next. If anything required is still unanswered it exits 1 and says so; nothing
is silently guessed.

### 4. Validate and build

```powershell
.\src\Build\Build-IntunePackage.ps1 `
    -SourcePath .\source `
    -ConfigPath .\package.json `
    -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe `
    -SystemContext
```

Run this **elevated**, on a machine you can roll back.

### 5. Read the result

Open `build\IntuneConfiguration.md`. If its status is anything other than
`PRODUCTION READY`, do not upload the package — read
`build\TestResults\FailureReport.md` instead.

### 6. Create the app in Intune

Upload `build\*.intunewin` and copy the values from `IntuneConfiguration.md`
into the Intune app. See [Intune configuration](#intune-configuration) below.

---

## How the tool asks for information

### It discovers before it asks

Before any question, the tool works through its sources in order: the
installer's metadata, values derived from what it already knows, an
installation capture, the application if it is already installed on this
machine, a previous build, and the saved project. You are asked only when all
of those come up empty, or when the answer is a deployment policy that nothing
about the installer can decide.

### Answering a prompt

Prompts are numbered. Reusing a value the tool already holds is always listed
first, so the normal answer is a single digit:

| Key | Meaning |
| --- | --- |
| `1`, `2`, `3`… | Choose that option |
| `t` | Type a value. Only offered for fields that accept a path or free text |
| `s` | Skip for now. The question comes back next run; nothing is assumed |

There are no file-browser dialogs — this is a console tool. In practice you
rarely type a path, because installers and `IntuneWinAppUtil.exe` are found by
scanning, and anything else can be passed as a parameter (`-InstallerPath`,
`-CapturePath`, `-PreviousManifest`).

### How paths are shown

Every path the tool stores or displays uses forward slashes, including on
Windows:

```
Project     C:/Users/774641/Downloads/staging-spoon-claude
Source      C:/Users/774641/Downloads/staging-spoon-claude/source
Installer   C:/Users/774641/Downloads/staging-spoon-claude/source/Setup.exe
```

This is the same path Windows would write with backslashes — Windows accepts
either — and it is what keeps `package.json` readable, because a backslash path
doubles every separator as soon as it is written to JSON. You will not see
`C:\\Users\\...` in any file the tool produces.

Generated commands follow the same rule, so the install command reads
`-File ./Install.ps1`. If you type a path with backslashes it is accepted and
converted; a project saved by an older version repairs itself when you open it.

### What the status words mean

Each value the tool holds has a state. You will see these in the review and in
the project information listing:

| State | Meaning | What to do |
| --- | --- | --- |
| `FOUND` | Discovered automatically, not yet confirmed by you | Usually nothing; it is already in use |
| `CONFIRMED` | You supplied or accepted it | Nothing |
| `UNKNOWN` | The tool could not determine it safely | Answer the prompt, or supply it with a parameter |
| `CONFLICT` | Two sources disagree and neither outranks the other | Resolve it; the tool will not pick for you |
| `INVALID` | A value exists but failed validation | Correct it |
| `NOT_APPLICABLE` | Cannot apply to this package | Nothing |

In the readiness summary, anything not yet satisfied is shown as `Missing`,
split into **required** (blocks the build) and **recommended** (does not).

> `UNKNOWN` never means "no". The tool will not substitute a default for
> something it could not determine — it asks, or it blocks.

### When something is unknown, do not guess

Use, in order of preference:

1. **Re-run discovery** — supply the installer if you have not yet.
2. **Run a validation first** and feed the resulting capture back with
   `-CapturePath` (see below).
3. **Reuse a previous build** with `-PreviousManifest`.
4. **Check the vendor's documentation**, especially for silent switches.
5. **Type it** as a last resort.

Manual entry is the fallback, not the default. A typed value is recorded as
coming from you, so later reviews show that it was asserted rather than
observed.

---

## Information the tool reuses

The project directory `.project\` stores everything that has been established:
the installer reference, application name, version, architecture, install
location, executable, detection details, observed installation changes, and
every decision you made.

That information is reused when you:

- re-run `New-PackageProject.ps1` — it asks nothing that is already answered
- rebuild after changing the source
- come back to the project days later
- package a newer version of the same application

Because paths are stored relative to the project, you can move or copy the
whole project directory to another machine and it still resolves. If a
referenced file has moved inside the project, the tool finds it again by name
and content hash rather than failing.

---

## Installation capture

### What it is

During validation the tool takes a snapshot of the machine before the install
and another after it, and records the difference. That difference is written to
`build\TestResults\InstallDelta.json` and is the evidence of what the installer
actually did — as opposed to what it claims to do.

### What it observes

| Observed | Notes |
| --- | --- |
| Files created or removed | Under the watched paths |
| Registry keys added, removed or changed | |
| Uninstall registration | Display name, version, product code |
| Services | Added or removed |
| Scheduled tasks | Added or removed |
| Machine environment variables | Added or removed |
| Machine `PATH` entries | Added or removed |
| Shortcuts | Added or removed |

### What it does not observe

The tool does **not** capture file associations, context-menu entries, protocol
handlers, firewall rules, certificates, drivers, or per-user (`HKCU`) changes.
If your application depends on any of those, you must handle them yourself in
`Install.ps1` and verify them separately. The tool will not warn you that they
are missing, because it never saw them.

### What the capture is not

It is **not** a machine cloner. It does not replay every change it saw onto
target devices. It records what happened so that you can decide what the
deployment should reproduce, and so that detection can be based on something
real.

The tool also does not classify changes as "application-owned" versus "user
data" versus "unrelated noise". That judgement is yours — which is why a clean
VM matters.

### Using a capture

Capture happens as part of validation, so the sequence is:

```powershell
# 1. Validate once. This installs, snapshots, uninstalls, and writes the delta.
.\src\Build\Build-IntunePackage.ps1 -SourcePath .\source -ConfigPath .\package.json -SystemContext

# 2. Feed what it observed back into the project.
.\src\Build\New-PackageProject.ps1 -Root . -CapturePath .\build\TestResults\InstallDelta.json
```

After step 2 the install location, primary executable, uninstall registration,
PATH changes and shortcuts are all known, and the tool stops asking about them.
What it asks instead are the policy questions the capture raised:

```
Decisions raised by the installation capture

  Apply Machine PATH Change?  [optional]
    Why: Capture saw the installer change the machine PATH. Deployment policy
         decides whether to keep it.
    Observed during capture:
      C:\Program Files\Contoso\Reader\bin

    [1] Apply
    [2] Do not apply
```

Answering that records a **decision**. The observation itself is kept
separately and is never overwritten — so the record still shows that the
installer modifies the PATH even if you decide the package should not.

### When capture is worth it

Use it when the installer's behaviour is unclear: poor documentation, suspected
environment or PATH changes, unexplained Intune behaviour, or anything where
you are not sure what detection should look for.

Skip it when the installer is a plain MSI whose behaviour you already know.

---

## Install context: System or User

Intune runs a Win32 app either as `NT AUTHORITY\SYSTEM` or as the signed-in
user. This is the single most common cause of a package that works on your desk
and fails on a device.

Running an installer manually as an administrator is **not** the same as
running it as SYSTEM. As SYSTEM there is:

- no interactive desktop, so anything that shows a dialog hangs
- no user profile, so `%APPDATA%`, `%USERPROFILE%` and `HKCU` are not what you
  expect
- no mapped drives
- a different `PATH`

Choose **System** for machine-wide installs, which is most applications. Choose
**User** only when the application genuinely installs per-user.

> A per-user change seen during capture should not be assumed to belong in a
> SYSTEM deployment. Writing to `HKCU` as SYSTEM writes to the system account's
> hive, not to any real user's. If your application needs per-user
> configuration, handle it deliberately — an Active Setup entry, a run-once
> task, or a separate user-context app.

---

## Install, Uninstall and Detection

Three scripts are packaged, and Intune calls each at a different time.

**Install.ps1** runs the vendor installer silently and returns the vendor's own
exit code, and writes a log. It waits for the installer process itself and
nothing else: an installer that leaves a helper or updater running is behaving
normally, and waiting for one that never exits would stall the deployment until
the timeout.

**Uninstall.ps1** removes the application, using the product code or the
registered uninstall string.

**Detection.ps1** tells Intune whether the application is present. Intune's
contract is exact:

| Script behaviour | Intune's conclusion |
| --- | --- |
| Writes to STDOUT **and** exits 0 | Installed |
| Exits 0 with no output | Not installed |
| Non-zero exit, output or not | Not installed |

Detection drives everything you see in Intune and Company Portal: install
status, compliance reporting, and whether Intune retries. Get it wrong and the
application reinstalls in a loop or reports failure after a successful install.
The template never throws, because an unhandled exception is a non-zero exit,
which Intune reads as "not installed". That is also why its criteria section
holds plain text only. Anything that can fail - reading an environment
variable, joining a path, touching the disk - runs inside the guarded section,
because a statement above it that throws ends the script before the error
handling exists. If your detection stage reports `exit code 1` with nothing on
either stream, that is what happened: look for a typo or a parse error in
`Detection.ps1`. `$env:ProgramFiles(x86)` is the usual one - it is not valid
PowerShell, which is why the template names the variable as text instead.

---

## Local validation

Validation proves the whole round trip, not just that the installer ran:

```
Install
   -> succeeds with an expected exit code
Detection after install
   -> must report INSTALLED
Post-install validation
   -> declared files, registry keys and uninstall entries must exist
Uninstall
   -> succeeds
Detection after uninstall
   -> must report NOT INSTALLED
```

All of it must pass. An install that succeeds but is not detected causes an
endless reinstall loop; a detection that still reports "installed" after
uninstall makes the application impossible to remove through Intune. Both are
caught here rather than on a thousand devices.

To run validation alone, without rebuilding:

```powershell
.\src\Testing\Test-IntunePackage.ps1 `
    -SourcePath .\source `
    -ManifestPath .\source\PackageManifest.json `
    -SystemContext
```

Useful switches: `-SkipUninstall` while iterating on the install step,
`-DetectionSettleSeconds` when an installer finishes asynchronously, and
`-TimeoutSeconds` for slow installers.

The package is copied to a random directory under `%SystemRoot%\Temp` before it
runs, so a package that only works from its build location fails here instead
of on a device.

### Running one command on its own

A full cycle is a lot of machine time to spend on an install command that is
one switch away from working. To run a single command and see everything it
produced:

```powershell
.\src\Testing\Invoke-PackageCommand.ps1 -SourcePath .\source -Command Install
.\src\Testing\Invoke-PackageCommand.ps1 -SourcePath .\source -Command Detection
.\src\Testing\Invoke-PackageCommand.ps1 -SourcePath .\source -Command Uninstall
```

It runs the same string the cycle runs and the same string you enter into
Intune, and prints the exit code, STDOUT and STDERR in full. Add
`-SystemContext` to run it the way Intune will, and `-Staged` to run it from a
temporary copy the way the full cycle does.

This never produces a `.intunewin`, and one command passing is not a validated
package. Use it to get each command working, then run the full cycle.

**When detection reports `exit code 1` with nothing on either stream**, the
script failed before its own error handling ran. Run it directly to see the
parser's message, which nothing else will show you:

```powershell
powershell.exe -NoProfile -File .\source\Detection.ps1
```

---

## SYSTEM validation

Add `-SystemContext` and every stage runs as `NT AUTHORITY\SYSTEM` through a
scheduled task, which is how Intune runs a System-context app. This requires an
elevated session.

Always use it before shipping. It is what surfaces:

- installers that need an interactive desktop
- dependencies on a user profile, `%APPDATA%` or `HKCU`
- dependencies on a mapped drive
- `PATH` differences between your session and SYSTEM
- permission problems masked by running as an administrator
- hard-coded paths that only exist on your machine

If the manifest says `InstallBehavior=System` and you omit `-SystemContext`,
the tool warns you that the run does not prove what you need it to prove.

---

## Building the .intunewin

```
source folder (installer + Install.ps1 + Uninstall.ps1 + Detection.ps1)
        |
        v
  Win32 Content Prep Tool
        |
        v
      .intunewin
```

The build runs validation **first**. If validation fails, no `.intunewin` is
produced — you cannot accidentally ship an unvalidated package.

If `IntuneWinAppUtil.exe` cannot be found, the build warns and continues
without producing the package file; pass `-IntuneWinAppUtilPath` to fix that.

`-SkipValidation` exists for producing a package without installing anything.
A package built that way is never marked production ready, and should not be
deployed.

The `.intunewin` is only the **content**. It carries no commands, no detection
rules and no requirements — those are Intune settings you enter separately,
which is what the generated configuration is for.

---

## Intune configuration

`build\IntuneConfiguration.md` lists the exact values to enter. They map to the
Intune Win32 app pages like this:

| Intune page and field | Value from the tool |
| --- | --- |
| App information -> Name | Application name |
| App information -> App version | Application version |
| Program -> Install command | `InstallCommand.txt`, verbatim |
| Program -> Uninstall command | `UninstallCommand.txt`, verbatim |
| Program -> Install behavior | Install behavior (System or User) |
| Program -> Device restart behavior | Restart behavior |
| Program -> Return codes | The listed return codes, including any reboot codes |
| Requirements -> Operating system architecture | Architecture |
| Requirements -> Minimum operating system | Minimum operating system |
| Detection rules -> Rules format | Use a custom detection script |
| Detection rules -> Script file | The contents of `Detection.ps1` |
| Detection rules -> Run script as 32-bit | As stated; yes only for x86 packages |
| Detection rules -> Enforce script signature check | As stated; No |

Two Intune settings are not generated, because nothing about the package
determines them: **Run detection script as the logged-on user** (No for a
System-context app) and the app's **assignments**.

Copy the commands **exactly**, including quotes. The file also contains a
command sanity check confirming that the commands it tells you to enter are the
same strings that were tested. If that check fails, the package is not marked
production ready — a command that was changed after testing has not been
tested.

`PackageHash.txt` holds the SHA256 of the `.intunewin`, so you can confirm
later that what is in Intune is what you validated.

---

## Packaging a new version

Do not start a new project. Reuse the previous one:

```
existing project
      |
      v
select the new installer      New-PackageProject.ps1 -InstallerPath <new>
      |
      v
carry forward the last build  -PreviousManifest <old PackageManifest.json>
      |
      v
review what changed
      |
      v
answer only what is new
      |
      v
validate and build
```

```powershell
.\src\Build\New-PackageProject.ps1 -Root . `
    -InstallerPath .\source\ContosoReader-4.2.2-x64.exe `
    -PreviousManifest .\build\PackageManifest.json
```

The previous build supplies the deployment decisions — install context, restart
behaviour, commands, detection method. The **new installer still wins on
identity**, so the version does not silently stay at the old number. Anything
that changed is reported:

```
Carried forward from PackageManifest.json
  7 values reused
  Changed: Version                4.2.1 -> 4.2.2
```

Raise the package version yourself if you are rebuilding the same application
version, so the two builds remain distinguishable.

---

## Logs and reports

| Location | Contents |
| --- | --- |
| `build\IntuneConfiguration.md` | The values to enter in Intune, and the status |
| `build\IntuneConfiguration.json` | The same values, for a pipeline |
| `build\IntuneValidationReport.html` | Full validation evidence: every stage, exact command, exit code and output. Open this first when something fails |
| `build\TestResults\ValidationResult.json` | Per-stage pass or fail, and the execution context |
| `build\TestResults\InstallDelta.json` | What actually changed on the machine |
| `build\TestResults\FailureReport.md` | Written only on failure: classification and how to reproduce it |
| `build\PackageManifest.json` | Authoritative description of what was packaged |
| `build\PackageHash.txt` | SHA256 of the `.intunewin` |
| `%ProgramData%\IntuneDeployment\Logs` | Logs written by `Install.ps1` and `Uninstall.ps1`, on the machine that ran them |
| `.project\decisions.json` | Every decision you made |
| `.project\facts.json` | Every observation, with its source |
| `.project\evidence.json` | The above plus the full change history |

When a failure needs escalating, collect the HTML report, `FailureReport.md`,
`InstallDelta.json`, and the wrapper log from `%ProgramData%`.

### Failure classifications

`FailureReport.md` names the failure mode, which tells you where to look:

| Classification | Usually means |
| --- | --- |
| `PACKAGING_FAILURE` | The package was rejected before anything ran |
| `INSTALLER_FAILURE` | The vendor installer itself failed |
| `SYSTEM_CONTEXT_FAILURE` | Works as a user, fails as SYSTEM |
| `USER_CONTEXT_FAILURE` | Needed a user profile that was not there |
| `PERMISSION_FAILURE` | Access denied |
| `DETECTION_FAILURE` | Installed but not detected, or detected after removal |
| `RETURN_CODE_FAILURE` | An exit code that was not declared as successful |
| `CONTEXT_FAILURE` | Wrong architecture or install scope |
| `PATH_FAILURE` | A path that did not exist where the package ran |
| `COMMAND_FAILURE` | The command itself was malformed |
| `DEPENDENCY_FAILURE` | Something the application needs was missing |
| `REBOOT_FAILURE` | A reboot requirement was mishandled |
| `APPLICATION_FAILURE` | Installed, but the application itself is broken |
| `UNKNOWN` | Not enough evidence; read the HTML report |

Reproduce first, fix second, rebuild third.

---

## Common problems

### Validation appears to hang at "[3/9] Executing install command"

Two separate causes produced this, both fixed. Each line is timestamped, so the
last one printed tells you where a run stopped, and the stage states its
timeout when it begins.

**The application installed fine but the console never came back.** The stage
captures the installer's output through a pipe. That pipe is inherited by
whatever the installer starts, and by whatever *those* start. Reading it to the
end waits for every copy of the handle to close — so a vendor updater or helper
that deliberately keeps running held it open, and the wait never ended. The
exit code had already been collected; the run then blocked on output that would
never finish arriving, and no timeout covered that wait. Output is now read as
it arrives and the *process* is what is timed, so a resident helper cannot
block anything.

**The wrapper waited for the installer's descendants.** `Install.ps1` used
`Start-Process -Wait`, which on Windows waits for the process *and every
descendant it started*. An installer that leaves a helper or updater resident —
normal behaviour, not a failure — therefore never let the wait return, and the
stage sat until the timeout fired. `Uninstall.ps1` did the same, and also
waited for any process named `msiexec` to disappear, which never happens
because `msiexec.exe` is the long-lived Windows Installer service.

Both wrappers now run the installer exactly as a command prompt would — no
shell, no redirection, no window handling — and wait for the installer process
alone. Its exit code is what says the installation finished. Anything it leaves
running is left running, and is never terminated.

```
[16:07:28] [INFO] Starting installer: C:/.../Setup.exe /S
[16:07:28] [INFO] Installer running as PID 733
[16:07:28] [INFO] Installer process exited with code 0
```

### Cancelling a run without closing the window

Every stage watches for a cancel signal. The path is printed when validation
starts:

```
[08:05:51]   Cancel  : C:/.../build/TestResults/cancel.request
```

Create that file and the current stage stops, terminates the process tree it
started, and unwinds through normal cleanup — the scheduled task is removed and
the report still gets written. From another window:

```powershell
New-Item -Path .\build\TestResults\cancel.request -ItemType File
```

The stage is recorded as `CANCELLED`, which blocks production readiness the
same way a failure does. The file is cleared automatically at the start of the
next run. Ctrl+C still works, but it is no longer the only way out.

If your installer deliberately leaves a helper or updater running, that is
expected and blocks nothing. The wrapper waits for the installer process and
nothing else, because the installer's own exit code is what says it finished.

To tune the waiting, edit `$TimeoutSeconds` at the top of `Install.ps1` — how
long the vendor installer itself may take. The validation run's own budgets are
`-TimeoutSeconds`, `-DetectionTimeoutSeconds` and `-DetectionSettleSeconds`
(the quiet period after the installer, for applications that finish
registering asynchronously).

A stage that runs out of time is reported as `TIMED OUT` rather than a generic
failure, so the report distinguishes "never finished" from "finished badly".

### Install fails with exit 1 and nothing obvious in the summary

Exit 1 from the wrapper usually means the wrapper itself stopped before the
vendor installer ever started. Open the `## Output` section of
`build\TestResults\FailureReport.md` — the wrapper logs every step, so the last
line before the failure names the cause. The same lines are in
`%ProgramData%\IntuneDeployment\Logs`.

The most common cause is the install command naming an installer the package
does not ship — `SourceInstaller` and the `-InstallerName` in the install
command disagreeing with the file that is actually present. The wrapper cannot
find it and stops. Pre-build validation checks the command against the manifest
and blocks the build, so the message to look for is:

```
[FAIL] Install.ps1 targets the packaged installer
       The install command runs 'Setup.exe' but the package ships '<your installer>'
```

The fix is to regenerate `package.json` with `New-PackageProject.ps1` against
the real installer, rather than editing the wrapper: the installer name and its
silent switches live in `package.json` and are passed to `Install.ps1` when it
runs. Nothing about the installer is written inside the template.

The second most common cause is the silent switches themselves. `/S` is NSIS,
`/VERYSILENT` is Inno, `/qn` is MSI — there is no universal set. Exit 1 from a
vendor installer given switches it does not understand is common; use the ones
the vendor documents, set in `package.json`.

### The installer works manually but fails through Intune

Almost always context. Re-run validation with `-SystemContext`; if it fails
there, you have reproduced it locally. Look for an interactive prompt, a user
profile dependency, or a mapped drive.

### Detection says "Not installed" after a successful install

The script says why. When it finds nothing it writes its reasoning to STDERR,
which Intune ignores and the validation harness records, so the report and the
console both carry it:

```
Not detected. Criteria checked:
  - No registry entry matched DisplayName 'Vendor Application'.
  - Registered names containing 'Vendor': Vendor Application 5.2.1 (64-bit)
  - File not present: C:\Program Files\Vendor\Application\App.exe
```

Read the candidate list. **The usual cause is `$DisplayName` not matching what
the installer registered** — installers routinely append an edition or a
version, so `Example App` does not match `Example App 5.2.1 (64-bit)`. Either
use the registered name exactly or use a wildcard: `Example App*`.

The other causes the reasoning distinguishes:

| What it says | What it means |
| --- | --- |
| `is version X, below the expected Y` | `$ExpectedVersion` is above what is installed. It is a minimum, not an exact match |
| `matched but registers no DisplayVersion` | The application has no version in the registry; detect it by file instead |
| `Registry view not readable from this process` | A 32-bit PowerShell cannot see `WOW6432Node` by that name |
| `Nothing registered contains '<name>'` | Nothing by that name is installed machine-wide. A per-user install is invisible to SYSTEM |
| `Environment variable '<name>' is not set` | `$ProgramFilesVariable` names a variable that does not exist |

To run it on its own against a machine where the application is installed:

```powershell
.\src\Testing\Invoke-PackageCommand.ps1 -SourcePath .\source -Command Detection
```

`InstallDelta.json` from a validation run shows what the installer actually
registered, if you need to compare.

Pre-build validation blocks a package whose criteria are still the template's
example values, so this cannot be caused by a `Detection.ps1` nobody edited:

```
[FAIL] Detection criteria are filled in
       Detection.ps1 still carries the template's example values: $DisplayName, $ExpectedVersion
```

### Detection says "Installed" when the application is gone

Detection is matching something the uninstall leaves behind — an empty folder
or an orphaned registry key. Make the check more specific, usually by testing
for the executable and its version rather than a directory.

### The application reinstalls over and over

Detection is returning "not installed" after a successful install. Same fix as
above. A detection script that throws produces exactly this, which is why
nothing in the template runs outside its error handling.

### PowerShell `-File` path errors

The path after `-File` must be relative to the package and quoted:
`-File ".\Install.ps1"`. Pre-build validation rejects a command pointing at a
script that is not in the package.

### Quoting or duplicate-argument errors

Let the tool generate the commands rather than writing them by hand. It builds
them from structure and renders them once, and flags duplicate switches and
missing `-NonInteractive`.

### PATH changes do not appear on target devices

Either the installer's PATH change was not captured, or you answered "Do not
apply" to the PATH decision. Check `InstallDelta.json` for what was observed
and `.project\decisions.json` for what you chose. Note that a process started
before the change will not see the new PATH until it restarts.

### "InstallBehavior=User but this run uses -SystemContext"

The package declares a per-user install, but validation is running as SYSTEM.
A per-user installer driven as SYSTEM writes into the service account's
profile, so it can appear to succeed while being invisible to every real user —
and detection then reports "not installed" on every device.

Decide which is true. If the application installs machine-wide, set
`InstallBehavior` to `System`. If it genuinely installs per-user, drop
`-SystemContext` so validation runs in the context Intune will actually use,
and set the Intune app's install behaviour to User to match.

### User-specific configuration is missing

Expected. A SYSTEM install cannot write a real user's `HKCU` or `%APPDATA%`.
Handle per-user configuration deliberately; see
[Install context](#install-context-system-or-user).

### The application installs but will not launch

The package is fine; the application is not. Check for a missing runtime, and
confirm on the reference machine that the application starts after a manual
install. Look for `APPLICATION_FAILURE` in the failure report.

### Uninstall fails

Check `$DisplayName` or `$ProductCode` in `Uninstall.ps1` against what the
installer registered — `InstallDelta.json` records it. Remember 32-bit
applications register under `WOW6432Node`.

### The installer requires interaction

It cannot be deployed as-is. Find the silent switches in the vendor's
documentation. Pre-build validation rejects `/qb`, `/passive` and similar,
because they need a desktop that Intune does not provide.

### The installer starts a child process and returns early

The deployment is reported as finished while installation is still running.
`Install.ps1` waits for known installer child processes; increase
`-DetectionSettleSeconds` if detection runs before the application has settled.

### A reboot causes unexpected behaviour

Check that the reboot codes (1641, 3010) are in the declared return codes and
that restart behaviour is what you intend. The tool preserves those codes by
default; translating them to 0 should be a deliberate choice.

### The build succeeds but deployment fails

Confirm the commands in Intune match `InstallCommand.txt` and
`UninstallCommand.txt` character for character, and that the `.intunewin` you
uploaded matches `PackageHash.txt`. A command edited in the Intune console after
testing is a command that was never tested.

---

## What this tool does not do

Stated plainly so you do not rely on it:

- It does not capture file associations, context-menu entries, protocol
  handlers, firewall rules, certificates, drivers, or per-user (`HKCU`) changes.
- It does not classify observed changes as application-owned, user data or
  unrelated noise — use a clean VM so there is little noise to classify.
- It does not flag high-risk installation behaviour for special review.
- It has no manual "start capture / stop capture" mode; snapshots are taken
  around the automated install during validation.
- It does not upload to Intune or talk to Microsoft Graph. Creating the app is
  a manual step.
- It does not manage dependencies or supersedence.
- It does not test on real enrolled devices. Validate the deployment in Company
  Portal on a pilot device before broad assignment.
