#!/bin/sh
# M26 gate: scanf/fscanf/sscanf conversions (%lld %s and callbacks), widths,
# stream scanning over the path filesystem.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm26.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m26_test.nas > "$T/m26.nan"
./aarch64/android/nan_cli --img "$T/m26.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m26.expected "$T/got"; then echo "ncc_m26: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m26: FAIL"; tail -3 "$T/err"; exit 1; fi
