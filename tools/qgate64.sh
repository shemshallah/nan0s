#!/bin/sh
# tools/qgate64.sh - boot the 32-bit loader, enter x86-64 long mode, and
# require the 64-bit COM1 banner.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qgate64: SKIP (no qemu-system-x86_64)"; exit 0; }
T="${TMPDIR:-/tmp}/qgate64.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
clang --target=x86_64-none-elf -c src/native64/longmode.S -o "$T/longmode.o"
ld.lld -m elf_x86_64 -T src/native64/longmode.ld -e _start -o "$T/longmode.elf" "$T/longmode.o"
llvm-objcopy -O binary "$T/longmode.elf" "$T/kernel64.bin"
[ "$(wc -c < "$T/kernel64.bin")" -le 65536 ] || { echo "qgate64: FAIL (kernel > 64 KiB)"; exit 1; }
[ -f build/nan0s.img ] || sh tools/mkall.sh >/dev/null 2>&1
dd if=build/nan0s.img of="$T/boot.bin" bs=512 count=1 2>/dev/null
cat "$T/boot.bin" "$T/kernel64.bin" > "$T/img"
truncate -s 66048 "$T/img"
truncate -s 1474560 "$T/img"
rm -f "$T/com"
MEM="${QGATE64_MEM:-512}"
timeout 30 qemu-system-x86_64 -m "$MEM" -drive format=raw,if=floppy,file="$T/img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
if grep -q 'NAN0S x86-64 OK' "$T/com" && grep -q 'NAN0S MMAP64 OK' "$T/com"; then
  if grep -q '^RAM64 ' "$T/com"; then
    echo "qgate64: PASS (long mode + 4-level mapping + 64-bit E820)"
  else
    echo "qgate64: PASS (long mode + 4-level mapping; BIOS E820 table unavailable)"
  fi
else
  echo "qgate64: FAIL (no long-mode banner)"
  head -c 200 "$T/com" | cat -v; echo
  exit 1
fi
