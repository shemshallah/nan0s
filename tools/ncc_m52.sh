#!/bin/sh
# M52 gate: vscanf/vfscanf/vsscanf.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm52.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m52_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 40000000 \
  --keys "9,SPACE,o,k,ENTER" --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m52.expected "$T/got"; then echo "ncc_m52: PASS (vscanf family)"; else echo "ncc_m52: FAIL"; tail -2 "$T/err"; exit 1; fi
