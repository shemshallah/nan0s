#!/bin/sh
# M32 gate: C99 designated initializers (.member=, [index]=) for local and
# global structs/arrays, including nested braced struct designators.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm32.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m32_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m32.expected "$T/got"; then echo "ncc_m32: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m32: FAIL"; tail -2 "$T/err"; exit 1; fi
