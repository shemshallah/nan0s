#!/bin/sh
# tools/ncc_aligned.sh - C11 aligned_alloc on the NaN-native S0 heap.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccaligned.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_aligned_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 200000000 --serial > "$T/o" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/o" > "$T/got"
cmp -s "$T/got" src/tests/ncc_aligned.expected || { echo "ncc_aligned: FAIL"; diff -u src/tests/ncc_aligned.expected "$T/got" | head -20; tail -2 "$T/err"; exit 1; }
echo "ncc_aligned: PASS (aligned_alloc 16/32/64, writes, free, realloc)"
