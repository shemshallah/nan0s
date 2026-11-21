#!/bin/sh
# M40 gate: function-returning-function-pointer definitions with parameters.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm40.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m40_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m40.expected "$T/got"; then echo "ncc_m40: PASS (FP-returning definitions with parameters)"; else echo "ncc_m40: FAIL"; tail -2 "$T/err"; exit 1; fi
