#!/usr/bin/env bash
set -Eeuo pipefail

# Example:
# REPAIR_KIT_REPO=OWNER/REPO REPAIR_KIT_REF=v1.2.0 REPAIR_KIT_REF_KIND=tag bash install-from-github.sh
REPO="${REPAIR_KIT_REPO:-}"
REF="${REPAIR_KIT_REF:-main}"
REF_KIND="${REPAIR_KIT_REF_KIND:-branch}"
EXPECTED_SHA256="${REPAIR_KIT_SHA256:-}"

if [[ -z "$REPO" || ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "[ERROR] Set REPAIR_KIT_REPO=OWNER/REPOSITORY." >&2
  exit 2
fi
if [[ ! "$REF" =~ ^[A-Za-z0-9_./-]+$ || "$REF" == *..* ]]; then
  echo "[ERROR] Invalid REPAIR_KIT_REF." >&2
  exit 2
fi
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERROR] Run as root." >&2
  exit 1
fi

case "$REF_KIND" in
  branch) ARCHIVE_URL="https://codeload.github.com/${REPO}/zip/refs/heads/${REF}" ;;
  tag) ARCHIVE_URL="https://codeload.github.com/${REPO}/zip/refs/tags/${REF}" ;;
  commit) ARCHIVE_URL="https://codeload.github.com/${REPO}/zip/${REF}" ;;
  *) echo "[ERROR] REPAIR_KIT_REF_KIND must be branch, tag, or commit." >&2; exit 2 ;;
esac

for cmd in curl unzip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Missing $cmd. Install it first, then rerun." >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE="$TMP_DIR/repo.zip"

printf '[INFO] Downloading %s (%s: %s)\n' "$REPO" "$REF_KIND" "$REF"
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 "$ARCHIVE_URL" -o "$ARCHIVE"

if [[ -n "$EXPECTED_SHA256" ]]; then
  if [[ ! "$EXPECTED_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    echo "[ERROR] REPAIR_KIT_SHA256 must be a 64-character SHA-256 hex string." >&2
    exit 2
  fi
  printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE" | sha256sum -c -
else
  echo "[WARNING] No pinned archive SHA-256 supplied. Review the repository/ref before using this bootstrapper." >&2
fi

unzip -q "$ARCHIVE" -d "$TMP_DIR"
REPO_DIR=""
while IFS= read -r candidate; do
  if [[ -f "$candidate/install.sh" && -f "$candidate/repair.sh" && -f "$candidate/patch_sb.py" ]]; then
    REPO_DIR="$candidate"
    break
  fi
done < <(find "$TMP_DIR" -mindepth 1 -maxdepth 2 -type f -name install.sh -printf '%h\n' | sort)

if [[ -z "$REPO_DIR" ]]; then
  echo "[ERROR] Archive does not contain the expected repair-kit files." >&2
  exit 1
fi

# The downloaded code is intentionally run only after the archive has been
# extracted and the expected entry points have been checked. Review the repo
# and pin REPAIR_KIT_SHA256 for production use.
bash "$REPO_DIR/install.sh"
