#!/bin/sh
# M21 gate: printf %g/%G with precision, width, # flag, plus float
# exponent literals (1e10, 1.5e-5, 2E3).
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm21.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m21_test.nas > "$T/m21.nan"
./aarch64/android/nan_cli --img "$T/m21.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m21.expected "$T/got"; then echo "ncc_m21: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m21: FAIL"; tail -3 "$T/err"; exit 1; fi
