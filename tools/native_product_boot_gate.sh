#!/bin/sh
# native_product_boot_gate.sh - boot the shipped product image on bare QEMU.
#
# No C harness and no S1 KABI: this is the same raw IDE image a machine boots,
# through the native boot sector and NaN16 core.  It must print the NaN/0S
# banner and the NANIX shell startup line on COM1.
#
# QEMU's floppy geometry is not reliable for a multi-megabyte file.  The
# published image is a raw IDE image; stage the boot+kernel window on a
# 1.44 MiB boot floppy and attach the full image as the primary IDE disk.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/native_boot.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

[ -f build/nan0s.img ] || {
  echo "native_boot: FAIL (build/nan0s.img missing; run tools/build.sh)"; exit 1; }
command -v qemu-system-i386 >/dev/null 2>&1 || {
  echo "native_boot: FAIL (qemu-system-i386 not installed)"; exit 1; }

cp build/nan0s.img "$T/ide.img"
truncate -s 1474560 "$T/floppy.img"
dd if=build/nan0s.img of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none

timeout 35 qemu-system-i386 -m 512 \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$T/ide.img" \
    -boot a -display none -serial "file:$T/com" -no-reboot \
    > "$T/out" 2> "$T/err" || true

[ -s "$T/com" ] || {
  echo "native_boot: FAIL (no COM1 output)"; tail -8 "$T/err"; exit 1; }
grep -q 'NaN/0S' "$T/com" || {
  echo "native_boot: FAIL (NaN/0S banner missing)"; head -10 "$T/com" | cat -v; exit 1; }
grep -q 'NANIX SHELL READY' "$T/com" || {
  echo "native_boot: FAIL (NANIX shell startup missing)"; head -10 "$T/com" | cat -v; exit 1; }

echo "native_boot: PASS (native boot sector + NaN16 core + full guest .nan; no C harness)"
