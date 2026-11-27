#!/bin/sh
# nsafetensors_gate.sh - safetensors JSON header parser + nkv views (F7b).
#
# Builds src/tests/nsafetensors_test.nas and runs it on nan_cli.  The image
# contains a hand-built safetensors file (u64 length, 200-byte JSON header,
# F32/F16/U8 tensors), the real nsafetensors parser and nkv views; no C
# harness is linked.
#
# Proves: u64 header length, JSON object/array/string/number parsing,
# __metadata__ skipping, dtype/shape/data_offsets validation, 64-bit absolute
# data offsets, zero-copy F32/F16/U8 nkv views and element reads; rejection
# of bad JSON, unsupported dtype, zero/non-numeric dims, missing shape,
# begin>end, size mismatch, data past storage, too many tensors, zero/oversize
# header length and truncated storage.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nsafetensors.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nsafetensors: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nsafetensors.nas ] || fail "missing src/lib/nsafetensors.nas"
[ -f src/tests/nsafetensors_test.nas ] || fail "missing test image"
grep -q '^nsafetensors_parse:' src/lib/nsafetensors.nas || fail "missing parser"
grep -q '@nsafetensors_parse' src/tests/nsafetensors_test.nas || fail "test does not call parser"
grep -q 'nkv_view_create' src/lib/nsafetensors.nas || fail "no nkv view creation"
grep -q 'sf_skip_value' src/lib/nsafetensors.nas || fail "no JSON value skipper"
grep -q 'sf_skip_string' src/lib/nsafetensors.nas || fail "no JSON string scanner"
grep -q 'sf_parse_uint' src/lib/nsafetensors.nas || fail "no JSON number parser"
grep -q '"__metadata__"' src/lib/nsafetensors.nas || fail "no metadata key"
grep -q '0x4846534E' src/lib/nsafetensors.nas || fail "no header magic"
grep -q '0x5454534E' src/lib/nsafetensors.nas || fail "no tensor magic"
grep -q '0x000000C8' src/tests/nsafetensors_test.nas || fail "no 200-byte header"
grep -q '0x3F800000' src/tests/nsafetensors_test.nas || fail "no exact F32 element"
grep -q '0xBC003800' src/tests/nsafetensors_test.nas || fail "no F16 bytes"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nsafetensors_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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
  tail -3 "$T/err" >&2; fail "safetensors self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "nsafetensors: PASS (u64+JSON header, __metadata__, F32/F16/U8 nkv views, 12 reject cases)"
