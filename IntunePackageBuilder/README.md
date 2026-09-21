# Intune Package Builder

Builds a Microsoft Intune Win32 package from one flat configuration file:
three self-contained scripts, the installer, and nothing else.

> **Under construction.** The generator, the package runtime and the
> SYSTEM-context local test are built and tested. Validation, `.intunewin`
> packaging, the Intune deployment preview, Installation Capture, the UI and
> package history are not yet. Until they are, the previous framework in
> [`IntuneApp\`](../IntuneApp/README.md) is the one to use for production work.
> [`REBUILD_AUDIT.md`](../REBUILD_AUDIT.md) records why this exists and
> [`CHANGELOG.md`](../CHANGELOG.md) records what has changed.

---

## What makes it different

**The package is five files.** The previous framework shipped roughly 7,500
lines of GUI, wizard and test code to every managed endpoint, because
`IntuneWinAppUtil -c` archives everything beneath the folder it is given. This
one ships the installer, three scripts and a configuration:

```
PackageSource\
├── setup.exe             # your installer, under the name the configuration uses
├── Install.ps1           # self-contained
├── Uninstall.ps1         # self-contained
├── Detection.ps1         # self-contained
└── Configuration.psd1    # every app-specific setting
```

There is no `Helpers\` directory. Each script carries the shared runtime
inline, spliced in at build time from one maintained copy — so a fix to PATH
handling is one edit, and every package on every machine is the same program to
debug.

**Local testing runs as SYSTEM.** Intune's Management Extension runs packages as
`NT AUTHORITY\SYSTEM`. Testing as an administrator is a different test, and the
difference is the usual explanation for "it worked locally but failed through
Company Portal":

| | Administrator | SYSTEM |
|---|---|---|
| `HKCU` | the admin's hive | `.DEFAULT`, no real user |
| `%USERPROFILE%` | the admin's profile | `systemprofile` |
| Desktop / Start Menu | the admin's | the system profile's |
| Mapped drives | present | absent |
| User PATH | the admin's | the system profile's |

A package that writes a shortcut to "the user's desktop" passes as an
administrator and lands somewhere nobody can see as SYSTEM. `Builder\LocalTest.ps1`
runs the real `Install.ps1` in the context Intune uses.

**A test result expires.** Every result is recorded against a fingerprint of the
configuration, the three scripts and the installer. Edit any of them and the
previous pass stops counting, so a configuration nobody ran cannot be packaged
on the strength of an older test.

**Intune supplies no arguments.** The Program install command launches the
wrapper and nothing else. `Configuration.psd1` is the single authoritative
source of installer arguments, so what was tested locally is byte-for-byte what
runs on the endpoint.

---

## Using `New-IntunePackage.ps1`

One command does everything. It keeps track of what stage you are at and offers
the next step.

```powershell
cd C:\Packages
C:\path\to\IntunePackageBuilder\New-IntunePackage.ps1
```

With no arguments, it shows where you are and what to do next. The argument to
`-Mode` picks the operation:

| Mode | What it does |
|---|---|
| `Where` (default) | Show the current package state and the next command |
| `New` | Create a new package folder with a starter configuration |
| `Build` | Generate PackageSource from the configuration |
| `Test` | Install as SYSTEM, check, and uninstall (needs elevated Windows) |
| `Status` | Say whether a test result still applies |
| `Intune` | Print exactly what to enter in the Intune portal |
| `Pack` | Run Microsoft's `IntuneWinAppUtil.exe` to produce the `.intunewin` |

### Walkthrough

#### 1. Create the package folder

```powershell
C:\IntunePackageBuilder\New-IntunePackage.ps1 -Mode New `
    -Path C:\Packages\ExampleTool `
    -ApplicationName 'Example Tool' `
    -Publisher 'Example Corp' `
    -Version 2.1.0
```

This creates:

```
C:\Packages\ExampleTool\
├── Configuration.psd1              you edit this
└── Installer\                       put the vendor's installer here
```

#### 2. Add the installer and edit the configuration

Copy the vendor's EXE/MSI/BAT to `Installer\`.

Edit `Configuration.psd1`:

- **`InstallerFile`** — the name the installer will have in the package (e.g.
  `setup.exe` if the vendor called it `ExampleToolSetup.exe`). The file `Installer\`
  holds must have this name.
- **`InstallArguments`** — the vendor's real silent switches, e.g. `/S` or
  `/quiet /norestart`. These are _never_ guessed or modified; you read the
  vendor's documentation.
- **`Detection.Path`** — a file that exists only once the application is
  installed, e.g. `C:\Program Files\Example Tool\example.exe`. This is what
  Intune checks to decide the application is already deployed.
- If `InstallerType` is `MSI`, also set **`ProductCode`** (from `msiexec /i
  installer.msi /qb` and reading the registry, or from the vendor).

Sanity checks appear when you run `-Mode Where` again:

```powershell
C:\IntunePackageBuilder\New-IntunePackage.ps1 -Path C:\Packages\ExampleTool
```

#### 3. Build the package

```powershell
C:\IntunePackageBuilder\New-IntunePackage.ps1 -Mode Build -Path C:\Packages\ExampleTool
```

This creates `PackageSource\` with all five files (Install.ps1, Uninstall.ps1,
Detection.ps1, Configuration.psd1, and your installer). Nothing else goes in
there — stray files would be archived into the `.intunewin` and deployed to
every endpoint.

#### 4. Test locally (on an elevated Windows machine you can afford to change)

```powershell
C:\IntunePackageBuilder\New-IntunePackage.ps1 -Mode Test -Path C:\Packages\ExampleTool
```

This **installs real software on the machine it runs on**, as `NT AUTHORITY\SYSTEM`.
It registers a scheduled task, runs Install.ps1, runs the package's own
Detection.ps1 to verify, runs Uninstall.ps1, re-checks Detection.ps1, and
removes the task. You must type `test` to confirm — there is no silent mode,
because silently installing software is a security mistake.

If everything passes:

- The result is recorded against a fingerprint of the configuration and the scripts.
- Any edits to either will invalidate that result, so you must re-test before packaging.

If a feature stage fails (e.g. "Desktop Shortcut FAIL"), the output goes to
`LastTest-Install.log` and `LastTest-Uninstall.log` so you can read what went wrong.

#### 5. Print the Intune commands

```powershell
C:\IntunePackageBuilder\New-IntunePackage.ps1 -Mode Intune -Path C:\Packages\ExampleTool
```

This shows exactly what to enter in the Intune portal:

- **Install command** — `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install.ps1`
- **Uninstall command** — `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Uninstall.ps1`
- **Detection rule** — upload the `Detection.ps1` from PackageSource as a
  custom detection script
- **Return codes** — 0 and 3010 (soft reboot)

The install and uninstall commands take **no arguments on purpose.** The
arguments live inside the package in `Configuration.psd1`. That is what was
tested locally, so what runs on the endpoint is the same thing — byte for byte.

#### 6. Package for Intune

Get `IntuneWinAppUtil.exe` from
[github.com/microsoft/Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool).
Do NOT put it in the package folder — `IntuneWinAppUtil -c` archives everything
it finds there, so a copy sitting inside would ship to every managed machine.

```powershell
C:\IntunePackageBuilder\New-IntunePackage.ps1 -Mode Pack -Path C:\Packages\ExampleTool
```

This looks for `IntuneWinAppUtil.exe` in:

1. The same directory as `New-IntunePackage.ps1`
2. The package folder itself (a warning if found — you should move it)
3. `C:\Tools\`

Or pass `-UtilPath` to specify exactly:

```powershell
... -Mode Pack -UtilPath 'C:\Downloads\IntuneWinAppUtil.exe'
```

The result is `PackageSource.intunewin` in an `Output\` folder inside the
package folder.

---

## Layout

```
IntunePackageBuilder\
├── New-IntunePackage.ps1          # the one command, covers all modes
├── Builder\
│   ├── Psd1.ps1                   # .psd1 reading and writing, 5.1-safe
│   ├── PackageConfig.ps1          # the flat schema, defaults, entry constructors
│   ├── Generator.ps1              # splices the runtime, writes the package source
│   ├── LocalTest.ps1              # SYSTEM-context test and test-state currency
│   └── Templates\
│       ├── _Runtime.ps1           # the shared runtime spliced into all three
│       ├── Install.ps1            # template, carries a #<RUNTIME> marker
│       ├── Uninstall.ps1          # template
│       └── Detection.ps1          # template
└── Tests\
    └── Test-LocalTest.ps1         # fingerprint, invalidation, wrapper, SYSTEM run
```

---

## Configuration schema

One flat file. No nested `Installer.Arguments` or
`Environment.SystemPath.Entries`; the previous framework's schema does not load
here and is not meant to.

### Required fields

| Field | Use |
|---|---|
| `ApplicationName` | Name that appears in Intune, logs, and shortcuts |
| `Publisher` | Your organization's name |
| `Version` | Application version |
| `InstallerType` | `EXE`, `MSI`, or `BAT` |
| `InstallerFile` | The name the installer has in the package |
| `InstallArguments` | The vendor's silent switches, e.g. `/S` or `/quiet /norestart` |
| `Detection` | How Intune tells if the app is installed |

If `InstallerType` is `MSI`, also set `ProductCode` (used for uninstall).

### Optional fields

| Field | Default | Purpose |
|---|---|---|
| `UninstallArguments` | — | For EXE/BAT uninstallers. MSI uses ProductCode. |
| `InstallPath` | — | Where the app lands. Used as the default for detection and for shortcut targets. |
| `SuccessExitCodes` | `@(0, 3010)` | Exit codes that mean success. 3010 means reboot pending. |
| `RebootBehavior` | `Suppress` | How Intune handles reboots: `Suppress`, `Allow`, or `Force` |
| `Path` | disabled | Machine or User PATH entry to add |
| `FileAssociations` | `@()` | File types the app handles, e.g. `.json` |
| `ContextMenus` | `@()` | Context menu entries, e.g. "Open with Example Tool" |
| `Shortcuts` | `@()` | Desktop or Start Menu shortcuts |
| `Logging` | enabled, `C:\ProgramData\IntunePackageBuilder\Logs` | Where the scripts write logs |
| `Architecture` | `x64` | `x64` or `x86`. Informational for Intune. |
| `Description` | — | Optional description for the portal |

### Building entries

Use the builder functions from the command line or in your own scripts:

```powershell
. .\Builder\PackageConfig.ps1

$config = New-PackageConfig

# Add a PATH entry
$config.Path = @{ Enabled = $true; Scope = 'Machine'; Value = 'C:\Program Files\Example' }

# Add shortcuts
$config.Shortcuts = @(
    (New-Shortcut -Name 'Example Tool' -Target 'C:\Program Files\Example\example.exe' -Location Desktop),
    (New-Shortcut -Name 'Example Tool' -Target 'C:\Program Files\Example\example.exe' -Location StartMenu)
)

# Add file associations
$config.FileAssociations = @(
    (New-FileAssociation -Extension .json -Executable 'C:\Program Files\Example\example.exe' -SetAsDefault $true)
)

# Add context menus
$config.ContextMenus = @(
    (New-ContextMenu -Name 'Edit with Example' -Command 'C:\Program Files\Example\example.exe "%1"' -Extensions @('.json', '.txt'))
)

Export-PackageConfig -Config $config -Path 'Configuration.psd1'
```

### Installer types

| Type | How it runs |
|---|---|
| `EXE` | Started directly, arguments passed as given |
| `MSI` | `msiexec.exe /i "<file>"`, uninstalled by `ProductCode` |
| `BAT` | Through `cmd.exe /c call`, so `cmd`'s quote-stripping rule does not eat the path |

### Detection

`Detection.Type` can be:

| Type | Field | What Intune checks |
|---|---|---|
| `File` | `Path` | File exists and (optionally) has a minimum version |
| `Folder` | `Path` | Folder exists |
| `Registry` | `Path` | Registry key exists |
| `MSI` | `ProductCode` | Installer is registered in the Add/Remove Programs list |

The verdict Intune sees comes from the detection rule **and nothing else** — never
from PATH, shortcuts, associations or context menus. Those are configuration the
package applies, not evidence the application is present, and making the verdict
depend on them turns a missing shortcut into a reinstall loop.

---

## Script endpoints

For automation or integration with other tools:

```powershell
. .\Builder\Psd1.ps1
. .\Builder\PackageConfig.ps1
. .\Builder\Generator.ps1
. .\Builder\LocalTest.ps1

# Load and merge a configuration
$config = Import-PackageConfig -Path 'Configuration.psd1'

# Build the package source directory
New-PackageSource -Config $config -InstallerPath 'path/to/installer.exe' -OutputPath 'PackageSource'

# Check that the generated scripts are sound
$check = Test-GeneratedScripts -PackagePath 'PackageSource'
if (-not $check.Valid) { $check.Errors }

# Run the local test
$result = Invoke-LocalPackageTest -PackagePath 'PackageSource' -Force
Write-LocalTestReport -Result $result

# Record the test result
Save-TestResult -PackagePath 'PackageSource' -Result $result

# Check if a result is still current
$state = Test-PackageTestCurrent -PackagePath 'PackageSource'
if ($state.Current) { "OK to package" }
```

---

## What is not here yet

Validation (§25), `.intunewin` packaging (§23), the Intune deployment preview
(§24), Installation Capture (§13-20), the UI (§31) and package history (§32).
Services and scheduled tasks are deliberately out of scope — the previous
framework managed both, and that capability is being dropped rather than
carried forward.
