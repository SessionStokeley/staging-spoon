# Intune packaging

This repository holds two implementations of the same job — building a
Microsoft Intune Win32 application package — while the second replaces the
first.

| | Use it for | Status |
|---|---|---|
| [**`IntuneApp\`**](IntuneApp/README.md) — Intune Win32 Packaging Framework | Anything going to production today | Complete. 467 assertions, 26 skipped on a non-Windows host. |
| [**`IntunePackageBuilder\`**](IntunePackageBuilder/README.md) — Intune Package Builder | Nothing yet | Under construction. Generator, package runtime and SYSTEM-context local test are done and tested. |

**The two configuration schemas are not compatible.** `IntuneApp` uses a nested
schema (`Installer.Arguments`, `Environment.SystemPath.Entries`,
`WindowsIntegration.DesktopShortcut.Mode`); Intune Package Builder uses a flat
one. A `Configuration.psd1` written for one will not load in the other, and
there is no converter.

## Why the rebuild

[`REBUILD_AUDIT.md`](REBUILD_AUDIT.md) is the full account. The short version:

- **Local testing never ran as SYSTEM.** It ran as the current administrator,
  which differs from Intune's context in `HKCU`, `%USERPROFILE%`, the user
  Desktop and Start Menu, mapped drives and user PATH. This is the most
  plausible cause of "passes locally, fails in Company Portal", and no amount
  of restructuring addresses it on its own.
- **Nothing invalidated a stale test result.** A configuration could be tested,
  edited and packaged without ever being retested.
- **The package shipped the whole toolchain** — roughly 7,500 lines of GUI,
  wizard and tests delivered to every managed machine, because
  `IntuneWinAppUtil -c` archives everything beneath the folder it is given.

The problem the rebuild was originally written to fix — duplicated installer
arguments — had already been found and fixed in `IntuneApp` before the rebuild
began. That is recorded rather than quietly dropped.

## Other files

- [`CHANGELOG.md`](CHANGELOG.md) — changes to the tooling itself.
- [`DEBUGGING-LOG.md`](DEBUGGING-LOG.md) — BUG-001 to BUG-013, each with how it
  was found and what it broke. Every one of these fixes is being carried into
  the new implementation with its tests.
- [`REBUILD_AUDIT.md`](REBUILD_AUDIT.md) — architecture, reusable code,
  removals, rewrites and risks.

`IntuneApp\` is removed once Intune Package Builder is finished and has
absorbed the coverage that still applies. Until then, both are here on purpose.
