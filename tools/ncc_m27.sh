#!/bin/sh
# M27 gate: strftime, tmpnam/tmpfile, wide-character string helpers.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm27.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m27_test.nas > "$T/m27.nan"
./aarch64/android/nan_cli --img "$T/m27.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m27.expected "$T/got"; then echo "ncc_m27: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m27: FAIL"; tail -3 "$T/err"; exit 1; fi
