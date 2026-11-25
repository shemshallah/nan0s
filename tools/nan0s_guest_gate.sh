#!/bin/sh
# nan0s_guest_gate.sh - run a NaN guest on the nan0s machine.
#
# Default (NAN0S_GUEST_ARCH=64): the x86_64 S1 machine (s1_runner.sh)
# executes the NaN guest.  This is the upgraded machine path.
# NAN0S_GUEST_ARCH=32: build the legacy 32-bit kboot0+kan16 floppy and boot
# it with qemu-system-i386.
#
# usage: sh tools/nan0s_guest_gate.sh [guest.nas] [expected-text]
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
GUEST=${1:-src/tests/nanfs_meta_test.nas}
EXPECT=${2:-PASS}
ARCH=${NAN0S_GUEST_ARCH:-64}
T="${TMPDIR:-/tmp}/nan0s_guest.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

gawk -f tools/nmk.awk -v CMD=emit "$GUEST" > "$T/g.nan" 2> "$T/asm.err"

if [ "$ARCH" = 64 ]; then
    RUNNER=${NAN0S_GUEST_RUNNER:-tools/s1_runner.sh}
    "$RUNNER" --img "$T/g.nan" --mem "${NAN0S_GUEST_MEM:-16}" \
        --steps "${NAN0S_GUEST_STEPS:-10000000}" --serial \
        > "$T/com1.txt" 2> "$T/run.err" || true
    if ! grep -q "$EXPECT" "$T/com1.txt" 2>/dev/null; then
        echo "nan0s_guest: FAIL ($GUEST did not print '$EXPECT' on x86_64 S1)"
        head -20 "$T/com1.txt" 2>/dev/null || true
        tail -5 "$T/run.err" 2>/dev/null || true
        exit 1
    fi
    echo "nan0s_guest: PASS ($GUEST on x86_64 S1; $(wc -c < "$T/com1.txt") COM1 bytes)"
    exit 0
fi

if [ "$ARCH" != 32 ]; then
    echo "nan0s_guest: FAIL (unknown NAN0S_GUEST_ARCH=$ARCH; use 32 or 64)" >&2
    exit 2
fi

# Legacy 32-bit unified image path.
: > "$T/carts.txt"
gawk -f tools/mkimg.awk \
    -v GOLD=src/native/nan16_x86.nan \
    -v GUEST="$T/g.nan" -v CARTS="$T/carts.txt" \
    -v OUTB="$T/b" -v OUTG="$T/g2" > "$T/mk.log" 2>&1
cat "$T/b" "$T/g2" > "$T/img"
python3 - "$T/img" <<'PY'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
if len(d) < 1474560:
    d += b"\0" * (1474560 - len(d))
open(p, "wb").write(d)
PY

timeout "${NAN0S_GUEST_TIMEOUT:-20}" qemu-system-i386 -m "${NAN0S_GUEST_MEM32:-512}" \
    -drive format=raw,if=floppy,file="$T/img" \
    -display none -serial "file:$T/com1.txt" -no-reboot >/dev/null 2>&1 || true
if ! grep -q "$EXPECT" "$T/com1.txt" 2>/dev/null; then
    echo "nan0s_guest: FAIL ($GUEST did not print '$EXPECT' on kboot0+kan16)"
    head -20 "$T/com1.txt" 2>/dev/null || true
    exit 1
fi
echo "nan0s_guest: PASS ($GUEST on 32-bit kboot0+kan16; $(wc -c < "$T/com1.txt") COM1 bytes)"
