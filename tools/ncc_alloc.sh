#!/bin/sh
# tools/ncc_alloc.sh - ncc S0 allocator gate.
# 10,000 random malloc/free/realloc operations over the in-guest free-list
# heap: alignment, live-block overlap, full-pattern realloc preservation,
# coalescing/leak check via a 100,000,000-byte allocation (the whole dynamic
# heap on a 128 MiB-payload VM) and reuse,
# calloc zeroing and overflow, and realloc(NULL,n). The whole test is compiled and run by ncc in
# the NaN16 guest; no host C runtime takes part.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccalloc.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_alloc_test.nas > "$T/a.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/a.nan" --mem 128 --steps 1000000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if cmp -s "$T/got" src/tests/ncc_alloc.expected; then
  echo "ncc_alloc: PASS (10,000 malloc/free/realloc ops, no overlap, realloc data preserved)"
else
  echo "ncc_alloc: FAIL"; diff -u src/tests/ncc_alloc.expected "$T/got" | head -20; tail -2 "$T/err"; exit 1
fi
