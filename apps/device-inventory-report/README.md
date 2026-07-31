# Device Inventory Report

Collects a comprehensive hardware/security/health snapshot that Microsoft Graph
cannot provide for Intune-managed Windows devices, and reports it to the Dashhouse
Admin UI. Everything Graph *can* expose (RAM, disk capacity, TPM version, BitLocker
status, signed-in users) is already pulled centrally by Dashhouse's own Intune sync
job - this app exists only for what that job structurally cannot get.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8.

---

## What it does on each device

Every day at **04:30** local time (plus up to an hour of random delay so a whole
fleet doesn't hit the ingest endpoint at once), a background task runs as SYSTEM and:

1. Reads the device's Entra ID (Azure AD) device GUID from `dsregcmd /status` - the
   same identifier Dashhouse's Intune sync already stores as `azure_ad_device_id`, so
   a report from this script lines up with a device's existing row with no separate
   mapping step.
2. Collects everything below.
3. Posts the result as JSON to the Dashhouse Admin UI's ingest endpoint, authenticated
   via mutual TLS (see *Ingest authentication* below). The endpoint upserts by device
   ID - no history is kept for most fields, since most of this doesn't need one;
   child lists (network adapters, local admins, monitors) are fully replaced each run
   rather than diffed.

The install also runs the task once immediately, so a newly enrolled or newly updated
device reports in right away rather than waiting for the next scheduled run.

**Why daily, not weekly:** most hardware identity fields (CPU/GPU/disk model) barely
change day to day, but this app also collects things that can - location, which
network the device is attached to, TPM/BitLocker/Defender state, local admin
membership. That data is exactly what matters most *after* a device goes missing. A
weekly cadence means up to six days of blind spot between a device's last known-good
report and it going dark; daily bounds that to under a day.

### What's collected

**Component serials** - chassis, motherboard, BIOS/system, CPU (`ProcessorId` - the
closest thing to a CPU serial Windows exposes; real per-chip serials were dropped
after the Pentium III era), primary disk.

**CPU/GPU** - model name, core/thread count, every connected GPU's model name.

**TPM capabilities and attestation readiness** - present/enabled/activated/owned
state, spec version, manufacturer, Endorsement Key certificate presence, and -
crucially - `tpmReadyForAttestation` / `tpmCapableForAttestation`, read directly from
`tpmtool.exe GetDeviceInformation`'s own fields. This is **Microsoft's own local
determination**, not a guess assembled from raw TPM state: it's why a VM's virtual
TPM correctly reports as not attestation-capable even though it can report TPM 2.0,
enabled/activated/owned. Also captures `TPM Has Vulnerable Firmware` and the
BitLocker PCR7 binding state from the same tool.

**Firmware/boot mode** - whether Windows actually booted via UEFI or the legacy/CSM
path (there's no OS-visible way to read "is CSM enabled" as a standalone firmware
toggle; this reflects how Windows itself booted, which is the meaningful signal in
practice), and Secure Boot state.

**Disk health** - `HealthStatus` from Storage Management, plus SMART/reliability
counters where supported: wear percentage (SSD), temperature, power-on hours,
cumulative read/write error counts.

**Network adapters** (one row per adapter with a MAC address) - name, MAC, media
type, link speed, status, currently-connected SSID for wireless, and **network
location**: IPv4 address, subnet prefix length, default gateway, and the gateway's
MAC address (resolved via the ARP/neighbor cache) - useful for inferring which
building/floor a device is on from which network segment it's connected to, since
Windows has no direct physical-location API.

**Geolocation** - a best-effort Windows Location API fix (GPS or Wi-Fi positioning),
10-second timeout. Running as SYSTEM, this is normally expected to fail or time out,
since location consent is usually an interactive per-user privacy setting SYSTEM
doesn't have - but on this fleet it has been observed to succeed (presumably due to a
tenant-wide location policy), so it's collected rather than assumed impossible.
Denied/unavailable is a normal, logged outcome, not an error.

