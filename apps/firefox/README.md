# Mozilla Firefox (Win32)

Deploys Firefox ESR via Mozilla's official MSI, wrapped as a Win32 app.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8, same as
every other app in this repo.

---

## Why this exists instead of the native Microsoft Store app

Firefox is also deployed tenant-wide via Intune's native winGetApp (Microsoft Store)
app type - that one stays in place for the rest of the fleet. This Win32 version
exists **only** for `sec.device.windows.selfdeploy` (self-deploying Autopilot
devices), where the native app can't install at all:

- The native app type installs in **user context** (`RunAs: user`) - confirmed via
  the tenant's actual synced policy data, not assumed.
- Microsoft Store app installs are fundamentally per-user; they cannot run against
  the "no user" identity at all.
- Querying a self-deploy device's install state under the no-user identity
  (`/users('00000000-0000-0000-0000-000000000000')/mobileAppIntentAndStates`) showed
  Firefox as `notApplicable` - correctly so, since there's no user for a user-context
  app to install against. It genuinely wasn't a bug, just a structural mismatch
  between deployment type and app type (same root cause class as the Office self-
  deploy issue - see `apps/office-m365-apps/README.md`).

So: same fix shape as Office. Package the same underlying installer as a Win32 app,
scope it to just the population that needs it, exclude that population from the
native app so devices aren't targeted by both.

**Install scope**: Firefox's MSI is confirmed (Mozilla's own source docs) to not be a
"true" Windows Installer package - it just wraps the full installer. What actually
forces a per-machine (all users) install is the MSI's own `ALLUSERS=1` property,
verified directly against the shipped MSI's Property table rather than assumed from
documentation. Running it under SYSTEM context (as this app does, same as every app
in this repo) installs Firefox machine-wide to `C:\Program Files\Mozilla Firefox\`.

**Do not delete or "clean up" the native winGetApp Firefox assignment for the rest of
the fleet** - it works fine everywhere else. This Win32 version is additive and
deliberately scoped to `sec.device.windows.selfdeploy` only; the native app excludes
that same group so devices are never targeted by both at once.

---

## What it does on each device

`Invoke-AppDeployToolkit.ps1` installs/uninstalls via PSADT's native
`Start-ADTMsiProcess` cmdlet against the shipped MSI - a plain, silent
`msiexec`-driven install, nothing custom. No `Show-ADTInstallationWelcome` prompt -
this is an unattended, userless deployment; there's no one to answer a "close
Firefox" dialog.

### Detection

Like every other app in this repo, this writes its own marker key,
`HKLM:\SOFTWARE\Organization\FirefoxWin32\Version`, set to *this wrapper package's*
version (matching the Firefox ESR build it currently ships) - not read from Firefox's
own installed version, since Firefox auto-updates itself independently after install
and this marker only needs to reflect what this package last deployed. Only written
after `Start-ADTMsiProcess` returns without throwing, so a genuinely failed install
never gets marked as installed.

---

## Settings

`SupportFiles/` is deliberately empty in source control - the Firefox ESR MSI
(~70MB) is downloaded by CI from Mozilla's official release archive and verified
against a pinned SHA-256 (see the "Inject Firefox ESR MSI" step in
`build-and-publish.yml`), the same pattern this repo uses for `hp-cmsl`, rather than
committing a large binary to git.

To ship a newer Firefox ESR build:

1. Download the new version from Mozilla's official release archive:
   `https://ftp.mozilla.org/pub/firefox/releases/<version>/win64/en-US/Firefox%20Setup%20<version>.msi`
   (Mozilla's per-version archive URLs are stable/permanent, unlike the "latest"
   bouncer link used to find the current version in the first place - that's why a
   specific version is pinned in CI rather than always fetching newest.)
2. Compute its SHA-256 yourself from the downloaded file - don't copy a hash from
   anywhere else.
3. Update `FIREFOX_MSI_URL` and `FIREFOX_MSI_SHA256` in
   `.github/workflows/build-and-publish.yml`.
4. Query the new MSI's own `ProductCode` property (it can change between ESR
   releases - don't assume it's stable) and update `$FirefoxProductCode` in
   `Invoke-AppDeployToolkit.ps1` to match.
5. Bump `AppVersion` to the new Firefox version.
6. Commit and push to `main` (via a merged PR).

CI builds and publishes to Intune automatically. **If you don't bump `AppVersion`,
nothing is published** - the version is how Intune knows there's an update.

---

## Checking on a device

```powershell
# Wrapper's own marker (what Intune's detection rule checks)
(Get-ItemProperty 'HKLM:\SOFTWARE\Organization\FirefoxWin32').Version

# Is it actually there, and where
Test-Path 'C:\Program Files\Mozilla Firefox\firefox.exe'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{1294A4C5-9977-480F-9497-C0EA1E630130}' -ErrorAction SilentlyContinue
```

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1        the installer (Start-ADTMsiProcess against the MSI)
SupportFiles/                      empty in git - CI injects FirefoxSetup.msi at build time
manifest.json                      which Intune app this publishes to
```

Build and publishing are handled by the shared pipeline - see the top-level
[README](../../README.md).

### Setting up the Intune app (first time only)

The pipeline updates an existing Intune app; it doesn't create one. This app's Intune
object already exists (`38f5a869-64ea-4316-9dc3-cec210b45ccf`), assigned Required to
`sec.device.windows.selfdeploy` only (with that same group excluded from the native
Firefox winGetApp assignment). For reference, a **Windows app (Win32)** needs:

- **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
- **Install behavior:** System
- **Detection rule:** anything to start with - the pipeline replaces it on first publish
- **Assignment:** Required, to `sec.device.windows.selfdeploy` only - do not widen
  this without first confirming the native app's exclusion for that group stays in
  sync, or devices will be targeted by both at once.
