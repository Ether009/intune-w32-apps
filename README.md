# Intune Win32 Apps

PSAppDeployToolkit-based Win32 apps for Intune, each built and published to its own
Intune app entry by a shared CI pipeline. No manual `.intunewin` upload required —
push a version bump to `main` and the pipeline builds, and if the version changed,
publishes the new content and a matching detection rule.

## Getting the repo

This is a **private** repo, so you need to be signed in as a collaborator (or the
owner) before cloning.

- **Via GitHub CLI** (handles auth for you if you're already `gh auth login`'d):
  ```bash
  gh repo clone Ether009/intune-w32-apps
  ```
- **Via plain git** (HTTPS — you'll be prompted to authenticate, or use a PAT/SSH key
  you've already set up):
  ```bash
  git clone https://github.com/Ether009/intune-w32-apps.git
  ```

Either way you end up with a normal local clone on `main`; everything below assumes
you're working from there.

## Repository layout

```
apps/
  <app-name>/
    manifest.json                 <- Intune app ID + detection registry settings for this app
    Invoke-AppDeployToolkit.ps1   <- customized PSADT entry point
    SupportFiles/                 <- app-specific payload (scripts, config, icons, ...)
.github/workflows/
  build-and-publish.yml           <- discovers apps/*/, builds and publishes each
```

Each app folder is a minimal overlay, not a full PSADT project: only the customized
`Invoke-AppDeployToolkit.ps1` and `SupportFiles/` are committed. CI downloads the
official PSAppDeployToolkit v4 template (pinned release + verified SHA-256) and layers
each app's files on top before packaging. A local working copy may additionally
contain the extracted template folders (`PSAppDeployToolkit\`, `Assets\`, `Config\`,
`Strings\`, `Files\`, `Invoke-AppDeployToolkit.exe`) for local testing — those are
gitignored.

## Making a change (branch + pull request)

Every change — a new app, a config tweak, a version bump — follows the same flow:

1. **Start from an up-to-date `main`:**
   ```bash
   git checkout main
   git pull
   ```
2. **Create a branch** — name it for what it does, e.g. `git checkout -b
   profile-cleanup/retention-45-days`. There's no enforced naming convention on a repo
   this size; just make it recognizable in a PR list.
3. **Make your changes** under `apps/<name>/`. If the change should actually publish
   once merged, remember to bump `AppVersion` in that app's `Invoke-AppDeployToolkit.ps1`
   — see **Adding a new app** and each app's own README for what that triggers.
4. **Commit and push the branch:**
   ```bash
   git add <files>
   git commit -m "Short description of the change"
   git push -u origin <branch-name>
   ```
5. **Open a pull request against `main`:**
   - **Web:** GitHub shows a "Compare & pull request" banner right after the push —
     click it, or go to **Pull requests → New pull request**.
   - **CLI:**
     ```bash
     gh pr create --base main --title "Short title" --body "What changed and why"
     ```
6. **Review, then merge.** Once the PR looks right, **Merge pull request** (or
   squash-merge — either is fine here) on GitHub. Merging is what lands the change on
   `main` and is what the build/publish pipeline actually reacts to.

> **Note:** `build-and-publish.yml` only triggers on pushes to `main` (see **Build and
> publish (CI)** below) — opening a PR does **not** run a build to validate it, since
> there's no `pull_request` trigger configured. Review the diff itself before merging;
> the first real CI feedback (build success/failure, and a real Intune publish if the
> version changed) arrives after the merge lands on `main`. If PR-time build validation
> ever becomes worth having, that would mean adding a `pull_request` trigger to the
> workflow that runs the build-only steps (never the publish step) — not set up today.

## Adding a new app

1. Create `apps/<name>/` with `Invoke-AppDeployToolkit.ps1` and `SupportFiles/`.
2. Add `apps/<name>/manifest.json`:
   ```json
   {
     "displayName": "Human-readable name",
     "intuneAppId": "<GUID of an existing Windows app (Win32) object in Intune>",
     "detectionRegistryPath": "HKLM:\\SOFTWARE\\Vendor\\AppKey",
     "detectionRegistryValueName": "Version"
   }
   ```
   The pipeline only manages an app's **content and detection rule** — it does not
   create the Intune app object itself. Create the Win32 app once in Intune first
   (any install/uninstall command, any placeholder detection rule; both get overwritten
   on first publish), note its object ID, and put that ID in `intuneAppId`.
3. Push to `main` (via a merged PR, per **Making a change** above). CI discovers the
   new folder automatically — no workflow changes needed.

## Build and publish (CI)

`.github/workflows/build-and-publish.yml` runs on every push to `main` that touches
`apps/**` (and on manual dispatch). It has two jobs:

1. **discover** — lists every `apps/*/` folder that has a `manifest.json`.
2. **build-and-publish** — a matrix job, one run per discovered app, each independent
   (`fail-fast: false`, so one app's failure doesn't block the others):
   1. **Assemble**: downloads the pinned official PSADT v4 template and the Microsoft
      Win32 Content Prep Tool, verifies both against recorded SHA-256 hashes, extracts
      the template, and overlays that app's files on top.
   2. **Build**: produces `Invoke-AppDeployToolkit.intunewin` and attaches it to the
      workflow run as an artifact (named `<app>-<version>`, version parsed from that
      app's `AppVersion`).
   3. **Publish**: fetches the Intune app's current `displayVersion` via Microsoft
      Graph. If it differs from the repo's `AppVersion`, uploads the new content,
      updates the displayed version, and regenerates + uploads a detection script from
      `manifest.json`'s registry path/value and the new version — so an app's install
      and its detection rule can never drift apart. If the versions already match,
      publishing is skipped (build-only run) — this is what makes the pipeline safe to
      run on every push regardless of which app changed.

### Credentials (one-time setup, do this yourself)

Publishing authenticates to Microsoft Graph via an Entra app registration using the
client-credentials flow. This grants **tenant-wide** write access to Intune Win32 apps
(the Graph permission isn't scopable to a single app), so set it up yourself rather
than having an agent do it, and review the permission before consenting:

1. **Entra admin center → App registrations → New registration.** Name it something
   identifiable (e.g. `intune-apps-ci`). Single tenant. No redirect URI needed.
2. **API permissions → Add a permission → Microsoft Graph → Application permissions**
   → search `DeviceManagementApps.ReadWrite.All` → Add. Then **Grant admin consent**
   for the tenant (requires an account with sufficient privilege, e.g. Cloud
   Application Administrator or Global Administrator).
3. **Certificates & secrets → New client secret.** Copy the secret **value**
   immediately — it's only shown once.
4. **Overview** page: note the **Application (client) ID** and **Directory (tenant) ID**.
5. In this repo: **Settings → Secrets and variables → Actions → New repository secret**,
   add all three:
   - `INTUNE_TENANT_ID`
   - `INTUNE_CLIENT_ID`
   - `INTUNE_CLIENT_SECRET`

Until all three are set, the workflow builds normally and skips publishing with a
warning (it does not fail). One registration/secret covers every app in this repo —
no per-app credentials needed. To rotate the secret later: add a new client secret in
the same app registration, update the `INTUNE_CLIENT_SECRET` repository secret, then
delete the old client secret.

## Per-app documentation

See each app's own `README.md` under `apps/<name>/` for what it does, how its
detection/versioning works, and app-specific known limitations.
