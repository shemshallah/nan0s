#!/bin/sh
# tools/narena64.sh - 64-bit NaN arena: high-half base and 4 GiB crossing.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/narena64.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/narena64_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 100000 --serial > "$T/c.out" 2>"$T/c.err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/c.out" > "$T/c.got"
printf 'ARENA64 PASS\n' > "$T/want"
cmp -s "$T/c.got" "$T/want" || { echo "narena64: FAIL (C core)"; cat "$T/c.got"; exit 1; }
if command -v qemu-system-i386 >/dev/null 2>&1 && [ -f src/native/nan16_x86.nan ]; then
  gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/t.nan" \
       -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>/dev/null
  cat "$T/b.bin" "$T/g.bin" > "$T/t.img"; truncate -s 1474560 "$T/t.img"
  sh tools/manifest_build.sh "$T/t.img" >/dev/null 2>&1 ||
    { echo "manifest signing failed"; exit 1; }
  rm -f "$T/n.com"
  timeout 30 qemu-system-i386 -m 512 -drive format=raw,if=floppy,file="$T/t.img" \
    -display none -serial "file:$T/n.com" -no-reboot >/dev/null 2>&1 || true
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/n.com" > "$T/n.got"
  cmp -s "$T/n.got" "$T/want" || { echo "narena64: FAIL (native x86)"; cat "$T/n.got"; exit 1; }
  echo "narena64: PASS (64-bit arena, high base + 4 GiB crossing, both cores)"
else
  echo "narena64: PASS (64-bit arena, C core; native x86 skipped)"
fi
