This folder is intentionally empty in source control.

The Adobe Creative Cloud Desktop ESD installer (Set-up.exe + packages/ + resources/,
~315MB unpacked) is downloaded by CI from Adobe's official CDN, verified against a
pinned SHA-256, and extracted here at build time - the same pattern used for the
Firefox ESR MSI and HP CMSL installer. It is never committed to this repo (a 300MB+
payload has no place in git history). See the "Inject Creative Cloud installer" step
in .github/workflows/build-and-publish.yml and this app's README.md.
