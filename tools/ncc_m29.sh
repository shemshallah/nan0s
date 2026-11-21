#!/bin/sh
# M29 gate: signal() handlers are invoked by raise().
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm29.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m29_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m29.expected "$T/got"; then echo "ncc_m29: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m29: FAIL"; exit 1; fi
