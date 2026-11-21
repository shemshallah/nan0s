#!/bin/sh
# M56 gate: wcscoll/wcsxfrm.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm56.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m56_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 40000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m56.expected "$T/got"; then echo "ncc_m56: PASS (wcscoll/wcsxfrm)"; else echo "ncc_m56: FAIL"; tail -2 "$T/err"; exit 1; fi
