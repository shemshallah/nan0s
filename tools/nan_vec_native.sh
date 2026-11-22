#!/bin/sh
# tools/nan_vec_native.sh - native x86 lowering of VZERO/VBCAST/VDP4B/VGET/VSET.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "nan_vec_native: SKIP (no qemu)"; exit 0; }
T="${TMPDIR:-/tmp}/nanvecn.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/vec512_native_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/t.nan" \
     -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>"$T/m.err"
cat "$T/b.bin" "$T/g.bin" > "$T/t.img"; truncate -s 1474560 "$T/t.img"
rm -f "$T/com"
timeout 30 qemu-system-i386 -m 512 -drive format=raw,if=floppy,file="$T/t.img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/com" > "$T/got"
cmp -s "$T/got" src/tests/vec512_native.expected || { echo "nan_vec_native: FAIL"; diff -u src/tests/vec512_native.expected "$T/got" | head -20; exit 1; }
echo "nan_vec_native: PASS (VZERO/VBCAST/VADD8/VSUB8/VADD32/VSUB32/VMUL32/VDP4B/VGET/VSET on bare x86)"
