# Intune Win32 Packaging Framework

Configuration-driven Microsoft Intune Win32 application packaging. Supports EXE and MSI installers with optional PATH and environment variable management.

## Structure

```
IntuneApp\
├── New-IntuneApp.ps1        # Studio entry point (interactive generator)
├── Install.ps1              # Installation script
├── Uninstall.ps1            # Uninstallation script
├── Detection.ps1            # Detection script (used by Intune)
├── Configuration.psd1       # All app-specific settings
├── Test-Local.ps1           # Local testing helper
├── Studio\                  # Interactive configuration generator
│   ├── Analyzer.ps1         # Read-only installer analysis
│   ├── ConfigModel.ps1      # Configuration schema and psd1 round-trip
│   ├── ConfigGenerator.ps1  # Model -> .psd1 serializer
│   ├── ConfigValidator.ps1  # Graded validation (error/warning/info)
│   ├── Preview.ps1          # Plain-language description of a config
│   ├── Prompt.ps1           # Console prompt primitives
│   ├── Wizard.ps1           # The question flow
│   ├── Runner.ps1           # Approval gate and engine hand-off
│   └── Studio.ps1           # WPF graphical front end (Windows)
├── Helpers\
│   ├── ConfigLoader.ps1     # 5.1-safe config loading, custom detection
│   ├── Environment.ps1      # PATH and environment variable helpers
│   └── WindowsIntegration.ps1 # Shortcuts, context menus, associations, services, tasks
├── Tests\
│   ├── Run-AllTests.ps1     # Runs every suite, one table
│   ├── Test-Environment.ps1 # PATH/environment tests
│   ├── Test-Studio.ps1      # Generator tests
│   ├── Test-Detection.ps1   # Intune detection contract tests
│   ├── Test-Lifecycle.ps1   # Install/uninstall against a fake registry
│   ├── Test-Integration.ps1 # Windows integration modes and ownership
│   ├── Test-PS51Compat.ps1  # Windows PowerShell 5.1 compatibility
│   ├── Test-Gui.ps1         # Studio GUI data layer, without WPF
│   ├── Test-WpfSmoke.ps1    # XAML, control binding, live WPF window
│   └── Test-Elevated.ps1    # Real registry/shell primitives (elevated Windows)
└── Files\
    └── <installer>          # Your EXE or MSI
```

## Quick Start

Let the Studio build the configuration for you:

```powershell
cd IntuneApp
.\New-IntuneApp.ps1                      # console wizard
.\New-IntuneApp.ps1 -Mode Gui            # graphical (Windows)
```

Or configure by hand:

1. Place your installer in `IntuneApp\Files\`
2. Edit `Configuration.psd1` with your application details
3. Validate: `.\Test-Local.ps1 -Mode Validate`
4. Test locally as Administrator: `.\Test-Local.ps1 -Mode Install`
5. Package with `IntuneWinAppUtil.exe -c IntuneApp -s Install.ps1 -o Output`

## Interactive Configuration Generator

The Studio analyzes an installer, asks what it needs, and writes the
`Configuration.psd1`. It does not install anything: generating a configuration
and running one are separate, explicitly approved steps.

```
Select installer -> Analyze -> Questions -> Generate Config.psd1
   -> Review -> Validate -> Approve -> Run -> Validate -> Build
