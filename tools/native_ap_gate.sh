#!/bin/sh
# native_ap_gate.sh - native AP startup and real APIC ids on the 32-bit core.
#
# The 32-bit core sends INIT-SIPI-SIPI before entering the guest.  APs enter
# protected mode at 0x6200, record their LAPIC id in the SM_FLAGS bitmap, and
# increment SM_DONE with LOCK INC.  The BSP packs the ids into a 32-bit bitmap
# (port 0x4E0E) and reports the logical CPU count (port 0x4E0F).  The guest
# prints "S<ncpu>A<bitmap>C<cpu-id>" and verifies the bitmap.
#
# Required transcripts:
#   i386 -smp 1  S1A00000000C0
#   i386 -smp 2  S2A00000002C0
#   i386 -smp 4  S4A0000000EC0
#   x64  -smp 1  S1A00000000C0   (x64 AP startup is still BSP-only)
#
# Every transcript ends with "OK".  The x64 core's SPEL stage marker is
# stripped before comparison.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/native_ap.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

CLI32=qemu-system-i386
CLI64=qemu-system-x86_64
command -v "$CLI32" >/dev/null 2>&1 || { echo "native_ap: SKIP (no i386 qemu)"; exit 0; }
command -v "$CLI64" >/dev/null 2>&1 || { echo "native_ap: SKIP (no x86_64 qemu)"; exit 0; }

awk -f tools/nmk.awk -v CMD=emit src/tests/smp_ap_test.nas > "$T/test.nan" 2> "$T/e" ||
  { cat "$T/e" >&2; exit 1; }

build() { # gold out
  g=$1; out=$2
  LC_ALL=C gawk -f tools/mkimg.awk -v NOTOC=1 -v GOLD="$g" \
    -v GUEST="$T/test.nan" -v CARTS=/dev/null \
    -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" >/dev/null 2> "$T/mk.err" ||
    { cat "$T/mk.err" >&2; exit 1; }
  cat "$T/b.bin" "$T/g.bin" > "$out"
  sz=$(wc -c < "$out"); rem=$((sz % 512))
  [ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$out"
  sh tools/manifest_build.sh "$out" >/dev/null 2> "$T/man.err" ||
    { cat "$T/man.err" >&2; exit 1; }
}

run() { # qemu img ncpu out
  q=$1; img=$2; n=$3; out=$4
  truncate -s 1474560 "$T/floppy.img"
  dd if="$img" of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none
  rm -f "$out"
  timeout 25 "$q" -m 512 -smp "$n" \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$img" \
    -boot a -display none -serial file:"$out" -no-reboot >/dev/null 2>&1 || true
  if [ "$q" = "$CLI64" ]; then
    sed 's/^SPEL//' "$out" > "$out.tmp"
    mv "$out.tmp" "$out"
  fi
}

check() { # label got want
  label=$1; got=$2; want=$3
  printf '%s' "$want" > "$T/want"
  cmp -s "$got" "$T/want" ||
    { echo "native_ap: FAIL ($label)"; cat -v "$got" >&2; exit 1; }
}

build src/native/nan16_x86.nan "$T/i386.img"
build src/native/nan16_x64.nan "$T/x64.img"

run "$CLI32" "$T/i386.img" 1 "$T/i386.1.com"
check "i386 -smp 1" "$T/i386.1.com" 'S1A00000000C0
OK
'

run "$CLI32" "$T/i386.img" 2 "$T/i386.2.com"
check "i386 -smp 2" "$T/i386.2.com" 'S2A00000002C0
OK
'

run "$CLI32" "$T/i386.img" 4 "$T/i386.4.com"
check "i386 -smp 4" "$T/i386.4.com" 'S4A0000000EC0
OK
'

run "$CLI64" "$T/x64.img" 1 "$T/x64.1.com"
check "x64 -smp 1" "$T/x64.1.com" 'S1A00000000C0
OK
'

echo "native_ap: PASS (INIT-SIPI-SIPI, APIC ids, i386 1/2/4 CPUs; x64 BSP)"
