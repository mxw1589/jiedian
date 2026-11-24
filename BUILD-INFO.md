# Build info — 1.2.2

Base: uploaded ArgoSBX dual-stack compact manager bundle 1.2.0, aligned with public repository main branch structure and URLs as checked on 2026-11-25.

Changes:
- Added node output family selector to manager.html (46 / 4 / 6).
- Generated command uses RAW_URL from https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh and appends local CLI command `sb-manager nodes {46|4|6}`.
- Shell CLI supports the family parameter and refreshes node files before displaying the selected URI list.
- Main index explains the upstream `ippz` limitation and links to the user's own manager generator.

Validation is local only; no live VPS install or connection test is claimed.
