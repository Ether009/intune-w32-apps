# User Profile Cleanup

Keeps managed Windows devices from filling up with stale user profiles. A daily
scheduled task deletes profiles nobody has used for a while, empties the Downloads
folder of shared accounts, clears browser caches, and reclaims OneDrive disk space.

Deployed to Intune as a Win32 app built with PSAppDeployToolkit v4.1.8. Everything you
normally need to change lives in one JSON file.

---

## What it does on each device

Once a day at **03:00** (plus up to an hour of random delay so a whole fleet doesn't
wake at once), a background task runs as SYSTEM and:

1. **Looks at every user profile** on the device and works out how long since each was
   genuinely last used (see *How "last used" is worked out* below).
2. **Deletes the ones past the retention window** (default **30 days**) - except the
   profiles it must never touch (below).
3. **Empties the Downloads folder** of any account listed as a purge target, every run,
   regardless of age. This is for shared/generic accounts that shouldn't leave files
   sitting in a folder everyone can reach.
4. **Frees up OneDrive space** on the profiles it keeps, by making synced files
   "online-only". Never on an account that is signed in.
5. **Clears browser caches** for accounts nobody is signed into.
6. **Optionally redirects folders into OneDrive** - `Videos`, `Music` or `Downloads` -
   so content that would otherwise only ever exist on the local disk starts syncing
   (off by default).

It also writes a log on the device and can send a summary to a Power Automate flow so
you get an email or Teams message instead of checking machines by hand.

### Profiles it never touches

- **The most recent users** - by default the **2** most recently used profiles.
  Whoever is signed in right now is always one of them, so an active user is never
  disturbed. Excluded profiles (below) don't count towards these slots: they're kept
  anyway, so letting them take a slot would waste the protection on a profile that
  doesn't need it and leave a real user without it.
- **Anyone you list** in `ExcludedSids` or `ExcludedUsernames`. These are never
  deleted, and never signed out or otherwise disturbed either.
- **A profile with no recorded last-use time** - kept and flagged in the log, since its
  age can't be determined.

Windows' own built-in profiles (SYSTEM, Default, Public, and similar) are excluded
automatically.

### How "last used" is worked out

Windows' own `LastUseTime` value is **not** trusted, because it reports the *current*
time for any profile whose registry hive is still loaded - and hives routinely stay
loaded long after someone signs out, especially on shared machines. Taken at face value
it makes every such profile look like it was used today.

Instead, each profile's last use is resolved in this order, and the report tells you
which one was used:

| Source shown in the report | Trusted? | Meaning |
|---|---|---|
| `signed in now` | yes | That user has a live session on the device right now - of any age. |
| `unknown (loaded, never unloaded)` | - | A background service account whose hive Windows loaded at boot and has never released. Reported as unknown, so it is kept. |
| `unknown (no usable timestamp)` | - | Nothing readable at all. Also kept. |
| `recent activity` | yes | One of the user's own local folders (jump lists, browser profile) was last touched then. The report names which folder. |
| `profile unload time` | yes | When the profile last finished being used, from the registry. |
| `NTUSER.DAT (untrusted fallback)` | no | Only used when nothing trustworthy exists. |
| `LastUseTime (untrusted fallback)` | no | Last resort of all. |

Apart from a live session, the **newest of the two trusted signals** wins. Both are
needed: the unload time freezes for the whole length of a session (so someone signed in
for a month, whose machine then reboots, would look untouched since the day they
started), while activity folders only move when the user actually does something.

**`NTUSER.DAT` is deliberately not trusted.** Windows servicing, policy processing and
management agents rewrite it on machines nobody has signed into for months, which made
profiles look freshly used. It is reported only when nothing else is available, and is
labelled as untrusted when it is.

**A profile that is loaded but has never once unloaded is reported as unknown**, not
aged. That shape belongs to accounts Windows loads for its own services rather than to
anybody who signs in - their folders were written when the image was built and never
since, so an activity date would read as years old and mark them for deletion.

