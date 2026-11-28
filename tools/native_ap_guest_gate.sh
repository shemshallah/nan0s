#!/bin/sh
# native_ap_guest_gate.sh - an AP executes real guest NaN code.
#
# CPU0 publishes entry PC 0x1000 and guest stack 0x3C000 through the nansmp
# mailbox ports (0x4E10/0x4E11), fences, sets go (0x4E12), and HALTs.  Every
# AP wakes from the park loop, aliases virtual 0x8000 to a private interpreter
# state page via paging, and runs the guest program at word 0x1000: 1000
# atomic fetch-adds on the shared word 0x20000.  APIC id 1 waits for all APs
# and prints "AP <total>" (1000 on 2 CPUs, 3000 on 4) and OK.  A single CPU
# prints "AP 00000000" (no AP to run the program).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/native_ap_guest.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

CLI=qemu-system-i386
command -v "$CLI" >/dev/null 2>&1 || { echo "native_ap_guest: SKIP (no i386 qemu)"; exit 0; }

awk -f tools/nmk.awk -v CMD=emit src/tests/smp_ap_guest_test.nas > "$T/test.nan" 2> "$T/e" ||
  { cat "$T/e" >&2; exit 1; }

LC_ALL=C gawk -f tools/mkimg.awk -v NOTOC=1 -v GOLD=src/native/nan16_x86.nan \
  -v GUEST="$T/test.nan" -v CARTS=/dev/null \
  -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" >/dev/null 2> "$T/mk.err" ||
  { cat "$T/mk.err" >&2; exit 1; }
cat "$T/b.bin" "$T/g.bin" > "$T/img"
sz=$(wc -c < "$T/img"); rem=$((sz % 512))
[ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$T/img"
sh tools/manifest_build.sh "$T/img" >/dev/null 2> "$T/man.err" ||
  { cat "$T/man.err" >&2; exit 1; }
truncate -s 1474560 "$T/floppy.img"
dd if="$T/img" of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none

run() { # ncpu out
  n=$1; out=$2
  rm -f "$out"
  timeout 25 "$CLI" -m 512 -smp "$n" \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$T/img" \
    -boot a -display none -serial file:"$out" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot \
    >/dev/null 2> "$T/q.err" || true
  if grep -q '!O\|!G' "$out"; then
    echo "native_ap_guest: FAIL ($n CPUs, native trap)"; cat -v "$out" >&2; exit 1
  fi
}

run 1 "$T/com.1"
printf 'AP 00000000\nOK\n' > "$T/want.1"
cmp -s "$T/com.1" "$T/want.1" ||
  { echo "native_ap_guest: FAIL (-smp 1)"; cat -v "$T/com.1" >&2; exit 1; }

run 2 "$T/com.2"
printf 'AP 000003E8\nOK\n' > "$T/want.2"
cmp -s "$T/com.2" "$T/want.2" ||
  { echo "native_ap_guest: FAIL (-smp 2)"; cat -v "$T/com.2" >&2; exit 1; }

run 4 "$T/com.4"
printf 'AP 00000BB8\nOK\n' > "$T/want.4"
cmp -s "$T/com.4" "$T/want.4" ||
  { echo "native_ap_guest: FAIL (-smp 4)"; cat -v "$T/com.4" >&2; exit 1; }

echo "native_ap_guest: PASS (every AP runs 1000 guest fetch-adds on private paged state; 1/2/4 CPUs)"