```

The `.psd1` is the source of truth. The wizard is just a convenient way to
write it, and the existing engine (`Install.ps1`, `Uninstall.ps1`,
`Detection.ps1`) is what executes it.

### Modes

| Command | What it does |
|---|---|
| `.\New-IntuneApp.ps1` | Console wizard: analyze, ask, generate |
| `.\New-IntuneApp.ps1 -Mode Gui` | Graphical version of the same flow (Windows only) |
| `.\New-IntuneApp.ps1 -Mode Analyze -InstallerPath <file>` | Analysis only; writes nothing |
| `.\New-IntuneApp.ps1 -Mode Validate` | Check a configuration |
| `.\New-IntuneApp.ps1 -Mode Preview` | Describe what a configuration would do |
| `.\New-IntuneApp.ps1 -Mode Summary` | One-screen deployment summary for review |
| `.\New-IntuneApp.ps1 -Mode DryRun` | Print every change the engine would make, and make none |
| `.\New-IntuneApp.ps1 -Profile Standard` | Start the wizard from a named profile |
| `.\New-IntuneApp.ps1 -Mode Run` | Validate, review, **approve**, then run the engine |
| `.\New-IntuneApp.ps1 -Mode Build` | Build the `.intunewin` |
| `.\New-IntuneApp.ps1 -OpenConfig <file>` | Re-open an existing configuration to edit |

### What the analyzer reads

Metadata only — the installer is never launched:

- Name, publisher, version, architecture (from the PE header and version resource)
- SHA256 hash and Authenticode signature status
- Installer technology (Inno Setup, NSIS, WiX Burn, InstallShield, Squirrel, MSI and others)
- Suggested silent switches for that technology, with a confidence level
- MSI `ProductCode`, `ProductName` and `Manufacturer` from the MSI property table
- Candidate CLI directories, when the application is already installed

Recommendations carry `High`, `Medium` or `Low` confidence. Anything below
`High` is called out so you can verify it against vendor documentation rather
than trusting a guess.

### Safety boundary

```
ANALYSIS -> CONFIGURATION -> REVIEW -> APPROVAL -> EXECUTION
```

While you are answering questions, nothing is installed, no PATH or registry
value is touched, no shortcut or service is created, and no package is built.
The wizard's only output is a file.

`-Mode Run` shows the exact configuration path, lists only the effects that
configuration actually enables, and requires you to type `run`. Validation
errors block execution; warnings do not. Automation can pass `-Force` to skip
the prompt, which should only be used where approval has already been obtained.

The test suite enforces this boundary: it inspects the generator's source (with
comments stripped) and fails if it ever gains a call that starts a process,
writes the registry, modifies PATH, invokes the engine, or builds a package.

### Editing the generated file

The wizard prints the real `.psd1` with line numbers and syntax colouring, not
a summary. You can edit the file directly at any point and re-open it:

```powershell
.\New-IntuneApp.ps1 -OpenConfig .\Configuration.psd1
```

Re-opening merges the file over the schema defaults, so older configurations
still load, missing sections get sensible defaults, and hand-written keys the
Studio does not know about are preserved. Saving is byte-stable: re-saving an
unchanged configuration produces an identical file, so diffs stay clean.

### Installation profiles

A profile pre-selects which features a package uses. It only decides which
questions matter; every name, target and path is still asked for.

| Profile | Turns on |
|---|---|
| `Minimal` | Installer, Detection |
| `Standard` | Installer, Detection, Desktop shortcut, Start Menu shortcut |
| `Full` | Standard plus context menu, file associations, PATH and environment variables |

```powershell
.\New-IntuneApp.ps1 -Profile Standard
```

### Dry run

`-Mode DryRun` hands the real engine its own `-TestMode`, so what is printed is
what the engine would actually do rather than a second description of it.

```
[DRY-RUN] Would run: C:\Build\IntuneApp\Files\Setup.exe /S
[DRY-RUN] Would add to system PATH: C:\Program Files\App\bin
[DRY-RUN] Would create Machine variable JAVA_HOME = C:\App\jdk
[DRY-RUN] Would create shortcut: C:\Users\Public\Desktop\App.lnk -> C:\Program Files\App\App.exe
[DRY-RUN] Would register context menu verb: HKLM:\SOFTWARE\Classes\.abc\shell\Company.App.Open
```

`Install.ps1 -TestMode` and `Uninstall.ps1 -TestMode` do the same directly. Both
validate the configuration, resolve every path, and read the machine to say
whether each change is actually needed — without writing anything.

## Intune Configuration

| Setting | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1` |
| Install behavior | System |
| Detection | Custom script: `Detection.ps1` |

## Configuration.psd1

All application-specific settings live in one file. The scripts are generic.

### Installer

```powershell
Installer = @{
    Type      = "EXE"         # EXE or MSI
    File      = "Setup.exe"   # Filename in Files\ directory
    Arguments = "/quiet /norestart"
}
```

