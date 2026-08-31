This folder is intentionally missing two files in source control:
onedrive-teamsync-cert.pfx and onedrive-teamsync-cert.pfx.pw.

They're the Graph auth certificate for the OneDrive-TeamSync-App Entra app registration
(app-only, Group.Read.All + User.Read.All, admin-consented). CI injects both from repo
secrets (ONEDRIVE_TEAMSYNC_CLIENT_PFX_BASE64 / ONEDRIVE_TEAMSYNC_CLIENT_PFX_PASSWORD) at
build time - see the "Inject OneDrive Team Sync client certificate" step in
build-and-publish.yml. Never commit these here; the same pattern is used for
device-inventory-report's ingest client cert.

To rotate the certificate:
1. Generate a new self-signed cert and upload it as a second key credential on the
   OneDrive-TeamSync-App app registration (don't delete the old one until the new
   thumbprint is live everywhere, or every device with the old cert loses auth).
2. Export the new cert as a password-protected PFX, base64-encode it, and update the
   two repo secrets above.
3. Update $CertThumbprint in Sync-OneDriveTeams.ps1 to the new cert's thumbprint.
4. Bump this app's AppVersion in Invoke-AppDeployToolkit.ps1 and push to main.
5. Once confirmed rolled out, remove the old key credential from the app registration.
