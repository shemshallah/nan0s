#!/bin/sh
# M8 gate: float literals/arithmetic, casts, comparisons, sin/cos.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccbuild.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m8_test.nas > "$T/m8.nan"
./aarch64/android/nan_cli --img "$T/m8.nan" --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m8.expected "$T/got"; then echo "ncc_m8: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m8: FAIL"; exit 1; fi
