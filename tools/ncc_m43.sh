#!/bin/sh
# M43 gate: wscanf translation/delegation, including %ls widening.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm43.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m43_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 20000000 \
  --keys "1,SPACE,2,SPACE,a,b,ENTER" --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m43.expected "$T/got"; then echo "ncc_m43: PASS (wscanf)"; else echo "ncc_m43: FAIL"; tail -2 "$T/err"; exit 1; fi
