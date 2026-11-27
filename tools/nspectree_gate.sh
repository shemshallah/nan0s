#!/bin/sh
# nspectree_gate.sh - tree speculation vs plain decode, batched verifier,
# branch promotion and npaged_trim rollback.
#
# Builds src/tests/nspectree_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image links the real
# src/lib/nspectree.nas + nspec.nas + npaged.nas + nattn.nas + nkv.nas +
# nheap.nas + nanobj.nas; no C harness is linked.
#
# Proves: one immutable nattn weight root; a depth-2 / two-root / two-child
# draft tree appended to one paged context with per-candidate ordered causal
# masks and branch/owner record tags; one batched verifier call over all six
# candidates; longest root-to-leaf accept; promotion/relocation of the winning
# branch; release of every other candidate through npaged_trim; exact token
# ids, pre-sample logits and final next-token logits against plain
# npaged_decode; generation bump on an in-block trim and generation stability
# on a boundary trim; alternate-root promotion, depth-1 partial accept with a
# free verifier token, and full no-root fallback; deterministic rerun of ids,
# logits, counters, trace count and trace head.  Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nspectree.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nspectree: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nspectree.nas ] || fail "missing src/lib/nspectree.nas"
[ -f src/tests/nspectree_test.nas ] || fail "missing test image"
for sym in nspectree_init nspectree_prefill nspectree_generate \
           nspectree_generate_plain nspectree_cur_logits nspectree_set_flags \
           nspectree_flags nspectree_head nspectree_trace nspectree_stats \
           nspectree_cand nspectree_mask_len nspectree_mask \
           nspectree_branch_gen nt_build nt_verify nt_accept nt_attn_mask \
           nt_relocate nt_probe nt_append_cand nt_mask_one; do
  grep -q "^$sym:" src/lib/nspectree.nas || fail "missing $sym"
done
for sym in nspectree_init nspectree_prefill nspectree_generate \
           nspectree_generate_plain nspectree_cur_logits nspectree_set_flags \
           nspectree_stats nspectree_cand nspectree_mask_len nspectree_mask \
           nspectree_branch_gen nspectree_trace; do
  grep -q "@$sym" src/tests/nspectree_test.nas || fail "test does not call $sym"
done
grep -q '^npaged_trim:' src/lib/npaged.nas || fail "missing npaged_trim"
grep -q '@npaged_trim' src/lib/nspectree.nas || fail "library does not trim"
grep -q '@npaged_trim' src/tests/nspectree_test.nas || fail "no direct trim proof"
grep -q '@nspectree_generate_plain' src/tests/nspectree_test.nas || fail "no plain decode reference"
grep -q '@npaged_check' src/tests/nspectree_test.nas || fail "no generation check"
grep -q '@cmpw' src/tests/nspectree_test.nas || fail "no bitwise parity"
grep -q 'NT_C_MASKS' src/lib/nspectree.nas || fail "no per-branch masks"
grep -q '@nt_attn_mask' src/lib/nspectree.nas || fail "no masked verifier"
grep -q '@npaged_decode' src/lib/nspectree.nas || fail "no plain decode path"
grep -q 'NT_E_VERIFY' src/lib/nspectree.nas || fail "no batched verify event"
grep -q 'NT_E_PROMOTE' src/lib/nspectree.nas || fail "no promotion event"
grep -q '@nt_relocate' src/lib/nspectree.nas || fail "no branch relocation"
grep -q '@nt_probe' src/lib/nspectree.nas || fail "no draft probe"
grep -q 'NT_E_ACCEPT' src/lib/nspectree.nas || fail "no accept event"
grep -q 'NT_E_REJECT' src/lib/nspectree.nas || fail "no reject event"
grep -q 'NT_E_TRIM' src/lib/nspectree.nas || fail "no trim event"
grep -q '@ns_sample' src/lib/nspectree.nas || fail "no sampler reuse"
grep -q '0x00042021' src/tests/nspectree_test.nas || fail "no pinned xorshift"
grep -q 'include "nspec.nas"' src/lib/nspectree.nas || fail "no nspec reuse"
grep -q 'include "../lib/nspectree.nas"' src/tests/nspectree_test.nas || \
  fail "test does not include the library"
grep -q '@stA+2' src/tests/nspectree_test.nas || fail "no accepted count check"
grep -q '@stA+3' src/tests/nspectree_test.nas || fail "no rejected count check"
grep -q '@stA+4' src/tests/nspectree_test.nas || fail "no trimmed count check"
grep -q '@stD+3' src/tests/nspectree_test.nas || fail "no alternate-branch rejects"
grep -q '@stD+18' src/tests/nspectree_test.nas || fail "no accepted-length check"
grep -q '0xFFFFFFFF' src/tests/nspectree_test.nas || fail "no fail-closed checks"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nspectree_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

timeout 300 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 32 \
  --steps 120000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2; cat -v "$T/out" >&2
  tail -3 "$T/err" >&2; fail "tree speculative self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "nspectree: PASS (6-candidate depth-2 tree, per-branch masks, one batched paged verifier, longest-branch promote + npaged_trim, tree ids/logits == plain, alt/partial/zero-root paths, deterministic rerun)"
