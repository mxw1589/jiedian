#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash install.sh" >&2
  exit 1
fi

for file in repair.sh patch_sb.py; do
  if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
    echo "[ERROR] Missing required file: $SCRIPT_DIR/$file" >&2
    exit 1
  fi
done

exec bash "$SCRIPT_DIR/repair.sh"