If nothing yields a usable time, the profile is **kept** and flagged as unknown rather
than being guessed at.

**Which folders count as activity** is set by `ActivityPaths` in the config. A folder
only belongs there if nothing but that user, *on that machine*, writes to it. Two
categories are deliberately absent:

- `AppData\Local\Temp`, `AppData\Local\Packages` - Storage Sense, cleanup tools and
  Store servicing write these for every profile on the device.
- `Desktop`, `Documents`, `Downloads` - OneDrive Known Folder Move syncs these, so a
  change made on *any* device updates the folder everywhere. Observed live: two
  separate machines reported the same profile's `Downloads` with an identical
  timestamp to the minute, for a user who had signed into neither in months.

What's left is local-only and never synced: jump lists and browser profile folders.
If you find another folder behaving this way, remove it from `ActivityPaths` - the
`Signals` field names the folder responsible, and it's a config edit, not a code change.

Every entry also carries a `Signals` field showing all the raw values behind the
decision, including local times and which folder supplied the activity figure:

```
unload=2026-05-29 14:02 activity=2026-07-25 23:05 [Downloads] ntuser=2026-07-24 03:11 lastuse=2026-07-24 03:11 loaded=False
```

If an age looks wrong, that line identifies the culprit without visiting the device -
and the clock times let you correlate it against a known sign-in or against this task's
own run time.

> If a report shows several profiles all at `0 day(s) ago` via `LastUseTime`, that's the
> symptom of the problem above - treat those ages as unreliable and check the device.

---

## Settings

Edit **`SupportFiles/ProfileCleanupConfig.json`**. No PowerShell changes needed.

