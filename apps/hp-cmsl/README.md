# HP Client Management Script Library

Installs HP's official **HP Client Management Script Library (HP CMSL)** PowerShell
module on the device. This app is install-only: it never imports HPCMSL or invokes
any of its cmdlets (BIOS updates, Softpaq downloads, etc.) - it exists purely to put
the module on disk so that other tooling/scripts which already expect HPCMSL to be
present can find it.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8, wrapping HP's
own installer.

---

## What it does on each device

1. **Install**: runs HP's official CMSL installer (`hp-cmsl-installer.exe`) silently
   (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`). HP's installer is an InnoSetup
   executable, not an MSI - it drops the `HP.*` module folders under the machine's
   PowerShell module path(s) (`Program Files\WindowsPowerShell\Modules` and, if
   present, `Program Files\PowerShell\Modules`) and registers itself in the standard
   Windows uninstall registry like any other application.
2. Writes `HKLM:\SOFTWARE\Organization\HPCMSL\Version` for Intune detection.

Nothing runs in the background afterwards - unlike this repo's other apps, there's no
scheduled task. This is a one-time module install; once it's on disk, anything that
imports `HPCMSL` can use it.

## Uninstall

Looks up HP CMSL in the standard uninstall registry (`Get-ADTApplication`) and invokes
its own registered uninstaller silently (`Uninstall-ADTApplication`) - the correct way
to drive an InnoSetup-based installer's removal, since Inno places the uninstaller
under a generated, version-specific folder that isn't safe to hard-code. Then removes
the detection registry key.

## The installer binary

HP's installer (~23MB, HP Inc-signed) is **not committed to this repo**. CI downloads
it fresh from HP's official download endpoint and verifies it against a pinned
SHA-256 before staging it into the package - the same pattern already used here for
the PSADT template and the Microsoft Win32 Content Prep Tool. See the "Inject HP CMSL
installer" step in `.github/workflows/build-and-publish.yml`.

`SupportFiles/` in source control only holds a placeholder note explaining this - a
locally hand-assembled test build (extracting the PSADT template yourself instead of
letting CI do it) won't have the real installer, so `Install-HpCmslScriptLibrary`
throws a clear error rather than silently doing nothing.

Note: the app was initially rolled out with `AppVersion` at `1.0.1` (one bump above the
Intune app object's placeholder `1.0.0` displayVersion) rather than jumping straight to
`1.9.0`, so a fix could be republished without already being pinned at the real target
version. That first rollout was confirmed working end-to-end on a test device -
`AppVersion` is now at `1.9.0`, matching the HP CMSL release actually shipped, and the
two are kept in lockstep from here on.

### Updating to a newer HP CMSL release

1. Download the new `hp-cmsl-<version>.exe` from HP's
   [Client Management Solutions downloads page](https://www.hp.com/us-en/solutions/client-management-solutions/download.html)
   and compute its SHA-256 (`Get-FileHash`).
2. Update `HP_CMSL_INSTALLER_URL` and `HP_CMSL_INSTALLER_SHA256` at the top of
   `.github/workflows/build-and-publish.yml`.
3. Bump `AppVersion` in `Invoke-AppDeployToolkit.ps1` to match the new HP CMSL version
   (this is both what's recorded in the detection registry key and what CI compares
   against Intune's `displayVersion` to decide whether to publish).
4. Commit and push to `main` (via a merged PR).

**If you don't bump `AppVersion`, nothing is published** - the version is how Intune
knows there's an update, and how the pipeline knows to build a package containing the
newly-pinned installer at all.

## Build and publish (CI)

This app is built and published by the repo-wide `.github/workflows/build-and-publish.yml`,
which discovers every app under `apps/*/` and builds/publishes each independently - see
the top-level [README](../../README.md) for how that pipeline works and how credentials
are set up. This app's Intune target and detection-registry settings live in
`manifest.json`.

## Checking on a device

```powershell
# Is the module actually installed?
Get-Module -ListAvailable HPCMSL

# What version does the detection registry key say?
(Get-ItemProperty 'HKLM:\SOFTWARE\Organization\HPCMSL').Version

# Confirm it's in the standard uninstall registry too
Get-Package -Name 'HP Client Management Script Library*' -ErrorAction SilentlyContinue
```

## Good to know

- **Install-only, by design.** This app never runs `Import-Module HPCMSL` or any HPCMSL
  cmdlet - it only places the module on disk. Anything that actually *uses* HPCMSL
  (BIOS/firmware updates, Softpaq management, etc.) is out of scope for this app and
  belongs in its own tooling/script that separately imports the module.
- **No scheduled task.** Every other app in this repo runs something in the background;
  this one doesn't need to - a PowerShell module doesn't need to be "kept running."
- **Detection is our own registry key, not HPCMSL's module version.** Consistent with
  every other app in this repo: CI regenerates the detection script from `AppVersion`
  on every publish, so install and detection can never drift apart. It does mean a
  device that already has some other copy of HPCMSL (installed outside this pipeline)
  won't show as "detected" until this app installs over it and writes the key.
- **Setting up the Intune app (first time only)**: the pipeline updates an existing
  Intune app; it doesn't create one. This app's Intune object already exists
  (`ef5253af-d765-4182-aa1d-991f43561bd0`). For reference, a **Windows app (Win32)**
  needs:
  - **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
  - **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
  - **Install behavior:** System
  - **Detection rule:** anything to start with - the pipeline replaces it on first publish
  - **Assignment:** Required, to a device group
