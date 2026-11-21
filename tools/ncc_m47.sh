#!/bin/sh
# M47 gate: vprintf/vfprintf/vsprintf/vsnprintf and * width/precision.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm47.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m47_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m47.expected "$T/got"; then echo "ncc_m47: PASS (vprintf family)"; else echo "ncc_m47: FAIL"; tail -2 "$T/err"; exit 1; fi
