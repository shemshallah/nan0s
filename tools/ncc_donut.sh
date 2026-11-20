#!/bin/sh
# Donut gate: compile and run the classic C donut (one frame) in raw NaN16.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccdonut.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_donut_test.nas > "$T/d.nan"
./aarch64/android/nan_cli --img "$T/d.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
if grep -q '@@' "$T/out" && grep -q '\$\$' "$T/out" && [ "$(wc -c < "$T/out")" -gt 1700 ]; then
  echo "ncc_donut: PASS (C donut rendered in raw NaN16)"
else
  echo "ncc_donut: FAIL"; tail -3 "$T/err"; head -c 300 "$T/out"; echo; exit 1
fi
