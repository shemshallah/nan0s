#!/bin/sh
# M60 gate: setitimer/getitimer with SIGALRM delivery.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm60.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m60_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 30000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m60.expected "$T/got"; then echo "ncc_m60: PASS (setitimer/getitimer)"; else echo "ncc_m60: FAIL"; tail -2 "$T/err"; exit 1; fi
