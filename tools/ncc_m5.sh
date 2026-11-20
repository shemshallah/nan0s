#!/bin/sh
# M5 gate: lexer-integrated preprocessor (#define/#undef/#ifdef/#ifndef/
# #if/#else/#elif/#endif, #include skipped, defined()).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccbuild.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m5_test.nas > "$T/m5.nan"
./aarch64/android/nan_cli --img "$T/m5.nan" --steps 100000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m5.expected "$T/got"; then
  echo "ncc_m5: PASS ($(wc -l < "$T/got") lines, exact)"
else
  echo "ncc_m5: FAIL"
  exit 1
fi
