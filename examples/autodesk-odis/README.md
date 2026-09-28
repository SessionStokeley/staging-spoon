# Autodesk ODIS deployment (Revit 2027.3)

A worked example of packaging an **Autodesk ODIS offline deployment** (the kind
produced by the Autodesk deployment tool / `AdOdisDeployTool.exe`) for Intune.
Autodesk deployments break three assumptions the generic templates make, so this
example ships purpose-built wrappers instead of the ones in `templates/`.

## Why the generic templates don't fit

1. **The installer runs from a fixed absolute path, not the package.** The
   deployment image bakes `C:\Program Files\Autodesk\image` into `Collection.xml`
   (`<DeploymentImagePath>`) and `odisver.xml` (`<location>`), and lays the
   product down as symlinks into that image (`<Symlink>true</Symlink>`). The
   image must therefore live at that path, and must **stay there** after install
   or Revit's symlinked files break.
2. **The vendor `.bat` is not silent.** Its active line uses `--ui_mode basic`,
   which shows a UI and hangs under SYSTEM (session 0). The genuinely silent
   command — the one this example runs — is `Installer.exe -i deploy
   --offline_mode -q -o "...\Collection.xml" --installer_version "..."`.
3. **The payload is ~14 GB.** It is the whole offline image, and it persists on
   the device because of the symlink deployment.

## What the wrappers do

| Script | Behaviour |
| --- | --- |
| `Install.ps1` | Stages the packaged `image\` to `C:\Program Files\Autodesk\image` with robocopy (idempotent), then runs the silent `-i deploy -q` command. Preserves the vendor exit code; waits on the installer process alone. |
| `Uninstall.ps1` | Runs `Installer.exe -i uninstall -q --manifest ...\setup.xml --extension_manifest ...\setup_ext.xml` against the staged image (falls back to the packaged copy), then removes the staged image to reclaim the ~14 GB. |
| `Detection.ps1` | Detects `Revit 2027` by ARP name and by `C:\Program Files\Autodesk\Revit 2027\Revit.exe`. Presence-based by default; see the note in the script to pin it to the 2027.3 build. |

`package.json` declares it as an `InstallerType: Wrapper`, System context, x64,
minimum OS Windows 11, success codes `0, 1641, 3010`, and a
`PostInstallExpectation` so validation confirms `Revit.exe` actually landed.

## Building it

The image is not in git (it is ~14 GB). To build:

1. Create the working payload folder and put the built deployment image in it:
   ```
   source\Autodesk\
     image\            <- the built Autodesk deployment (Installer.exe, Collection.xml, RVT_2027_en-US, ...)
     Install.ps1       <- from this example
     Uninstall.ps1     <- from this example
     Detection.ps1     <- from this example
     package.json      <- from this example
   ```
2. If your deployment's `DeploymentImagePath`, bundle folder (`RVT_2027_en-US`),
   or `--installer_version` differ, update the config block at the top of
   `Install.ps1` / `Uninstall.ps1` to match `Collection.xml` and `odisver.xml`.
3. Validate and build on a **disposable VM** you can roll back, elevated:
   ```powershell
   .\src\Build\Build-IntunePackage.ps1 `
       -SourcePath .\source\Autodesk `
       -ConfigPath .\source\Autodesk\package.json `
       -IntuneWinAppUtilPath .\tools\IntuneWinAppUtil.exe `
       -SystemContext
   ```
   This installs and uninstalls Revit for real. Do not run it on a workstation.

## Caveats

- **The image persists on the device** (~14 GB) while Revit is installed, by
  design of the symlink deployment. `Uninstall.ps1` reclaims it on removal.
- **Content Prep / Intune size**: a ~14 GB `.intunewin` is large; confirm it is
  within your tenant's Win32 app size limit and expect slow content processing.
- **Detection version**: left presence-based. To require the 2027.3 update
  specifically, read the installed `Revit.exe` version on a reference machine
  and set `$ExpectedVersion` in `Detection.ps1`.
- Timeouts in the wrappers (staging 1 h, install 2 h, uninstall 1 h) are sized
  for Revit; adjust for your hardware.
