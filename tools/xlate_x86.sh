#!/bin/sh
# tools/xlate_x86.sh - NaN-native block translator -> packed x86 -> EXECN.
# Covers MOVI/MOVHI/ADD/SUB/ADDI/SHL/SHR/LD/ST/LDB/STB, guest flags,
# CMP/CMPS and JMP[GT]/JMP[LT] taken and fallthrough.  Success means the
# translated x86 leaves the exact same state the interpreter would.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "xlate_x86: SKIP (no qemu)"; exit 0; }
T="${TMPDIR:-/tmp}/xlate.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/xlate_x86_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/t.nan" \
     -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>"$T/m.err"
cat "$T/b.bin" "$T/g.bin" > "$T/t.img"; truncate -s 1474560 "$T/t.img"
rm -f "$T/com"
timeout 30 qemu-system-i386 -m 512 -drive format=raw,if=floppy,file="$T/t.img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/com" > "$T/got"
cmp -s "$T/got" src/tests/xlate_x86.expected || { echo "xlate_x86: FAIL"; diff -u src/tests/xlate_x86.expected "$T/got" | head -20; exit 1; }
echo "xlate_x86: PASS (NaN translator emits ALU/memory/flags/branches; EXECN runs them exactly)"
