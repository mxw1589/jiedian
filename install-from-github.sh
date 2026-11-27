#!/usr/bin/env bash
set -Eeuo pipefail

# Set this to OWNER/REPOSITORY before publishing, or pass it as an environment variable.
REPO="${REPAIR_KIT_REPO:-}"
REF="${REPAIR_KIT_REF:-main}"

if [[ -z "$REPO" ]]; then
  echo "[ERROR] Set REPAIR_KIT_REPO=OWNER/REPOSITORY before running this installer." >&2
  exit 2
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "[ERROR] Invalid repository path. Expected OWNER/REPOSITORY." >&2
  exit 2
fi
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERROR] Run as root." >&2
  exit 1
fi

for cmd in curl unzip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Missing $cmd. Install it first, then rerun." >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE="$TMP_DIR/repo.zip"
URL="https://codeload.github.com/${REPO}/zip/refs/heads/${REF}"

echo "[INFO] Downloading ${REPO}@${REF} from GitHub..."
curl --fail --location --silent --show-error --retry 3 "$URL" -o "$ARCHIVE"
unzip -q "$ARCHIVE" -d "$TMP_DIR"

REPO_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '__MACOSX' -print -quit)"
if [[ -z "$REPO_DIR" || ! -f "$REPO_DIR/install.sh" ]]; then
  echo "[ERROR] Repository archive does not contain install.sh." >&2
  exit 1
fi

bash "$REPO_DIR/install.sh"
