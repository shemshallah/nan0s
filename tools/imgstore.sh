#!/bin/sh
# Image store gate: the guest word count is a LE32 at byte 504, so images may
# exceed the historical 65,536-word/1.44 MB boundary (up to the 4M-word VM).
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
CLI=aarch64/android/nan_cli; IMG=build/nan0s.img
[ -x "$CLI" ] || { echo "imgstore: nan_cli missing"; exit 1; }
[ -f "$IMG" ] || { echo "imgstore: image missing"; exit 1; }
T="${TMPDIR:-/tmp}/imgstore.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
for n in 70000 200000; do
  cp "$IMG" "$T/i$n.img"
  cur=$(wc -c < "$T/i$n.img")
  need=$((8704 + n * 8))
  if [ "$cur" -lt "$need" ]; then dd if=/dev/zero bs=1 count=$((need-cur)) >> "$T/i$n.img" 2>/dev/null; fi
  # LE32 word count at byte 504
  b0=$((n & 255)); b1=$(((n >> 8) & 255)); b2=$(((n >> 16) & 255)); b3=$(((n >> 24) & 255))
  printf "\\$(printf '%03o' $b0)\\$(printf '%03o' $b1)\\$(printf '%03o' $b2)\\$(printf '%03o' $b3)" |
    dd of="$T/i$n.img" bs=1 seek=504 conv=notrunc 2>/dev/null
  # marker word at guest word n-1 (payload 0x12345678)
  off=$((8704 + (n-1) * 8))
  printf '\170\126\064\022\000\000\000\000' |
    dd of="$T/i$n.img" bs=1 seek=$off conv=notrunc 2>/dev/null
  got=$("$CLI" --img "$T/i$n.img" --steps 10 --peek $((n-1)):1 2>/dev/null | tail -1 | tr -d ' \r')
  [ "$got" = "00001234" ] || { echo "imgstore: FAIL ($n words, got $got)"; exit 1; }
done
echo "imgstore: PASS (70,000- and 200,000-word guest images load)"
