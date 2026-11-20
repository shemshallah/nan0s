#!/bin/sh
# M9 gate: function pointers: globals, locals, assignment, indirect calls,
# function designators as values, and pointer comparison.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm9.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m9_test.nas > "$T/m9.nan"
./aarch64/android/nan_cli --img "$T/m9.nan" --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m9.expected "$T/got"; then echo "ncc_m9: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m9: FAIL"; tail -3 "$T/err"; exit 1; fi
