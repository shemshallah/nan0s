#!/bin/sh
# nmodel_gate.sh - RMSNorm + Q4/Q8 GEMV + deterministic sampler + tiny model.
#
# Builds src/tests/nmodel_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image contains the real
# src/lib/nmodel.nas + src/lib/nq4.nas; no C harness is linked.
#
# Proves: exact RMSNorm bits; Q4_0 and Q8_0 GEMV; a 1-layer tiny model
# (embedding average -> RMSNorm -> Q4 projection) with exact logits for two
# prompts and exact next-token ids 0 and 2; greedy sampling leaves the seed
# unchanged; xorshift32 seed 1 -> 0x00042021 and seed 0x12345678 ->
# 0x87985AA5; top-k picks are reproducible and respect k.  Attention is not
# part of this slice.  Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nmodel.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nmodel: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nmodel.nas ] || fail "missing src/lib/nmodel.nas"
[ -f src/tests/nmodel_test.nas ] || fail "missing test image"
for sym in nmod_rmsnorm nmod_gemv_q4 nmod_gemv_q8 nmod_argmax nmod_sample \
           nmod_xorshift nmod_forward; do
  grep -q "^$sym:" src/lib/nmodel.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nmodel_test.nas || fail "test does not call $sym"
done
grep -q 'include "nq4.nas"' src/lib/nmodel.nas || fail "does not use nq4"
grep -q 'BOOL.6' src/lib/nmodel.nas || fail "no xorshift xor"
grep -q '0x00042021' src/tests/nmodel_test.nas || fail "no exact seed-1 sample"
grep -q '0x87985AA5' src/tests/nmodel_test.nas || fail "no exact seed-2 sample"
grep -q 'FEXP' src/lib/nmodel.nas || fail "no temperature exp"
grep -q 'FSQRT' src/lib/nmodel.nas || fail "no RMSNorm sqrt"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nmodel_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

timeout 60 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 \
  --steps 5000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2; cat -v "$T/out" >&2
  tail -5 "$T/err" >&2; fail "model self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "nmodel: PASS (exact RMSNorm/Q4/Q8 GEMV, tiny-model prompts -> ids 0 and 2, xorshift/top-k sampler)"
