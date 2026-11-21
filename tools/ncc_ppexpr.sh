#!/bin/sh
# tools/ncc_ppexpr.sh - #if/#elif constant-expression gate.
# Covers arithmetic, shifts, bitwise/logical operators, comparisons,
# unary ! ~ + -, defined(), parentheses, object-like macro values,
# nested skipped blocks, and ?: in the guest preprocessor.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccppexpr.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_ppexpr_test.nas > "$T/a.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/a.nan" --steps 120000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if cmp -s "$T/got" src/tests/ncc_ppexpr.expected; then
  echo "ncc_ppexpr: PASS (#if/#elif arithmetic/bitwise/logical/defined/ternary)"
else
  echo "ncc_ppexpr: FAIL"; diff -u src/tests/ncc_ppexpr.expected "$T/got" | head -20; tail -2 "$T/err"; exit 1
fi
