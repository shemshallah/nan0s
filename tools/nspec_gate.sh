#!/bin/sh
# nspec_gate.sh - speculative decode vs plain decode equality + KV rollback.
#
# Builds src/tests/nspec_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image links the real
# src/lib/nspec.nas + npaged.nas + nattn.nas + nkv.nas + nheap.nas +
# nanobj.nas; no C harness is linked.
#
# Proves: one draft table stream and one exact verifier stream over the same
# immutable nattn weight root; a forced-rejection step appends a deliberately
# wrong draft, rejects it, trims the paged KV to the accepted prefix with a
# block generation bump (stale generation fails npaged_check, new passes),
# then appends the verifier token; 16 speculative token ids, 16x32 pre-sample
# logits and the final next-token logits are bit-equal to plain npaged_decode;
# accepted+rejected==generated, rejected==rollbacks,
# verifier passes==generated+rejected, drafts==generated; the hash-chained
# trace contains prefill/draft/reject/rollback/emit events and a full rerun
# reproduces the same ids/logits/stats/head; npaged_trim releases blocks above
# the target, bumps/rewrites an in-block tail, trims at a block boundary
# without touching the previous block, rejects trim-above-used, re-appends,
# and trims to zero.  Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nspec.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nspec: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nspec.nas ] || fail "missing src/lib/nspec.nas"
[ -f src/tests/nspec_test.nas ] || fail "missing test image"
for sym in nspec_init nspec_prefill nspec_generate nspec_generate_plain \
           nspec_cur_logits nspec_set_flags nspec_flags nspec_head \
           nspec_trace nspec_stats ns_sample ns_xorshift ns_event ns_copy; do
  grep -q "^$sym:" src/lib/nspec.nas || fail "missing $sym"
done
for sym in nspec_init nspec_prefill nspec_generate nspec_generate_plain \
           nspec_cur_logits nspec_set_flags nspec_trace nspec_stats \
           ns_xorshift; do
  grep -q "@$sym" src/tests/nspec_test.nas || fail "test does not call $sym"
done
grep -q '^npaged_trim:' src/lib/npaged.nas || fail "missing npaged_trim"
grep -q '@npaged_trim' src/lib/nspec.nas || fail "nspec does not trim"
grep -q '@npaged_trim' src/tests/nspec_test.nas || fail "no direct trim proof"
grep -q '@npaged_check' src/tests/nspec_test.nas || fail "no generation check"
grep -q '@nspec_generate_plain' src/tests/nspec_test.nas || fail "no plain stream"
grep -q '@nspec_generate' src/tests/nspec_test.nas || fail "no draft stream"
grep -q '@cmpw' src/tests/nspec_test.nas || fail "no bitwise parity"
grep -q '@anynz' src/tests/nspec_test.nas || fail "no non-vacuous logits"
grep -q 'CALL @nspec_set_flags' src/tests/nspec_test.nas || fail "no forced reject"
grep -q '0x00042021' src/tests/nspec_test.nas || fail "no pinned xorshift"
grep -q '0x12345678' src/tests/nspec_test.nas || fail "no draft seed"
grep -q 'include "npaged.nas"' src/lib/nspec.nas || fail "no npaged verifier"
grep -q 'npaged_attention' src/lib/nspec.nas || fail "no nattn attention"
grep -q 'SHL r2,r1,13' src/lib/nspec.nas || fail "no xorshift <<13"
grep -q 'SHR r2,r1,17' src/lib/nspec.nas || fail "no xorshift >>17"
grep -q 'SHL r2,r1,5' src/lib/nspec.nas || fail "no xorshift <<5"
grep -q 'FEXP' src/lib/nspec.nas || fail "no temperature softmax"
grep -q 'NS_E_ROLLBACK' src/lib/nspec.nas || fail "no rollback event"
grep -q '@nspec_trace' src/tests/nspec_test.nas || fail "no trace inspection"
grep -q 'NS_C_CUR' src/lib/nspec.nas || fail "no current-logits parity path"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nspec_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

timeout 180 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 32 \
  --steps 80000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2; cat -v "$T/out" >&2
  tail -3 "$T/err" >&2; fail "speculative decode self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "nspec: PASS (spec ids/logits == plain, forced reject + paged KV trim rollback, deterministic trace head, npaged_trim block/boundary/zero)"
