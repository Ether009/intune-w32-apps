# Lunds Fontänhus Desktop Shortcut Deployment Framework

Deploys and maintains managed shortcuts on every device's **Public Desktop** via Intune,
using PSAppDeployToolkit (PSADT) **v4.1.8** as the Win32 app wrapper. The actual
shortcut creation happens continuously in the background via a scheduled task,
independent of the one-time app install/uninstall.

## Repository layout

Only the custom files are tracked here. The official PSADT v4 template payload
(module, compiled front-end, Assets/Config/Strings) is **not committed** — the build
pipeline downloads the pinned 4.1.8 release, verifies its SHA-256, and overlays the
files from this repo on top before packaging. A local working copy may additionally
contain the extracted template folders (`PSAppDeployToolkit\`, `Assets\`, `Config\`,
`Strings\`, `Files\`, `Invoke-AppDeployToolkit.exe`); those are gitignored.

```
/
├── .github/workflows/
│   └── build-and-publish.yml     <- CI: builds the .intunewin and publishes it to Intune
├── Invoke-AppDeployToolkit.ps1   <- customized PSADT entry point: framework logic lives here
├── SupportFiles/
│   ├── New-Shortcuts.ps1         <- the logon-time worker script
│   ├── Shortcuts.json            <- shortcut definitions
│   └── Icons/                    <- .ico files bundled for Url shortcuts
└── README.md
```

## How it works

1. **Win32 app install** (`Invoke-AppDeployToolkit.ps1`, `-DeploymentType Install`):
   - Copies `New-Shortcuts.ps1`, `Shortcuts.json`, and any bundled `Icons\` to
     `%ProgramData%\LundsFontanhus\ShortcutDeployment\`.
   - Registers scheduled task **"Lunds Fontanhus - Deploy Desktop Shortcuts"**:
     - Trigger: *At log on*, no specific user configured -> fires for **any** user.
     - Principal: **NT AUTHORITY\SYSTEM**, highest privileges, `ServiceAccount` logon type.
     - Because SYSTEM logon-triggered tasks run in **Session 0** (no desktop attached),
       the task is invisible by construction — no window flash, regardless of
       `-WindowStyle Hidden`.
   - Runs the task once immediately so the currently logged-on user doesn't have to
     log off/on to get their shortcuts.
   - Writes `HKLM:\SOFTWARE\LundsFontanhus\ShortcutDeployment\Version` for Intune detection.

2. **Every logon, for any user** (`New-Shortcuts.ps1`, run as SYSTEM):
   - Reads `Shortcuts.json`.
   - For each entry, if the target file doesn't already exist on the Public Desktop,
     creates it. Existing `Local`/`Network` shortcuts are **never touched** — this keeps
     it safe to run at every logon on a shared/multi-user machine.
   - `Url` entries become `.url` files (works with any type of shortcut, no admin
     rights or COM needed). An existing `Url` shortcut **is icon-verified**: if its
     stored `IconFile`/`IconIndex` no longer match what the config specifies, it is
     recreated so an updated packaged icon takes effect. Nothing else about a `Url`
     shortcut is enforced, and if the expected icon file is missing at run time the
     existing shortcut is left as-is rather than stripped.
   - `Local`/`Network` entries become `.lnk` files created via the `WScript.Shell` COM
     object, which **does not validate that the target exists** — so a shortcut to a
     share or local folder that hasn't been provisioned yet is created without error
     and will simply work once the destination shows up.
   - If a `Local`/`Network` target contains `{USERNAME}` or `{USERPROFILE}`, the script
     resolves the actual logged-on user's profile by looking up the SID that owns the
     `explorer.exe` process against `HKLM\...\ProfileList` — the same source Windows
     itself uses — rather than trusting `$env:USERNAME` (which under SYSTEM would be
     `SYSTEM`, not the interactive user). This also correctly handles Entra
     ID/AzureAD-joined devices where the profile folder name isn't a simple username.
   - If no interactive user can be resolved yet (e.g. task fires before Explorer is
     up), user-scoped entries are skipped and retried on the next logon.

3. **Win32 app uninstall** (`-DeploymentType Uninstall`):
   - Unregisters the scheduled task.
   - Deletes any shortcuts on the Public Desktop that match names in `Shortcuts.json`.
   - Removes the installed files and registry key.

## Customizing

- Edit **`SupportFiles/Shortcuts.json`** to add/remove/change shortcuts. No PowerShell
  changes are needed for new shortcuts — just add JSON entries:

  | Field              | Applies to      | Notes |
  |--------------------|-----------------|-------|
  | `Name`             | all             | Also used as the shortcut's file name. |
  | `Type`             | all             | `Url`, `Local`, or `Network`. |
  | `Target`           | all             | URL, local path, or UNC path. May contain `{USERNAME}` / `{USERPROFILE}`. |
  | `IconFile`         | `Url` only      | Optional. A **bare filename** (e.g. `canva.ico`) uses an icon bundled in `SupportFiles\Icons\` (see below). A rooted path or one with a separator — e.g. `%SystemRoot%\System32\shell32.dll` — is used as-is. |
  | `IconIndex`        | `Url` only      | Optional (default `0`). Icon index within `IconFile`; leave at `0` for a standalone `.ico`. |
  | `IconLocation`     | `Local`/`Network` | Optional, `"path,index"` format (e.g. `imageres.dll,-112`). May also contain the tokens. |
  | `Arguments`        | `Local`/`Network` | Optional command-line arguments if `Target` is an executable. |
  | `WorkingDirectory` | `Local`/`Network` | Optional. |
  | `Description`      | `Local`/`Network` | Optional tooltip text. |

### Bundling icons for `Url` shortcuts

To ship a custom icon inside the package (rather than relying on a file that already
exists on the device):

1. Drop the `.ico` file into **`SupportFiles\Icons\`** (e.g. `canva.ico`).
2. Reference it by bare filename in the `Url` entry: `"IconFile": "canva.ico"`.

At install, everything under `SupportFiles\Icons\` is copied to
`%ProgramData%\LundsFontanhus\ShortcutDeployment\Icons\`, and each `.url` shortcut's
`IconFile=` line points there — an absolute path under `ProgramData`, readable by all
users, so the icon renders for everyone on the Public Desktop. If a referenced icon is
missing at runtime, the shortcut is still created (just without the custom icon) and a
warning is logged. Use `.ico`; a `.png` is not a valid Windows icon resource — convert
it first.

> **Updating an icon:** the worker verifies the icon on every logon, so changing a
> `Url` entry's `IconFile`/`IconIndex` (and shipping the new `.ico`) automatically
> recreates already-deployed shortcuts with the new icon — no rename or manual cleanup
> needed. Push the updated package (bump `AppVersion` so Intune re-runs the install and
> the new icon lands in `...\Icons\`), and each device applies it at the next logon.
> The trade-off is that a manually customized icon on a `Url` shortcut will be reverted
> to the configured one; that's the point of enforcing it. Icons that live outside the
> package (system paths / `%ENV%` sources) are compared the same way.

- The vendor slug is set via `$ShortcutFrameworkInstallDir`, `$ShortcutFrameworkTaskName`,
  `$ShortcutFrameworkRegKey` (in `Invoke-AppDeployToolkit.ps1`) and `AppVendor` in the
  `$adtSession` block — currently `LundsFontanhus` / `Lunds Fontänhus`. Update all of
  these together if the org name ever changes, and keep `SupportFiles\New-Shortcuts.ps1`'s
  default `-LogPath` in sync with `$ShortcutFrameworkInstallDir` (it can't read the
  deploy script's variable since it runs standalone from the scheduled task).
- **Encoding matters.** Identifiers that end up as OS objects — the scheduled-task name,
  install dir, and registry key — are kept **ASCII-only** on purpose: PowerShell reads a
  `.ps1` as ANSI when it lacks a UTF-8 BOM, which mangles diacritics (`ä` → `Ã¤`) and
  once left the task registered under a broken name with no working task. Keep both `.ps1`
  files saved as **UTF-8 with BOM** (as they are now), so branding text like `Lunds
  Fontänhus` and non-ASCII shortcut names read correctly. `New-Shortcuts.ps1` also reads
  `Shortcuts.json` with `-Encoding UTF8`, so shortcut names with diacritics render right
  regardless of the JSON's BOM. `Register-ShortcutScheduledTask` verifies the task exists
  after registering and throws if not, so a registration that silently leaves no task
  fails the install (and is retried/reported) instead of passing quietly.
- To push a change (new/edited shortcuts, icons, or worker logic):
  1. Bump `AppVersion` in `Invoke-AppDeployToolkit.ps1` (this becomes the `Version`
     registry value and is the single source of truth for the release).
  2. Commit and push to `main`.

  CI does the rest: it builds the `.intunewin`, uploads it to the existing Intune app,
  sets the app's version, and regenerates + uploads the detection script from the same
  `AppVersion` value — so the install and its detection can never drift apart. If
  `AppVersion` was not bumped, CI builds the package but skips publishing. The install
  phase always re-copies the script, config, and icons; shortcuts update at the next
  logon after each device syncs.

## Build and publish (CI)

This app is built and published by the repo-wide `.github/workflows/build-and-publish.yml`,
which discovers every app under `apps/*/` and builds/publishes each independently — see
the top-level `README.md` for how that pipeline works and how credentials are set up.
This app's Intune target and detection-registry settings live in `manifest.json`.

To bump the PSADT release itself: update the template URL + SHA-256 in the workflow,
and update the `Guid`/`ModuleVersion` pin in the `Import-Module -FullyQualifiedName`
calls (two places in the Initialization section) plus `DeployAppScriptVersion`.

### Manual fallback / first-time app creation

Assemble locally (extract the template zip, overlay the repo files), then wrap with
`IntuneWinAppUtil.exe -c <folder> -s Invoke-AppDeployToolkit.exe -o <out>`. In Intune,
create a **Windows app (Win32)**:
   - **Install command:**
     `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
   - **Uninstall command:**
     `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
   - **Install behavior:** System (required — the task must be created under a SYSTEM
     context and target the machine, not a per-user context).
   - **Detection rule:** a **custom detection script** that reports "installed" only
     when `HKLM\SOFTWARE\LundsFontanhus\ShortcutDeployment` `Version` **equals the
     version this build ships**. This must be **version-specific**: Intune gates a Win32
     update on the detection rule, so a device still on the previous version has to read
     as *not installed* for IME to run the new install (which writes the new `Version`,
     after which detection passes). A version-agnostic "key exists" rule would break
     updates — an already-installed device would be detected and IME would skip the new
     install. (Also: the portal's manual Registry-rule wizard flow got stuck on "step
     has errors" in this tenant, so the script route is used.)

     > CI regenerates the detection script from `AppVersion` on every publish, so the
     > install and its detection cannot drift apart. If you ever update the app
     > manually instead: bump `AppVersion`, generate/edit the detection script to
     > expect the **same** value, and upload **both** the rebuilt `.intunewin` (App
     > information → Edit) and the detection script (Detection rules → Edit). If they
     > disagree, install writes one version while detection checks another and every
     > targeted device install-loops.
   - **Assignment:** assign as **Required** to a device group — this framework does
     nothing meaningful as a "user available" app, since its whole job is a
     machine-wide scheduled task.

## Verifying on a test machine

```powershell
# Confirm the task exists and is enabled, targeting any user, running as SYSTEM
Get-ScheduledTask -TaskName 'Lunds Fontanhus - Deploy Desktop Shortcuts' | Format-List *

# Run it on demand and tail the log
Start-ScheduledTask -TaskName 'Lunds Fontanhus - Deploy Desktop Shortcuts'
Get-Content "$env:ProgramData\LundsFontanhus\ShortcutDeployment\Logs\New-Shortcuts.log" -Tail 20 -Wait
```

To test the deploy script itself before packaging (requires a locally assembled folder,
i.e. the template extracted with this repo's files overlaid):

```powershell
# From an elevated PowerShell prompt, in the assembled folder:
.\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
.\Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent
```

Note that `RequireAdmin = $true` is intentional (the task writes to `HKLM` and registers
a SYSTEM-context scheduled task), so a non-elevated run stops at `Open-ADTSession`'s
admin check with exit code 60008. When testing changes to the worker script, always
exercise the bare invocation path too (`powershell.exe -File New-Shortcuts.ps1` with no
arguments, in a fresh process) — parameter-binding failures there don't surface in runs
that pass every parameter explicitly.

## Known limitations

- Per-user token resolution (`{USERNAME}`/`{USERPROFILE}`) picks the **first**
  interactively logged-on session it can resolve. On a single-user device (the normal
  Intune-managed client case) this is always correct. On a shared/RDS host where
  multiple users can be logged on simultaneously, the *first* user to trigger the task
  after a shortcut is missing "wins" that shortcut's target — by design, since the
  requirement is idempotent creation (create only if missing), not per-user
  personalization of a file that's inherently shared on the Public Desktop.
- **Changing** the icon of an already-deployed shortcut updates the `.url` file
  correctly, but Explorer's per-user icon cache (`iconcache*.db`) may keep displaying
  the old image — even across a relog — until the cache refreshes. Harmless and
  self-correcting over time; to force it: F5 on the desktop, `ie4uinit.exe -show`, or
  restart Explorer. First-time icon assignment (shortcut created with its icon) is not
  affected, so normal rollouts never hit this — only re-icon operations do.
