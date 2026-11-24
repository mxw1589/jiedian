#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo 'ERROR: Node.js is required for the UI/generator tests.' >&2; exit 1; }
count=0
for test_file in "$ROOT"/tests/*.sh; do
    [ -f "$test_file" ] || continue
    [ "$(basename "$test_file")" = 'run-all.sh' ] && continue
    printf '\n=== %s ===\n' "${test_file##*/}"
    sh "$test_file"
    count=$((count + 1))
done
for test_file in "$ROOT"/tests/*.js; do
    [ -f "$test_file" ] || continue
    printf '\n=== %s ===\n' "${test_file##*/}"
    node "$test_file"
    count=$((count + 1))
done
printf '\nPASS: all %s automated test files completed.\n' "$count"