For MSI, the framework runs `msiexec.exe /i <file> <arguments>`.

### Uninstaller

```powershell
# EXE uninstaller (supports absolute paths for registry-discovered uninstallers)
Uninstaller = @{
    Type      = "EXE"
    File      = "C:\Program Files\App\uninstall.exe"
    Arguments = "/quiet /norestart"
}

# MSI uninstaller
Uninstaller = @{
    Type        = "MSI"
    ProductCode = "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
}
```

### Detection Methods

**File** — verify an executable exists with optional version check:
```powershell
Detection = @{
    Type           = "File"
    Path           = "C:\Program Files\Example"
    FileName       = "Example.exe"
    MinimumVersion = "1.0.0.0"   # Optional
}
```

**Registry** — verify a registry value exists:
```powershell
Detection = @{
    Type          = "Registry"
    RegistryPath  = "HKLM:\SOFTWARE\Company\Example"
    ValueName     = "InstalledVersion"
    ExpectedValue = "1.0.0"      # Optional
}
```

**MSI** — verify a ProductCode is registered:
```powershell
Detection = @{
    Type        = "MSI"
    ProductCode = "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
}
```

**Custom** — PowerShell, as a string or a script file:
```powershell
# Inline
Detection = @{
    Type   = "Custom"
    Script = 'Test-Path "C:\Program Files\Example\Example.exe"'
}

# Or a .ps1 shipped in the package (path is relative to the package root)
Detection = @{
    Type       = "Custom"
    ScriptFile = "Detect-Example.ps1"
}
```

The **last** value the script emits is the verdict, so it may print progress
before deciding.

The older `ScriptBlock = { ... }` form still works, but prefer the two above.
Windows PowerShell 5.1 — which is what Intune's Management Extension runs —
cannot load a script-block literal from a `.psd1` at all, and the failure takes
the whole configuration with it rather than just detection. The framework falls
back to reading the file's syntax tree so those configurations keep working, but
`Script` and `ScriptFile` need no fallback. Validation points this out.

### Exit Codes

```powershell
SuccessExitCodes = @(0, 3010)   # 3010 = success, reboot required
```

## Environment & PATH Management

Enable PATH and environment variable configuration by setting `Environment.Enabled = $true` in Configuration.psd1.

### System PATH

Adds directories to the machine-wide PATH (applies to all users):
```powershell
Environment = @{
    Enabled = $true
    SystemPath = @{
        Enabled           = $true
        Entries           = @(
            "C:\Program Files\Example\bin"
            "C:\Program Files\Example\tools"
        )
        AddIfMissing      = $true
        RemoveOnUninstall = $true
    }
}
```

### User PATH

Adds directories to the current user's PATH:
```powershell
UserPath = @{
    Enabled           = $true
    Entries           = @("C:\Program Files\Example\bin")
    AddIfMissing      = $true
    RemoveOnUninstall = $true
}
```

**Warning:** When Intune runs as SYSTEM, User PATH changes only affect the Default user profile, not existing user accounts. The framework logs this warning during installation.

### Environment Variables

```powershell
Variables = @(
    # Append to a list variable: existing entries are kept.
    @{
        Name              = "CLASSPATH"
        Value             = "C:\Program Files\Example\lib"
        Scope             = "Machine"      # Machine or User
        Mode              = "Append"       # Append, Prepend, or Set
        Expandable        = $false
        RemoveOnUninstall = $true
    }
    # Replace a single-value variable.
    @{
        Name              = "JAVA_HOME"
        Value             = "C:\Program Files\Java\jdk-21"
        Scope             = "Machine"
        Mode              = "Set"
        Expandable        = $false
        RemoveOnUninstall = $true
    }
)
```

#### Mode

| Mode | Behavior | Use for |
|---|---|---|
| `Append` | Adds the value to the variable's `;`-separated list, keeping every existing entry | List variables: `CLASSPATH`, `PSModulePath`, `LIB` |
| `Prepend` | As `Append`, but the new entry goes first so it takes priority | List variables where order matters |
| `Set` | Replaces the whole value | Single-value variables: `JAVA_HOME` |

