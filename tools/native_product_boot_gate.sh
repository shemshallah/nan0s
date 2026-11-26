#!/bin/sh
# native_product_boot_gate.sh - boot the shipped product image on bare QEMU.
#
# No C harness and no S1 KABI: this is the same floppy image a machine boots,
# through the native boot sector and NaN16 core.  It must print the NaN/0S
# banner on COM1.
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

timeout 20 qemu-system-i386 \
    -drive format=raw,if=floppy,file=build/nan0s.img \
    -boot a -display none -serial "file:$T/com" -no-reboot \
    > "$T/out" 2> "$T/err" || true

[ -s "$T/com" ] || {
  echo "native_boot: FAIL (no COM1 output)"; tail -8 "$T/err"; exit 1; }
grep -q 'NaN/0S' "$T/com" || {
  echo "native_boot: FAIL (NaN/0S banner missing)"; head -10 "$T/com" | cat -v; exit 1; }

echo "native_boot: PASS (native boot sector + NaN16 core + guest .nan; no C harness)"
