#!/bin/sh
# tools/nan16_scanf_gate.sh - differential guest sscanf against host libc.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-scanf.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SRC=src/tests/tcc/scanf_probe.c
RUNNER=${NAN16_SCANF_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_SCANF_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "nan16_scanf: SKIP (no x86_64 S1 runner; set NAN16_SCANF_RUNNER or NAN16_SCANF_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "nan16_scanf: FAIL runner not executable: $RUNNER"; exit 1; }

echo "nan16_scanf: native reference"
$CC -std=gnu99 -O2 -o "$T/native" "$SRC"
"$T/native" > "$T/native.out"

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "nan16_scanf: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "nan16_scanf: build guest"
"$T/tcc0" -nostdlib -o "$T/scanf.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$SRC" > "$T/build.log" 2>&1 || {
    cat "$T/build.log"; exit 1; }

"$RUNNER" --img "$T/scanf.bin" --mem 128 --steps 500000000 \
    --guest-stdout "$T/guest.out" --guest-stderr "$T/guest.err" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run" || true
[ "$(tail -n 1 "$T/peek" 2>/dev/null)" = "00000000" ] || {
    echo "nan16_scanf: FAIL (main result)"; tail -3 "$T/run"; exit 1; }
tr -d '\r' < "$T/guest.out" > "$T/guest.norm"
if ! diff -u "$T/native.out" "$T/guest.norm"; then
    echo "nan16_scanf: FAIL (guest != host sscanf)"
    [ -f "$T/guest.err" ] && cat "$T/guest.err"
    exit 1
fi
if [ "$MODE" = oracle ]; then
    echo "nan16_scanf: ORACLE MATCH (guest sscanf == host; x86_64 S1 acceptance via NAN16_SCANF_RUNNER)"
else
    echo "nan16_scanf: PASS (guest sscanf == host)"
fi
