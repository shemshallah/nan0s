#!/bin/sh
# tools/tcc_nan16_tcc2.sh - tcc1 -> tcc2 fixpoint gate.
#
# Builds self1, compiles the preprocessed TCC sources (libc.i + libtcc.i +
# driver.i) with self1, extracts self2, runs self2 on test.c and compares
# self1/self2.  The compile is resumable: each slice runs a fixed number of VM
# steps and checkpoints the state.
#
#   sh tools/tcc_nan16_tcc2.sh                  # temporary dir, full run
#   TCC2_DIR=/tmp/tcc2run sh tools/tcc_nan16_tcc2.sh
#                                               # persistent, resumes after a
#                                               # kill/restart
#   TCC2_STEPS=12000000000 ...                  # total step budget
#   TCC2_SLICE=500000000 ...                    # steps per checkpoint
#   TCC2_REBUILD=1 ...                          # force rebuilding self1
#
# With TCC2_DIR, the build is reused if selfcompile.bin exists.  Set
# TCC2_REBUILD=1 after changing compiler/libc sources so stale checkpoints are
# discarded.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
KEEP=${TCC2_KEEP:-0}
if [ -n "${TCC2_DIR:-}" ]; then
    T=$TCC2_DIR
    mkdir -p "$T"
    KEEP=1
else
    T="${TMPDIR:-/tmp}/tcc_nan16_tcc2.$$"
    mkdir -p "$T"
fi
cleanup() {
    if [ "$KEEP" = 1 ]; then
        echo "tcc2: kept $T"
    else
        rm -rf "$T"
    fi
}
trap cleanup EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
CLI=aarch64/android/nan_cli
INC="-I$LIBC/include -I$TT/include -I$TT"

if [ -f "$T/slice" ]; then
    SLICE=$(cat "$T/slice")
    if [ -n "${TCC2_SLICE:-}" ] && [ "${TCC2_SLICE}" != "$SLICE" ]; then
        echo "tcc2: using saved slice $SLICE (requested $TCC2_SLICE)"
    fi
else
    SLICE=${TCC2_SLICE:-500000000}
    printf '%s\n' "$SLICE" > "$T/slice"
fi
LIMIT=${TCC2_STEPS:-8000000000}

[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)

if [ -f "$T/selfcompile.bin" ] && [ "${TCC2_REBUILD:-0}" != 1 ]; then
    echo "tcc2: reusing built self1/selfcompile images in $T"
else
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
    "$T/tcc0" -nostdlib -DNAN16_HEAP_SIZE=134217728 -o "$T/selfcompile.bin" $INC -I"$T" \
        "$LIBC/src/libc.c" "$T/libtcc.i" "$LIBC/src/selfhost_compile_driver.c"
    rm -f "$T"/state*.nan1 "$T"/prog*.bin "$T"/size*.txt "$T"/self2.bin "$T"/self2.done
fi

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

if [ ! -f "$T/self2.done" ]; then
    # Resume from the highest completed checkpoint.
    n=0
    while [ -f "$T/state$((n + 1)).nan1" ] && [ -f "$T/size$((n + 1)).txt" ] \
          && [ -f "$T/prog$((n + 1)).bin" ]; do n=$((n + 1)); done
    if [ "$n" -gt 0 ]; then
        state="$T/state$n.nan1"
        echo "tcc2: resume after $((n * SLICE)) steps from $state"
    else
        state=""
    fi
    echo "tcc2: self-compile (slice=$SLICE limit=$LIMIT)"
    final_state=""; final_size=0
    while [ $((n * SLICE)) -lt "$LIMIT" ]; do
        n=$((n + 1))
        if [ -z "$state" ]; then img="$T/selfcompile.bin"; else img="$state"; fi
        next="$T/state$n.nan1"
        "$CLI" --img "$img" --mem 256 --steps "$((n * SLICE))" --state-out "$next" \
            --dump-bytes "0x03F00000:4:$T/prog$n.bin" \
            --peek '0x0BFFFFC:1' > "$T/size$n.txt" 2> "$T/slice$n.err" || true
        size_hex=$(tail -n 1 "$T/size$n.txt")
        prog=$(python3 -c "import struct;print(struct.unpack('<I',open('$T/prog$n.bin','rb').read(4))[0])")
        echo "tcc2: slice $n total=$((n * SLICE)) size=$size_hex progress=$prog"
        # 9 is set only after the driver's memcpy of self2 to 0x03000000.
        if [ "$prog" -ge 9 ]; then
            final_state="$next"; final_size=$((0x$size_hex)); break
        fi
        state="$next"
    done
    [ -n "$final_state" ] || {
        echo "tcc2: PARTIAL (limit $LIMIT reached; rerun with a larger TCC2_STEPS or TCC2_DIR)"
        exit 1
    }
    [ "$final_size" -gt 0 ] || { echo "tcc2: FAIL (selfcompile produced no self2)"; exit 1; }

    echo "tcc2: extract self2 ($final_size bytes)"
    "$CLI" --img "$final_state" --mem 256 --steps 10 \
        --dump-bytes "0x03000000:$final_size:$T/self2.bin" >/dev/null 2>&1
    [ "$(wc -c < "$T/self2.bin")" = "$final_size" ] || {
        echo "tcc2: FAIL (self2 extraction truncated)"; exit 1; }
    : > "$T/self2.done"
else
    echo "tcc2: reusing extracted self2"
fi

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
