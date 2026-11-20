#!/bin/sh
# M11 gate: struct/union pass-by-value and return-by-value, copy semantics.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm11.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m11_test.nas > "$T/m11.nan"
./aarch64/android/nan_cli --img "$T/m11.nan" --steps 300000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m11.expected "$T/got"; then echo "ncc_m11: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m11: FAIL"; tail -3 "$T/err"; exit 1; fi
