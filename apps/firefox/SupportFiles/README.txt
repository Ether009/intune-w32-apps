This folder is intentionally empty in source control.

The Firefox ESR MSI (FirefoxSetup.msi, ~70MB) is downloaded by CI from Mozilla's
official release archive, verified against a pinned SHA-256 in
build-and-publish.yml, and injected here at build time - the same pattern used
for the HP CMSL installer and the PSAppDeployToolkit template itself. It is never
committed to this repo (a 70MB binary exceeds GitHub's recommended file size and
doesn't belong in git history anyway). See the "Inject Firefox ESR MSI" step in
.github/workflows/build-and-publish.yml and this app's README.md.
