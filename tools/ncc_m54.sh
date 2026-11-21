#!/bin/sh
# M54 gate: frexp/nextafter.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm54.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m54_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 40000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m54.expected "$T/got"; then echo "ncc_m54: PASS (frexp/nextafter)"; else echo "ncc_m54: FAIL"; tail -2 "$T/err"; exit 1; fi
