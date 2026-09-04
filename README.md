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
│   └── Environment.ps1      # PATH and environment variable helpers
├── Tests\
│   ├── Test-Environment.ps1 # PATH/environment tests
│   └── Test-Studio.ps1      # Generator tests
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

### Windows integration sections

`WindowsIntegration` (shortcuts, file associations, context menu, services,
scheduled tasks) is **recorded for review and hand-off**. The installer itself
normally creates these, and the current packaging engine does not apply that
section. Validation reports this as an informational finding rather than
implying behavior the engine does not have.

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

**Custom** — PowerShell scriptblock fallback:
```powershell
Detection = @{
    Type        = "Custom"
    ScriptBlock = { Test-Path "C:\Program Files\Example\Example.exe" }
}
```

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

## Local Testing

Test-Local.ps1 supports these modes:

| Mode | Description |
|---|---|
| `Validate` | Check package structure, config, and script syntax |
| `Install` | Run Install.ps1 |
| `Uninstall` | Run Uninstall.ps1 |
| `Detection` | Run Detection.ps1 |
| `Environment` | Validate PATH entries, env vars, duplicates, and state tracking |
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
# Run from the IntuneApp directory
powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Environment.ps1
powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Studio.ps1
```

`Test-Studio.ps1` covers the configuration generator: psd1 serialization and
round-tripping, save-cycle stability, schema merging and backward
compatibility, installer analysis, validation grading, preview output, the
end-to-end wizard flow, and the analysis/execution safety boundary. It runs on
Windows PowerShell 5.1 and PowerShell 7, and installs nothing.

`Test-Environment.ps1` covers path normalization, case-insensitive comparison, duplicate detection, state tracking, CLI discovery, expandable variable preservation, idempotency, and backward compatibility. PATH modification tests require Administrator elevation and skip gracefully otherwise.

## Packaging

```powershell
IntuneWinAppUtil.exe -c C:\Build\IntuneApp -s Install.ps1 -o C:\Build\Output
```

Upload the resulting `.intunewin` file to Intune.

## Backward Compatibility

Existing configurations without an `Environment` section continue to work unchanged. The feature is disabled by default (`Environment.Enabled = $false`).
