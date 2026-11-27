#!/bin/sh
# ngguf_gate.sh - zero-copy GGUF v2/v3 import over a 2 TiB storage cap.
#
# Builds src/tests/ngguf_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image contains the real
# src/lib/ngguf.nas parser plus nkv views; no C harness is linked.
#
# Proves: magic/version/counts, metadata key/type/value skipping (u32, bool,
# f32, u64, string, array-of-strings), general.alignment, tensor infos
# (F32 rank 2, Q4_0, F16, Q8_0), 64-bit relative/absolute offsets, exact
# names/sizes/block counts, typed F32/F16 nkv views, raw u8 Q4/Q8 views,
# a Q8 tensor range crossing 4 GiB, a view element exactly at 4 GiB, and
# rejection of bad magic/version/counts/alignment/dtype/misalignment,
# truncated storage and a too-small tensor table.  Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/ngguf.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "ngguf: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/ngguf.nas ] || fail "missing src/lib/ngguf.nas"
[ -f src/tests/ngguf_test.nas ] || fail "missing test image"
for sym in ngguf_parse; do
  grep -q "^$sym:" src/lib/ngguf.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/ngguf_test.nas || fail "test does not call $sym"
done
for f in NG_MAGIC NG_DT_F32 NG_DT_Q4_0 NG_DT_Q8_0 NG_H_DATAOFF NG_T_ABSOFF NG_T_VIEW; do
  grep -q "$f" src/lib/ngguf.nas || fail "missing $f"
done
grep -q 'nkv_view_create' src/lib/ngguf.nas || fail "no nkv view creation"
grep -q 'n64_add' src/lib/ngguf.nas || fail "no 64-bit offsets"
grep -q '0xFFFFFD80' src/tests/ngguf_test.nas || fail "no 4 GiB-crossing tensor"
grep -q 'scap_small' src/tests/ngguf_test.nas || fail "no truncated-storage case"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/ngguf_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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
  tail -5 "$T/err" >&2; fail "GGUF self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "ngguf: PASS (GGUF v3 header/metadata/tensor infos, F32/F16/Q4_0/Q8_0 views, 4 GiB-crossing range, reject cases)"
