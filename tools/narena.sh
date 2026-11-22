#!/bin/sh
# tools/narena.sh - NaN-native bump-arena gate.
# Checks alignment, non-overlap, mark/release reuse, reset and exhaustion on
# the portable C core and, when qemu exists, on the bare-metal x86 core.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/narena.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/narena_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 100000 --serial > "$T/c.out" 2>"$T/c.err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/c.out" > "$T/c.got"
cmp -s "$T/c.got" src/tests/narena.expected || { echo "narena: FAIL (C core)"; diff -u src/tests/narena.expected "$T/c.got" | head; exit 1; }
if command -v qemu-system-i386 >/dev/null 2>&1 && [ -f src/native/nan16_x86.nan ]; then
  gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/t.nan" \
       -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>"$T/m.err"
  cat "$T/b.bin" "$T/g.bin" > "$T/t.img"; truncate -s 1474560 "$T/t.img"
  rm -f "$T/n.com"
  timeout 30 qemu-system-i386 -m 512 -drive format=raw,if=floppy,file="$T/t.img" \
    -display none -serial "file:$T/n.com" -no-reboot >/dev/null 2>&1 || true
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/n.com" > "$T/n.got"
  cmp -s "$T/n.got" src/tests/narena.expected || { echo "narena: FAIL (native x86)"; diff -u src/tests/narena.expected "$T/n.got" | head; exit 1; }
  echo "narena: PASS (NaN arena exact on C core + native x86)"
else
  echo "narena: PASS (NaN arena exact on C core; native x86 skipped)"
fi
