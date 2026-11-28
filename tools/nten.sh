#!/bin/sh
# tools/nten.sh - 64-bit tensor path arithmetic, including a 4 GiB crossing.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nten.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/nten_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 100000 --serial > "$T/c.out" 2>/dev/null || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/c.out" > "$T/c.got"
cmp -s "$T/c.got" src/tests/nten.expected || { echo "nten: FAIL (C core)"; cat "$T/c.got"; exit 1; }
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
  cmp -s "$T/n.got" src/tests/nten.expected || { echo "nten: FAIL (native x86)"; cat "$T/n.got"; exit 1; }
  echo "nten: PASS (64-bit tensor paths + 4 GiB crossing, both cores)"
else
  echo "nten: PASS (64-bit tensor paths, C core; native x86 skipped)"
fi
