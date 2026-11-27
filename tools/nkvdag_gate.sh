#!/bin/sh
# nkvdag_gate.sh - content-hash prefix-page DAG, dedup and late joins (F13i).
#
# Builds src/tests/nkvdag_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image links the real
# src/lib/nkvdag.nas, nagent.nas and ngen.nas; no C harness is linked.
#
# Proves, from four cold inits (two close orders, each repeated) and two
# word-for-word snapshot comparisons:
#   four nagent records and four ngen agents; agent 1 at gen 5 and agent 2/3/4
#   at gen 2/3/4.  Branch 1 seals a 10-token prefix P over two immutable pages.
#   Each page is hashed by a deterministic two-lane 32-bit content mix; P0 and
#   P1 are DAG nodes with one header each and P1 is the root.  Branch 3 joins
#   P by root hash, then branch 4 late-joins the same existing DAG; both joins
#   acquire each node and increment per-node join counters.  Branch 2 builds a
#   second 16-token prefix Q whose first page has identical content to P0:
#   seal finds P0 by content hash, increments dedup hits and refs, and creates
#   no duplicate header.  P0 therefore has four refs, one dedup hit, one
#   header, two joins; total DAG headers is three.
#   Branch 1 publishes gen 6.  A fresh open at old gen 5 fails ESTALE with
#   ngen EDRAIN; the old ctx still reads its admitted DRAINING snapshot; a
#   fresh gen-6 ctx rejects the old view with EGEN.  A shared-page write and a
#   referenced-node free fail ESHARED/EREF.  A duplicate raw header insert is
#   EDUP and a hash-key/content mismatch is ECOLL.  Unknown-root join is
#   ENOENT.
#   Each branch appends a divergent suffix.  Branch 1/3/4 COW exactly the
#   2-token shared boundary page; the third COW frees P1 at refcount zero.
#   Branch 2's extra suffix page is private.  Sibling values are isolated and
#   a private view write succeeds only on the owning generation.
#   Close orders A (4,3,2,1,1b) and B (1,2,3,4,1b) both free every node at
#   zero refs; P0 is freed only when its last sharer closes, Q1 when branch 2
#   closes.  An orphan ctx then joins the old P and Q roots and gets ENOENT.
#   Exact alloc/free/ref/leave/dedup/join/COW/token-copy/header counters,
#   nagent KV roots and ngen states are checked; the 5280-word snapshot
#   (7 contexts, 64-node registry, stats, payload buffer, four nagent records,
#   four ngen statuses, trace ring) is identical across two cold runs per
#   close order.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nkvdag.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nkvdag: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nkvdag.nas ] || fail "missing src/lib/nkvdag.nas"
[ -f src/tests/nkvdag_test.nas ] || fail "missing test image"
[ -f src/lib/nagent.nas ] || fail "missing nagent.nas"
[ -f src/lib/ngen.nas ] || fail "missing ngen.nas"

for sym in nkd_init nkd_open nkd_publish nkd_seal nkd_join nkd_append \
           nkd_view_open nkd_view_read nkd_view_write nkd_close \
           nkd_node_info nkd_node_find nkd_node_free nkd_raw_add nkd_hash \
           nkd_stats nkd_ctx_info nkd_trace nkd_trace_head nkd_errno; do
  grep -q "^$sym:" src/lib/nkvdag.nas || fail "missing $sym"
done
for sym in nkd_init nkd_open nkd_publish nkd_seal nkd_join nkd_append \
           nkd_view_open nkd_view_read nkd_view_write nkd_close \
           nkd_node_info nkd_node_find nkd_node_free nkd_raw_add nkd_hash \
           nkd_stats nkd_ctx_info; do
  grep -q "@$sym" src/tests/nkvdag_test.nas || fail "test does not call $sym"
done

grep -q 'include "nagent.nas"' src/lib/nkvdag.nas || fail "not tied to nagent"
grep -q 'include "ngen.nas"' src/lib/nkvdag.nas || fail "not tied to ngen"
grep -q '@nagent_roots' src/lib/nkvdag.nas || fail "no nagent KV root binding"
grep -q '@nagent_verify' src/lib/nkvdag.nas || fail "no nagent identity check"
grep -q '@ngen_enter' src/lib/nkvdag.nas || fail "no ngen admission"
grep -q '@ngen_exit' src/lib/nkvdag.nas || fail "no ngen drain on close"
grep -q '@ngen_publish' src/lib/nkvdag.nas || fail "no generation publish"
for f in NKD_EGEN NKD_ESTALE NKD_ESHARED NKD_EBLK NKD_EDUP NKD_ECOLL \
         NKD_EREF NKD_F_SHARED NKD_N_REFS NKD_N_HEADERS NKD_N_DEDUP \
         NKD_G_DEDUP NKD_G_JOINOPS NKD_G_JOINREFS NKD_G_COWS NKD_G_TCOPY \
         NKD_T_DEDUP NKD_T_JOIN NKD_T_COW NKD_T_FREE; do
  grep -q "#$f" src/lib/nkvdag.nas || grep -q "$f" src/lib/nkvdag.nas || \
    fail "missing $f"
