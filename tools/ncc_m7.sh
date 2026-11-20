#!/bin/sh
# M7 gate: block scope/shadowing, aggregate initializers for structs/unions,
# and struct assignment (member-wise byte copy).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccbuild.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m7_test.nas > "$T/m7.nan"
./aarch64/android/nan_cli --img "$T/m7.nan" --steps 100000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m7.expected "$T/got"; then
  echo "ncc_m7: PASS ($(wc -l < "$T/got") lines, exact)"
else
  echo "ncc_m7: FAIL"
  exit 1
fi
