#!/bin/sh
# qgate64abi.sh - translator SVC/SVCRET frame + control-port proof.
#
# The NaN translator emits three x86-64 blocks.  The first drives the control
# ports with OUTL, then SVC 7.  The kernel block reads frame[20], writes the
# return word, and SVCRETs.  The guest resumes at the saved PC with the saved
# SP and returns 0x9A.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qgate64abi: SKIP"; exit 0; }

T="${TMPDIR:-$PWD/tmp}/qgate64abi.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

awk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_abi.nas > "$T/t.nan" 2>"$T/e" || {
  cat "$T/e"; exit 1; }
./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 200000 --serial \
  --peek 0x8000:8192 > "$T/peek" 2>/dev/null || true

python3 - "$T/peek" "$T" <<'PY'
import sys
ws=[l.strip() for l in open(sys.argv[1]) if len(l.strip())==8 and all(c in '0123456789ABCDEFabcdef' for c in l.strip())]
data=b''.join(int(w,16).to_bytes(4,'little') for w in ws)
def block(off):
    raw=data[off:off+0x1000]
    k=raw.rfind(b'\xc3')
    assert k>0, ('no RET at', hex(off), len(raw))
    return raw[:k+1]
b0=block(0x0000); b1=block(0x1000); b2=block(0x2000)
assert b0[:3]==b'\xc7\x04\x25', ('bad block0 prefix', b0[:8].hex())
assert b1[:3]==b'\x8b\x04\x25' or b1[:3]==b'\x8b\x87' or b1[:3]==b'\xc7\x04\x25', ('bad block1 prefix', b1[:8].hex())
assert b2[:3]==b'\xc7\x04\x25', ('bad block2 prefix', b2[:8].hex())
assert b'\xbb\x00\x81\x01\x00\xff\xd3' in b0, 'no OUTL helper call'
assert b'\x8b\x04\x25\x00\x0e\x05\x00' in b0, 'no KIN load in SVC'
assert b'\xc7\x04\x25\x00\x0e\x05\x00\x01\x00\x00\x00' in b0, 'SVC does not set KIN'
assert b'\xc1\xe0\x03' in b0 and b'\x05\x00\x00\x20\x00' in b0, 'no frame base computation'
assert b'\xc7\x04\x25\x00\x0e\x05\x00\x00\x00\x00\x00' in b2, 'SVCRET does not clear KIN'
assert b'\x83\xe0\x03' in b2, 'SVCRET does not mask k'
assert b'\xb9\x01\x00\x00\x00' in b2, 'SVCRET does not build the FLAGM mask'
assert b'\xd3\xe1' in b2, 'SVCRET does not rebuild FLAGM'
assert b'\x89\x04\x25\x04\x00\x05\x00' in b2, 'SVCRET does not restore r1'
for name,b in (('b0.bin',b0),('b1.bin',b1),('b2.bin',b2)):
    open(sys.argv[2]+'/'+name,'wb').write(b + b'\0'*(2048-len(b)))
print('blocks',len(b0),len(b1),len(b2))
PY

ROOT=$(pwd)
cat > "$T/core64.S" <<EOS
.section .rodata
.globl block0
block0:
.incbin "$T/b0.bin"
.globl block1
block1:
.incbin "$T/b1.bin"
.globl block2
block2:
.incbin "$T/b2.bin"
.p2align 3
.globl block_table
block_table:
.quad 0, 0x51000
.quad 11, 0x52000
.quad 13, 0x53000
.quad 0xFFFFFFFF, 0
.text
.include "$ROOT/src/native64/core64_dispatch_body.S"
.text
.code64
.org 0x8000
port_in:
  cmp \$0x4E00,%edx
  je pi_entry
  cmp \$0x4E01,%edx
  je pi_frame
  cmp \$0x4E03,%edx
  je pi_stack
  cmp \$0x4E06,%edx
  je pi_status
  xor %eax,%eax
  ret
pi_entry:
  mov 0x50E04,%eax
  ret
pi_frame:
  mov 0x50E0C,%eax
  ret
pi_stack:
  mov 0x50E08,%eax
  ret
pi_status:
  mov 0x50E00,%eax
  ret
.org 0x8100
port_out:
  cmp \$0x4E00,%edx
  je po_entry
  cmp \$0x4E01,%edx
  je po_frame
  cmp \$0x4E03,%edx
  je po_stack
  ret
po_entry:
  movl %eax,0x50E04
  ret
po_frame:
  movl %eax,0x50E0C
  ret
po_stack:
  movl %eax,0x50E08
  ret
EOS
clang --target=x86_64-none-elf -c "$T/core64.S" -o "$T/core64.o"
ld.lld -m elf_x86_64 -T src/native64/core64.ld -e _start -o "$T/core64.elf" "$T/core64.o"
llvm-objcopy -O binary "$T/core64.elf" "$T/kernel64.bin"
[ "$(wc -c < "$T/kernel64.bin")" -le 65536 ] || { echo "qgate64abi: FAIL (kernel >64K)"; exit 1; }

[ -f build/nan0s.img ] || sh tools/mkall.sh >/dev/null 2>&1
dd if=build/nan0s.img of="$T/boot.bin" bs=512 count=1 2>/dev/null
cat "$T/boot.bin" "$T/kernel64.bin" > "$T/img"; truncate -s 1474560 "$T/img"
rm -f "$T/com"
timeout 30 qemu-system-x86_64 -m 512 -drive format=raw,if=floppy,file="$T/img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
if grep -q 'NAN64 CORE 0000009A XPC 0000000B OK' "$T/com"; then
  echo "qgate64abi: PASS (SVC/SVCRET frame, control ports, return 0x9A, resume PC 11)"
else
  echo "qgate64abi: FAIL"; cat -v "$T/com"; echo
  exit 1
fi
