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

## Layout

```
IntunePackageBuilder\
├── Builder\
│   ├── Psd1.ps1               # .psd1 reading and writing, 5.1-safe
│   ├── PackageConfig.ps1      # the flat schema, defaults, entry constructors
│   ├── Generator.ps1          # splices the runtime, writes the package source
│   ├── LocalTest.ps1          # SYSTEM-context test and test-state currency
│   └── Templates\
│       ├── _Runtime.ps1       # the shared runtime spliced into all three
│       ├── Install.ps1        # template, carries a #<RUNTIME> marker
│       ├── Uninstall.ps1      # template
│       └── Detection.ps1      # template
└── Tests\
    └── Test-LocalTest.ps1     # fingerprint, invalidation, wrapper, SYSTEM run
```

---

## Building a package

```powershell
. .\Builder\Psd1.ps1
. .\Builder\PackageConfig.ps1
. .\Builder\Generator.ps1

$config = New-PackageConfig
$config.ApplicationName = 'Example Tool'
$config.Publisher       = 'Example Corp'
$config.Version         = '2.1.0'
$config.InstallerType   = 'EXE'          # EXE, MSI or BAT
$config.InstallerFile   = 'setup.exe'
$config.InstallArguments = '/S /norestart'
$config.Detection = @{
    Type = 'File'
    Path = 'C:\Program Files\Example\example.exe'
    Version = '2.1.0'
    VersionComparison = 'GreaterThanOrEqual'
}

New-PackageSource -Config $config `
                  -InstallerPath 'C:\Downloads\ExampleSetup.exe' `
                  -OutputPath 'C:\Build\PackageSource'

Test-GeneratedScripts -PackagePath 'C:\Build\PackageSource'
```

`New-PackageSource` clears the files it previously generated, copies the
installer in under the name the configuration refers to, and reports anything
else left in the directory — because `IntuneWinAppUtil` would otherwise archive
that stray file into every endpoint's package.

---

## Configuration

One flat file. No nested `Installer.Arguments` or
`Environment.SystemPath.Entries`; the previous framework's schema does not load
here and is not meant to.

```powershell
@{
    ApplicationName  = 'Example Tool'
    Publisher        = 'Example Corp'
    Version          = '2.1.0'
    Description      = ''
    Architecture     = 'x64'

    InstallerType    = 'EXE'                  # EXE | MSI | BAT
    InstallerFile    = 'setup.exe'
    InstallArguments = '/S'
    UninstallArguments = ''
    ProductCode      = ''                     # required for MSI
    InstallPath      = 'C:\Program Files\Example'
    SuccessExitCodes = @(0, 3010)
    RebootBehavior   = 'Suppress'

    Path = @{ Enabled = $true; Scope = 'Machine'; Value = 'C:\Program Files\Example' }

    FileAssociations = @()
    ContextMenus     = @()
    Shortcuts        = @()

    Detection = @{ Type = 'File'; Path = 'C:\Program Files\Example\example.exe'
                   Version = ''; VersionComparison = 'GreaterThanOrEqual' }

    Logging = @{ Enabled = $true; Path = 'C:\ProgramData\IntunePackageBuilder\Logs' }
}
```

`New-FileAssociation`, `New-ContextMenu` and `New-Shortcut` build the entries for
the three list fields.

### Installer types

| Type | How it runs |
|---|---|
| `EXE` | started directly, arguments passed as given |
| `MSI` | `msiexec.exe /i <file>`, uninstalled by `ProductCode` |
| `BAT` | through `cmd.exe /c call`, so `cmd`'s quote-stripping rule does not eat the path |

### Detection

`Detection.Type` is `File`, `Folder`, `Registry` or `MSI`. The verdict Intune
sees comes from that rule and nothing else — never from PATH, shortcuts,
associations or context menus. Those are configuration the package applies, not
evidence the application is present, and making the verdict depend on them turns
a missing shortcut into a reinstall loop.

A configuration that cannot be read exits non-zero **and** explains itself on
stderr. Exiting silently would be byte-for-byte what "not installed" looks like.

---

## Local testing

```powershell
. .\Builder\Psd1.ps1
. .\Builder\PackageConfig.ps1
. .\Builder\LocalTest.ps1

$result = Invoke-LocalPackageTest -PackagePath 'C:\Build\PackageSource'
Write-LocalTestReport -Result $result
Save-TestResult -PackagePath 'C:\Build\PackageSource' -Result $result
```

This **installs real software on the machine it runs on**. It needs
administrator rights, and it refuses to run until you type `test` — pass
`-Force` only from automation that already has approval.

It registers a scheduled task under `\IntunePackageBuilder` whose principal is
`NT AUTHORITY\SYSTEM`, runs the package, reads the result and unregisters the
task in a `finally` block whatever happens. Task Scheduler rather than PsExec,
because it needs nothing installed; the wrapper writes its own exit code to a
file, because `LastTaskResult` reports the task host's result and is `0` for a
task that started successfully even when the script inside it failed.

Stages: installer present → install → detection → PATH, associations, context
menus, shortcuts → uninstall → detection again. Every line comes from the
package's own `Detection.ps1 -Report`, so the test and the package cannot
disagree about what "installed" means.

`-SkipUninstall` leaves the application on the machine, which is useful while
investigating a failure and means the machine is left changed.

### Has this package been tested?

```powershell
$state = Test-PackageTestCurrent -PackagePath 'C:\Build\PackageSource'
if (-not $state.Current) { Write-Warning $state.Reason }
```

`$state.Current` is `$false` when the package was never tested, when the last
result was not a pass, or when anything changed since that pass.

---

## Tests

```powershell
pwsh -File Tests\Test-LocalTest.ps1
powershell.exe -ExecutionPolicy Bypass -File Tests\Test-LocalTest.ps1
```

Assertions needing a capability the host does not have report `SKIP` with the
reason, and are counted separately from passes — a suite that skipped everything
has proved nothing.

Off Windows, the SYSTEM execution assertions skip; the fingerprint, invalidation,
refusal, report-parsing and wrapper-construction assertions all run.

---

## What is not here yet

Validation, `.intunewin` packaging, the Intune deployment preview, Installation
Capture, the UI and package history. Services and scheduled tasks are
deliberately out of scope — the previous framework managed both, and that
capability is being dropped rather than carried forward.
