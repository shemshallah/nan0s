#!/bin/sh
# M13 gate: nested aggregate initializers (structs in structs, arrays of arrays,
# partial brace elision, global and local).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm13.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m13_test.nas > "$T/m13.nan"
./aarch64/android/nan_cli --img "$T/m13.nan" --steps 300000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m13.expected "$T/got"; then echo "ncc_m13: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m13: FAIL"; tail -3 "$T/err"; exit 1; fi
