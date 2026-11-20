#!/bin/sh
# M14 gate: bit-fields (masked reads/writes, signed fields, anonymous fields,
# comma declarators, initializers). Layout is non-packed (implementation-defined).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm14.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m14_test.nas > "$T/m14.nan"
./aarch64/android/nan_cli --img "$T/m14.nan" --steps 300000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m14.expected "$T/got"; then echo "ncc_m14: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m14: FAIL"; tail -3 "$T/err"; exit 1; fi
