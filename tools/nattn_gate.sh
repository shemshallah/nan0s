#!/bin/sh
# nattn_gate.sh - one-head causal attention over nkv token views (F7b).
#
# Builds src/tests/nattn_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image contains the real
# src/lib/nattn.nas + nq4.nas + nkv.nas; no C harness is linked.
#
# Proves: exact RoPE; exact f32 softmax (uniform, one-hot, 3-way, 2-way);
# Q4/Q8 quantize/dequant; fused Q4xQ8 QK^T bit-identical to the nq4_dot32
# oracle over two blocks; Q4/Q8 matvec over 32/64 columns; a real nkv KV slab
# with four f32 token views; uniform-attention contexts; and a 1-layer
# attention token gate with exact expected ids 1, 3 and 2.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nattn.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nattn: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nattn.nas ] || fail "missing src/lib/nattn.nas"
[ -f src/tests/nattn_test.nas ] || fail "missing test image"
for sym in nattn_view_ptr nattn_rope nattn_softmax nattn_qk_fused \
           nattn_quant_q4 nattn_quant_q8 nattn_matvec_q4 nattn_matvec_q8 \
           nattn_forward nattn_last_logits; do
  grep -q "^$sym:" src/lib/nattn.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nattn_test.nas || fail "test does not call $sym"
done
grep -q 'include "nq4.nas"' src/lib/nattn.nas || fail "does not use nq4"
grep -q 'include "nkv.nas"' src/lib/nattn.nas || fail "does not use nkv"
grep -q 'nkv_slab_token_view' src/tests/nattn_test.nas || fail "no nkv token view"
grep -q '@nq4_dot32' src/tests/nattn_test.nas || fail "no nq4_dot32 oracle"
grep -q '0x3EAAAAAB' src/tests/nattn_test.nas || fail "no exact 1/3 softmax"
grep -q '0x3E800000' src/tests/nattn_test.nas || fail "no exact 1/4 softmax"
grep -q '0x3F000000' src/tests/nattn_test.nas || fail "no exact 1/2 context"
grep -q 'FEXP' src/lib/nattn.nas || fail "no f32 exp softmax"
grep -q 'CMPS' src/lib/nattn.nas || fail "no signed quantize clamp"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nattn_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

timeout 120 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 \
  --steps 20000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2; cat -v "$T/out" >&2
  tail -3 "$T/err" >&2; fail "attention self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "nattn: PASS (exact RoPE/softmax, fused Q4xQ8 QK^T == nq4_dot32 oracle, nkv KV token views, 1-layer token gate ids 1/3/2)"
