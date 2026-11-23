#!/bin/sh
# tools/tcc_nan16_tcc2.sh - tcc1 -> tcc2 fixpoint gate.
#
# Builds self1, compiles the preprocessed TCC sources (libc.i + libtcc.i +
# driver.i) with self1, extracts self2, runs self2 on test.c and compares
# self1/self2.  The compile is resumable in TCC2_SLICE steps and checkpoints
# the VM state after every slice.
#
#   sh tools/tcc_nan16_tcc2.sh             # build and run the fixpoint
#   TCC2_STEPS=10000000000 ...             # larger total budget
#
# This gate is intentionally not part of presqlite_gate yet: a full TCC
# self-compile is much slower than the 37-program tcc0 gate.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/tcc_nan16_tcc2.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
CLI=aarch64/android/nan_cli
SLICE=${TCC2_SLICE:-500000000}
LIMIT=${TCC2_STEPS:-5000000000}
INC="-I$LIBC/include -I$TT/include -I$TT"

[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)

echo "tcc2: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

echo "tcc2: preprocess libtcc.c, libc.c, selfhost_driver.c"
"$T/tcc0" -E -nostdinc -DTCC_TARGET_NAN16 -DONE_SOURCE -DCONFIG_TCC_STATIC \
    -DCONFIG_TCC_BACKTRACE=0 $INC "$TT/libtcc.c" -o "$T/libtcc.i"
"$T/tcc0" -E -nostdinc -DTCC_TARGET_NAN16 -DONE_SOURCE -DCONFIG_TCC_STATIC \
    -DCONFIG_TCC_BACKTRACE=0 $INC "$LIBC/src/libc.c" -o "$T/libc.i"
"$T/tcc0" -E -nostdinc -DTCC_TARGET_NAN16 -DONE_SOURCE -DCONFIG_TCC_STATIC \
    -DCONFIG_TCC_BACKTRACE=0 $INC "$LIBC/src/selfhost_driver.c" -o "$T/driver.i"

echo "tcc2: build self1 and selfcompile"
"$T/tcc0" -nostdlib -o "$T/self1.bin" $INC "$LIBC/src/libc.c" "$T/libtcc.i" \
    "$LIBC/src/selfhost_driver.c"
python3 tools/nan16_embed.py "$T/compiler_src.h" \
    compiler_libc="$T/libc.i" compiler_libtcc="$T/libtcc.i" \
    compiler_driver="$T/driver.i"
"$T/tcc0" -nostdlib -DHEAP_SIZE=134217728 -o "$T/selfcompile.bin" $INC -I"$T" \
    "$LIBC/src/libc.c" "$T/libtcc.i" "$LIBC/src/selfhost_compile_driver.c"

run_test() { # run_test IMAGE LABEL -> requires inner main == 42
    img="$1"; label="$2"
    size_hex=$("$CLI" --img "$img" --mem 256 --steps 50000000 \
        --peek '0x0BFFFFC:1' 2>/dev/null | tail -n 1)
    size=$((0x$size_hex))
    [ "$size" -gt 0 ] || { echo "tcc2: FAIL ($label emitted no cartridge)"; exit 1; }
    "$CLI" --img "$img" --mem 256 --steps 50000000 \
        --dump-bytes "0x03000000:$size:$T/$label.inner" >/dev/null 2>&1
    ret=$("$CLI" --img "$T/$label.inner" --mem 64 --steps 100000 \
        --peek '0x100:1' 2>/dev/null | tail -n 1)
    [ "$ret" = "0000002A" ] || {
        echo "tcc2: FAIL ($label inner returned '$ret', expected 0000002A)"; exit 1; }
    echo "tcc2: $label inner returns 42 ($size bytes)"
}

echo "tcc2: verify self1"
run_test "$T/self1.bin" self1

echo "tcc2: self-compile (slice=$SLICE limit=$LIMIT)"
target=$SLICE; state=""; n=0; final_state=""; final_size=0
while [ "$target" -le "$LIMIT" ]; do
    n=$((n + 1))
    if [ -z "$state" ]; then img="$T/selfcompile.bin"; else img="$state"; fi
    next="$T/state$n.nan1"
    "$CLI" --img "$img" --mem 512 --steps "$target" --state-out "$next" \
        --dump-bytes "0x03F00000:4:$T/prog$n.bin" \
        --peek '0x0BFFFFC:1' > "$T/size$n.txt" 2> "$T/slice$n.err" || true
    size_hex=$(tail -n 1 "$T/size$n.txt")
    prog=$(python3 -c "import struct;print(struct.unpack('<I',open('$T/prog$n.bin','rb').read(4))[0])")
    echo "tcc2: slice $n target=$target size=$size_hex progress=$prog"
    # 9 is set only after the driver's memcpy of self2 to 0x03000000; the
    # size at 0x02FFFFF0 is stored before that copy starts.
    if [ "$prog" -ge 9 ]; then
        final_state="$next"; final_size=$((0x$size_hex)); break
    fi
    state="$next"; target=$((target + SLICE))
done
[ -n "$final_state" ] || { echo "tcc2: FAIL (not finished within $LIMIT steps)"; exit 1; }
[ "$final_size" -gt 0 ] || { echo "tcc2: FAIL (selfcompile produced no self2)"; exit 1; }

echo "tcc2: extract self2 ($final_size bytes)"
"$CLI" --img "$final_state" --mem 512 --steps "$target" \
    --dump-bytes "0x03000000:$final_size:$T/self2.bin" >/dev/null 2>&1
[ "$(wc -c < "$T/self2.bin")" = "$final_size" ] || {
    echo "tcc2: FAIL (self2 extraction truncated)"; exit 1; }
run_test "$T/self2.bin" self2

if cmp -s "$T/self1.bin" "$T/self2.bin"; then
    hash=$(sha256sum "$T/self1.bin" | cut -d' ' -f1)
    echo "tcc2: sha256 $hash"
    echo "tcc2: PASS (tcc1 == tcc2, $(wc -c < "$T/self1.bin") bytes)"
else
    echo "tcc2: DIFF (self1 != self2)"
    cmp -l "$T/self1.bin" "$T/self2.bin" | head -10 || true
    exit 1
fi
