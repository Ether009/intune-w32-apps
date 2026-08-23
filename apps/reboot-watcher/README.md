# Reboot Watcher

Watches each device's uptime and, for security reasons, nudges the signed-in user to
restart once it gets stale - then forces the issue if it's ignored for too long.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8.

---

## What it does on each device

Two scheduled tasks are installed:

1. **"Lunds Fontanhus - Reboot Watcher Check"** - runs as **SYSTEM**, hourly. Reads
   the device's uptime and decides what state the device is in:
   - **Under 14 days:** nothing to do; any leftover state from a previous cycle is
     cleared.
   - **14-29 days:** flags `WarningActive` in the registry for the notify task to
     pick up.
   - **30+ days:** issues the restart itself - `shutdown.exe /r /t 600 /c "<message>"`
     - a 10-minute countdown with a custom Swedish message. Runs as SYSTEM
     specifically so this works even if no one is signed in, and so the native
     Windows countdown notice (rendered at the system level, not tied to whichever
     session issued it) reaches whoever *is* signed in. It only issues this once per
     uptime cycle - a registry timestamp guards against re-issuing (and thus
     perpetually extending) the countdown on every hourly run - but re-issues it if
     the delay has clearly elapsed without a restart happening (e.g. someone with
     admin rights aborted it), rather than leaving the device stuck past the
     threshold indefinitely.

2. **"Lunds Fontanhus - Reboot Watcher Notify"** - runs as **whichever user is
   signed in** (triggered at logon, plus every 4 hours after), because a systray
   balloon can only be raised inside an interactive session - a SYSTEM task runs in
   Session 0, which has no desktop to render one on. If the check task's
   `WarningActive` flag is set (and a forced restart isn't already in flight - that
   case gets its own native notice from `shutdown.exe`, a second balloon would just
   be confusing), it shows a standard Windows systray balloon notification: title
   "Lunds Fontänhus IT - Säkerhetsvarning", body in Swedish, stressing that the
   restart is needed for security reasons.

The install also runs the check task once immediately, so a newly enrolled or
newly updated device evaluates its current uptime right away.

### Why two tasks instead of one

The uptime check and the forced restart need SYSTEM (so they work with nobody signed
in), but the systray balloon can *only* be shown inside an interactive user session -
`System.Windows.Forms.NotifyIcon` has no way to raise a notification into a session
it isn't running in. Splitting the work lets each task run in the context it actually
needs, with the SYSTEM task as the source of truth (written to `HKLM`, readable by
any standard user, writable only by SYSTEM) and the user task as a thin, best-effort
presentation layer that never touches enforcement.

---

## Settings

Edit **`SupportFiles/RebootWatcherConfig.json`**. No PowerShell changes needed.

| Setting | What it does |
|---|---|
| `WarningThresholdDays` | Uptime (days) at which the systray warning starts appearing. Default `14`. |
| `ForceRebootThresholdDays` | Uptime (days) at which a restart is forced. Default `30`. |
| `ForceRebootDelaySeconds` | Countdown before the forced restart, passed to `shutdown.exe /t`. Default `600` (10 minutes). |
| `OrganizationName` | Informational only - not read by either script directly, kept here for reference alongside the message text below. |
| `BalloonTitle` | Title of the systray warning balloon. |
| `BalloonMessage` | Body of the systray warning balloon. `{0}` is replaced with the current uptime in days. |
| `ForceRebootMessage` | The `/c` message passed to `shutdown.exe` for the forced restart. `{0}` is replaced with the current uptime in days. |

### Rolling out a change

1. Edit the JSON.
2. Bump `AppVersion` in `Invoke-AppDeployToolkit.ps1`.
3. Commit and push to `main` (via a merged PR).

CI builds and publishes to Intune automatically. **If you don't bump `AppVersion`,
nothing is published** - the version is how Intune knows there's an update.

---

## Checking on a device

```powershell
# Is the check task there and enabled? When did it last run?
Get-ScheduledTask -TaskName 'Lunds Fontanhus - Reboot Watcher Check'
Get-Content "$env:ProgramData\LundsFontanhus\RebootWatcher\Logs\Invoke-RebootWatcherCheck.log" -Tail 20 -Wait

# Current state as the check task sees it
Get-ItemProperty 'HKLM:\SOFTWARE\LundsFontanhus\RebootWatcher'

# Force an immediate re-check (as SYSTEM's own schedule would)
Start-ScheduledTask -TaskName 'Lunds Fontanhus - Reboot Watcher Check'

# Force the notify task to run now, in your own session, to see the balloon
Start-ScheduledTask -TaskName 'Lunds Fontanhus - Reboot Watcher Notify'

# What version is installed?
(Get-ItemProperty 'HKLM:\SOFTWARE\LundsFontanhus\RebootWatcher').Version
```

To abort a forced restart that's already counting down (requires admin):

```powershell
shutdown /a
```

Note this only cancels the countdown - it does not clear `ForceRebootScheduledUtc`
in the registry, so the check task's safety net will re-issue the restart once the
original delay window has clearly elapsed (delay + 1 hour) if uptime is still past
the threshold. The state only fully resets once the device actually reboots.

---

## Good to know

- **Read-only on the device beyond its own install folder, registry key, and
  scheduled tasks**, except for the forced restart itself, which is the entire point
  of this app.
- **The forced restart is not silent or hideable by a standard user** - it's issued
  by SYSTEM via `shutdown.exe`, which a standard user cannot cancel (`shutdown /a`
  requires admin). This is intentional: the point is that a device that's gone 30+
  days without restarting actually restarts.
- **Multiple concurrent interactive sessions** (e.g. Fast User Switching, RDP) each
  get their own notify task run and their own balloon - there's no dedup across
  sessions, but this is an unusual setup for this fleet's devices.
- **The balloon uses `SupportFiles/Icons/lundsfontan.ico`** (the same icon used by
  the desktop-shortcuts app) so it's visibly a Lunds Fontänhus notification, not an
  unbranded generic warning.

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1              the installer (registers both scheduled tasks)
SupportFiles/
  Invoke-RebootWatcherCheck.ps1            runs hourly as SYSTEM: checks uptime, forces restart
  Show-RebootWatcherNotification.ps1       runs as the logged-on user: shows the systray balloon
  RebootWatcherConfig.json                 the settings and message text you'll actually edit
  Icons/lundsfontan.ico                    branding icon for the balloon
manifest.json                            which Intune app this publishes to
```

Build and publishing are handled by the shared pipeline - see the top-level
[README](../../README.md).

### Setting up the Intune app (first time only)

The pipeline updates an existing Intune app; it doesn't create one. This app's Intune
object already exists (`316cdc38-381e-45cd-9b60-76a5efda5d6c`). For reference, a
**Windows app (Win32)** needs:

- **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
- **Install behavior:** System
- **Detection rule:** anything to start with - the pipeline replaces it on first publish
- **Assignment:** Required, to a device group
