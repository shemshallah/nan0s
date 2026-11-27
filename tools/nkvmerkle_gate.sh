#!/bin/sh
# nkvmerkle_gate.sh - Merkle multi-parent prefix DAG with root-only proofs
# (F13j).
#
# Builds src/tests/nkvmerkle_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image links the real
# src/lib/nkvmerkle.nas, nagent.nas and ngen.nas; no C harness is linked.
#
# Proves, from four cold inits (two close orders, each repeated) and two
# word-for-word snapshot comparisons:
#   four nagent records and four ngen agents; agent 1 and agent 2 at gen 5,
#   agent 3 at gen 3, agent 4 at gen 4.  Branch 1 seals a 10-token prefix P
#   over two pages.  Each node commits its used content, ordered parent
#   hashes, used count and generation tag through the documented two-lane
#   mix; P1 commits P0 and P1 is P's root.
#   Branch 3 joins P by root hash, branch 4 late-joins after Q exists.
#   Branch 2 at gen 5 builds a 16-token prefix Q whose first page has the
#   identical node hash and committed fields as P0: seal dedups to one header
#   (refs increment, dedup 1, no second header) and Q1 commits P0.
#   Branch 1 publishes gen 6; the old gen-5 slot drains and the old admitted
#   branch still reads its snapshot while a fresh gen-6 view is EGEN.  A
#   fresh merge context publishes M with two ordered parents {P1,Q1} at gen 6,
#   so M is a multi-parent root and P0 has the two root paths M->P1->P0 and
#   M->Q1->P0.
#   Page proofs for P0 and Q1 and token proofs for P1[1]=0x5009 and
#   P0[3]=0x5003 are generated from M and verified from the M root hash alone.
#   The gate also checks the verifier section contains no node-registry call.
#   Mutating content, ordered parent hash, generation tag, used count, token
#   value, token content, target hash, root field, depth, parent order or the
#   supplied root hash each fails with EPROOF.
#   Branches 1/3/4 COW the shared 2-token P1 boundary page; branch 2 starts a
#   private third page.  Close orders A (4,3,2,1,5) and B (5,1,2,3,4) both
#   free every node at zero refs, with the M parent-reference cascade checked
#   by exact P0 refs after every close.  An orphan gen-6 context then joins
#   the old P and Q roots and gets ENOENT.  After every node is gone the saved
#   P0 proof still verifies from the saved root hash.
#   Exact alloc/free/ref/dedup/join/COW/header/proof/trace counters, node
#   headers, table slots, nagent KV roots and ngen states are checked; the
#   6816-word snapshot (7 contexts, 64-node registry, stats, payload buffer,
#   four nagent records, four ngen statuses, trace ring) is identical across
#   two cold runs per close order.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nkvmerkle.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nkvmerkle: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nkvmerkle.nas ] || fail "missing src/lib/nkvmerkle.nas"
[ -f src/tests/nkvmerkle_test.nas ] || fail "missing test image"
[ -f src/lib/nagent.nas ] || fail "missing nagent.nas"
[ -f src/lib/ngen.nas ] || fail "missing ngen.nas"

for sym in nkm_init nkm_open nkm_publish nkm_seal nkm_join nkm_merge_n \
           nkm_append nkm_view_open nkm_view_read nkm_view_write nkm_close \
           nkm_proof nkm_proof_verify nkm_node_info nkm_node_find \
           nkm_node_free nkm_hash nkm_stats nkm_ctx_info nkm_root_info \
           nkm_trace nkm_trace_head nkm_errno; do
  grep -q "^$sym:" src/lib/nkvmerkle.nas || fail "missing $sym"
done
for sym in nkm_init nkm_open nkm_publish nkm_seal nkm_join nkm_merge_n \
           nkm_append nkm_view_open nkm_view_read nkm_view_write nkm_close \
           nkm_proof nkm_proof_verify nkm_node_info nkm_node_find \
           nkm_node_free nkm_hash nkm_stats nkm_ctx_info nkm_root_info \
           nkm_trace; do
  grep -q "@$sym" src/tests/nkvmerkle_test.nas || fail "test does not call $sym"
done

grep -q 'include "nagent.nas"' src/lib/nkvmerkle.nas || fail "not tied to nagent"
grep -q 'include "ngen.nas"' src/lib/nkvmerkle.nas || fail "not tied to ngen"
grep -q '@nagent_roots' src/lib/nkvmerkle.nas || fail "no nagent KV root binding"
grep -q '@nagent_verify' src/lib/nkvmerkle.nas || fail "no nagent identity check"
grep -q '@ngen_enter' src/lib/nkvmerkle.nas || fail "no ngen admission"
grep -q '@ngen_exit' src/lib/nkvmerkle.nas || fail "no ngen drain on close"
grep -q '@ngen_publish' src/lib/nkvmerkle.nas || fail "no generation publish"
for f in NKM_EPROOF NKM_EGEN NKM_ESTALE NKM_ESHARED NKM_EBLK NKM_ECOLL \
         NKM_EREF NKM_N_PCOUNT NKM_N_PHLO NKM_N_PHHI NKM_N_REFS \
         NKM_G_DEDUP NKM_G_JOINOPS NKM_G_JOINREFS NKM_G_COWS NKM_G_TCOPY \
         NKM_G_PROOFS NKM_G_VERIFIES NKM_G_XPROOF NKM_P_DEPTH NKM_P_MODE \
         NKM_P_TOKVAL NKM_T_DEDUP NKM_T_JOIN NKM_T_COW NKM_T_PROOF; do
  grep -q "#$f" src/lib/nkvmerkle.nas || grep -q "$f" src/lib/nkvmerkle.nas || \
    fail "missing $f"