`Append` and `Prepend` are idempotent — re-running an install never duplicates
an entry. Matching ignores case and trailing slashes, and treats `%VAR%` as
equal to its expanded form, so a directory is never added twice under two
spellings.

Values containing `%VAR%` are stored as `REG_EXPAND_SZ` and are never written
back expanded.

#### What uninstall does

Uninstall removes only this package's own contribution, using the ownership
recorded at install time:

| At install | At uninstall |
|---|---|
| Appended to a variable that already existed | That entry is removed; every other entry stays |
| Created a variable that did not exist | The variable is deleted |
| Replaced an existing value (`Set`) | The pre-install value is restored |

A variable that existed before the package is never deleted, and its other
entries are never disturbed.

### How It Works

- Uses Windows registry APIs with `ExpandString` type (not `setx`) to preserve `%SystemRoot%`, `%ProgramFiles%`, and other expandable variables
- Compares paths case-insensitively with trailing slash normalization to prevent duplicates
- Broadcasts `WM_SETTINGCHANGE` after modification so running applications detect the change
- Tracks which entries were added in `C:\ProgramData\IntunePackagingStudio\State\<AppName>\environment-state.json`
- Uninstall only removes entries the package added; pre-existing entries are never touched
- All operations are idempotent

### Install Workflow

```
Install Application
    -> Verify Installation (Detection)
    -> Configure System PATH
    -> Configure User PATH
    -> Set Environment Variables
    -> Broadcast Environment Change
    -> Validate PATH Registration
    -> Complete
```

PATH failures log a warning but do not fail the install. The application itself is the primary success criterion.

### Uninstall Workflow

```
Clean Up PATH Entries (package-owned only)
    -> Clean Up Environment Variables
    -> Broadcast Environment Change
    -> Run Uninstaller
    -> Verify Removal (Detection)
    -> Remove State Tracking File
    -> Complete
```

## Windows Integration

Shortcuts, Explorer context-menu verbs, file associations, services and
scheduled tasks. Set `WindowsIntegration.Enabled = $true`, then choose a mode
per feature.

### Three modes

| Mode | What the framework does |
|---|---|
| `DISABLED` | Nothing at all. |
| `VALIDATE` | Checks the installer created it, and reports. Never creates, never removes. |
| `MANAGE` | Creates it, records that it owns it, and removes it on uninstall. |

Most commercial installers create their own shortcuts and associations. For
those, `VALIDATE` confirms the installer did its job without the framework
duplicating it and then deleting the vendor's copy on uninstall.

Configurations written before modes existed still work: `Enabled = $true` on a
feature means `MANAGE`.

### Required

`Required = $true` makes a failure to create that integration fail the whole
install. `Required = $false` logs a warning and carries on.

### Ownership

Nothing is removed unless this package's own state file records that this
package created it.

| At install | At uninstall |
|---|---|
| The framework created it (`MANAGE`) | Removed |
| It already existed when `MANAGE` ran | Left alone, and never claimed as owned |
| The feature is in `VALIDATE` | Never touched — nothing was recorded |
| No state file | Nothing is removed; the names are logged |
| A file association replaced an extension default | The previous handler is restored |

Ownership is tracked in
`C:\ProgramData\IntunePackagingStudio\State\<AppName>\integration-state.json`.

Uninstall removes only the key it created — an application-specific verb, or a
ProgID it registered. It never deletes a shared parent such as `Classes\*` or
`Classes\Directory`, so unrelated software is unaffected.

### Shortcuts

```powershell
DesktopShortcut = @{
    Mode             = "MANAGE"
    Required         = $true
    Name             = "Example"
    Target           = "C:\Program Files\Example\Example.exe"
    Arguments        = ""
    WorkingDirectory = "C:\Program Files\Example"
    Icon             = "C:\Program Files\Example\Example.exe"
    Location         = "PublicDesktop"   # or UserDesktop
}

StartMenuShortcut = @{
    Mode     = "MANAGE"
    Name     = "Example"
    Target   = "C:\Program Files\Example\Example.exe"
    Folder   = "Company\Example"   # subfolder under Programs
    Location = "AllUsers"           # or CurrentUser
}
```

