#!/bin/sh
# qgate64smpblock.sh - F1 real-AP immutable-block runtime gate.
#
# Translates src/tests/xlate64_smpblock.nas with the NaN block translator
# (x64_block), extracts the emitted x86-64 bytes from guest byte memory at
# 0x20000, embeds them in the S1 test kernel, and boots QEMU with two real
# CPUs.  Each CPU enters through the MADT/INIT-SIPI-SIPI trampoline with its
# own 4-level CR3 root:
#
#   core0 root 0x38000: VA 0x50000 -> state page 0x70000
#   core1 root 0x3C000: VA 0x50000 -> state page 0x71000
#
# The block page 0x51000 and shared guest word memory 0x200000 stay identity
# mapped under both roots.  The same immutable bytes must produce
# r1/slot/done = 0x11 on CPU0 and 0x21 on CPU1.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C

QEMU_BIN=${QEMU:-qemu-system-x86_64}
command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  echo "qgate64smpblock: SKIP (no $QEMU_BIN)"; exit 0; }

TMPBASE=${QSMPSBLOCK_TMP:-${TMPDIR:-/tmp}}
if ! mkdir -p "$TMPBASE" 2>/dev/null; then TMPBASE="$PWD/build"; mkdir -p "$TMPBASE"; fi
T="$TMPBASE/qgate64smpblock.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
TIMEOUT=${QSMPSBLOCK_TIMEOUT:-90}

# ------------------------------------------------------- translate the block
awk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_smpblock.nas \
  > "$T/t.nan" 2> "$T/emit.err"
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || { echo "qgate64smpblock: FAIL (no word count)"; cat "$T/emit.err"; exit 1; }
# The translator driver must not sit under its own byte-memory output at 0x20000.
[ $((WORDS * 8)) -le $((0x20000)) ] || {
  echo "qgate64smpblock: FAIL (translator image overlaps 0x20000)"; exit 1; }
awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err"
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  echo "qgate64smpblock: FAIL (nmk check)"; cat "$T/check.err"; exit 1; }

timeout 60 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 32 --steps 200000 \
  --serial --dump-bytes "0x20000:4096:$T/raw.bin" >/dev/null 2> "$T/nc.err" || true
[ -s "$T/raw.bin" ] || {
  echo "qgate64smpblock: FAIL (nan_cli emitted no bytes)"; cat "$T/nc.err"; exit 1; }

python3 - "$T/raw.bin" "$T/block.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
k = d.rfind(b'\xc3')
assert k > 0, 'no RET at the end of the emitted block'
b = d[:k + 1]
assert b.startswith(bytes.fromhex('8b0425040005000501000000')), \
    ('bad ADDI r1,r1,1 prefix', b[:16].hex())
assert bytes.fromhex('8b042508000500') in b, 'no load of per-core r2'
assert bytes.fromhex('8b04250c000500') in b, 'no load of per-core r3'
assert bytes.fromhex('8b0c2504000500') in b, 'no load of per-core r1 for ST'
assert bytes.fromhex('c70425000c050001000000c3') in b, 'no HALT tail'
assert b.count(b'\xc3') == 1, 'unexpected extra RET byte'
assert len(b) <= 4096, ('block too large', len(b))
open(sys.argv[2], 'wb').write(b)
print('block %d bytes' % len(b))
PY

# ------------------------------------------------------------ AP trampoline
clang --target=x86_64-none-elf -c src/native64/smp_tramp.S -o "$T/tramp.o"
ld.lld -m elf_x86_64 --image-base=0 -Ttext=0x8000 -e _start \
  -o "$T/tramp.elf" "$T/tramp.o"
llvm-objcopy -O binary "$T/tramp.elf" "$T/tramp.bin"
TSZ=$(wc -c < "$T/tramp.bin")
[ "$TSZ" -gt 0 ] && [ "$TSZ" -le 4096 ] || {
  echo "qgate64smpblock: FAIL (trampoline size $TSZ)"; exit 1; }

# Embed the immutable block and the trampoline in the test kernel.
cat > "$T/blob.S" <<EOF
.section .rodata
.p2align 3
.global block0
block0:
.incbin "$T/block.bin"
.global block0_end
block0_end:
.p2align 3
.global smp_tramp_blob
smp_tramp_blob:
.incbin "$T/tramp.bin"
.global smp_tramp_blob_end
smp_tramp_blob_end:
.text
EOF

# ------------------------------------------------------------------- kernel
clang --target=x86_64-none-elf -c src/native64/s1_boot.S -o "$T/boot.o"
clang --target=x86_64-none-elf -c src/native64/s1_smp_isr.S -o "$T/isr.o"
clang --target=x86_64-none-elf -std=gnu99 -O2 -Wall -Wextra -DBLOCK_SMP \
  -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone \
  -mno-sse -mno-mmx -mno-avx \
  -c src/tests/native64/s1_smp.c -o "$T/smp.o"
clang --target=x86_64-none-elf -c "$T/blob.S" -o "$T/blob.o"
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$T/s1.elf" "$T/boot.o" "$T/smp.o" "$T/isr.o" "$T/blob.o"
llvm-objcopy -O binary "$T/s1.elf" "$T/s1.bin"
[ "$(wc -c < "$T/s1.bin")" -le 65536 ] || {
  echo "qgate64smpblock: FAIL (S1 block-SMP image > 64 KiB)"; exit 1; }
BSS_END=$(llvm-nm "$T/s1.elf" | awk '$3=="__bss_end"{print $1}')
[ -n "$BSS_END" ] || { echo "qgate64smpblock: FAIL (no __bss_end)"; exit 1; }
[ $((0x$BSS_END)) -le $((0x30000)) ] || {
  echo "qgate64smpblock: FAIL (BSS overlaps page tables)"; exit 1; }

# 512-byte boot fixture + 64 KiB kernel window.
clang --target=i386-none-elf -c src/native64/s1_bootsec.S -o "$T/bootsec.o"
ld.lld -m elf_i386 --image-base=0 -Ttext=0x7C00 -e _start \
  -o "$T/bootsec.elf" "$T/bootsec.o"
llvm-objcopy -O binary "$T/bootsec.elf" "$T/bootsec.bin"
[ "$(wc -c < "$T/bootsec.bin")" -eq 512 ] || {
  echo "qgate64smpblock: FAIL (bad boot fixture size)"; exit 1; }
cat "$T/bootsec.bin" "$T/s1.bin" > "$T/img"
truncate -s 1474560 "$T/img"

# --------------------------------------------------------------- transcript
rm -f "$T/com"
timeout "$TIMEOUT" "$QEMU_BIN" -m 256M -smp 2 \
  -drive format=raw,if=floppy,file="$T/img" -boot a \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -display none -serial "file:$T/com" -no-reboot >/dev/null 2>&1 || true

expected='NAN0S BLOCK SMP x86_64
BLOCK SMP cpus=2
BLOCK SMP core0 r1=0x11 slot=0x11 done=0x11
BLOCK SMP core1 r1=0x21 slot=0x21 done=0x21
BLOCK SMP PASS'
got=$(cat "$T/com" 2>/dev/null || true)
cat "$T/com" 2>/dev/null || true
[ "$got" = "$expected" ] || {
  echo "qgate64smpblock: FAIL (COM1 transcript)"; exit 1; }
echo "qgate64smpblock: PASS (2 real CPUs, one immutable $(wc -c < "$T/block.bin")-byte NaN-emitted block, per-core CR3 state, shared guest memory)"
