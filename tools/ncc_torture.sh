#!/bin/sh
# ncc_torture: differential C torture case. The same source is compiled by
# clang (reference output saved in ncc_torture.expected) and by ncc on NaN16.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/ncctor.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_torture_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 60000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_torture.expected "$T/got"; then echo "ncc_torture: PASS (integer/pointer/struct/varargs/setjmp torture)"; else echo "ncc_torture: FAIL"; tail -2 "$T/err"; exit 1; fi
