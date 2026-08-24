This folder is intentionally empty in source control.

The HP CMSL installer (hp-cmsl-installer.exe) is downloaded by CI from HP's
official download endpoint, verified against a pinned SHA-256 in
build-and-publish.yml, and injected here at build time - the same pattern
used for the PSAppDeployToolkit template itself. It is never committed to
this repo. See the "Inject HP CMSL installer" step in
.github/workflows/build-and-publish.yml and this app's README.md.
