# Adobe Creative Cloud Desktop (Win32)

Deploys the Adobe Creative Cloud Desktop launcher via Adobe's official ESD
installer, wrapped as a Win32 app.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8, same as
every other app in this repo.

---

## Why this exists instead of the native Microsoft Store app

Creative Cloud is also deployed via Intune's native winGetApp (Microsoft Store) app
type, assigned to the small `Adobe Datorer` device group. Unlike Firefox and Office,
that native app already runs in **system context** (`runAsAccount: system`) and is
not individually broken - it isn't affected by the user-context/self-deploy bug that
forced the Firefox and Office migrations.

This Win32 version exists purely per the tenant's broader policy decision to move
off msstore/winget app types generally, since that app type class has caused ESP and
context problems elsewhere in the fleet. `Adobe Datorer` has **no overlap** with
`sec.device.windows.selfdeploy` today, so there was nothing to "fix" for self-deploy
specifically - this app is scoped to `sec.device.windows.selfdeploy` so those devices
start getting Creative Cloud Desktop going forward. The native app and its
`Adobe Datorer` assignment are untouched.

**Scope note**: this only installs the Creative Cloud Desktop *launcher*. It does
NOT pre-install or pre-license individual creative apps (Photoshop, Illustrator,
etc.) - this tenant's Adobe licenses are individual/nonprofit-discounted, not
Teams/Enterprise Admin Console-managed, so there is no API or package mechanism to
silently install a specific creative app tied to a specific license. Users still
sign in to Creative Cloud Desktop with their own Adobe account and click Install on
whichever app they need.

---

## What it does on each device

`Invoke-AppDeployToolkit.ps1` runs the installer's own bootstrapper
(`Set-up.exe --silent`) via PSADT's `Start-ADTProcess` - `--silent` is Adobe's
documented enterprise/unattended switch for this ESD-style installer (the same
switch Adobe Admin Console package exports produce). No `Show-ADTInstallationWelcome`
prompt - this is an unattended, userless deployment; there's no one to answer any
dialog.

### Uninstall

Uses Adobe's documented enterprise uninstall path - the ADC/AAM common installer
engine ("HDBox") shipped with every Creative Cloud Desktop install:
`C:\Program Files\Common Files\Adobe\Adobe Desktop Common\HDBox\Setup.exe --uninstall --silent`.
**Not yet exercised against a real device in this tenant** - verify on the first
real uninstall and correct here if Adobe's actual behavior differs.

### Detection

Like every other app in this repo, this writes its own marker key,
`HKLM:\SOFTWARE\Organization\CreativeCloudWin32\Version`, set to *this wrapper
package's* version - not read from Creative Cloud Desktop's own installed version,
since it auto-updates itself independently after install and this marker only needs
to reflect what this package last deployed. Only written after `Start-ADTProcess`
returns without throwing, so a genuinely failed install never gets marked as
installed.

---

## Settings

`SupportFiles/` is deliberately empty in source control - the Creative Cloud
Desktop ESD installer (~315MB unpacked: `Set-up.exe` + `packages/` + `resources/`)
is downloaded by CI from Adobe's official CDN and verified against a pinned
SHA-256 (see the "Inject Creative Cloud installer" step in
`build-and-publish.yml`), the same pattern this repo uses for Firefox and hp-cmsl,
rather than committing a large binary to git.

To ship a newer Creative Cloud Desktop build:

1. Find the current direct-download link from Adobe's official direct-links page
   (do not use a search result or a third-party mirror).
2. Download the ZIP yourself and compute its SHA-256 directly from the downloaded
   file - don't copy a hash from anywhere else.
3. Update `CREATIVE_CLOUD_ZIP_URL` and `CREATIVE_CLOUD_ZIP_SHA256` in
   `.github/workflows/build-and-publish.yml`.
4. Bump `AppVersion` in `Invoke-AppDeployToolkit.ps1` to the new Creative Cloud
   Desktop version (check `packages/ApplicationInfo.xml` inside the extracted ZIP
   if the version isn't obvious from the filename).
5. Commit and push to `main` (via a merged PR).

CI builds and publishes to Intune automatically. **If you don't bump `AppVersion`,
nothing is published** - the version is how Intune knows there's an update.

---

## Checking on a device

```powershell
# Wrapper's own marker (what Intune's detection rule checks)
(Get-ItemProperty 'HKLM:\SOFTWARE\Organization\CreativeCloudWin32').Version

# Is it actually there
Test-Path 'C:\Program Files\Adobe\Adobe Creative Cloud\Creative Cloud.exe'
```

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1        the installer (Start-ADTProcess against Set-up.exe --silent)
SupportFiles/                      empty in git - CI extracts the Creative Cloud installer at build time
manifest.json                      which Intune app this publishes to
```

Build and publishing are handled by the shared pipeline - see the top-level
[README](../../README.md).

### Setting up the Intune app (first time only)

The pipeline updates an existing Intune app; it doesn't create one. This app's
Intune object already exists (`0e385de4-71d2-450f-a638-99b289a55539`), assigned
Required to `sec.device.windows.selfdeploy` only. For reference, a
**Windows app (Win32)** needs:

- **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
- **Install behavior:** System
- **Detection rule:** anything to start with - the pipeline replaces it on first publish
- **Assignment:** Required, to `sec.device.windows.selfdeploy` only, with
  `notifications: hideAll` (fully silent - no PSADT UI and no native Intune toast).
