#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PY="$SCRIPT_DIR/check_manager_source.py"
if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] Python 3 is required. Install python3 and retry." >&2
  exit 1
fi
exec python3 "$PY" "$@"
