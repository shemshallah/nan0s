#!/bin/sh
# M36 gate: [] array size inference from brace lists (local/global/struct/designated).
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm36.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m36_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m36.expected "$T/got"; then echo "ncc_m36: PASS (array size inference)"; else echo "ncc_m36: FAIL"; tail -2 "$T/err"; exit 1; fi