done

grep -q 'NKD_EGEN' src/tests/nkvdag_test.nas || fail "no cross-generation proof"
grep -q 'NKD_ESTALE' src/tests/nkvdag_test.nas || fail "no old-generation proof"
grep -q 'NKD_ESHARED' src/tests/nkvdag_test.nas || fail "no shared-write proof"
grep -q 'NKD_EREF' src/tests/nkvdag_test.nas || fail "no zero-ref free proof"
grep -q 'NKD_EDUP' src/tests/nkvdag_test.nas || fail "no duplicate-header proof"
grep -q 'NKD_ECOLL' src/tests/nkvdag_test.nas || fail "no collision proof"
grep -q 'NG_EDRAIN' src/tests/nkvdag_test.nas || fail "no ngen EDRAIN tie"
grep -q 'NG_S_DRAINING' src/tests/nkvdag_test.nas || fail "no drain window"
grep -q 'NG_S_DRAINED' src/tests/nkvdag_test.nas || fail "no drained end state"
grep -q '0x5000' src/tests/nkvdag_test.nas || fail "no shared P0 values"
grep -q '0x6000' src/tests/nkvdag_test.nas || fail "no branch 1 suffix values"
grep -q '0x7000' src/tests/nkvdag_test.nas || fail "no branch 3 suffix values"
grep -q '0x8000' src/tests/nkvdag_test.nas || fail "no branch 4 suffix values"
grep -q '0x9000' src/tests/nkvdag_test.nas || fail "no Q-specific page values"
grep -q '@nkd_raw_add' src/tests/nkvdag_test.nas || fail "no raw header insert"
grep -q '@nkd_hash' src/tests/nkvdag_test.nas || fail "no content-hash check"
grep -q '@nkd_node_free' src/tests/nkvdag_test.nas || fail "no free rejection"
grep -q '@close1' src/tests/nkvdag_test.nas || fail "no branch 1 close"
grep -q '@close4' src/tests/nkvdag_test.nas || fail "no branch 4 close"
grep -q '@p0_ref_chk' src/tests/nkvdag_test.nas || fail "no per-close ref proof"
grep -q '@after_close' src/tests/nkvdag_test.nas || fail "no zero-ref close check"
grep -q '@orphan' src/tests/nkvdag_test.nas || fail "no orphan-root check"
grep -q '@snapshot' src/tests/nkvdag_test.nas || fail "no state snapshot"
grep -q '5280' src/tests/nkvdag_test.nas || fail "no full snapshot compare"
grep -q '@order' src/tests/nkvdag_test.nas || fail "no close-order switch"
grep -q '@rd_range' src/tests/nkvdag_test.nas || fail "no range read proof"
grep -q '@read_fail' src/tests/nkvdag_test.nas || fail "no read rejection helper"
grep -q '@write_fail' src/tests/nkvdag_test.nas || fail "no write rejection helper"
grep -q '@cmpbuf' src/tests/nkvdag_test.nas || fail "no deterministic compare"

# The DAG must not silently be an nkvgen/nkvtree edit.
git diff --quiet -- src/lib/nkvgen.nas src/lib/nkvtree.nas 2>/dev/null || \
  fail "nkvgen.nas or nkvtree.nas was modified"

[ -x ./aarch64/android/nan_cli ] || fail "missing aarch64/android/nan_cli"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nkvdag_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

run_once() {
  out=$1; err=$2
  timeout 300 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 \
    --steps 40000000 --serial > "$out" 2> "$err" || true
  got=$(cat "$out")
  [ "$got" = "O" ] || {
    echo "--- nan_cli ---" >&2; cat -v "$out" >&2
    tail -5 "$err" >&2; fail "content-hash DAG self-test did not prove O"; }
  [ "$(wc -c < "$out")" -eq 1 ] || fail "output is not exactly one byte"
}

run_once "$T/out1" "$T/err1"
run_once "$T/out2" "$T/err2"
cmp -s "$T/out1" "$T/out2" || fail "two cold runs differ"

printf 'O\n'
echo "nkvdag: PASS (4 agents, P/Q prefixes, identical P0 page deduped to one header (refs 4, dedup 1, headers 1), branch3 join + late branch4 join, per-branch ngen tags, private COW suffix isolation, cross-gen/old-gen/shared-write/EDUP/ECOLL/EREF/ENOENT rejects, zero-ref frees in both close orders, exact counters + 5280-word deterministic snapshot)"