Intune runs as SYSTEM, where "the current user" is not a real person's profile,
so `PublicDesktop` and `AllUsers` are the defaults — they are the locations that
produce a shortcut every user can see.

A shortcut is never created pointing at a target that does not exist. One that
looks installed and fails when clicked is worse than none.

### Context menu

```powershell
ContextMenu = @{
    Mode    = "MANAGE"
    Entries = @(
        @{
            Name       = "Open with Example"
            Verb       = "Company.Example.Open"
            Target     = "FILE"              # FILE, FOLDER, DIRECTORY or ALL_FILES
            Extensions = @(".abc", ".xyz")
            Executable = "C:\Program Files\Example\Example.exe"
            Arguments  = '"%1"'
        }
    )
}
```

`Verb` must be application-specific. It is what makes uninstall able to remove
this package's key and nothing else, so an entry without one is rejected.

`FILE` with `Extensions` listed attaches per extension. `FILE` without them, and
`ALL_FILES`, attach to `Classes\*` — every file on the machine — so validation
warns when a configuration asks for that.

An existing verb is never overwritten: it belongs to whoever put it there, and
replacing it would break their integration with nothing to restore.

### File associations

```powershell
FileAssociations = @{
    Mode         = "MANAGE"
    SetAsDefault = $false
    Associations = @(
        @{
            Extension   = ".abc"
            ProgId      = "Company.Example"
            Description = "Example Document"
            Executable  = "C:\Program Files\Example\Example.exe"
            Arguments   = '"%1"'
            Icon        = "C:\Program Files\Example\Example.exe,0"
        }
    )
}
```

With `SetAsDefault = $false` the ProgID is registered and offered under "Open
with", without taking the extension over. With `$true` it becomes the default
and the previous handler is recorded, which uninstall restores. Windows asks
the user to confirm a default-application change either way.

The older single-string `OpenCommand` form is still accepted in place of
`Executable` + `Arguments`.

### Services and scheduled tasks

Both default to `DISABLED`, because the vendor installer almost always creates
them. A service that already exists is left exactly as it is and is not claimed
as owned, so uninstall cannot remove it.

A scheduled task is never silently given SYSTEM or highest privileges — those
are honoured only when `RunAsUser` and `RunLevel` ask for them by name, and
validation warns when they do.

### Explorer

After association or verb changes the framework broadcasts `SHCNE_ASSOCCHANGED`
so new entries appear without a sign-out. Explorer is never restarted: killing
it closes the user's open windows.

## Local Testing

Test-Local.ps1 supports these modes:

| Mode | Description |
|---|---|
| `Validate` | Check package structure, config, and script syntax |
| `Install` | Run Install.ps1 |
| `Uninstall` | Run Uninstall.ps1 |
| `Detection` | Run Detection.ps1 |
| `Environment` | Validate PATH entries, env vars, duplicates, and state tracking |
| `Integration` | Report the mode of each Windows integration, whether it is present, and what the package owns |
| `DryRun` | Run `Install.ps1 -TestMode`: print every planned change, make none |
| `DryRunUninstall` | Run `Uninstall.ps1 -TestMode` |
| `DetectPaths` | Scan install directory for CLI executable candidates |
| `TestCommand` | Resolve and run a command through PATH |

### Examples

```powershell
# Validate package before building
.\Test-Local.ps1 -Mode Validate

# Install and test
.\Test-Local.ps1 -Mode Install
.\Test-Local.ps1 -Mode Detection

# Discover CLI directories after installation
.\Test-Local.ps1 -Mode DetectPaths -InstallPath "C:\Program Files\Example"

# Verify PATH was configured
.\Test-Local.ps1 -Mode Environment

# Test command resolution
.\Test-Local.ps1 -Mode TestCommand -Command "example-cli --version"

# Uninstall and verify cleanup
.\Test-Local.ps1 -Mode Uninstall
.\Test-Local.ps1 -Mode Detection
```

