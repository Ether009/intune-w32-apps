# OneDrive Team Sync

Keeps a signed-in user's synced OneDrive Team libraries in sync with their actual Team
memberships: adds newly-joined Teams, removes ones they've lost access to (renamed, removed
from the Team, the Team itself deleted). Deployed as a Win32 app with PSAppDeployToolkit v4.1.8.

---

## Why this exists

Replaces a prior remediation-script-based tool ("OneDrive Sync Setup") that had three real
problems:

1. **Only ever added syncs, never removed them.** If a Team got renamed or the user lost
   access, the old local sync just sat there indefinitely - a known, repeatedly-hit issue.
2. **Ran with a visible console window** on every login, since Intune remediation scripts and
   Startup-folder shortcuts don't reliably suppress a PowerShell window even with
   `-WindowStyle Hidden`.
3. **Hardcoded a Graph app client secret in plaintext** directly in the script body, deployed
   to every device it ran on.

This tool fixes all three: proper add/remove diffing against current Team membership, a
hidden **scheduled task** (not a Startup shortcut - scheduled tasks suppress their process
window far more reliably) triggered at logon, and **certificate-based** app-only Graph auth
(`OneDrive-TeamSync-App`, `Group.Read.All` + `User.Read.All`, nothing broader) instead of a
secret.

The old remediation script object has been deleted from Intune. This installer also actively
removes any leftover copy of it (`C:\Scripts\odsetup.ps1` and its Startup-folder shortcut) from
devices that picked it up before it was retired.

---

## How it works

`Sync-OneDriveTeams.ps1` runs once per user logon (scheduled task, `BUILTIN\Users`, hidden,
15-minute execution limit):

1. Authenticates to Graph app-only via the deployed certificate (JWT client-assertion flow,
   no MSAL dependency).
2. Resolves the current user's UPN via `whoami /upn` and fetches their Team memberships
   (`resourceProvisioningOptions` contains `Team`) and each Team's default document library
   (matched by `list.template -eq 'documentLibrary'`, not a hardcoded/localized display name -
   the old script's hardcoded Swedish "Delade Dokument" name is exactly the kind of thing that
   silently breaks).
3. Reads currently-synced libraries from `HKCU:\Software\SyncEngines\Providers\OneDrive\*`
   (`UrlNamespace` encodes `;{siteId};{webId};{listId}`, `MountPoint` is the local folder).
4. Diffs the two lists:
   - **Missing sync for a current Team** → adds it via `odopen://sync/...` (same mechanism the
     old script used - it's still the only supported way to trigger an add).
   - **Synced library for a site the user is no longer a Team member of** → removes it.

### Removal is unsupported/undocumented, and that's a known tradeoff

**Microsoft provides no official API to unsync a library.** The only community-established way
is deleting that library's registry key under `SyncEngines\Providers\OneDrive` and restarting
OneDrive so it picks up the change. That's what this does - per the explicit decision made when
this was built, it also **deletes the local folder**, not just the sync connection (full
cleanup rather than leaving an orphaned local copy). This is unsupported by Microsoft and could
behave differently after a future OneDrive client update - if removals start misbehaving, this
is the first place to look.

### Conflict handling: channel already synced, Team-level sync wanted

OneDrive only allows one sync per site's document library. If a specific channel folder is
already synced for a Team and the script wants to sync the Team's *main* library, it can't just
add both. On detecting this:

- If the user has previously **approved** this exact swap (by site ID) → automatically unsyncs
  the channel-specific folder and syncs the Team's main library instead.
- If the user has previously **rejected** it → skips silently, doesn't re-prompt.
- Otherwise → shows a Windows toast notification asking Yes/No, and remembers the answer in
  `%LocalAppData%\OneDriveTeamSync\decisions.json` (keyed by site ID) so it's only asked once
  per conflict.

The toast's Yes/No buttons work via a custom `odteamsync://` URI protocol registered at install
time (`HKLM:\SOFTWARE\Classes\odteamsync`) - clicking a button re-invokes this same script with
`-ToastCallback "approve|<siteId>"` or `"reject|<siteId>"`, since a script-hosted toast has no
native activation callback outside a fully packaged app.

### Logging

Everything logs to `%LocalAppData%\OneDriveTeamSync\sync.log` (per-user, since the task runs in
the user's own session).

---

## Settings

`SupportFiles/` is missing `onedrive-teamsync-cert.pfx` / `.pfx.pw` in source control - CI
injects both from repo secrets (`ONEDRIVE_TEAMSYNC_CLIENT_PFX_BASE64` /
`ONEDRIVE_TEAMSYNC_CLIENT_PFX_PASSWORD`) at build time, same pattern as
`device-inventory-report`'s ingest client cert. See `SupportFiles/README.txt` for the exact
certificate rotation steps.

The cert is imported to `LocalMachine\My` at install time, with its private key's file-level
ACL explicitly granted **Read** to `Authenticated Users` - the sync script runs as the
interactive user (not SYSTEM), so it needs to be able to use the key itself. The cert can only
sign token requests for `Group.Read.All`/`User.Read.All` (read-only), which is what makes that
broad-but-read-only grant an acceptable, deliberate tradeoff.

---

## Checking on a device

```powershell
# Wrapper's own marker (what Intune's detection rule checks)
(Get-ItemProperty 'HKLM:\SOFTWARE\Organization\OneDriveTeamSync').Version

# Scheduled task
Get-ScheduledTask -TaskName OneDriveTeamSync

# Per-user sync log (run as that user, or from an admin PowerShell with that user's profile)
Get-Content "$env:LOCALAPPDATA\OneDriveTeamSync\sync.log" -Tail 50

# Remembered conflict decisions
Get-Content "$env:LOCALAPPDATA\OneDriveTeamSync\decisions.json"
```

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1        installer - removes legacy artifacts, imports cert + ACL,
                                    registers the odteamsync:// protocol, creates the logon task
SupportFiles/Sync-OneDriveTeams.ps1  the actual sync logic, deployed to
                                      C:\Program Files\Organization\OneDriveTeamSync\
SupportFiles/                      cert files empty in git - CI injects them at build time
manifest.json                      which Intune app this publishes to
```

Build and publishing are handled by the shared pipeline - see the top-level
[README](../../README.md).

### Setting up the Intune app (first time only)

The pipeline updates an existing Intune app; it doesn't create one. This app's Intune object
already exists (`451986e2-ea47-4a67-b1e5-3c1a2b848486`), currently assigned Required to
**`sec.device.windows.selfdeploy` only, for testing** - the intent is to move this to
corporate-wide (`sec.device.windows.corporate` / `AllCorporate`) once verified working. For
reference, a **Windows app (Win32)** needs:

- **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
- **Install behavior:** System
- **Detection rule:** anything to start with - the pipeline replaces it on first publish
- **Assignment:** Required, `notifications: hideAll`

### Entra app registration

`OneDrive-TeamSync-App` (appId `7a8d6e5a-734c-44ce-8673-3f7c05c47421`) - application
permissions `Group.Read.All` + `User.Read.All`, admin-consented. Nothing broader; nothing
write-capable. Auth is certificate-only, no client secret exists for this app.
