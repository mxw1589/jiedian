# Sing-box-yg v26.4.11 Community Repair Kit

[简体中文说明](README_CN.md)

A community-maintained, targeted repair kit for an existing **Sing-box-yg v26.4.11** installation. This is not the upstream installer and does not bundle or replace the sing-box core.

## Scope

- Target script: `/usr/bin/sb`
- Expected upstream version: `v26.4.11`
- The patch checks the version marker (when present) and exact source anchors. It stops on unexpected source layouts instead of applying a blind replacement.

## Fixes

- Runtime dependency checks and best-effort package installation.
- TTY guard around `stty` for non-interactive execution.
- Safer VMess TLS state detection before the Argo path.
- Timestamped backup and `bash -n` validation with rollback on syntax failure.

## Not included

- No sing-box core installation or upgrade.
- No replacement of `/etc/s-box/sb.json`.
- No intentional changes to UUIDs, ports, certificates, subscriptions, or node data.
- No intentional firewall opening or disabling.
- No bypass of upstream VMess TLS/Argo behavior.

The repair process may install missing operating-system packages. Review the scripts and take a VPS snapshot or backup before running them.

## Usage

Clone the repository and run:

```bash
git clone https://github.com/<OWNER>/<REPOSITORY>.git
cd <REPOSITORY>
bash install.sh
```

Or download and extract the repository ZIP, then run `bash install.sh` from the extracted directory.

After the repository is published, the remote bootstrap command will be:

```bash
REPAIR_KIT_REPO=<OWNER>/<REPOSITORY> bash <(curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPOSITORY>/main/install-from-github.sh)
```

Replace the placeholders with the actual GitHub owner and repository. Inspect remote scripts before execution.

## Tests

```bash
sha256sum -c SHA256SUMS.txt
python3 -m unittest discover -s tests -v
bash -n repair.sh
python3 -m py_compile patch_sb.py tests/test_patch.py
```

Unit tests cover source-anchor matching, idempotence, and rejection of unknown source layouts. They do not prove compatibility with every customized installation.

## Upstream and license

This patch targets the v26.4.11 script structure from [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg). The upstream repository identifies its license as GPL-3.0. See [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE).

This is an independent community project and is not affiliated with or endorsed by the upstream author.

## Security

Never post API keys, Argo tokens, private keys, certificate private material, subscription URLs, node URIs, or unredacted configuration files in Issues or Discussions. See [SECURITY.md](SECURITY.md).
