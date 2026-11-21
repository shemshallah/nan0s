#!/bin/sh
# M30 gate: explicit function-returning-function-pointer declarators
# (prototype form) parse and do not disturb ordinary function pointers.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm30.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m30_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m30.expected "$T/got"; then echo "ncc_m30: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m30: FAIL"; tail -2 "$T/err"; exit 1; fi
