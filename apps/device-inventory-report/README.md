# Device Inventory Report

Fills the one real gap in Dashhouse's device data: Microsoft Graph has no field for
CPU model name on Intune-managed Windows devices. Everything else Dashhouse tracks
(RAM, disk capacity, TPM, BitLocker status, signed-in users, ...) is pulled centrally
by the existing Intune sync job - this app exists only for what that job structurally
cannot get.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8.

---

## What it does on each device

Once a week, **Monday at 04:30** (plus up to an hour of random delay so a whole fleet
doesn't hit the ingest endpoint at once), a background task runs as SYSTEM and:

1. Reads the device's Entra ID (Azure AD) device GUID from `dsregcmd /status`. This is
   the same identifier Dashhouse's Intune sync already stores as `azure_ad_device_id`
   (used to join sign-in data), so a report from this script lines up with a device's
   existing row with no separate mapping step.
2. Reads the CPU model name and core/thread count (`Win32_Processor`).
3. Reads the GPU model name(s) (`Win32_VideoController`) - joined with a comma if a
   device has more than one, e.g. integrated + discrete.
4. Reads the primary (OS) disk's model and media type - SSD/HDD/Unspecified
   (`Get-PhysicalDisk`), useful for upgrade/replace planning that RAM and capacity
   alone don't answer.
5. Posts the result as JSON to the Dashhouse Admin UI's ingest endpoint, authenticated
   with a shared secret header.

The install also runs the task once immediately, so a newly enrolled or newly updated
device reports in right away rather than waiting up to a week.

### Why weekly, not daily

CPU/GPU/disk identity changes rarely - only on a hardware swap. A daily cadence like
the Intune sync (02:00) or profile cleanup (03:00) job would just be wasted requests
against the ingest endpoint for data that isn't moving. Weekly is enough to catch a
hardware change within a few days, and the run-once-on-install covers new devices
immediately.

---

## Where the data goes

`POST https://admin.dashhouse.kaijunet.se:8443/api/inventory`, upserted into the
`device_extra_inventory` table by `azure_ad_device_id` (one row per device - no
history is kept, since hardware identity doesn't need one). The endpoint checks an
`X-Ingest-Key` header against a secret stored in the Admin UI's `.env`
(`DEVICE_INGEST_KEY`) - this is machine-to-machine, so it doesn't go through the
Entra ID SSO session auth the rest of the Admin UI uses.

To use the data in Grafana, join `device_extra_inventory` to `device_snapshots` on
`azure_ad_device_id`:

```sql
SELECT ds.device_name, ds.manufacturer, ds.model,
    dei.cpu_model, dei.cpu_cores, dei.gpu_model, dei.disk_model, dei.disk_media_type,
    dei.received_at
FROM device_snapshots ds
LEFT JOIN device_extra_inventory dei ON dei.azure_ad_device_id = ds.azure_ad_device_id
WHERE ds.id IN (SELECT MAX(id) FROM device_snapshots GROUP BY device_id)
```

A device that hasn't run the task yet (not targeted by the app, or hasn't hit its
weekly window) simply has `NULL`s from the join - not an error.

---

## Settings

Edit **`SupportFiles/DeviceInventoryConfig.json`**. No PowerShell changes needed.

| Setting | What it does |
|---|---|
| `IngestUrl` | The Admin UI's ingest endpoint. |
| `IngestKey` | Shared secret sent as `X-Ingest-Key`. Must match `DEVICE_INGEST_KEY` in the Admin UI's `.env` on the VM - if you rotate one, rotate the other and bump `AppVersion` to republish. |

### Rolling out a change

1. Edit the JSON.
2. Bump `AppVersion` in `Invoke-AppDeployToolkit.ps1`.
3. Commit and push to `main` (via a merged PR).

CI builds and publishes to Intune automatically. **If you don't bump `AppVersion`,
nothing is published** - the version is how Intune knows there's an update.

---

## Checking on a device

```powershell
# Is the task there and enabled?
Get-ScheduledTask -TaskName 'Organization - Device Inventory Report'

# Run it now and watch the log
Start-ScheduledTask -TaskName 'Organization - Device Inventory Report'
Get-Content "$env:ProgramData\Organization\DeviceInventory\Logs\Get-DeviceInventory.log" -Tail 20 -Wait

# What version is installed?
(Get-ItemProperty 'HKLM:\SOFTWARE\Organization\DeviceInventory').Version
```

To test the worker script directly without waiting for the scheduled task (harmless -
it only reads hardware info and posts a report):

```powershell
& "$env:ProgramData\Organization\DeviceInventory\Get-DeviceInventory.ps1"
```

---

## Good to know

- **Read-only on the device.** This app never modifies anything on the machine it
  runs on beyond its own install folder, registry key, and scheduled task - it only
  reads hardware info and sends a report.
- **A device with no Azure AD device ID is skipped, not reported with a blank ID.**
  Hybrid-joined or non-Entra devices where `dsregcmd /status` doesn't return a
  `DeviceId` log a warning and exit without posting, rather than sending a report
  Dashhouse couldn't correlate to anything.
- **Multi-GPU devices report every GPU**, comma-separated, rather than picking one -
  useful for devices with both integrated and discrete graphics.
- **The primary disk is the one holding the OS partition**, identified via
  `Win32_DiskPartition`/`Win32_LogicalDisk`, not just "whichever disk comes first" -
  falls back to the first disk reported if that lookup fails for any reason.

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1        the installer (registers the scheduled task)
SupportFiles/
  Get-DeviceInventory.ps1           what runs each week
  DeviceInventoryConfig.json         the settings you'll actually edit
manifest.json                      which Intune app this publishes to
```

Build and publishing are handled by the shared pipeline - see the top-level
[README](../../README.md).

### Setting up the Intune app (first time only)

The pipeline updates an existing Intune app; it doesn't create one. This app's Intune
object already exists (`fb42f268-29c8-4520-a3e4-227120fde04f`). For reference, a
**Windows app (Win32)** needs:

- **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
- **Install behavior:** System
- **Detection rule:** anything to start with - the pipeline replaces it on first publish
- **Assignment:** Required, to a device group
