#!/bin/sh
# M23 gate: stdio FILE streams over the path filesystem: fopen/fclose,
# fprintf/fputs/fputc, fgets/fread, ftell/feof/fseek, rename/remove.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm23.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m23_test.nas > "$T/m23.nan"
./aarch64/android/nan_cli --img "$T/m23.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m23.expected "$T/got"; then echo "ncc_m23: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m23: FAIL"; tail -3 "$T/err"; exit 1; fi
