#!/bin/sh
# tools/kabi64_gate.sh - primary-target x86_64 bare-metal S1 ABI gate.
#
# Boots src/native64/s1_bootsec.S (self-contained 512-byte fixture) into flat
# protected mode, then src/native64/s1_boot.S into long mode and runs the
# 64-bit C S1 slice in src/tests/native64/s1_kabi.c.  This is an ABI-mechanics
# slice (integer/memory/port, SVC/SVCRET, timer, region checks), NOT the
# no tools/mkall.sh, no host path constants.  COM1 transcript is exact.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "kabi64: SKIP (no qemu-system-x86_64)"; exit 0; }
T="${TMPDIR:-/tmp}/kabi64.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
MEM="${KABI64_MEM:-128}"

# 512-byte boot fixture: load 64 KiB, A20, protected mode, jump 0x10000.
clang --target=i386-none-elf -c src/native64/s1_bootsec.S -o "$T/bootsec.o"
ld.lld -m elf_i386 --image-base=0 -Ttext=0x7C00 -e _start \
  -o "$T/bootsec.elf" "$T/bootsec.o"
llvm-objcopy -O binary "$T/bootsec.elf" "$T/bootsec.bin"
[ "$(wc -c < "$T/bootsec.bin")" -eq 512 ] || { echo "kabi64: FAIL (bad boot fixture size)"; exit 1; }
[ "$(od -An -tx1 -j510 -N2 "$T/bootsec.bin" | tr -d ' \n')" = "55aa" ] || {
  echo "kabi64: FAIL (boot fixture lacks 55AA)"; exit 1; }

clang --target=x86_64-none-elf -c src/native64/s1_boot.S -o "$T/boot.o"
clang --target=x86_64-none-elf -std=gnu99 -O2 -Wall -Wextra \
  -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone \
  -c src/tests/native64/s1_kabi.c -o "$T/s1.o"
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$T/s1.elf" "$T/boot.o" "$T/s1.o"
llvm-objcopy -O binary "$T/s1.elf" "$T/s1.bin"
[ "$(wc -c < "$T/s1.bin")" -le 65536 ] || { echo "kabi64: FAIL (image > 64 KiB)"; exit 1; }

# The linker ASSERT already rejects this; check the symbol explicitly too.
BSS_END=$(llvm-nm "$T/s1.elf" | awk '$3=="__bss_end"{print $1}')
[ -n "$BSS_END" ] || { echo "kabi64: FAIL (no __bss_end)"; exit 1; }
BSS_DEC=$((0x$BSS_END))
[ "$BSS_DEC" -le $((0x30000)) ] || { echo "kabi64: FAIL (BSS overlaps page tables)"; exit 1; }
[ "$BSS_DEC" -lt $((0x1F0000)) ] || { echo "kabi64: FAIL (BSS overlaps stack)"; exit 1; }

cat "$T/bootsec.bin" "$T/s1.bin" > "$T/img"
truncate -s 1474560 "$T/img"
rm -f "$T/com"
timeout 30 qemu-system-x86_64 -m "$MEM" -drive format=raw,if=floppy,file="$T/img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true

cat > "$T/expect" <<'EOF'
NAN0S S1 KABI x86_64
S1 KABI x86_64 PASS 107 checks, 0 failures
EOF
if ! diff -u "$T/expect" "$T/com" > "$T/diff" 2>&1; then
  echo "kabi64: FAIL (COM1 transcript differs)"
  cat "$T/diff"
  echo "--- actual ---"; cat -v "$T/com"
  exit 1
fi
echo "kabi64: PASS (x86_64 long mode + ABI mechanics, 107 checks, ${MEM} MiB)"