Test-Local.ps1 sets `$env:INTUNE_LOCAL_TEST` to suppress SYSTEM account warnings during local testing. Production Intune deployments run as SYSTEM.

## Automated Tests

```powershell
# Everything, one table
powershell.exe -ExecutionPolicy Bypass -File Tests\Run-AllTests.ps1

# Only the suites that need no Windows-specific capability
powershell.exe -ExecutionPolicy Bypass -File Tests\Run-AllTests.ps1 -PortableOnly
```

| Suite | Covers |
|---|---|
| `Test-Environment.ps1` | Path normalization, case-insensitive comparison, duplicate detection, state tracking, CLI discovery, expandable-variable preservation, idempotency, backward compatibility |
| `Test-Lifecycle.ps1` | The real install/uninstall orchestration against an in-memory registry |
| `Test-Integration.ps1` | Windows integration: mode resolution, creation, validation, ownership, and what uninstall may remove |
| `Test-Detection.ps1` | The Intune detection contract in both directions |
| `Test-PS51Compat.ps1` | PowerShell 7-only syntax audit, the 5.1 loader path executed, and a live 5.1 run |
| `Test-Studio.ps1` | psd1 serialization, round-tripping, save stability, schema merging, validation grading, the wizard flow, and the analysis/execution safety boundary |
| `Test-Gui.ps1` | The Studio's model-to-form functions, without WPF |
| `Test-WpfSmoke.ps1` | XAML parsing, control binding cross-checks, and a live WPF window |
| `Test-Elevated.ps1` | The registry, shell and service primitives themselves |

Skips are reported separately from passes and never counted as success. A suite
that skipped everything has proved nothing, and the summary says so.

### What runs where

Most of this project's logic is tested by **substituting the primitives that
touch the machine** — the registry, the shell, the service database, the task
scheduler — so the real orchestration executes on any platform. That is where
the interesting behaviour lives: which mode applies, whether something
pre-existed, what is recorded as owned, and what uninstall is therefore allowed
to remove.

What that leaves is whether the primitives themselves do what the stand-ins
pretend they do. `Test-Elevated.ps1` covers exactly that, and needs an elevated
Windows session. It snapshots the machine PATH and every variable it touches,
restores them in a `finally` block, and then asserts the PATH matches the
snapshot byte for byte — so a restore that did not work is itself a failure.

On Linux, 22 checks skip: 9 elevated primitives, 7 registry round-trips, 5
live-WPF checks and 1 live PowerShell 5.1 run. Each says why.

### PowerShell 5.1

Intune's Management Extension runs Windows PowerShell 5.1, so
`Test-PS51Compat.ps1` walks every shipped script's syntax tree and fails the
build on a ternary, `??`, `??=`, `?.`, `?[]`, `&&`/`||`, a Core-only automatic
variable such as `$IsWindows`, or a PowerShell 7-only cmdlet. Detection is by
AST node type rather than by grep, so a construct inside a string or a comment
cannot produce a false positive.

It also executes the 5.1 configuration-loading path for real on any platform —
`-Strict` forces the syntax-tree reader that 5.1 requires — and drives
`Detection.ps1` end to end through it. The only part that needs Windows is the
live `powershell.exe` run, which reports `[SKIP]` elsewhere.

## Packaging

```powershell
IntuneWinAppUtil.exe -c C:\Build\IntuneApp -s Install.ps1 -o C:\Build\Output
```

Upload the resulting `.intunewin` file to Intune.

## Backward Compatibility

Existing configurations continue to work unchanged:

- A configuration with no `Environment` or `WindowsIntegration` section is
  inert. Both features are disabled by default.
- `WindowsIntegration.<Feature>.Enabled = $true` still means `MANAGE`, which is
  what it meant before modes existed. `Mode` takes precedence when set.
- `Detection.ScriptBlock = { ... }` still works. On Windows PowerShell 5.1 it is
  loaded through the syntax-tree reader rather than the native loader, which
  cannot read it.
- The older `OpenCommand` and `IconPath` keys on a file association are still
  accepted alongside `Executable` / `Arguments` / `Icon`.
- Re-saving an unchanged configuration is byte-stable, so diffs stay clean.
