#!/bin/sh
# npaged_gate.sh - per-agent paged KV + incremental decode parity (F13a).
#
# Builds src/tests/npaged_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image links the real
# src/lib/npaged.nas + nattn.nas + nkv.nas + nheap.nas + nanobj.nas; no C
# harness is linked.
#
# Proves: 2 MiB nheap-backed KV blocks with an nkv storage cap and per-token
# f32 views; a stable logical token -> (block, slot) mapping; prefill 4 and 3
# tokens followed by one-token decode with RoPE at the new position; bitwise
# logits and argmax parity against a full nattn recompute for two prompts
# (lengths 7 and 4); remap of block 1 to a fresh 2 MiB page with old
# generation rejection, new generation acceptance, stable slot arithmetic and
# parity for the token decoded after the remap; pressure 58%/66%, capacity
# failure at 13 tokens, tail-block eviction to nheap and re-append.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/npaged.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "npaged: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/npaged.nas ] || fail "missing src/lib/npaged.nas"
[ -f src/tests/npaged_test.nas ] || fail "missing test image"
for sym in npaged_init npaged_append npaged_prefill npaged_decode \
           npaged_attention npaged_remap npaged_evict_last \
           npaged_token_word npaged_token_gen npaged_check \
           npaged_pressure npaged_remaining npaged_stats; do
  grep -q "^$sym:" src/lib/npaged.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/npaged_test.nas || fail "test does not call $sym"
done
grep -q 'include "nattn.nas"' src/lib/npaged.nas || fail "does not reuse nattn"
grep -q 'NP_BLOCK_BYTES 0x200000' src/lib/npaged.nas || fail "no 2 MiB block"
grep -q 'nheap_alloc' src/lib/npaged.nas || fail "no nheap allocation"
grep -q 'nheap_free' src/lib/npaged.nas || fail "no nheap eviction"
grep -q 'nobj_release' src/lib/npaged.nas || fail "no capability release"
grep -q 'nkv_view_create' src/lib/npaged.nas || fail "no nkv views"
grep -q 'nattn_qk_fused' src/lib/npaged.nas || fail "no fused QK^T"
grep -q 'nattn_rope' src/lib/npaged.nas || fail "no RoPE"
grep -q 'nattn_quant_q4' src/lib/npaged.nas || fail "no Q4 cache"
grep -q 'nattn_quant_q8' src/lib/npaged.nas || fail "no Q8 cache"
grep -q '@npaged_remap' src/tests/npaged_test.nas || fail "no remap proof"
grep -q '@npaged_evict_last' src/tests/npaged_test.nas || fail "no eviction proof"
grep -q '@npaged_check' src/tests/npaged_test.nas || fail "no generation proof"
grep -q '@cmpw' src/tests/npaged_test.nas || fail "no bitwise parity"
grep -q '@anynz' src/tests/npaged_test.nas || fail "no non-vacuous logits"
grep -q 'MOVI r4,0x66' src/tests/npaged_test.nas || fail "no post-remap parity"
grep -q 'MOVI r4,0x67' src/tests/npaged_test.nas || fail "no second prompt"
grep -q 'MOVI r4,0x68' src/tests/npaged_test.nas || fail "no second decode"
grep -q 'FEXP' src/lib/npaged.nas || fail "no f32 exp softmax"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/npaged_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

timeout 180 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 32 \
  --steps 50000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2; cat -v "$T/out" >&2
  tail -3 "$T/err" >&2; fail "paged decode self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "npaged: PASS (2 MiB blocks, stable logical map, prefill+decode == full recompute, remap/generation, pressure/capacity/eviction)"
