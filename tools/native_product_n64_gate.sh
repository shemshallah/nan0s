#!/bin/sh
# native_product_n64_gate.sh - 64-bit product ABI at boot.
#
# gui_sched_boot.nas includes n64/narena64/nten/nmat and runs an n64_probe
# before the shell: it allocates from a 64-bit arena, builds an nten tensor
# descriptor, checks a 64-bit pointer, and runs an nmat DP4B dot.  Success
# prints "N64 OK"; failure prints "N64 BAD".  The same guest also boots the
# GUI/shell, so this gate checks both.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/native_product_n64.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

[ -f build/nan0s.img ] || {
  echo "native_product_n64: FAIL (build/nan0s.img missing; run tools/build.sh)"; exit 1; }
command -v qemu-system-i386 >/dev/null 2>&1 || {
  echo "native_product_n64: SKIP (no i386 qemu)"; exit 0; }

cp build/nan0s.img "$T/ide.img"
truncate -s 1474560 "$T/floppy.img"
dd if=build/nan0s.img of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none
timeout 35 qemu-system-i386 -m 512 \
  -drive format=raw,if=floppy,file="$T/floppy.img" \
  -drive format=raw,if=ide,file="$T/ide.img" \
  -boot a -display none -serial "file:$T/com" -no-reboot \
  > "$T/out" 2> "$T/err" || true

[ -s "$T/com" ] || {
  echo "native_product_n64: FAIL (no COM1 output)"; tail -8 "$T/err"; exit 1; }
grep -q 'N64 OK' "$T/com" || {
  echo "native_product_n64: FAIL (N64 OK missing)"; cat -v "$T/com" >&2; exit 1; }
! grep -q 'N64 BAD' "$T/com" || {
  echo "native_product_n64: FAIL (N64 BAD)"; cat -v "$T/com" >&2; exit 1; }
grep -q 'NANIX SHELL READY' "$T/com" || {
  echo "native_product_n64: FAIL (shell startup missing)"; cat -v "$T/com" >&2; exit 1; }

echo "native_product_n64: PASS (narena64/nten/nmat probe prints N64 OK; shell starts)"
