#!/bin/sh
# nmoe_gate.sh - deterministic 4-expert top-2 MoE routing and expert FFN (F13d).
#
# Builds src/tests/nmoe_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image contains the real
# src/lib/nmoe.nas + nmodel.nas + nq4.nas; no C harness is linked.
#
# Proves: exact router logits from a Q4_0 matrix; stable top-2 ids and exact
# 1/2,1/2 softmax weights; a two-layer Q4_0 expert FFN with ReLU; token
# dispatch with capacity factor 2 (no drops) and factor 1 (capacity 2, one
# token's both assignments dropped); load-balance and placement hint
# accounting (local/remote, VRAM/DRAM); a remote NUMA bias that flips token 3
# from experts (0,1) to (0,2) while preserving the gate weights; and a
# deterministic rerun with bit-equal outputs and an 80-word stats block.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nmoe.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nmoe: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nmoe.nas ] || fail "missing src/lib/nmoe.nas"
[ -f src/tests/nmoe_test.nas ] || fail "missing test image"
for sym in nmoe_init nmoe_router nmoe_topk nmoe_softmax_sel nmoe_route \
           nmoe_expert nmoe_forward; do
  grep -q "^$sym:" src/lib/nmoe.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nmoe_test.nas || fail "test does not call $sym"
done
grep -q 'include "nmodel.nas"' src/lib/nmoe.nas || fail "does not use nmodel"
grep -q 'nmod_gemv_q4' src/lib/nmoe.nas || fail "no nmodel GEMV"
grep -q 'FEXP' src/lib/nmoe.nas || fail "no f32 softmax exp"
grep -q 'FCMP' src/lib/nmoe.nas || fail "no expert ReLU compare"
grep -q 'BFILL' src/lib/nmoe.nas || fail "no deterministic counter clear"
grep -q 'DIVU' src/lib/nmoe.nas || fail "no capacity division"
grep -q '0x454F4D4E' src/lib/nmoe.nas || fail "no NMOE magic"
grep -q '0x3F000000' src/tests/nmoe_test.nas || fail "no exact 1/2 weight"
grep -q '0x3FC00000' src/tests/nmoe_test.nas || fail "no exact 1.5 combined logit"
grep -q '0x40400000' src/tests/nmoe_test.nas || fail "no exact 3.0 combined logit"
grep -q '0x8889888A' src/tests/nmoe_test.nas || fail "no hand-built router block"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nmoe_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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
  tail -5 "$T/err" >&2; fail "MoE self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "nmoe: PASS (top-2 Q4 router, exact 1/2 weights, 4 expert FFNs, capacity drop/overflow, load+NUMA/VRAM accounting, placement flip, deterministic rerun)"
