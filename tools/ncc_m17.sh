#!/bin/sh
# M17 gate: sprintf/snprintf into guest buffers, including truncation and
# snprintf's would-be length.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm17.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m17_test.nas > "$T/m17.nan"
./aarch64/android/nan_cli --img "$T/m17.nan" --steps 300000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m17.expected "$T/got"; then echo "ncc_m17: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m17: FAIL"; tail -3 "$T/err"; exit 1; fi
