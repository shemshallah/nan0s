#!/bin/sh
# tools/nan_vec_avx2.sh - require the AVX2 tier, then run the full vector
# family under qemu -cpu max.  The feature cart proves detection/XSAVE ran;
# nan_vec/nan_vec_native prove the AVX2 VDP4B lanes are exact.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "nan_vec_avx2: SKIP (no qemu)"; exit 0; }
T="${TMPDIR:-/tmp}/nanavx2.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/avx2_feature_test.nas > "$T/f.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/f.nan" \
     -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>"$T/m.err"
cat "$T/b.bin" "$T/g.bin" > "$T/f.img"; truncate -s 1474560 "$T/f.img"
rm -f "$T/f.com"
timeout 30 qemu-system-i386 -cpu max -m 512 -drive format=raw,if=floppy,file="$T/f.img" \
  -display none -serial "file:$T/f.com" -no-reboot >/dev/null 2>&1 || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/f.com" > "$T/f.got"
cmp -s "$T/f.got" src/tests/avx2_feature.expected || { echo "nan_vec_avx2: FAIL (tier not active)"; cat "$T/f.got"; exit 1; }
QEMU_CPU=max sh tools/nan_vec.sh
QEMU_CPU=max sh tools/nan_vec_native.sh
echo "nan_vec_avx2: PASS (feature bit set, AVX2 VDP4B + packed ALU lanes exact)"
