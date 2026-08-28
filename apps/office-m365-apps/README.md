# Microsoft 365 Apps for Windows 10 and later (Win32)

Deploys Microsoft 365 Apps (Word, Excel, PowerPoint, Outlook, Access, Publisher,
OneDrive) via the Office Deployment Tool (ODT), wrapped as a Win32 app.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8, same as
every other app in this repo.

---

## Why this exists instead of Intune's native "Microsoft 365 Apps" app type

Intune has a purpose-built app type for this ("Microsoft 365 Apps for Windows 10
and later") that's normally the right choice - it's still assigned to most of the
fleet directly, not through this repo. This Win32-wrapped version exists **only**
for `sec.device.windows.selfdeploy` (self-deploying Autopilot devices), where the
native type was observed to reliably never install:

- Every other required app on an affected device (Win32 apps delivered via the
  Intune Management Extension - printer drivers, Chrome, Teams, Adobe Reader,
  this repo's own apps) installed within seconds.
- The native Microsoft 365 Apps entry sat at "Waiting for install status"
  indefinitely - hours, on a real device, well past any plausible download time,
  even though the assignment itself (required, correctly targeted, no filter/
  exclusion issue) checked out.
- Rewrapping the *exact same* ODT invocation (`setup.exe /configure
  configuration.xml`) as a Win32 app and assigning it in place of the native type,
  scoped to just this group, fixed it - Office installed normally on the next
  sync.

**The mechanism was never conclusively root-caused.** The native app type isn't
installed by the IME - it uses Windows' Office CSP instead - so the leading theory
was a documented Microsoft concurrency conflict between the native Microsoft 365
Apps type and Win32 app installs during Autopilot's Enrollment Status Page (ESP).
That theory didn't survive a check of this tenant's actual ESP configuration: the
default ESP profile has app-install tracking switched off entirely
(`showInstallationProgress: false`), and the one profile that does track progress
has zero apps in its tracked list. The specific failure mode Microsoft describes
requires Office to be one of ESP's own tracked/blocking apps competing with a
concurrent Win32 install - which structurally can't have happened here, since ESP
wasn't tracking or blocking on Office (or anything else) at all.

So: the fix is real and reproduced once in practice, but *why* the native app
type gets stuck on this fleet's self-deploy devices specifically remains
unexplained. Filed as one of Intune's many unexplained deployment quirks rather
than chased further - if it resurfaces or starts affecting other device
populations, that's worth revisiting with real on-device logs (Office
Click-to-Run verbose logging, per Microsoft's own troubleshooting doc for the
native app type) rather than more remote Graph-side inspection, which is what
this dead end was built on.

**Do not delete or "clean up" the native Microsoft 365 Apps assignment for the
rest of the fleet** - it works fine everywhere else. This Win32 version is
additive and deliberately scoped to `sec.device.windows.selfdeploy` only; the
native app explicitly excludes that same group so devices are never targeted by
both at once.

---

## What it does on each device

`Invoke-AppDeployToolkit.ps1` runs the ODT's own `setup.exe` with a configuration
file, exactly as if an admin ran it by hand:

- **Install:** `setup.exe /configure configuration.xml` - downloads and installs
  Microsoft 365 Apps for Windows (64-bit, `O365ProPlusRetail`, `sv-se` locale,
  Current Channel (Preview) / `FirstReleaseCurrent`), matching the configuration
  of the native app type it replaces for this device population: same excluded
  apps (OneNote, Teams, Bing, SharePoint Designer, Lync/Skype for Business,
  Groove, InfoPath), Shared Computer Activation on, old MSI Office removed,
  silent/no UI.
- **Uninstall:** `setup.exe /configure configuration-uninstall.xml` - removes all
  Office products via ODT's own `<Remove All="TRUE" />`.
- Office apps are asked to close first (`Show-ADTInstallationWelcome`), same as
  any other Office deployment - Office's own installer refuses to proceed
  silently while its apps are open with unsaved work.

**The `.intunewin` package is small (a few MB), not gigabytes.** It only contains
the ODT bootstrapper (`setup.exe`) and two small config files - it does not bundle
the actual multi-GB Office application payload. `setup.exe` streams that down
live from Microsoft's own CDN (`officecdn.microsoft.com`) at install time on the
device itself, the same way the native Microsoft 365 Apps app type does. That's
by design in how Click-to-Run/ODT deployments work, not something specific to
this package - don't mistake the small package size for a broken/incomplete
deployment.

### Detection

This app writes its own marker key,
`HKLM:\SOFTWARE\Organization\OfficeM365AppsWin32\Version`, set to *this wrapper
package's own version* (from `AppVersion` in `Invoke-AppDeployToolkit.ps1`) -
**not** Office's actual installed build number. Office's real version lives
separately at `HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration\
VersionToReport` and is entirely Microsoft's own to manage; comparing that
against this wrapper's own version string would never match, since they're
unrelated numbers. The marker is only written after the ODT call returns a
success or reboot-required exit code - a failed `setup.exe` run never gets marked
as installed. This mirrors every other app in this repo (see e.g.
`profile-cleanup` or `device-inventory-report`) so the shared CI pipeline's
auto-generated version-comparison detection script works the same way here as
everywhere else.

---

## Settings

Edit **`SupportFiles/configuration.xml`** (install) and
**`SupportFiles/configuration-uninstall.xml`** (uninstall) directly - these are
plain Office Deployment Tool XML, not repo-specific. See [Configuration options
for the Office Deployment
Tool](https://learn.microsoft.com/en-us/deployoffice/office-deployment-tool-configuration-options)
for the full schema (channel, excluded apps, languages, shared computer
activation, etc.).

If the native Microsoft 365 Apps app type's configuration ever changes for the
rest of the fleet (update channel, included/excluded apps), update
`configuration.xml` here to match, so the self-deploy population doesn't quietly
drift from everyone else.

### Rolling out a change

1. Edit `SupportFiles/configuration.xml` (or `-uninstall.xml`).
2. Bump `AppVersion` in `Invoke-AppDeployToolkit.ps1`.
3. Commit and push to `main` (via a merged PR).

CI builds and publishes to Intune automatically. **If you don't bump
`AppVersion`, nothing is published** - the version is how Intune knows there's an
update. Bumping the version here does **not** force Office itself to reinstall or
update on already-provisioned devices (Click-to-Run manages its own updates via
the configured `Channel`) - it only controls whether *this package's content* gets
republished to Intune.

### Updating `setup.exe`

`SupportFiles/setup.exe` is Microsoft's Click-to-Run bootstrapper, downloaded from
`https://officecdn.microsoft.com/pr/wsus/setup.exe`. Unlike the HP CMSL installer
in this repo (a specific, dated, versioned release that gets pinned by SHA-256),
this is a rolling/evergreen binary Microsoft updates on their own schedule with no
stable version or hash to pin against - so it's committed directly to the repo
(same as any other app's real source files here) rather than downloaded and
hash-verified at build time. Re-download it from that same URL and replace the
committed file if you want to refresh the bootstrapper itself; this is rarely
necessary since `setup.exe`'s only job is to fetch and drive the real,
independently-versioned Office installation per `configuration.xml`.

---

## Checking on a device

```powershell
# Wrapper's own marker (what Intune's detection rule checks)
(Get-ItemProperty 'HKLM:\SOFTWARE\Organization\OfficeM365AppsWin32').Version

# Office's actual installed version
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration').VersionToReport

# ODT's own install/download logs
Get-ChildItem "$env:ProgramFiles\Microsoft Office\Updates\Download" -ErrorAction SilentlyContinue
```

If Office was assigned but the marker key is missing, check this app's PSADT log
(`Invoke-AppDeployToolkit_Install.log` under the usual PSADT log location) for the
ODT's actual exit code - `Install-ADTDeployment` throws (and leaves the marker
key unset) on any exit code other than a documented success or reboot-required
code.

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1        the installer (runs setup.exe /configure ...)
SupportFiles/
  setup.exe                         Office Deployment Tool bootstrapper (see "Updating setup.exe" above)
  configuration.xml                 install-time ODT configuration
  configuration-uninstall.xml       uninstall-time ODT configuration
manifest.json                      which Intune app this publishes to
```

Build and publishing are handled by the shared pipeline - see the top-level
[README](../../README.md).

### Setting up the Intune app (first time only)

The pipeline updates an existing Intune app; it doesn't create one. This app's
Intune object already exists (`a0b39507-bab0-47eb-8926-7c1da89c68cc`), assigned
Required to `sec.device.windows.selfdeploy` only (with that same group excluded
from the native Microsoft 365 Apps assignment - see *Why this exists* above). For
reference, a **Windows app (Win32)** needs:

- **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
- **Install behavior:** System
- **Detection rule:** anything to start with - the pipeline replaces it on first publish
- **Assignment:** Required, to `sec.device.windows.selfdeploy` only - do not widen
  this without first confirming the native app type's exclusion for that group
  stays in sync, or devices will be targeted by both at once.
