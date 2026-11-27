#!/bin/sh
# qgate64core2.sh - shared immutable block, per-core CR3 state windows.
#
# The NaN translator emits one block.  The native gate builds two 4-level
# roots; both identity-map the block and guest memory, but 0x50000 maps to
# core0's state page under root 0x38000 and core1's under root 0x3C000.
# Running the same bytes twice must produce r1=0x11/0x21 and the matching
# shared-memory slots.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qgate64core2: SKIP"; exit 0; }

T="${TMPDIR:-$PWD/tmp}/qgate64core2.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

awk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_core2.nas > "$T/t.nan" 2>"$T/e" || {
  cat "$T/e"; exit 1; }
./aarch64/android/nan_cli --img "$T/t.nan" --mem 32 --steps 200000 --serial \
  --dump-bytes 0x20000:4096:"$T/raw.bin" >/dev/null 2>"$T/nc.err" || true

python3 - "$T/raw.bin" "$T/b0.bin" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
k=d.rfind(b'\xc3')
assert k>0, 'no RET in emitted block'
b=d[:k+1]
assert b[:7]==b'\x8b\x04\x25\x04\x00\x05\x00', ('bad ADDI prefix', b[:8].hex())
assert b'\x05\x01\x00\x00\x00' in b, 'no ADDI +1'
assert b'\x89\x04\x25\x04\x00\x05\x00' in b, 'no store of r1'
assert b'\xc7\x04\x25\x00\x0c\x05\x00\x01\x00\x00\x00' in b, 'no HALT'
open(sys.argv[2],'wb').write(b)
print('block',len(b),'bytes')
PY

cat > "$T/blob.S" <<EOS
.section .rodata
.globl block0
block0:
.incbin "$T/b0.bin"
.globl block0_end
block0_end:
.text
EOS
clang --target=x86_64-none-elf -c src/native64/s1_boot.S -o "$T/boot.o"
clang --target=x86_64-none-elf -std=gnu99 -O2 -Wall -Wextra \
  -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone \
  -mno-sse -mno-mmx -mno-avx \
  -c src/native64/core2.c -o "$T/core2.o"
clang --target=x86_64-none-elf -c "$T/blob.S" -o "$T/blob.o"
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$T/core2.elf" "$T/boot.o" "$T/core2.o" "$T/blob.o"
llvm-objcopy -O binary "$T/core2.elf" "$T/core2.bin"
[ "$(wc -c < "$T/core2.bin")" -le 65536 ] || { echo "qgate64core2: FAIL (kernel >64K)"; exit 1; }

[ -f build/nan0s.img ] || sh tools/mkall.sh >/dev/null 2>&1
dd if=build/nan0s.img of="$T/boot.bin" bs=512 count=1 2>/dev/null
cat "$T/boot.bin" "$T/core2.bin" > "$T/img"; truncate -s 1474560 "$T/img"
timeout 30 qemu-system-x86_64 -m 128M -drive format=raw,if=floppy,file="$T/img" \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true

cat "$T/com" 2>/dev/null || true
expected='CORE2 BSP
CORE2 core0 r1=00000011 slot=00000011 halt=1
CORE2 core1 r1=00000021 slot=00000021 halt=1
CORE2 PASS'
got=$(cat "$T/com" 2>/dev/null || true)
[ "$got" = "$expected" ] || {
  echo "qgate64core2: FAIL (transcript)"; exit 1; }
echo "qgate64core2: PASS (one immutable block, two CR3 roots, per-core r1/slot, shared code/guest memory)"
