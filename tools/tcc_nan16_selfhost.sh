#!/bin/sh
# tools/tcc_nan16_selfhost.sh - build and verify the NaN16 self-host compiler.
# The cartridge contains libtcc + the minimal libc + a driver.  With --run it
# compiles test.c, emits an inner NaN16 cartridge, executes that cartridge and
# checks that it returns 42 (the tcc1 self-host milestone).
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/tccnan16self.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc_nan16" -lm -ldl
"$T/tcc_nan16" -E -nostdinc -DTCC_TARGET_NAN16 -DONE_SOURCE -DCONFIG_TCC_STATIC \
    -DCONFIG_TCC_BACKTRACE=0 -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$TT/libtcc.c" -o "$T/libtcc.i"
"$T/tcc_nan16" -nostdlib -o "$T/self1.bin" -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$T/libtcc.i" "$LIBC/src/selfhost_driver.c"
echo "tcc_nan16_selfhost: built $(wc -c < "$T/self1.bin") bytes"
if [ "$1" = --run ]; then
    size_hex=$("$CLI" --img "$T/self1.bin" --mem 256 --steps 50000000 \
        --peek '0x0BFFFFC:1' 2>/dev/null | tail -n 1)
    case "$size_hex" in
        [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) echo "tcc_nan16_selfhost: FAIL (bad output size '$size_hex')"; exit 1 ;;
    esac
    size=$((0x$size_hex))
    [ "$size" -gt 0 ] || { echo "tcc_nan16_selfhost: FAIL (empty output)"; exit 1; }
    "$CLI" --img "$T/self1.bin" --mem 256 --steps 50000000 \
        --dump-bytes "0x03000000:$size:$T/inner.bin" >/dev/null 2>&1
    ret=$("$CLI" --img "$T/inner.bin" --mem 64 --steps 100000 \
        --peek '0x100:1' 2>/dev/null | tail -n 1)
    if [ "$ret" = "0000002A" ]; then
        echo "tcc_nan16_selfhost: PASS (self1 emitted $size bytes; inner main returned 42)"
    else
        echo "tcc_nan16_selfhost: FAIL (inner main returned '$ret', expected 0000002A)"
        exit 1
    fi
fi
