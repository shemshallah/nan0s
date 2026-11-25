#!/bin/sh
# tools/xgold_gate.sh - rebuild the native gold stream with no C or Python.
#
# tools/xgold.sh stages a NaN source, runs the NaN assembler on the native S1
# under QEMU, captures its serial bytes, and repacks the gold text with awk.
# The output must be byte-identical to the checked-in gold stream.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C

sh tools/xgold.sh
git diff --exit-code -- src/native/nan16_x86.nan x86/native/nan16_x86.nan >/dev/null 2>&1 || {
  echo "xgold_gate: FAIL (gold stream changed)"
  git diff --stat -- src/native/nan16_x86.nan x86/native/nan16_x86.nan
  exit 1
}
[ "$(grep -c '; boot+' src/native/nan16_x86.nan)" -eq 32 ] || {
  echo "xgold_gate: FAIL (boot grid)"; exit 1;
}
[ "$(grep -c '; kernel+' src/native/nan16_x86.nan)" -eq 532 ] || {
  echo "xgold_gate: FAIL (kernel grid)"; exit 1;
}
echo "xgold_gate: PASS (native S1 assembles the gold core; no C, no Python)"
