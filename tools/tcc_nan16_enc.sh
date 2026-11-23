#!/bin/sh
# tools/tcc_nan16_enc.sh - host-side NaN16 encoder smoke test for tcc0.
# Builds the encoder, emits MOVI/ST/HALT both as raw words and .nan text,
# executes both in nan_cli and requires the stored payload 0x2A.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/tccnan16enc.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
CC=${HOST_CC:-cc}
$CC -std=c99 -O2 -Ithird_party/tinycc \
   third_party/tinycc/nan16-enc.c \
   third_party/tinycc/nan16-enc-selftest.c -o "$T/selftest"
"$T/selftest" "$T/prog.bin" "$T/prog.nan" "$T/loop.bin" "$T/loop.nan" "$T/call.bin" "$T/call.nan" "$T/const.bin" "$T/const.nan" > "$T/selftest.out"
grep -q '^NAN16 ENC OK words=3$' "$T/selftest.out"
grep -q '^NAN16 ENC OK loop=7$' "$T/selftest.out"
grep -q '^NAN16 ENC OK call=5$' "$T/selftest.out"
grep -q '^NAN16 ENC OK const=4$' "$T/selftest.out"
grep -q '^NAN16 ENC OK label=5$' "$T/selftest.out"
for img in prog.bin prog.nan loop.bin loop.nan call.bin call.nan const.bin const.nan; do
  "$CLI" --img "$T/$img" --mem 16 --steps 1000 --serial --peek 0x100:1 \
      > "$T/$img.out" 2> "$T/$img.err" || true
  want=0000002A
  case "$img" in loop*) want=00000003 ;; call*) want=00000007 ;; const*) want=12345678 ;; esac
  if ! grep -qx "$want" "$T/$img.out"; then
    echo "tcc_nan16_enc: FAIL ($img did not store $want)"
    cat -v "$T/$img.out" "$T/$img.err"; exit 1
  fi
  if ! grep -q 'rc=3' "$T/$img.err"; then
    echo "tcc_nan16_enc: FAIL ($img did not halt)"
    cat -v "$T/$img.err"; exit 1
  fi
done
echo "tcc_nan16_enc: PASS (encoder emits loadable/executable NaN16 words)"
