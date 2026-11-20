#!/bin/sh
# M10 gate: printf %f, precision, float width/flags, precision on %s/%d.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm10.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m10_test.nas > "$T/m10.nan"
./aarch64/android/nan_cli --img "$T/m10.nan" --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m10.expected "$T/got"; then echo "ncc_m10: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m10: FAIL"; tail -3 "$T/err"; exit 1; fi