**Local administrators** - every member of the local Administrators group (looked up
by well-known SID `S-1-5-32-544`, not the localized group name - `Get-LocalGroupMember
-Group 'Administrators'` fails outright on this fleet's Swedish-locale devices).
Azure AD member SIDs are best-effort resolved to a UPN via the identity store cache;
falls back to the raw SID when no cache entry exists (common for a group that's never
itself signed in locally).

**Defender status** - antivirus/real-time-protection enabled, signature age, last
quick/full scan times. `$null` (not "protection off") on a device where a third-party
AV has disabled Defender's engine entirely.

**Pending reboot** - whether the standard Windows/WSUS/CBS registry markers indicate
a restart is needed to finish applying an update.

**Windows activation status** - filtered specifically to the Windows product (not
Office or anything else that happens to have a license installed).

**Battery health** - design capacity, current full-charge capacity, and cycle count,
via `powercfg /batteryreport` rather than the per-vendor WMI battery classes (those
were found unreliable in testing - one returned "Generic failure" on a normal,
healthy battery). All-`$null` (not an error) on a desktop with no battery.

**Connected monitors** - manufacturer/model/serial from EDID data. Laptop-internal
panels frequently leave model/serial blank even when manufacturer is populated -
that's a real limitation of what the panel itself reports, not a parsing failure.

**Last boot time** - for spotting devices that never restart (and so never pick up
patches requiring a reboot).

---

## Where the data goes

`POST https://admin.dashhouse.kaijunet.se:8443/api/inventory`, authenticated via
**mutual TLS** (a shared client certificate) rather than the Entra ID SSO session
auth the rest of the Admin UI uses - this is machine-to-machine. **No secret is ever
part of this app's package or this repo** - see *Ingest authentication* below for why
and how devices actually get the certificate.

- **`device_extra_inventory`** - one row per device (upserted by `azure_ad_device_id`),
  holding everything that isn't inherently a list: serials, TPM/firmware/BitLocker
  state, disk health, Defender/activation/reboot state, battery, geolocation.
- **`device_network_adapters`** - one row per adapter per device, replaced in full on
  every report.
- **`device_local_admins`** - one row per local-admin-group member per device,
  replaced in full on every report.
- **`device_monitors`** - one row per connected monitor per device, replaced in full
  on every report.

Join example for Grafana:

```sql
SELECT ds.device_name, ds.manufacturer, ds.model,
    dei.cpu_model, dei.tpm_ready_for_attestation, dei.tpm_capable_for_attestation,
    dei.disk_health_status, dei.disk_wear_percentage,
    dei.pending_reboot, dei.windows_activation_status,
    dei.defender_realtime_protection_enabled,
    dei.battery_design_capacity_mwh, dei.battery_full_charge_capacity_mwh, dei.battery_cycle_count,
    dei.location_latitude, dei.location_longitude,
    dei.received_at
FROM device_snapshots ds
LEFT JOIN device_extra_inventory dei ON dei.azure_ad_device_id = ds.azure_ad_device_id
WHERE ds.id IN (SELECT MAX(id) FROM device_snapshots GROUP BY device_id)
```

A device that hasn't run the task yet simply has `NULL`s from the join - not an
error.

---

## A note on "attestation ready"

`tpmReadyForAttestation` / `tpmCapableForAttestation` come from `tpmtool.exe`'s own
computation, which accounts for EK certificate validity and PCR bank state - this is
authoritative, not a heuristic built here from raw TPM properties. It's still a
local, offline check rather than a live round-trip to Microsoft's Device Directory
Service, so on rare edge cases it can disagree with what an actual Autopilot
enrollment attempt reports - but it's the same computation Windows itself uses to
answer that question, not a guess. Confirmed in testing: a virtual TPM genuinely
fails this check, which is exactly why VMs can't do self-deploying/white-glove
Autopilot even though they happily report TPM 2.0/enabled/activated/owned.

---

## Ingest authentication (required one-time setup)

**This repo is public.** Nothing that authenticates a device to the ingest endpoint
can live in this app's package or anywhere in this repo - a static secret was tried
first and had to be rotated after it was briefly committed here. The fix: devices
authenticate with a **client certificate (mutual TLS)**, and that certificate is
**injected into the package at CI build time** from GitHub repo secrets - the exact
same pattern this workflow already uses for `INTUNE_CLIENT_SECRET` - rather than
being delivered by any separate mechanism.

Two things were considered and ruled out first, worth knowing so nobody re-discovers
the same dead ends:
- **An Intune Certificate profile** (PKCS certificate / PKCS imported certificate)
  sounds like the obvious native fit, but *both* variants require the **Certificate
  Connector for Microsoft Intune**, which only installs on Windows Server - this
  stack is Ubuntu-only, so that's real infrastructure this org doesn't have and
  would have to stand up just for this.
- **A "Trusted certificate" profile** doesn't help either - it only delivers a
  *public* certificate into the trust store (for a device to trust a CA), never a
  private key. mTLS needs the device to hold a private key to prove its own
  identity, which that profile type structurally cannot deliver.

**How it actually works:**

1. A CA and client certificate were generated once (`openssl`, 5-year validity). The
   server trusts this CA (`/opt/dashhouse-api/certs/ca.crt` on the VM, referenced by
   `DEVICE_INGEST_CA_PATH` / `DEVICE_INGEST_CLIENT_CN` in the Admin UI's `.env`).
2. The client cert+key (as a password-protected PFX) live **only** as two GitHub
   repo secrets: `DEVICE_INGEST_CLIENT_PFX_BASE64` and
   `DEVICE_INGEST_CLIENT_PFX_PASSWORD` (Settings > Secrets and variables > Actions).
   Never in a file in this repo.
3. `build-and-publish.yml`'s "Inject device-inventory-report ingest client
   certificate" step (app-specific, guarded by `if: matrix.app ==
   'device-inventory-report'`) decodes those secrets straight into the **staged**
   package - not the repo checkout - as `SupportFiles/client-cert.pfx` /
   `client-cert.pfx.pw`, right before the `.intunewin` is built. They exist only for
   that CI run and inside the resulting `.intunewin`, which lives in Intune's app
   content storage, not source control.
4. `Invoke-AppDeployToolkit.ps1`'s `Install-IngestClientCertificate` imports the PFX
   into `Cert:\LocalMachine\My` during install, then deletes both files from disk -
   nothing lingers once the private key is in the certificate store. Keyed by
   subject `CN=dashhouse-device-ingest-client`, matching
   `IngestClientCertSubjectCn` in `DeviceInventoryConfig.json`.
5. A **local, hand-assembled test build** (extracting the PSADT template yourself
   rather than letting CI do it) simply won't have these two files - that's expected,
   not a bug. `Install-IngestClientCertificate` logs a warning and continues rather
   than failing the rest of the install, so everything else is still testable
   locally. Only a real CI-built package can actually authenticate to the ingest
   endpoint.

Without the certificate present at runtime, `Get-IngestClientCertificate` in the
collection script logs a clear error and exits - worker-script failure, not a crash,
so Intune sees a clean non-zero exit rather than a hang.

**To rotate:** generate a new CA/cert, update `ca.crt` and the `.env` values on the
VM, restart `dashhouse-admin`, then update the two `DEVICE_INGEST_CLIENT_PFX_*` repo
secrets and bump `AppVersion` to force a republish (this time a version bump *is*
needed, since the new cert has to actually get built into a new package and pushed
to devices).

---

## Settings

Edit **`SupportFiles/DeviceInventoryConfig.json`**. No PowerShell changes needed.

| Setting | What it does |
|---|---|
| `IngestUrl` | The Admin UI's ingest endpoint. |
| `IngestClientCertSubjectCn` | The Subject CN of the client certificate to use for mutual TLS (see *Ingest authentication* above) - identifies which certificate to use, not a secret itself. |

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

Several fields (TPM state via `Get-Tpm`, Secure Boot, disk SMART/wear via
`Get-StorageReliabilityCounter`) require admin - they'll log warnings and come back
`$null`/`False` in an unelevated test shell even though they work correctly running
as SYSTEM. Run the worker script from an elevated prompt to see real values while
testing.

---

## Good to know

- **Read-only on the device.** This app never modifies anything on the machine it
  runs on beyond its own install folder, registry key, and scheduled task - it only
  reads information and sends a report.
- **A device with no Azure AD device ID is skipped, not reported with a blank ID.**
  Hybrid-joined or non-Entra devices where `dsregcmd /status` doesn't return a
  `DeviceId` log a warning and exit without posting.
- **NIC "serial number" isn't collected** - it isn't a real Windows/WMI concept.
  The MAC address is the adapter's unique identifier and is what's collected instead.
- **A run can take up to ~30-40 seconds**, mostly the Windows Location API's 10-second
  timeout when it doesn't get an immediate fix. Well within the task's 15-minute
  execution limit.
- **Non-ASCII text (e.g. Swedish adapter names) requires explicit UTF-8 encoding of
  the outbound request body** - Windows PowerShell 5.1's `Invoke-RestMethod` does not
  reliably send a plain `[String]` body as UTF-8 on its own; the script encodes to
  UTF-8 bytes explicitly before sending.

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1        the installer (registers the scheduled task)
SupportFiles/
  Get-DeviceInventory.ps1           what runs each day
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
