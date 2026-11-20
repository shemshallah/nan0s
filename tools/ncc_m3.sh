#!/bin/sh
# tools/ncc_m3.sh - ncc M3 gate: arrays, pointers, &/*, indexing, sizeof, strings.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccm3.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m3_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --steps 100000000 --serial > "$T/out" 2>"$T/err" || true
if cmp -s "$T/out" src/tests/ncc_m3.expected; then
  echo "ncc_m3: PASS ($(wc -l < "$T/out") lines, exact)"
else
  echo "ncc_m3: FAIL"; diff src/tests/ncc_m3.expected "$T/out" | head -20; exit 1
fi