done

grep -q 'NKM_EPROOF' src/tests/nkvmerkle_test.nas || fail "no proof rejection proof"
grep -q 'NKM_EGEN' src/tests/nkvmerkle_test.nas || fail "no cross-generation proof"
grep -q 'NKM_ESTALE' src/tests/nkvmerkle_test.nas || fail "no old-generation proof"
grep -q 'NKM_ESHARED' src/tests/nkvmerkle_test.nas || fail "no shared-write proof"
grep -q 'NKM_EREF' src/tests/nkvmerkle_test.nas || fail "no zero-ref free proof"
grep -q 'NKM_EDUP' src/tests/nkvmerkle_test.nas || fail "no duplicate-header proof"
grep -q 'NG_EDRAIN' src/tests/nkvmerkle_test.nas || fail "no ngen EDRAIN tie"
grep -q 'NG_S_DRAINING' src/tests/nkvmerkle_test.nas || fail "no drain window"
grep -q '0x5000' src/tests/nkvmerkle_test.nas || fail "no shared P content"
grep -q '0x9000' src/tests/nkvmerkle_test.nas || fail "no Q content"
grep -q '0xA000' src/tests/nkvmerkle_test.nas || fail "no multi-parent merge content"
grep -q '0x6000' src/tests/nkvmerkle_test.nas || fail "no branch 1 suffix"
grep -q '0x7000' src/tests/nkvmerkle_test.nas || fail "no branch 3 suffix"
grep -q '0x8000' src/tests/nkvmerkle_test.nas || fail "no branch 4 suffix"
grep -q '0x9100' src/tests/nkvmerkle_test.nas || fail "no branch 2 private suffix"
grep -q '@nkm_merge_n' src/tests/nkvmerkle_test.nas || fail "no merge test"
grep -q '@nkm_proof_verify' src/tests/nkvmerkle_test.nas || fail "no proof verify"
grep -q '@mut1' src/tests/nkvmerkle_test.nas || fail "no single-word mutation test"
grep -q '@swap2' src/tests/nkvmerkle_test.nas || fail "no parent-order mutation test"
grep -q '@rootbad' src/tests/nkvmerkle_test.nas || fail "no root mutation test"
grep -q '@close1' src/tests/nkvmerkle_test.nas || fail "no branch 1 close"
grep -q '@close5' src/tests/nkvmerkle_test.nas || fail "no merge close"
grep -q '@p0_ref_chk' src/tests/nkvmerkle_test.nas || fail "no per-close ref proof"
grep -q '@after_close' src/tests/nkvmerkle_test.nas || fail "no zero-ref close check"
grep -q '@orphan' src/tests/nkvmerkle_test.nas || fail "no orphan-root check"
grep -q '@snapshot' src/tests/nkvmerkle_test.nas || fail "no state snapshot"
grep -q '6816' src/tests/nkvmerkle_test.nas || fail "no full snapshot compare"
grep -q '@order' src/tests/nkvmerkle_test.nas || fail "no close-order switch"
grep -q '@rd_range' src/tests/nkvmerkle_test.nas || fail "no range read proof"
grep -q '@read_fail' src/tests/nkvmerkle_test.nas || fail "no read rejection helper"
grep -q '@write_fail' src/tests/nkvmerkle_test.nas || fail "no write rejection helper"
grep -q '@cmpbuf' src/tests/nkvmerkle_test.nas || fail "no deterministic compare"
grep -q 'MOVI r3,528' src/tests/nkvmerkle_test.nas || fail "no full proof copy"
grep -q 'NKM_PROOF_MAX' src/lib/nkvmerkle.nas || fail "no bounded proof depth"

# Root-only verification: the verifier section must not touch the node
# registry or content lookup.  Extract nkm_proof_verify up to the next label.
awk '/^nkm_proof_verify:/{f=1} f{print} f&&/^; ---------------------------------------------------------------------------$/{exit}' \
  src/lib/nkvmerkle.nas > "$T/verify.s"
grep -q '@nkm_nodeptr\|@nkm_find\|@nkm_lookup\|NKM_NODES' "$T/verify.s" && \
  fail "proof verify reads the node registry"
grep -q '@nkm_hash_arrays' "$T/verify.s" || fail "proof verify does not recompute hashes"

# The Merkle layer must not silently be an nkvdag/nkvgen/nkvtree edit.
git diff --quiet -- src/lib/nkvdag.nas src/lib/nkvgen.nas src/lib/nkvtree.nas 2>/dev/null || \
  fail "nkvdag/nkvgen/nkvtree was modified"

[ -x ./aarch64/android/nan_cli ] || fail "missing aarch64/android/nan_cli"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nkvmerkle_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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
    tail -5 "$err" >&2; fail "Merkle multi-parent DAG self-test did not prove O"; }
  [ "$(wc -c < "$out")" -eq 1 ] || fail "output is not exactly one byte"
}

run_once "$T/out1" "$T/err1"
run_once "$T/out2" "$T/err2"
cmp -s "$T/out1" "$T/out2" || fail "two cold runs differ"

printf 'O\n'
echo "nkvmerkle: PASS (4 agents, gen-tagged Merkle nodes, P/Q prefixes, P0 dedup refs 6 / one header, multi-parent M{P1,Q1}, page+token inclusion proofs verified from the M root only, 11 field/root/order mutation rejects, private COW suffixes, parent-ref cascade in both close orders, orphan ENOENT, post-free root-only proof verify, exact counters + 6816-word deterministic snapshot)"
