#!/bin/sh
# tools/nan_q4.sh - VDP4B4 Q4 weights x Q8 activations, exact lanes.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nanq4.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/q4dot_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 100000 --serial > "$T/o" 2>/dev/null || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/o" > "$T/got"
cmp -s "$T/got" src/tests/q4dot.expected || { echo "nan_q4: FAIL (C reference)"; diff -u src/tests/q4dot.expected "$T/got" | head -20; exit 1; }
if command -v qemu-system-i386 >/dev/null 2>&1; then
  gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/t.nan" \
       -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>/dev/null
  cat "$T/b.bin" "$T/g.bin" > "$T/t.img"; truncate -s 1474560 "$T/t.img"
  rm -f "$T/com"
  timeout 30 qemu-system-i386 ${QEMU_CPU:+-cpu $QEMU_CPU} -m 512 -drive format=raw,if=floppy,file="$T/t.img" \
    -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/com" > "$T/ngot"
  cmp -s "$T/ngot" src/tests/q4dot.expected || { echo "nan_q4: FAIL (native)"; diff -u src/tests/q4dot.expected "$T/ngot" | head -20; exit 1; }
  echo "nan_q4: PASS (VDP4B4 Q4xQ8 lanes exact, C reference + native x86)"
else
  echo "nan_q4: PASS (VDP4B4 C reference; native skipped)"
fi
