#!/bin/sh
# M6 gate: do/while, for, break/continue, short-circuit logic, ternary,
# compound assignment, and libc malloc/calloc/realloc/free/string/mem/atoi/abs.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccbuild.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m6_test.nas > "$T/m6.nan"
./aarch64/android/nan_cli --img "$T/m6.nan" --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m6.expected "$T/got"; then
  echo "ncc_m6: PASS ($(wc -l < "$T/got") lines, exact)"
else
  echo "ncc_m6: FAIL"
  exit 1
fi