| Setting | Default | What it does |
|---|---|---|
| `RetentionDays` | `30` | Delete a profile once it hasn't been used for this many days. |
| `LogOnly` | `false` | **Safety switch.** While `true`, nothing is deleted - the log just says what *would* be deleted. Now `false`, so profiles past the retention window are deleted for real. Set it back to `true` to return to reporting only. |
| `ActivityPaths` | *(3 local folders)* | Folders treated as evidence the user did something. Only include folders nothing but that user writes to - see *How "last used" is worked out*. |
| `ProtectedRecentUsers` | `2` | How many of the most recent users to protect. `1` protects only the current user. |
| `ExcludedSids` | `[]` | SIDs that are always kept, e.g. `"S-1-5-21--500"` for a local admin account. |
| `ExcludedUsernames` | `["IntelTelemetryAgent", "WsiAccount"]` | Usernames that are always kept, e.g. `"backupadmin"`. Case-insensitive. If an account has been deleted from Entra, use `ExcludedSids` instead - the name no longer resolves. |
| `NotificationWebhookUrl` | *(set)* | Where to send the run summary. Blank turns notifications off. |
| `NotifyOnlyIfActionable` | `false` | `true` = only notify when something was found. `false` = notify every run, so silence means something's wrong. |
| `IncludeProfileSize` | `true` | Include each profile's size in the report. Turn off if runs are slow - this is the most expensive part. |
| `TopFolderMinMB` | `0` | Only list folders for profiles at least this large. `0` lists them for every profile, so every row in the card expands the same way. Raise it if you only care about big profiles. Does not affect how long a run takes. |
| `TopFolderCount` | `10` | How many folders to list per profile. `0` turns the listing off entirely. Folders under 1 MB are never listed, and the list is trimmed automatically on devices with many profiles so the Teams card stays within its size limit. |
| `Dehydrate` | `true` | Free up OneDrive space on the profiles being kept. Never runs on an account that is signed in. See below. |
| `AdditionalDehydrateFolders` | `[]` | Extra folders to treat as OneDrive-synced, relative to the profile folder. Only needed if automatic detection misses one. |
| `ClearBrowserCaches` | `true` | Empty Edge, Chrome and Firefox caches on profiles nobody is signed into. Caches rebuild themselves, so the only cost is a slower first page load. Their size is reported either way, so you can see what turning this on would gain. |
| `BrowserCachePaths` | *(7 patterns)* | Which cache folders to empty. Wildcards cover each browser profile (`Default`, `Profile 1`, Firefox's random names). |
| `RedirectFolders` | `[]` | Folders to redirect into OneDrive so they sync from now on, e.g. `["Videos"]`. Only `Videos`, `Music` and `Downloads` \u2014 Known Folder Move already covers the rest. Moves real data, so it does nothing while `LogOnly` is on. See below. |
| `DownloadsPurgeUsernames` | `["shared-user"]` | Accounts whose Downloads folder is emptied every run. |
| `DownloadsPurgeUpns` | `[]` | Same, matched by UPN instead of name. An account matches if *either* list matches, so a rename won't break it. |
| `ScanDownloads` | `true` | Collect Downloads folder statistics for other users. Currently unused - groundwork for a future "your Downloads folder is large" reminder. |

### Rolling out a change

1. Edit the JSON (and/or drop in a new value above).
2. Bump `AppVersion` in `Invoke-AppDeployToolkit.ps1`.
3. Commit and push to `main`.

CI builds and publishes to Intune automatically. **If you don't bump `AppVersion`,
nothing is published** - the version is how Intune knows there's an update.

> **Changes take effect fleet-wide as each device syncs**, not gradually. There's no
> staged rollout. Turning off `LogOnly` (or turning on `Dehydrate`) starts real
> deletions on every assigned device within hours - the install runs the task once
> immediately rather than waiting for 03:00. Review the log output first, and consider
> a test device group.

---

## Downloads purge for shared accounts

Accounts in `DownloadsPurgeUsernames` / `DownloadsPurgeUpns` get their Downloads
folder emptied on **every** run - files and subfolders, whatever their age. There is
no preview mode for this; it acts as soon as a device has the config.

If a file is open and can't be deleted, the account is signed out to release it and
the delete is retried - **unless** that account is one of the protected recent users,
in which case it's left alone and retried next run. An active user is never signed out
mid-work.

---

## OneDrive space reclaim (optional, off by default)

With `Dehydrate` set to `true`, profiles this run is **keeping** have their
OneDrive-synced content (including synced SharePoint libraries) made **online-only** -
the same as right-clicking a folder and choosing "Free up space". Files stay visible
and re-download when opened; only the local copy is released.

This applies to the profiles that are staying, including recent and protected users -
not to stale ones. A stale profile is going to be deleted, so releasing its local
copies first reclaims nothing that deleting it wouldn't have; the space worth
reclaiming is in the accounts still in use.

**A profile with someone signed into it is always skipped**, since dehydrating
underneath a signed-in user would evict files they may have open. In practice the task
runs at 03:00, when most accounts are signed out.

### Redirecting other folders into OneDrive

OneDrive's Known Folder Move only covers **Desktop, Documents and Pictures**. Videos,
Music and Downloads stay on the local disk however KFM is configured, so a shared
account that collects large files in `Videos` fills the disk with content that is
neither synced nor recoverable once the profile is deleted.

List those folders in `RedirectFolders` (e.g. `["Videos"]`) and each run will point
them into the profile's OneDrive folder and move what's already there across. From
then on the folder syncs like any other, so the files upload the next time that user
signs in, and a later run can dehydrate them to free the local space.

- Only `Videos`, `Music` and `Downloads` are accepted. The other three are KFM's job,
  and competing with the policy would just fight it.
- Skipped for any account that is signed in, and for any account where OneDrive has
  never been set up - redirecting into a OneDrive that doesn't exist would strand the
  files with nothing to sync them.
- A folder already inside OneDrive is left alone, so re-running is harmless.
- **Content from every device is merged**, not just the first one's. The same account
  on several machines has a different `Videos` folder on each, and the first device to
  redirect fills the OneDrive one; later devices merge into it rather than giving up:
  - a file that isn't there yet is moved across
  - a file that is genuinely already there - same size and timestamp - has its local
    copy removed, since that content is in OneDrive already and leaving it would
    orphan an invisible copy in a folder that is no longer the known folder
  - a *different* file that happens to share a name is moved under a name tagged with
    the device, so both survive, e.g. `holiday (LUNDFONTAN-53).mp4`
  - a folder that exists on both sides is merged into, not skipped

  Files are compared by size and timestamp, never by reading them: the OneDrive copy
  is usually online-only, and reading it would download the whole file.
- **Nothing is moved while `LogOnly` is `true`** - the report says what it would do.
  Unlike dehydration this moves real data, so it follows the same safety switch as
  deletion.
- The space is not freed at the moment of redirection. The files upload on that user's
  next sign-in, and are released locally the first time a run dehydrates them
  afterwards.

> **This one is a prototype.** It changes files directly rather than going through the
> OneDrive client, which means it can't confirm a file finished uploading first. In
> normal use (a user signed out cleanly, sync caught up) that's fine, but it's the
> reason this is off by default. Test on a non-critical device before enabling it
> fleet-wide.

---

## Notifications

Set `NotificationWebhookUrl` to a Power Automate flow URL and each run posts a JSON
summary - device name, counts, and a per-profile breakdown (capped at 25 entries; the
device log always has the full list).

**Setting up the flow:**

1. **[make.powerautomate.com](https://make.powerautomate.com)  Create  Instant cloud
   flow**  choose the **"When a HTTP request is received"** trigger.
2. Open the trigger and set **"Who can trigger the flow"** to **Any user**. If you
   leave it on the default, every call is rejected with a `401` error.
3. Paste the schema below into the trigger's **Request Body JSON Schema** box. Use this
   rather than *"Use sample payload to generate schema"* - a generated schema is
   stricter than it needs to be and rejects devices running older versions.
4. Add **Send an email (V2)** or **Post message in a chat or channel**, and build the
   message from the available fields. Use an **Apply to each** over `Details` to list
   the profiles.
5. Save, reopen the trigger, and copy the **HTTP POST URL** into
   `NotificationWebhookUrl`.

**Request Body JSON Schema:**

```json
{
    "type": "object",
    "properties": {
        "DeviceName": { "type": "string" },
        "Version": { "type": "string" },
        "RunTime": { "type": "string" },
        "RunTimeUtc": { "type": "string" },
        "RetentionDays": { "type": "integer" },
        "LogOnly": { "type": "boolean" },
        "ProfilesEvaluated": { "type": "integer" },
        "Kept": { "type": "integer" },
        "Candidates": { "type": "integer" },
        "Deleted": { "type": "integer" },
        "Errors": { "type": "integer" },
        "ReclaimableMB": { "type": ["number", "null"] },
        "DetailsTruncated": { "type": "boolean" },
        "Details": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "DeviceName": { "type": "string" },
                    "Profile": { "type": "string" },
                    "LastUsed": { "type": "string" },
                    "AgeDays": { "type": ["number", "null"] },
                    "SizeMB": { "type": ["number", "null"] },
                    "SizeMBAfter": { "type": ["number", "null"] },
                    "IsCandidate": { "type": "boolean" },
                    "TopFolders": { "type": "string" },
                    "DehydratableMB": { "type": ["number", "null"] },
                    "DownloadsFreedMB": { "type": ["number", "null"] },
                    "BrowserCache": { "type": "string" },
                    "BrowserCacheFreedMB": { "type": ["number", "null"] },
                    "BrowserCacheFreeableMB": { "type": ["number", "null"] },
                    "Action": { "type": "string" },
                    "OneDrive": { "type": "string" },
                    "DownloadsPurge": { "type": "string" },
                    "FolderRedirect": { "type": "string" },
                    "Signals": { "type": "string" }
                }
            }
        }
    }
}
```

**This schema accepts every version ever deployed.** Nothing is marked required, so a
device on an older build that omits newer fields still reports successfully - you just
get blank columns for what it doesn't send. It also allows extra properties, so a future
field won't break the flow before you get around to updating this.

### What the fields mean

| Field | Meaning |
|---|---|
| `DeviceName` | The computer. Also repeated on each `Details` entry, so rows stay identifiable if you combine devices into one list. |
| `Version` | The config version this run used. Shows `Unknown` for devices running very old builds that predate versioning. |
| `RunTime` | When the run happened, in the device's local time - use this one. |
| `RunTimeUtc` | Same moment in UTC, kept so existing flows referencing it keep working. |
| `RetentionDays`, `LogOnly` | The settings that run used - handy for spotting a device on stale config. |
| `ProfilesEvaluated`, `Kept`, `Candidates`, `Deleted`, `Errors` | Run totals. `Candidates` is what *would* be deleted while `LogOnly` is on. |
| `ReclaimableMB` | Everything this run freed or could free on the device: stale profiles, Downloads emptied on purge accounts, browser caches (cleared or still sitting there), and dehydration - what it released, or what it *could* release on profiles it didn't run for. Nothing is counted twice. Totalled across the full list even when `Details` was truncated. |
| `Details[].IsCandidate` | `true` for a stale, unprotected profile - one this run would delete, did delete, or tried to. Use this to filter rather than reading the `Action` text. |
| `Details[].DehydratableMB` | What dehydration could still release from this profile - the files physically present inside its OneDrive-synced folders. Already-online-only files aren't counted, so this is the real remaining opportunity.  if OneDrive isn't synced here. |
| `Details[].BrowserCache`, `Details[].BrowserCacheFreedMB` | What browser cache cleanup did and how much it released. Empty/ unless it ran. |
| `Details[].DownloadsFreedMB` | Space actually released by emptying this profile's Downloads folder. Locked items that survived are not counted. |
| `Details[].TopFolders` | The profile's biggest folders, one per line. Big folders are broken down further than small ones - see *Reading the folder list*. Empty only if the profile is under `TopFolderMinMB`, has no folder over 1 MB, or sizes weren't measured. |
| `DetailsTruncated` | `true` if more than 25 profiles were found; the device log has the full list. |
| `Details[].Profile` | Account name, or the raw SID if the account no longer exists. |
| `Details[].LastUsed` | How long since that profile was used, and which signal said so - e.g. `"41 day(s) ago (via profile unload time)"`. See *How "last used" is worked out*. |
| `Details[].Signals` | All raw signals behind that decision, for diagnosing a wrong age - e.g. `unload=2026-03-27 activity=2026-03-27 ntuser=2026-07-25 lastuse=2026-07-25 loaded=False`. |
| `Details[].SizeMB` | Profile size **before** dehydration - space actually used on this disk. Files stored online-only in OneDrive aren't counted, since they take up nothing locally. `0` when not measured (e.g. `IncludeProfileSize` off). |
| `Details[].SizeMBAfter` | Profile size **after** dehydration, so you can see what a run reclaimed. Same as `SizeMB` when nothing was dehydrated - which is every run while `Dehydrate` is off. |
| `Details[].Action` | What happened and why - e.g. `Kept - most recently used profile on this device`. |
| `Details[].OneDrive`, `Details[].DownloadsPurge`, `Details[].FolderRedirect` | Empty unless those features applied to that profile. |
| `Details[].AgeDays` | **Legacy.** Only sent by very old builds, which used a number here instead of `LastUsed`. Present in the schema purely so those devices still validate. |

> **If you add or rename a field later**, add it to this schema too. Fields must also
> keep a consistent type - a field typed as a number here must never arrive empty, or
> the flow rejects the whole payload with `400 Bad Request`.

### Making the Teams message readable

Posting the payload straight to Teams gives you a wall of JSON. Power Automate can
turn it into an **Adaptive Card** instead - a proper formatted card with the device
name, a one-line summary, and one row per profile, with stale ones in red:

```

 085-W11-MINISTA                              <- amber band, green when clean
 6 stale  12294.6 MB reclaimable           

 alice                             4541.4 MB  <- red = would be deleted
 46 day(s) ago (via recent activity)        
 charlie                          7297.2 MB  <- normal = keeping it
 2 day(s) ago (via profile unload time)     

Retention 30 days  2026-07-26 00:10:14
```

It takes two actions. Follow the steps exactly - **the names matter**, because the
second step refers to the first one by name.

#### Step 1 - refresh the trigger schema

Open the flow, edit the **When a HTTP request is received** trigger, and paste in the
schema from the section above. Without this, `ReclaimableMB` won't show up in the
dynamic-content list. Do this only once every device has updated.

#### Step 2 - build the profile rows

**New step  Data Operations  Select.** Rename it to exactly **`Build rows`**
(click its title to rename).

- **From**: pick `Details` from the dynamic-content list.
- **Map**: click the small icon on the right of the Map box to switch it to **text
  mode**, then paste this in as a single block:

```json
{ "type": "Container", "spacing": "small", "separator": true, "selectAction": { "type": "Action.ToggleVisibility", "targetElements": [ "folders-@{item()?['Profile']}" ] }, "items": [ { "type": "ColumnSet", "columns": [ { "type": "Column", "width": "stretch", "items": [ { "type": "TextBlock", "text": "@{item()?['Profile']}", "weight": "bolder", "wrap": true, "color": "@{if(item()?['IsCandidate'], 'attention', 'default')}" } ] }, { "type": "Column", "width": "auto", "items": [ { "type": "TextBlock", "text": "@{if(greater(float(item()?['SizeMB']), 1024), concat(formatNumber(div(float(item()?['SizeMB']), 1024), 'N1'), ' GB'), concat(formatNumber(float(item()?['SizeMB']), 'N0'), ' MB'))}", "isSubtle": true } ] } ] }, { "type": "TextBlock", "text": "@{item()?['LastUsed']}", "size": "small", "isSubtle": true, "wrap": true, "spacing": "none" }, { "type": "TextBlock", "id": "folders-@{item()?['Profile']}", "isVisible": false, "text": "@{item()?['TopFolders']}", "size": "small", "isSubtle": true, "wrap": true, "spacing": "small" } ] }
```

This turns each profile into one block of the card. `item()` means "the profile this
row is about", so `item()?['Profile']` is that profile's name, and the `?` avoids an
error if a field is missing. The `if(...)` on `color` is what paints a stale profile
red: it reads `IsCandidate` and picks `attention` (red) or `default`.

The size expression shows GB above a gigabyte and MB below it, so a 96 GB profile
doesn't read as `98547.4 MB`. **`float(...)` is not optional there**: `div()` does
whole-number division when both numbers are whole, and a size like `809` arrives as a
whole number - without `float()` it would display as `0 GB`.

**Clicking a profile** shows its biggest folders. That is the last block: a hidden
text box holding `TopFolders`, plus the `selectAction` on the container, which makes
clicking anywhere on that profile's row show or hide it. The `id` includes the profile
name so each row toggles only its own list. Profiles under `TopFolderMinMB` have
nothing to show, so clicking them does nothing.

#### Step 3 - post the card

Delete the existing Teams "Post message" action and add **Post adaptive card in a
chat or channel** (Microsoft Teams).

- **Post as**: `Flow bot`
- **Post in**: `Channel`, then pick the team and channel
- **Adaptive Card**: paste this in

```json
{
  "type": "AdaptiveCard",
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "version": "1.4",
  "body": [
    {
      "type": "Container",
      "bleed": true,
      "style": "@{if(greater(triggerBody()?['Candidates'], 0), 'warning', 'good')}",
      "items": [
        { "type": "TextBlock", "text": "@{triggerBody()?['DeviceName']}", "size": "large", "weight": "bolder", "wrap": true },
        { "type": "TextBlock", "text": "@{if(greater(triggerBody()?['Candidates'], 0), concat(string(triggerBody()?['Candidates']), ' stale  ', formatNumber(div(float(triggerBody()?['ReclaimableMB']), 1024), 'N1'), ' GB reclaimable'), 'Nothing stale')}", "spacing": "none", "isSubtle": true, "wrap": true },
        { "type": "TextBlock", "text": "@{triggerBody()?['Version']}", "spacing": "small", "size": "small", "isSubtle": true, "wrap": true }
      ]
    },
    { "type": "Container", "items": @{body('Build_rows')} },
    { "type": "TextBlock", "text": "Retention @{triggerBody()?['RetentionDays']} days  @{triggerBody()?['RunTime']}", "size": "small", "isSubtle": true, "wrap": true }
  ]
}
```

`triggerBody()` means "the report that arrived", so `triggerBody()?['DeviceName']` is
the device name. `body('Build_rows')` pulls in the rows from step 2 - **note the
underscore**: Power Automate writes a space in an action name as `_` inside
expressions, which is why that step had to be named `Build rows`.

The coloured band at the top comes from the `style` line: amber when the run found
stale profiles, green when it didn't.

Save, then run a device task manually to check it.

#### If something goes wrong

- **The designer flags the card JSON as invalid.** The `"items": @{body('Build_rows')}`
  line is an expression where a list is expected, which the editor sometimes objects
  to even though it runs correctly. Save and test it before assuming it is broken.
- **The card is empty or the run fails on `Build_rows`.** The name doesn't match.
  Check the Select action is called exactly `Build rows`.
- **You would rather have something simpler**, use **Data Operations  Create HTML
  table** instead of steps 2 and 3: point its **From** at `Details` and put
  `@{body('Create_HTML_table')}` into an ordinary Teams "Post message" action. It is
  plainer, but it is one action and no card JSON.

---

## Checking on a device

```powershell
# Is the task there and enabled?
Get-ScheduledTask -TaskName 'Organization - Cleanup Stale User Profiles'

# Run it now and watch the log
Start-ScheduledTask -TaskName 'Organization - Cleanup Stale User Profiles'
Get-Content "$env:ProgramData\Organization\ProfileCleanup\Logs\Remove-StaleProfiles.log" -Tail 30 -Wait

# Which profiles exist, and which are the most recent (= protected)?
Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } |
    Sort-Object LastUseTime -Descending | Select-Object LocalPath, LastUseTime

# What version is installed?
(Get-ItemProperty 'HKLM:\SOFTWARE\Organization\ProfileCleanup').Version
```

**Before enabling the Downloads purge or turning off `LogOnly` for real**, try it on
one device first: sign in as the target account, leave a file in Downloads, run the
task from an elevated prompt on another session, and check the log.

---

## Good to know

- **Deleting profiles is permanent.** There's no undo, and uninstalling the app doesn't
  bring anything back - it only stops future runs.
- **Profile sizes are what's on the disk, not what's in the cloud.** OneDrive files kept
  online-only are excluded, because they report their full size while occupying nothing
  locally - counting them would badly overstate what deleting a profile frees up. Files
  the system can't read are also skipped, so the figure is a floor.
- **Notifications are per device, per run.** With `NotifyOnlyIfActionable` off, that's
  one message per device per day. Point it at a dedicated Teams channel or mail folder
  if the volume gets annoying.
- **Runs can take a while** on devices with large profiles, because measuring size
  walks every file. The task is capped at 1 hour; set `IncludeProfileSize` to `false`
  if that's ever a problem.
- **OneDrive space isn't reclaimed instantly.** Windows releases the local copies on
  its own schedule, so the size in the report may not drop right away.

---

## Files in this folder

```
Invoke-AppDeployToolkit.ps1        the installer (registers the scheduled task)
SupportFiles/
  Remove-StaleProfiles.ps1         what runs each night
  ProfileCleanupConfig.json         the settings you'll actually edit
manifest.json                      which Intune app this publishes to
```

Build and publishing are handled by the shared pipeline - see the top-level
[README](../../README.md).

### Setting up the Intune app (first time only)

The pipeline updates an existing Intune app; it doesn't create one. Create a **Windows
app (Win32)** once, then put its object ID in `manifest.json`:

- **Install:** `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall:** `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
- **Install behavior:** System
- **Detection rule:** anything to start with - the pipeline replaces it on first publish
- **Assignment:** Required, to a device group
