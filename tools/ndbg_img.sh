#!/bin/sh
# tools/ndbg_img.sh - bare-metal boot gate for the serial monitor.
#
# Builds a floppy image whose guest is src/dbg/n16dbg.nas (the monitor + core +
# disassembler + target), boots it on qemu-system-i386 with no host OS, and
# requires the monitor banner and prompt on COM1.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-$PWD/build}/ndbgimg.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "ndbg_img: qemu-system-i386 missing"; exit 1; }

awk -f tools/nmk.awk -v CMD=emit src/dbg/n16dbg.nas > "$T/guest.nan" 2>"$T/asm.err" || {
  cat "$T/asm.err"; echo "ndbg_img: ASSEMBLY FAIL"; exit 1;
}
gawk -f tools/mkimg.awk \
  -v GOLD=x86/native/nan16_x86.nan \
  -v GUEST="$T/guest.nan" \
  -v CARTS=/dev/null \
  -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" 2>"$T/mkimg.err" || {
  cat "$T/mkimg.err"; echo "ndbg_img: IMAGE FAIL"; exit 1;
}
cat "$T/boot.bin" "$T/guest.bin" > "$T/ndbg.img"
truncate -s 1474560 "$T/ndbg.img"

timeout 20 qemu-system-i386 -m 64 \
  -drive format=raw,if=floppy,file="$T/ndbg.img" \
  -display none -serial "file:$T/com1.txt" -no-reboot >/dev/null 2>&1 || true

bytes=$(wc -c < "$T/com1.txt" 2>/dev/null || echo 0)
if grep -q 'NANDBG MONITOR' "$T/com1.txt" && grep -q '^> ' "$T/com1.txt"; then
  echo "ndbg_img: PASS (bare-metal boot, monitor banner + prompt, $bytes bytes COM1)"
else
  echo "ndbg_img: FAIL ($bytes bytes COM1)"
  head -20 "$T/com1.txt" 2>/dev/null || true
  cat "$T/mkimg.err" 2>/dev/null || true
  exit 1
fi
