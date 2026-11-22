#!/bin/sh
# tools/qgate64core.sh - NaN-coded x86-64 core proof.
# The NaN translator emits a 64-bit block; the native substrate copies it to
# an executable page, runs it, and reads the guest register.  No instruction
# selection happens in the native code.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qgate64core: SKIP (no qemu-system-x86_64)"; exit 0; }
T="${TMPDIR:-/tmp}/qgate64core.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

# 1. NaN translator emits the block.
awk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 100000 --serial --peek 0x4000:12 > "$T/peek" 2>/dev/null || true
python3 - "$T/peek" "$T/block64.bin" <<'PY'
import sys
ws=[l.strip() for l in open(sys.argv[1]) if len(l.strip())==8 and all(c in '0123456789ABCDEFabcdef' for c in l.strip())]
data=b''.join(int(w,16).to_bytes(4,'little') for w in ws)[:46]
open(sys.argv[2],'wb').write(data)
PY
[ "$(wc -c < "$T/block64.bin")" -eq 46 ] || { echo "qgate64core: FAIL (translator emitted $(wc -c < "$T/block64.bin") bytes)"; exit 1; }
[ "$(od -An -tx1 -N4 "$T/block64.bin" | tr -d ' \n')" = "c7042504" ] || { echo "qgate64core: FAIL (bad block prefix)"; od -An -tx1 "$T/block64.bin" | head; exit 1; }

# 2. Build the substrate with the block embedded.
ROOT=$(pwd)
cat > "$T/core64.S" <<EOS
.section .rodata
.globl block64
block64:
.incbin "$T/block64.bin"
.globl block64_end
block64_end:
.text
.include "$ROOT/src/native64/core64_body.S"
EOS
clang --target=x86_64-none-elf -c "$T/core64.S" -o "$T/core64.o"
ld.lld -m elf_x86_64 -T src/native64/core64.ld -e _start -o "$T/core64.elf" "$T/core64.o"
llvm-objcopy -O binary "$T/core64.elf" "$T/kernel64.bin"
[ "$(wc -c < "$T/kernel64.bin")" -le 65536 ] || { echo "qgate64core: FAIL (kernel > 64 KiB)"; exit 1; }

# 3. Boot and require the NaN-emitted result.
[ -f build/nan0s.img ] || sh tools/mkall.sh >/dev/null 2>&1
dd if=build/nan0s.img of="$T/boot.bin" bs=512 count=1 2>/dev/null
cat "$T/boot.bin" "$T/kernel64.bin" > "$T/img"
truncate -s 66048 "$T/img"; truncate -s 1474560 "$T/img"
rm -f "$T/com"
timeout 30 qemu-system-x86_64 -m 512 -drive format=raw,if=floppy,file="$T/img" \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true
if grep -q 'NAN64 CORE 00000054 OK' "$T/com"; then
  echo "qgate64core: PASS (NaN translator -> x86-64 block -> native execution, r1=84)"
else
  echo "qgate64core: FAIL"; cat -v "$T/com"; echo
  exit 1
fi
