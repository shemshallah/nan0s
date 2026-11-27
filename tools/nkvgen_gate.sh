#!/bin/sh
# nkvgen_gate.sh - generation-tagged KV pages/views + COW prefix fork (F13g).
#
# Builds src/tests/nkvgen_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image links the real
# src/lib/nkvgen.nas, ngen.nas and nkv.nas; no C harness is linked.
#
# Proves, in one deterministic scenario repeated twice from a cold init and
# compared word-for-word:
#   ngen agent 1 reaches gen 5; a parent branch enters gen 5 and appends a
#   10-token prefix over two pages (8 full + 2 partial); fork publishes gen 6
#   and shares both pages read-only; parent and child both read the prefix;
#   parent->child and child->parent view presentations fail with exact EGEN;
#   a new open at old gen 5 fails with exact ESTALE and ngen EDRAIN while the
#   parent slot is DRAINING; the child's first append COW-copies only the
#   2-token partial boundary page and not the 8-token full prefix page; later
#   child appends stay private and allocate one new block; the parent prefix
#   and its partial suffix are unchanged; the child reads its copied boundary
#   at gen 6 and its own divergent suffix; shared prefix writes fail with
#   exact ESHARED; child close frees exactly two pages and leaves the two
#   parent pages at refcount 1; parent close frees the rest; join/leave/free,
#   alloc/copy/token-copy counters and the ngen DRAINING/DRAINED states are
#   exact; a second complete run produces the identical 1184-word snapshot.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nkvgen.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nkvgen: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nkvgen.nas ] || fail "missing src/lib/nkvgen.nas"
[ -f src/tests/nkvgen_test.nas ] || fail "missing test image"
[ -f src/lib/ngen.nas ] || fail "missing ngen.nas"
[ -f src/lib/nkv.nas ] || fail "missing nkv.nas"

for sym in nkvgen_init nkvgen_open nkvgen_fork nkvgen_append \
           nkvgen_view_open nkvgen_view_read nkvgen_view_write \
           nkvgen_close nkvgen_page_info nkvgen_stats nkvgen_ctx_info \
           nkvgen_errno; do
  grep -q "^$sym:" src/lib/nkvgen.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nkvgen_test.nas || fail "test does not call $sym"
done
grep -q 'include "ngen.nas"' src/lib/nkvgen.nas || fail "not tied to ngen"
grep -q 'include "nkv.nas"' src/lib/nkvgen.nas || fail "not built on nkv views"
grep -q 'ngen_enter' src/lib/nkvgen.nas || fail "no ngen admission"
grep -q 'ngen_publish' src/lib/nkvgen.nas || fail "no generation publish on fork"
grep -q 'ngen_exit' src/lib/nkvgen.nas || fail "no ngen drain on close"
grep -q 'nkv_view_create' src/lib/nkvgen.nas || fail "no nkv view mint"
grep -q 'nkv_view_addr' src/lib/nkvgen.nas || fail "no nkv view resolve"
grep -q 'nobj_release' src/lib/nkvgen.nas || fail "no capability release on free"
for f in NKG_EGEN NKG_ESTALE NKG_ESHARED NKG_EBLK NKG_F_SHARED \
         NKG_G_COPIES NKG_G_TCOPY NKG_G_JOINS NKG_G_LEAVES NKG_G_FREES \
         NKG_P_REFS NKG_P_GEN NKG_V_CTXGEN NKG_V_PAGEGEN; do
  grep -q "#$f" src/lib/nkvgen.nas || grep -q "$f" src/lib/nkvgen.nas || \
    fail "missing $f"
done
grep -q 'NKG_EGEN' src/tests/nkvgen_test.nas || fail "no cross-generation proof"
grep -q 'NKG_ESTALE' src/tests/nkvgen_test.nas || fail "no old-generation proof"
grep -q 'NKG_ESHARED' src/tests/nkvgen_test.nas || fail "no shared-write proof"
grep -q 'NG_EDRAIN' src/tests/nkvgen_test.nas || fail "no ngen EDRAIN tie"
grep -q 'NG_S_DRAINING' src/tests/nkvgen_test.nas || fail "no drain window"
grep -q 'NG_S_DRAINED' src/tests/nkvgen_test.nas || fail "no drained end state"
grep -q 'MOVI r3,5' src/tests/nkvgen_test.nas || fail "no parent gen 5"
grep -q 'MOVI r2,6' src/tests/nkvgen_test.nas || fail "no child gen 6"
grep -q '0x5000' src/tests/nkvgen_test.nas || fail "no parent prefix values"
grep -q '0x7000' src/tests/nkvgen_test.nas || fail "no child suffix values"
grep -q '@nkvgen_fork' src/tests/nkvgen_test.nas || fail "no fork proof"
grep -q '@read_fail' src/tests/nkvgen_test.nas || fail "no rejection helper"
grep -q '@write_fail' src/tests/nkvgen_test.nas || fail "no shared-write helper"
grep -q '@rd_range' src/tests/nkvgen_test.nas || fail "no range read proof"
grep -q '@cmpbuf' src/tests/nkvgen_test.nas || fail "no deterministic compare"
grep -q '1184' src/tests/nkvgen_test.nas || fail "no full snapshot compare"

[ -x ./aarch64/android/nan_cli ] || fail "missing aarch64/android/nan_cli"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nkvgen_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

run_once() {
  out=$1; err=$2
  timeout 180 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 \
    --steps 20000000 --serial > "$out" 2> "$err" || true
  got=$(cat "$out")
  [ "$got" = "O" ] || {
    echo "--- nan_cli ---" >&2; cat -v "$out" >&2
    tail -5 "$err" >&2; fail "COW/cross-generation self-test did not prove O"; }
  [ "$(wc -c < "$out")" -eq 1 ] || fail "output is not exactly one byte"
}

run_once "$T/out1" "$T/err1"
run_once "$T/out2" "$T/err2"
cmp -s "$T/out1" "$T/out2" || fail "two cold runs differ"

printf 'O\n'
echo "nkvgen: PASS (parent gen5 10-token prefix, fork gen6 shares pages, cross-gen/old-gen reject, COW 2-token boundary only, parent/child isolation, exact refcounts, deterministic rerun)"
