#!/bin/sh
# M25 gate: 64-bit long long (literals, arithmetic, casts, printf/scanf,
# structs, arrays, varargs, function pointers, LL<->float).
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm25.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m25_test.nas > "$T/m25.nan"
./aarch64/android/nan_cli --img "$T/m25.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m25.expected "$T/got"; then echo "ncc_m25: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m25: FAIL"; tail -3 "$T/err"; exit 1; fi
