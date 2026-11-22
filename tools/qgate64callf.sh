#!/bin/sh
# tools/qgate64callf.sh - NaN-coded 64-bit CALL/RET program gate.
# PC0 calls PC4, which adds and returns to PC2; PC2 increments and halts.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qgate64callf: SKIP (no qemu-system-x86_64)"; exit 0; }
T="${TMPDIR:-/tmp}/qgate64callf.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

awk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_callf.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 100000 --serial --peek 0x4000:2080 > "$T/peek" 2>/dev/null || true
python3 - "$T/peek" "$T" <<'PY'
import sys
ws=[l.strip() for l in open(sys.argv[1]) if len(l.strip())==8 and all(c in '0123456789ABCDEFabcdef' for c in l.strip())]
data=b''.join(int(w,16).to_bytes(4,'little') for w in ws)
def block(off):
    raw=data[off:off+512]
    k=raw.rfind(b'\xc3')
    assert k>=0, ('no RET at', hex(off))
    return raw[:k+1]
b0=block(0x0000)
b1=block(0x1000)
b2=block(0x2000)
assert b0[:3]==b'\xc7\x04\x25' and b0[-1:]==b'\xc3', b0[:8].hex()
assert b1[:3]==b'\x8b\x04\x25' and b1[-1:]==b'\xc3', b1[:8].hex()
assert b2[:3]==b'\x8b\x04\x25' and b2[-1:]==b'\xc3', b2[:8].hex()
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
.quad 2, 0x52000
.quad 4, 0x53000
.quad 0xFFFFFFFF, 0
.text
.include "$ROOT/src/native64/core64_dispatch_body.S"
EOS
clang --target=x86_64-none-elf -c "$T/core64.S" -o "$T/core64.o"
ld.lld -m elf_x86_64 -T src/native64/core64.ld -e _start -o "$T/core64.elf" "$T/core64.o"
llvm-objcopy -O binary "$T/core64.elf" "$T/kernel64.bin"
[ "$(wc -c < "$T/kernel64.bin")" -le 65536 ] || { echo "qgate64callf: FAIL (kernel > 64 KiB)"; exit 1; }

[ -f build/nan0s.img ] || sh tools/mkall.sh >/dev/null 2>&1
dd if=build/nan0s.img of="$T/boot.bin" bs=512 count=1 2>/dev/null
cat "$T/boot.bin" "$T/kernel64.bin" > "$T/img"
truncate -s 66048 "$T/img"; truncate -s 1474560 "$T/img"
rm -f "$T/com"
timeout 30 qemu-system-x86_64 -m 512 -drive format=raw,if=floppy,file="$T/img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
if grep -q 'NAN64 CORE 00000012 XPC 00000002 OK' "$T/com"; then
  echo "qgate64callf: PASS (NaN CALLF 24-bit target, r1=18, XPC=2)"
else
  echo "qgate64callf: FAIL"; cat -v "$T/com"; echo
  exit 1
fi
