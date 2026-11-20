#!/bin/sh
# M19 gate: C99 declarations accepted by ncc: inline, restrict, _Bool,
# bool/true/false, and _Bool normalization.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm19.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m19_test.nas > "$T/m19.nan"
./aarch64/android/nan_cli --img "$T/m19.nan" --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m19.expected "$T/got"; then echo "ncc_m19: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m19: FAIL"; tail -3 "$T/err"; exit 1; fi
