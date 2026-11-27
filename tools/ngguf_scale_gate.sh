#!/bin/sh
# ngguf_scale_gate.sh - direct GGUF Q4_0/Q8_0 f16-scale consumption (F7b).
#
# Builds src/tests/ngguf_scale_test.nas and runs it on nan_cli.  The image
# contains a minimal real GGUF v3 file, the real ngguf parser, nkv views and
# nq4 GEMV; no C harness is linked.
#
# Proves: exact f16 -> f32 (normals/subnormal/+-0/Inf/NaN); ngguf parse of a
# two-tensor Q8_0/Q4_0 image; ngguf_blocks_to_nq4 repacks f16 scales into nq4
# f32-scale blocks without altering payload bytes; nq8_gemv = -2.0 and
# nq4_gemv = 2.0 exact; a Q8 block range crossing 4 GiB is rejected with -2;
# a view based at 4 GiB is rejected with -2; bad magic/dtype/blocks/capacity
# return -1.  Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/ngguf_scale.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "ngguf_scale: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/ngguf.nas ] || fail "missing src/lib/ngguf.nas"
[ -f src/lib/nq4.nas ] || fail "missing src/lib/nq4.nas"
[ -f src/tests/ngguf_scale_test.nas ] || fail "missing test image"
for sym in nq_f16_to_f32 nq4_dequant nq8_dequant nq4_gemv nq8_gemv; do
  grep -q "^$sym:" src/lib/nq4.nas || fail "missing $sym"
done
for sym in ngguf_parse ngguf_blocks_to_nq4; do
  grep -q "^$sym:" src/lib/ngguf.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/ngguf_scale_test.nas || fail "test does not call $sym"
done
grep -q '0x46554747' src/tests/ngguf_scale_test.nas || fail "no GGUF magic image"
grep -q '0x00023800' src/tests/ngguf_scale_test.nas || fail "no f16 Q8 scale"
grep -q '0xFFFFFF00' src/tests/ngguf_scale_test.nas || fail "no 4 GiB view"
grep -q '0xFFFFFFFE' src/tests/ngguf_scale_test.nas || fail "no -2 range result"
grep -q '0x88888899' src/tests/ngguf_scale_test.nas || fail "no Q4 payload check"
grep -q 'n64_mul32' src/lib/ngguf.nas || fail "no 64-bit block range"
grep -q 'LDB' src/lib/ngguf.nas || fail "no byte reads over the view"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/ngguf_scale_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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
  tail -3 "$T/err" >&2; fail "GGUF scale self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "ngguf_scale: PASS (exact f16->f32, Q4/Q8 GGUF block repack to nq4, GEMV -2.0/2.0, 4 GiB view rejected -2)"
