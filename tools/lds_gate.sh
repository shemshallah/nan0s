#!/bin/sh
# tools/lds_gate.sh - native and C-core high-data STS/LDS round trip.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/lds.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/lds_test.nas > "$T/guest.nan" 2>"$T/asm.err" || {
  cat "$T/asm.err"; echo "lds_gate: ASSEMBLY FAIL"; exit 1;
}
"$CLI" --img "$T/guest.nan" --steps 2000000 --serial > "$T/c.out" 2>/dev/null || true
grep -qx 'LDS OK' "$T/c.out" || { echo "lds_gate: C CORE FAIL"; cat "$T/c.out"; exit 1; }

gawk -f tools/mkimg.awk \
  -v GOLD=x86/native/nan16_x86.nan \
  -v GUEST="$T/guest.nan" \
  -v CARTS=/dev/null \
  -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" 2>"$T/mk.err" || {
  cat "$T/mk.err"; echo "lds_gate: IMAGE FAIL"; exit 1;
}
cat "$T/boot.bin" "$T/guest.bin" > "$T/lds.img"
truncate -s 1474560 "$T/lds.img"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "lds_gate: qemu missing"; exit 1; }
timeout 20 qemu-system-i386 -m 64 \
  -drive format=raw,if=floppy,file="$T/lds.img" \
  -display none -serial "file:$T/com1.txt" -no-reboot >/dev/null 2>&1 || true
grep -qx 'LDS OK' "$T/com1.txt" || { echo "lds_gate: NATIVE FAIL"; cat "$T/com1.txt" 2>/dev/null; exit 1; }
echo "lds_gate: PASS (C core + native x86 STS/LDS high-data window)"
