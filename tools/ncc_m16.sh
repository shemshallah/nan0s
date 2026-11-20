#!/bin/sh
# M16 gate: string/ctype/stdlib built-ins (strchr/strstr/strdup, ctype,
# toupper/tolower, labs, memmove, rand/srand).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm16.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m16_test.nas > "$T/m16.nan"
./aarch64/android/nan_cli --img "$T/m16.nan" --steps 300000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m16.expected "$T/got"; then echo "ncc_m16: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m16: FAIL"; tail -3 "$T/err"; exit 1; fi
