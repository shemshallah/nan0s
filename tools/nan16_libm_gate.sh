#!/bin/sh
# tools/nan16_libm_gate.sh - differential guest libm against host libm.
#
# Builds libm_probe.c natively and as a tcc0 NaN16 guest (libc.c + probe),
# then requires identical scaled transcripts.  Covers exp/log/log2/log10,
# pow (fractional and negative base), sin/cos/tan, asin/acos/atan/atan2,
# sinh/cosh/tanh, round/trunc/copysign/modf, isfinite and signbit.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-libm.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SRC=src/tests/tcc/libm_probe.c
RUNNER=${NAN16_LIBM_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_LIBM_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "nan16_libm: SKIP (no x86_64 S1 runner; set NAN16_LIBM_RUNNER or NAN16_LIBM_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "nan16_libm: FAIL runner not executable: $RUNNER"; exit 1; }

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "nan16_libm: native reference"
$CC -std=gnu99 -O2 -o "$T/native" "$SRC" -lm
"$T/native" > "$T/native.out"

echo "nan16_libm: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "nan16_libm: build guest"
"$T/tcc0" -nostdlib -o "$T/libm.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$SRC" > "$T/build.log" 2>&1 || {
    cat "$T/build.log"; exit 1; }

"$RUNNER" --img "$T/libm.bin" --mem 128 --steps 1000000000 \
    --guest-stdout "$T/guest.out" --guest-stderr "$T/guest.err" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run" || true
[ "$(tail -n 1 "$T/peek" 2>/dev/null)" = "00000000" ] || {
    echo "nan16_libm: FAIL (main result)"; tail -3 "$T/run"; exit 1; }
tr -d '\r' < "$T/guest.out" > "$T/guest.norm"

if ! diff -u "$T/native.out" "$T/guest.norm"; then
    echo "nan16_libm: FAIL (guest != host libm)"
    [ -f "$T/guest.err" ] && cat "$T/guest.err"
    exit 1
fi
grep -qx 'LIBM PASS' "$T/guest.norm" || {
    echo "nan16_libm: FAIL (missing completion marker)"; exit 1; }

if [ "$MODE" = oracle ]; then
    echo "nan16_libm: ORACLE MATCH (guest libm == host libm; x86_64 S1 acceptance pending)"
else
    echo "nan16_libm: PASS (guest libm == host libm)"
fi
