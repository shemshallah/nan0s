#!/bin/sh
# nkvtree_gate.sh - three-agent shared-prefix branch tree (F13h).
#
# Builds src/tests/nkvtree_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image links the real
# src/lib/nkvtree.nas, nkv.nas, nagent.nas and nsym.nas/ngen.nas; no C
# harness is linked.
#
# Proves, in two deterministic close orders each repeated from a cold init and
# compared word-for-word:
#   one root tree agent holds a 10-token immutable prefix over two pages and
#   binds nsym weight root 15; child1 forks on ngen agent 2 at generation 2
#   and child2 on ngen agent 3 at generation 3 through nagent_fork records
#   (KV generation parent+1); both children share the two prefix pages
#   read-only and acquire the same weight root; each child appends a divergent
#   suffix and each boundary COW copies exactly the 2-token partial page, not
#   the 8-token full page; the parent publishes gen 6, keeps reading as a
#   DRAINING snapshot, and a fresh ctx at gen 6 rejects the old gen-5 view;
#   old-gen open fails ESTALE with ngen EDRAIN; sibling views are EGEN and
#   shared writes are ESHARED; close order child1->child2->parent and the
#   reverse both free every page and nsym root exactly at refcount zero; all
#   alloc/free/join/leave/copy/token-copy/refcount counters and the 3344-word
#   state snapshot (five contexts, page registry, stats, payloads, nsym roots,
#   nsym global, three nagent records, three ngen statuses, trace ring) are
#   exact; the ngen DRAINING/DRAINED end states are exact.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nkvtree.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nkvtree: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nkvtree.nas ] || fail "missing src/lib/nkvtree.nas"
[ -f src/tests/nkvtree_test.nas ] || fail "missing test image"
[ -f src/lib/nkv.nas ] || fail "missing nkv.nas"
[ -f src/lib/nagent.nas ] || fail "missing nagent.nas"
[ -f src/lib/nsym.nas ] || fail "missing nsym.nas"
[ -f src/lib/ngen.nas ] || fail "missing ngen.nas"

for sym in nkvt_init nkvt_open nkvt_bind nkvt_seal_prefix nkvt_fork \
           nkvt_publish nkvt_append nkvt_view_open nkvt_view_read \
           nkvt_view_write nkvt_close nkvt_page_info nkvt_stats \
           nkvt_ctx_info nkvt_trace nkvt_trace_head nkvt_errno; do
  grep -q "^$sym:" src/lib/nkvtree.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nkvtree_test.nas || fail "test does not call $sym"
done

grep -q 'include "nkv.nas"' src/lib/nkvtree.nas || fail "not built on nkv views"
grep -q 'include "nagent.nas"' src/lib/nkvtree.nas || fail "not tied to nagent"
grep -q 'include "nsym.nas"' src/lib/nkvtree.nas || fail "not tied to nsym roots"
grep -q '@nagent_fork' src/lib/nkvtree.nas || fail "fork does not use nagent_fork"
grep -q '@nagent_roots' src/lib/nkvtree.nas || fail "no nagent root binding"
grep -q '@nsym_root_create' src/lib/nkvtree.nas || fail "no nsym page root"
grep -q '@nsym_root_acquire' src/lib/nkvtree.nas || fail "no nsym join"
grep -q '@nsym_root_release' src/lib/nkvtree.nas || fail "no nsym leave"
grep -q '@ngen_publish' src/lib/nkvtree.nas || fail "no generation publish"
grep -q '@ngen_enter' src/lib/nkvtree.nas || fail "no ngen admission"
grep -q '@ngen_exit' src/lib/nkvtree.nas || fail "no ngen drain on close"
grep -q 'nkv_view_create' src/lib/nkvtree.nas || fail "no nkv view mint"
grep -q 'nkv_view_addr' src/lib/nkvtree.nas || fail "no nkv view resolve"
grep -q 'nobj_release' src/lib/nkvtree.nas || fail "no capability release on free"

