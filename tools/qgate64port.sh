#!/bin/sh
# qgate64port.sh - translator OUTL/INL -> native port helper proof.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qgate64port: SKIP"; exit 0; }
T="${TMPDIR:-$PWD/tmp}/qgate64port.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_port.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 100000 --serial --peek 0x4000:512 > "$T/peek" 2>/dev/null || true
python3 - "$T/peek" "$T/block.bin" <<'PY'
import sys
ws=[l.strip() for l in open(sys.argv[1]) if len(l.strip())==8 and all(c in '0123456789ABCDEFabcdef' for c in l.strip())]
data=b''.join(int(w,16).to_bytes(4,'little') for w in ws)
k=data.find(b'\xc3')
assert k>0, 'no RET in translated block'
open(sys.argv[2],'wb').write(data[:k+1])
assert data[:3]==b'\xc7\x04\x25', ('bad block prefix', data[:8].hex())
assert b'\xbb\x00\x80\x01\x00\xff\xd3' in data, 'no port helper call'
print('block',k+1,'bytes')
PY
ROOT=$(pwd)
cat > "$T/core64.S" <<EOS
.section .rodata
.globl block64
block64:
.incbin "$T/block.bin"
.globl block64_end
block64_end:
.text
.include "$ROOT/src/native64/core64_body.S"
.code64
.org 0x8000
port_helper:
  movl %eax,0x50D00
  movl %edx,0x50D04
  mov \$0x1234,%eax
  ret
EOS
clang --target=x86_64-none-elf -c "$T/core64.S" -o "$T/core64.o"
ld.lld -m elf_x86_64 -T src/native64/core64.ld -e _start -o "$T/core64.elf" "$T/core64.o"
llvm-objcopy -O binary "$T/core64.elf" "$T/kernel64.bin"
[ "$(wc -c < "$T/kernel64.bin")" -le 65536 ] || { echo "qgate64port: FAIL kernel >64K"; exit 1; }
[ -f build/nan0s.img ] || sh tools/mkall.sh >/dev/null 2>&1
dd if=build/nan0s.img of="$T/boot.bin" bs=512 count=1 2>/dev/null
cat "$T/boot.bin" "$T/kernel64.bin" > "$T/img"; truncate -s 1474560 "$T/img"
timeout 30 qemu-system-x86_64 -m 512 -drive format=raw,if=floppy,file="$T/img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
if grep -q 'NAN64 CORE 00001234 XPC 00000000 OK' "$T/com"; then
  echo "qgate64port: PASS (translator OUTL/INL -> native helper, r1=0x1234)"
else
  echo "qgate64port: FAIL"; cat -v "$T/com"; echo; exit 1
fi
