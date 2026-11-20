#!/bin/sh
# M4 parity gate: byte-accurate integer types, structs/unions/enums/typedefs,
# switch/goto/loops, arrays/pointers, and libc (printf/malloc/strings).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccbuild.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m4_test.nas > "$T/m4.nan"
./aarch64/android/nan_cli --img "$T/m4.nan" --steps 100000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m4.expected "$T/got"; then
  echo "ncc_m4: PASS ($(wc -l < "$T/got") lines, exact)"
else
  echo "ncc_m4: FAIL"
  exit 1
fi
