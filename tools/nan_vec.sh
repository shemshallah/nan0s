#!/bin/sh
# tools/nan_vec.sh - 512-bit abstract vector family (packed i8/i32 lanes).
# The C core is the semantic reference; the native x86 backend is the next
# stage and will be required to match these exact lanes.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
CPUARG=""
if [ -n "$QEMU_CPU" ]; then CPUARG="-cpu $QEMU_CPU"; fi
T="${TMPDIR:-/tmp}/nanvec.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/vec512_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 100000 --serial > "$T/o" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/o" > "$T/got"
cmp -s "$T/got" src/tests/vec512.expected || { echo "nan_vec: FAIL (C reference)"; diff -u src/tests/vec512.expected "$T/got" | head -20; exit 1; }
if command -v qemu-system-i386 >/dev/null 2>&1 && [ -f src/native/nan16_x86.nan ]; then
  gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/t.nan" \
       -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>/dev/null
  cat "$T/b.bin" "$T/g.bin" > "$T/t.img"; truncate -s 1474560 "$T/t.img"
  rm -f "$T/n.com"
  timeout 30 qemu-system-i386 $CPUARG -m 512 -drive format=raw,if=floppy,file="$T/t.img" \
    -display none -serial "file:$T/n.com" -no-reboot >/dev/null 2>&1 || true
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/n.com" > "$T/n.got"
  cmp -s "$T/n.got" src/tests/vec512.expected || { echo "nan_vec: FAIL (native x86)"; diff -u src/tests/vec512.expected "$T/n.got" | head -20; exit 1; }
  echo "nan_vec: PASS (full 512-bit V family, C reference + native x86)"
else
  echo "nan_vec: PASS (full 512-bit V family, C reference; native x86 skipped)"
fi
