#!/bin/sh
# tools/tcc_nan16_rawcc.sh - tcc1 raw-source/VFS gate.
#
# Builds tcc1, then has the self-hosted libtcc preprocess and compile raw C
# files from an embedded read-only guest VFS: /usr/include headers, libc.c and
# a test program.  The emitted inner cartridge must return 42.  This is the
# first step from host-preprocessed .i blobs to tcc1 compiling ordinary source
# files on the VM.
#
#   RAWCC_STEPS=N   VM step budget (default 6,000,000,000)
#   RAWCC_KEEP=1    keep the scratch directory for diagnosis
#
# Compiler gates use the portable C core as a conformance oracle.  The same
# flat cartridge is intended for the x86_64 S1; no phone/Android path is part
# of the product.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/tcc_rawcc.$$"; mkdir -p "$T"; trap 'if [ "${RAWCC_KEEP:-0}" = 1 ]; then echo rawcc: kept $T; else rm -rf "$T"; fi' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
CLI=aarch64/android/nan_cli
STEPS=${RAWCC_STEPS:-6000000000}
INC="-I$LIBC/include -I$TT/include -I$TT"

[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "rawcc: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

echo "rawcc: preprocess libtcc for the tcc1 image"
"$T/tcc0" -E -nostdinc -DTCC_TARGET_NAN16 -DONE_SOURCE -DCONFIG_TCC_STATIC \
    -DCONFIG_TCC_BACKTRACE=0 $INC "$TT/libtcc.c" -o "$T/libtcc.i"

cat > "$T/prog.c" <<'EOC'
#include <stdint.h>
#include <stddef.h>
int main(void)
{
    uint32_t x = 40;
    size_t y = 2;
    return (int)(x + y);
}
EOC

echo "rawcc: embed headers, libc.c and prog.c"
python3 tools/nan16_embed_tree.py "$T/guest_cc_src.h" \
    --tree "$LIBC/include=/usr/include" \
    --tree "$TT/include=/usr/lib/tcc/include" \
    --file "/work/libc.c=$LIBC/src/libc.c" \
    --file "/work/nan16_pow10.h=$LIBC/src/nan16_pow10.h" \
    --file "/work/prog.c=$T/prog.c"

echo "rawcc: build tcc1 raw-source driver"
NAN16_MAP=1 "$T/tcc0" -nostdlib -DNAN16_EXIT_DIAG -o "$T/tcc1_raw.bin" -I"$T" $INC \
    "$LIBC/src/libc.c" "$T/libtcc.i" "$LIBC/src/guest_cc_driver.c" \
    2> "$T/tcc1_raw.map"

echo "rawcc: compile raw source on the VM"
timeout 1800 "$CLI" --img "$T/tcc1_raw.bin" --mem 128 --steps "$STEPS" \
    --state-out "$T/state.nan1" --peek '0x0BFFFFC:1,0x0FC0000:1' \
    > "$T/size.txt" 2> "$T/run.err" || true
size_hex=$(head -n 1 "$T/size.txt")
prog_hex=$(tail -n 1 "$T/size.txt")
case "$size_hex" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
    *) echo "rawcc: FAIL (bad output size '$size_hex')"; tail -5 "$T/run.err"; exit 1 ;;
esac
size=$((0x$size_hex))
[ "$size" -gt 0 ] || {
    echo "rawcc: FAIL (no inner cartridge; progress=$prog_hex)"
    "$CLI" --img "$T/state.nan1" --mem 128 --steps 10 \
        --dump-bytes "0x03DFFFF0:0x4100:$T/diag.bin" >/dev/null 2>&1 || true
    if [ -f "$T/diag.bin" ]; then
        echo "rawcc: compiler stderr:"
        dd if="$T/diag.bin" bs=1 skip=16 count=4096 2>/dev/null | tr -d '\000'
        echo
    fi
    tail -5 "$T/run.err"
    exit 1
}

echo "rawcc: extract and run the inner cartridge ($size bytes)"
# The state snapshot contains the output copy; execute one step and dump.
"$CLI" --img "$T/state.nan1" --mem 128 --steps 10 \
    --dump-bytes "0x03000000:$size:$T/inner.bin" >/dev/null 2>&1 || true
[ "$(wc -c < "$T/inner.bin")" = "$size" ] || {
    echo "rawcc: FAIL (inner extraction truncated)"; exit 1; }
ret=$("$CLI" --img "$T/inner.bin" --mem 64 --steps 100000 \
    --peek '0x100:1' 2>/dev/null | tail -n 1)
[ "$ret" = "0000002A" ] || {
    echo "rawcc: FAIL (inner main returned '$ret', expected 0000002A)"; exit 1; }

echo "rawcc: PASS (tcc1 compiled raw C with VFS includes; inner main returned 42)"
