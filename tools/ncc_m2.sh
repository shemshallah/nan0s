#!/bin/sh
# tools/ncc_m2.sh - ncc M2 gate: assemble the raw-NaN16 C compiler, run it in
# the C core, and compare the guest transcript byte-for-byte with the golden file.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccm2.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m2\_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --steps 50000000 --serial > "$T/out" 2>"$T/err" || true
if cmp -s "$T/out" src/tests/ncc_m2.expected; then
  echo "ncc_m2: PASS ($(wc -l < "$T/out") lines, exact)"
else
  echo "ncc_m2: FAIL"; diff src/tests/ncc_m2.expected "$T/out" | head -20; exit 1
fi
