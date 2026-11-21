#!/bin/sh
# M44 gate: packed 32-bit bit-field layout, access, and sizeof.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm44.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m44_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m44.expected "$T/got"; then echo "ncc_m44: PASS (packed bit-fields)"; else echo "ncc_m44: FAIL"; tail -2 "$T/err"; exit 1; fi
