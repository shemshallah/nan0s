#!/bin/sh
# tools/nan16_heap_gate.sh - guest allocator split/coalesce/realloc stress.
#
# Runs heap_probe (targeted) and heap_stress (20k random malloc/realloc/free
# with pattern verification and physical/free-list integrity checks).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-heap.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
RUNNER=${NAN16_HEAP_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_HEAP_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "nan16_heap: SKIP (no x86_64 S1 runner; set NAN16_HEAP_RUNNER or NAN16_HEAP_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "nan16_heap: FAIL runner not executable: $RUNNER"; exit 1; }

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "nan16_heap: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

run_case() {
    name=$1; src=$2; expect=$3; steps=$4
    echo "nan16_heap: build $name"
    "$T/tcc0" -nostdlib -o "$T/$name.bin" \
        -I"$LIBC/include" -I"$TT/include" -I"$TT" \
        "$LIBC/src/libc.c" "$src" > "$T/$name.build" 2>&1 || {
        cat "$T/$name.build"; exit 1; }
    "$RUNNER" --img "$T/$name.bin" --mem 128 --steps "$steps" \
        --guest-stdout "$T/$name.out" --guest-stderr "$T/$name.err" \
        --peek '0x100:1' > "$T/$name.peek" 2> "$T/$name.run" || true
    [ "$(tail -n 1 "$T/$name.peek" 2>/dev/null)" = "00000000" ] || {
        echo "nan16_heap: FAIL ($name main result)"; tail -3 "$T/$name.run"; exit 1; }
    tr -d '\r' < "$T/$name.out" > "$T/$name.norm"
    grep -qx "$expect" "$T/$name.norm" || {
        echo "nan16_heap: FAIL ($name output)"; cat "$T/$name.norm"; exit 1; }
}

run_case probe src/tests/tcc/heap_probe.c 'HEAP PASS' 100000000
run_case stress src/tests/tcc/heap_stress.c 'heap_stress=PASS' 2500000000

if [ "$MODE" = oracle ]; then
    echo "nan16_heap: ORACLE MATCH (probe + 20k random ops; x86_64 S1 acceptance via NAN16_HEAP_RUNNER)"
else
    echo "nan16_heap: PASS (probe + 20k random ops)"
fi