for f in NKT_EGEN NKT_ESTALE NKT_ESHARED NKT_EBLK NKT_F_SHARED \
         NKT_G_COPIES NKT_G_TCOPY NKT_G_JOINS NKT_G_LEAVES NKT_G_FREES \
         NKT_G_RACQ NKT_G_RREL NKT_G_RFREE NKT_G_MIRERR NKT_P_REFS \
         NKT_P_ROOT NKT_V_CTXGEN NKT_V_PAGEGEN; do
  grep -q "#$f" src/lib/nkvtree.nas || grep -q "$f" src/lib/nkvtree.nas || \
    fail "missing $f"
done

grep -q 'NKT_EGEN' src/tests/nkvtree_test.nas || fail "no cross-generation proof"
grep -q 'NKT_ESTALE' src/tests/nkvtree_test.nas || fail "no old-generation proof"
grep -q 'NKT_ESHARED' src/tests/nkvtree_test.nas || fail "no shared-write proof"
grep -q 'NG_S_DRAINING' src/tests/nkvtree_test.nas || fail "no drain window"
grep -q 'NG_S_DRAINED' src/tests/nkvtree_test.nas || fail "no drained end state"
grep -q 'NG_EDRAIN' src/tests/nkvtree_test.nas || fail "no ngen EDRAIN tie"
grep -q '@nkvt_fork' src/tests/nkvtree_test.nas || fail "no tree fork test"
grep -q '@nsym_root_create' src/tests/nkvtree_test.nas || fail "no nsym root test"
grep -q '@nsym_root_status' src/tests/nkvtree_test.nas || fail "no nsym root status test"
grep -q '0x5000' src/tests/nkvtree_test.nas || fail "no shared prefix values"
grep -q '0x6000' src/tests/nkvtree_test.nas || fail "no parent suffix values"
grep -q '0x7000' src/tests/nkvtree_test.nas || fail "no child1 suffix values"
grep -q '0x8000' src/tests/nkvtree_test.nas || fail "no child2 suffix values"
grep -q '3344' src/tests/nkvtree_test.nas || fail "no full snapshot compare"
grep -q '@close1' src/tests/nkvtree_test.nas || fail "no child1 close"
grep -q '@close2' src/tests/nkvtree_test.nas || fail "no child2 close"
grep -q '@close_parent' src/tests/nkvtree_test.nas || fail "no parent close"
grep -q '@snapshot' src/tests/nkvtree_test.nas || fail "no state snapshot"
grep -q '@order' src/tests/nkvtree_test.nas || fail "no close-order switch"
grep -q '@rd_range' src/tests/nkvtree_test.nas || fail "no range read proof"
grep -q '@read_fail' src/tests/nkvtree_test.nas || fail "no rejection helper"
grep -q '@write_fail' src/tests/nkvtree_test.nas || fail "no shared-write helper"
grep -q '@cmpbuf' src/tests/nkvtree_test.nas || fail "no deterministic compare"

[ -x ./aarch64/android/nan_cli ] || fail "missing aarch64/android/nan_cli"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nkvtree_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

# The tree library must not be an nkvgen edit.
git diff --quiet -- src/lib/nkvgen.nas 2>/dev/null || \
  fail "src/lib/nkvgen.nas was modified"

run_once() {
  out=$1; err=$2
  timeout 300 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 \
    --steps 10000000 --serial > "$out" 2> "$err" || true
  got=$(cat "$out")
  [ "$got" = "O" ] || {
    echo "--- nan_cli ---" >&2; cat -v "$out" >&2
    tail -5 "$err" >&2; fail "three-agent tree self-test did not prove O"; }
  [ "$(wc -c < "$out")" -eq 1 ] || fail "output is not exactly one byte"
}

run_once "$T/out1" "$T/err1"
run_once "$T/out2" "$T/err2"
cmp -s "$T/out1" "$T/out2" || fail "two cold runs differ"

printf 'O\n'
echo "nkvtree: PASS (3 agents share 10-token prefix via nsym roots, child1 gen2/child2 gen3 divergent suffixes, parent gen5 suffix unchanged, boundary COW only, cross-gen/old-gen/shared-write reject, both close orders free at zero refs, exact counters + 3344-word deterministic snapshot)"
