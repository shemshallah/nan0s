#!/bin/sh
# mem64_gate.sh - native 5-level page tables, full 4 PiB direct map.
#
# Boots a 128 MiB QEMU guest, builds the architectural-maximum map (4 PiB
# physical / 128 PiB virtual when LA57 is present) with 1 GiB pages, maps a
# 1 TiB object range plus 2 MiB and 4 KiB leaves, walks the tables, switches
# CR3, reads through the high-half direct map, and rejects MAXPHYADDR and
# non-canonical addresses.  No 4 PiB of host RAM is allocated.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C

QEMU_BIN=${QEMU:-qemu-system-x86_64}
command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  echo "mem64: SKIP (no $QEMU_BIN)"; exit 0; }

TMPBASE=${MEM64_TMP:-${TMPDIR:-/tmp}}
if ! mkdir -p "$TMPBASE" 2>/dev/null; then TMPBASE="$PWD/build"; mkdir -p "$TMPBASE"; fi
T="$TMPBASE/mem64.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

CC=${CC:-clang}
LD=${LD:-ld.lld}
OBJCOPY=${OBJCOPY:-llvm-objcopy}

"$CC" --target=x86_64-none-elf -c src/native64/mem64_boot.S -o "$T/boot.o"
"$CC" --target=x86_64-none-elf -std=gnu99 -O2 -Wall -Wextra \
  -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone \
  -mno-sse -mno-mmx -mno-avx \
  -c src/native64/mem64.c -o "$T/mem.o"
"$LD" -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$T/mem.elf" "$T/boot.o" "$T/mem.o"
"$OBJCOPY" -O binary "$T/mem.elf" "$T/mem.bin"
[ "$(wc -c < "$T/mem.bin")" -le 65536 ] || {
  echo "mem64: FAIL (kernel > 64 KiB)"; exit 1; }

# 512-byte floppy fixture; the kernel occupies the 64 KiB window at 0x10000.
"$CC" --target=i386-none-elf -c src/native64/s1_bootsec.S -o "$T/bootsec.o"
"$LD" -m elf_i386 --image-base=0 -Ttext=0x7C00 -e _start \
  -o "$T/bootsec.elf" "$T/bootsec.o"
"$OBJCOPY" -O binary "$T/bootsec.elf" "$T/bootsec.bin"
[ "$(wc -c < "$T/bootsec.bin")" -eq 512 ] || {
  echo "mem64: FAIL (bad boot fixture)"; exit 1; }
cat "$T/bootsec.bin" "$T/mem.bin" > "$T/img"
truncate -s 1474560 "$T/img"

# max,la57=on gives 5-level paging on QEMU TCG; phys-bits=52 gives 4 PiB.
set +e
timeout 180 "$QEMU_BIN" -cpu max,la57=on,phys-bits=52 -m 128M \
  -drive format=raw,if=floppy,file="$T/img" -boot a \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1
set -e

echo "--- mem64 COM1 ---"
cat "$T/com" 2>/dev/null || true
echo "------------------"

grep -q '^NAN0S MEM64 x86_64$' "$T/com" || {
  echo "mem64: FAIL (no banner)"; exit 1; }
grep -q '^MEM64 LEVELS=5 PHYS=52 VIRT=57$' "$T/com" || {
  echo "mem64: FAIL (not 5-level / 52-bit / 57-bit)"; exit 1; }
grep -q '^MEM64 PASS$' "$T/com" || {
  echo "mem64: FAIL (no PASS)"; exit 1; }

line=$(grep '^MEM64 TABLES=' "$T/com" | tail -1)
tables=$(printf '%s\n' "$line" | sed -n 's/.*TABLES=\([0-9]*\).*/\1/p')
map=$(printf '%s\n' "$line" | sed -n 's/.*MAP=\(0x[0-9a-f]*\).*/\1/p')
pg1=$(printf '%s\n' "$line" | sed -n 's/.* 1G=\([0-9]*\).*/\1/p')
pg2=$(printf '%s\n' "$line" | sed -n 's/.* 2M=\([0-9]*\).*/\1/p')
pg4=$(printf '%s\n' "$line" | sed -n 's/.* 4K=\([0-9]*\).*/\1/p')

[ -n "$tables" ] && [ "$tables" -ge 8200 ] && [ "$tables" -le 8300 ] || {
  echo "mem64: FAIL (table count '$tables')"; exit 1; }
[ "$map" = "0x0010010000201000" ] || {
  echo "mem64: FAIL (mapped bytes '$map')"; exit 1; }
[ "$pg1" = "4195328" ] || {
  echo "mem64: FAIL (1G page count '$pg1')"; exit 1; }
[ "$pg2" = "1" ] && [ "$pg4" = "1" ] || {
  echo "mem64: FAIL (2M/4K leaves $pg2/$pg4)"; exit 1; }

echo "mem64: PASS (5-level, 4 PiB direct map, 1 TiB object, 2M/4K leaves, high-half read, max+canonical rejection)"
