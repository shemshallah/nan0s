#!/bin/sh
# M24 gate: scanf/fscanf/sscanf conversions (%d %x %s %f), widths,
# stream scanning over the path filesystem.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm24.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m24_test.nas > "$T/m24.nan"
./aarch64/android/nan_cli --img "$T/m24.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m24.expected "$T/got"; then echo "ncc_m24: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m24: FAIL"; tail -3 "$T/err"; exit 1; fi
