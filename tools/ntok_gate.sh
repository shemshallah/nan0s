#!/bin/sh
# ntok_gate.sh - deterministic byte-level tokenizer + 24-merge BPE.
#
# Builds src/tests/ntok_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image contains the real
# src/lib/ntok.nas; no C harness is linked.
#
# Proves: BOS/EOS/UNK/vocab constants, exact BPE ids for four strings,
# encode/decode round-trip for ASCII, NUL/high bytes and all 256 byte values,
# BOS/EOS skipping, UNK -> '?', invalid-id rejection and merged-token lengths.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/ntok.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "ntok: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/ntok.nas ] || fail "missing src/lib/ntok.nas"
[ -f src/tests/ntok_test.nas ] || fail "missing test image"
for sym in ntok_encode ntok_decode ntok_decode_token ntok_id_bytes \
           ntok_bos ntok_eos ntok_unk ntok_is_special; do
  grep -q "^$sym:" src/lib/ntok.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/ntok_test.nas || fail "test does not call $sym"
done
grep -q 'NTK_MERGES     24' src/lib/ntok.nas || fail "no 24-merge table"
grep -q '^ntok_merges:' src/lib/ntok.nas || fail "no merge table"
grep -q '266' src/tests/ntok_test.nas || fail "no merged hello id"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/ntok_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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
  tail -5 "$T/err" >&2; fail "tokenizer self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "ntok: PASS (24-merge deterministic BPE, exact ids, all-256-byte round-trip, BOS/EOS/UNK)"
