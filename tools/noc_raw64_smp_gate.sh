#!/bin/sh
# tools/noc_raw64_smp_gate.sh - F17 raw 64-bit 4-core AP timer/IPI/TSS/IST gate.
#
# Builds the raw64 product path with no C object in the link:
#   src/native64/s1_boot.S + src/native64/raw64_smp_body.S
#   + src/native64/smp_tramp.S + the NaN-emitted immutable block.
#
# The same image is booted with -smp 4 and -smp 2.  Each core must:
#   - come up through the MADT/INIT-SIPI-SIPI trampoline under its own CR3;
#   - run the one immutable NaN-emitted block (r1/slot/done exact);
#   - install a per-AP GDT/TSS with IST1/IST2 stacks and a shared IDT;
#   - take exactly one AP-local one-shot LAPIC timer interrupt;
#   - take exactly one reschedule IPI and publish the resched counter;
#   - issue exactly one EOI per timer/IPI (eoi=2), with no lost interrupts.
#
# The gate also audits the link inputs for C objects and runs
# tools/no_c_outside_tests.sh.  The C nan_cli translator is a build-time
# oracle only; its emitted bytes are linked, the executable is not.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/noc_raw64_smp_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

fail() { echo "noc_raw64_smp_gate: FAIL: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 missing"
command -v clang >/dev/null 2>&1 || fail "clang missing"
command -v ld.lld >/dev/null 2>&1 || fail "ld.lld missing"
command -v llvm-objcopy >/dev/null 2>&1 || fail "llvm-objcopy missing"
[ -x ./aarch64/android/nan_cli ] || fail "nan_cli translator oracle missing"

R="$T/raw64"
mkdir -p "$R"

# ------------------------------------------------------- NaN block emission
awk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_smpblock.nas \
  > "$R/t.nan" 2> "$R/emit.err" || { cat "$R/emit.err" >&2; fail "raw64 nmk"; }
timeout 60 ./aarch64/android/nan_cli --img "$R/t.nan" --mem 32 --steps 200000 \
  --serial --dump-bytes "0x20000:4096:$R/raw.bin" >/dev/null 2> "$R/nc.err" || true
[ -s "$R/raw.bin" ] || { cat "$R/nc.err" >&2; fail "translator oracle produced no bytes"; }
python3 - "$R/raw.bin" "$R/block.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
k = d.rfind(b'\xc3')
assert k > 0, 'no RET at the end of the emitted block'
b = d[:k + 1]
assert b.startswith(bytes.fromhex('8b0425040005000501000000')), ('bad ADDI prefix', b[:16].hex())
assert bytes.fromhex('8b042508000500') in b, 'no load of per-core r2'
assert bytes.fromhex('8b04250c000500') in b, 'no load of per-core r3'
assert bytes.fromhex('c70425000c050001000000c3') in b, 'no HALT tail'
assert len(b) <= 4096, ('block too large', len(b))
open(sys.argv[2], 'wb').write(b)
print('raw64 block %d bytes' % len(b))
PY

# ------------------------------------------------------------ trampoline
clang --target=x86_64-none-elf -c src/native64/smp_tramp.S -o "$R/tramp.o"
ld.lld -m elf_x86_64 --image-base=0 -Ttext=0x8000 -e _start \
  -o "$R/tramp.elf" "$R/tramp.o"
llvm-objcopy -O binary "$R/tramp.elf" "$R/tramp.bin"
TSZ=$(wc -c < "$R/tramp.bin")
[ "$TSZ" -gt 0 ] && [ "$TSZ" -le 4096 ] || fail "trampoline size $TSZ"

cat > "$R/blob.S" <<EOF
.section .rodata
.globl block0
block0:
.incbin "$R/block.bin"
.globl block0_end
block0_end:
.globl tramp_blob
tramp_blob:
.incbin "$R/tramp.bin"
.globl tramp_blob_end
tramp_blob_end:
.text
EOF

# ---------------------------------------------------------------- raw link
clang --target=x86_64-none-elf -c src/native64/s1_boot.S -o "$R/boot.o"
clang --target=x86_64-none-elf -c src/native64/raw64_smp_body.S -o "$R/raw.o"
clang --target=x86_64-none-elf -c "$R/blob.S" -o "$R/blob.o"

# Audit the link line: assembly objects plus the generated NaN block only.
LINK_INPUTS="$R/boot.o $R/raw.o $R/blob.o"
for o in $LINK_INPUTS; do
  case "$o" in
    *.c|*.cc|*.cpp|*.o.c) fail "C object in raw64 link: $o" ;;
  esac
done
case "$LINK_INPUTS" in *.c*|*.cc*|*.cpp*) fail "C object in raw64 link" ;; esac
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$R/raw.elf" $LINK_INPUTS
llvm-objcopy -O binary "$R/raw.elf" "$R/raw.bin"
[ "$(wc -c < "$R/raw.bin")" -le 65536 ] || fail "raw64 kernel > 64 KiB"
BSS_END=$(llvm-nm "$R/raw.elf" | awk '$3=="__bss_end"{print $1}')
[ -n "$BSS_END" ] || fail "raw64 __bss_end missing"
[ $((0x$BSS_END)) -le $((0x30000)) ] || fail "raw64 BSS overlaps page tables"
UND=$(llvm-nm -u "$R/raw.elf" | wc -l)
[ "$UND" -eq 0 ] || { llvm-nm -u "$R/raw.elf" >&2; fail "raw64 ELF has undefined symbols"; }
echo "raw64 link: s1_boot.S + raw64_smp_body.S + smp_tramp.S + NaN block; no C object, no undefined symbols"
echo "raw64 block sha256 $(sha "$R/block.bin"); kernel sha256 $(sha "$R/raw.bin")"

# ---------------------------------------------------------- boot fixture
clang --target=i386-none-elf -c src/native64/s1_bootsec.S -o "$R/bootsec.o"
ld.lld -m elf_i386 --image-base=0 -Ttext=0x7C00 -e _start \
  -o "$R/bootsec.elf" "$R/bootsec.o"
llvm-objcopy -O binary "$R/bootsec.elf" "$R/bootsec.bin"
[ "$(wc -c < "$R/bootsec.bin")" -eq 512 ] || fail "bad boot fixture size"
cat "$R/bootsec.bin" "$R/raw.bin" > "$R/img"
truncate -s 1474560 "$R/img"

# --------------------------------------------------------------- transcript
expected() {
  n=$1
  echo "NAN64 RAW SMP x86_64"
  echo "RAW64 cpus=$n"
  i=0
  while [ "$i" -lt "$n" ]; do
    case "$i" in
      0) v=00000011 ;;
      1) v=00000021 ;;
      2) v=00000031 ;;
      3) v=00000041 ;;
      *) fail "no expected value for core $i" ;;
    esac
    echo "RAW64 core$i r1=$v slot=$v done=$v timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1"
    i=$((i + 1))
  done
  echo "RAW64 PASS"
}

run_smp() {
  n=$1
  rm -f "$R/com$n"
  timeout 60 qemu-system-x86_64 -m 256 -smp "$n" \
    -drive format=raw,if=floppy,file="$R/img" -boot a \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -display none -serial "file:$R/com$n" -no-reboot >/dev/null 2>&1 || true
  [ -s "$R/com$n" ] || fail "-smp $n produced no COM1 output"
  expected "$n" > "$R/expect$n"
  if ! diff -u "$R/expect$n" "$R/com$n" > "$R/diff$n" 2>&1; then
    echo "noc_raw64_smp_gate: FAIL (-smp $n COM1 transcript differs)"
    cat "$R/diff$n"
    echo "--- actual ---"; cat -v "$R/com$n"
    exit 1
  fi
  echo "noc_raw64_smp_gate: -smp $n transcript:"
  cat "$R/com$n"
}

run_smp 4
run_smp 2

# ------------------------------------------- exception/IST reporting self-test
# Build the same raw body with a gate-only faulting load.  The BSP installs
# IDT+GDT/TSS+IST first, then reads the unmapped VA 1 GiB; the handler must
# report vector 14, the RIP, the error code and CR2=0x40000000 and halt.
clang --target=x86_64-none-elf -DRAW64_FAULT_TEST \
  -c src/native64/raw64_smp_body.S -o "$R/raw_exc.o"
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$R/raw_exc.elf" "$R/boot.o" "$R/raw_exc.o" "$R/blob.o"
llvm-objcopy -O binary "$R/raw_exc.elf" "$R/raw_exc.bin"
cat "$R/bootsec.bin" "$R/raw_exc.bin" > "$R/img_exc"
truncate -s 1474560 "$R/img_exc"
rm -f "$R/exc.com"
timeout 15 qemu-system-x86_64 -m 256 -smp 2 \
  -drive format=raw,if=floppy,file="$R/img_exc" -boot a \
  -display none -serial "file:$R/exc.com" -no-reboot >/dev/null 2>&1 || true
[ -s "$R/exc.com" ] || fail "exception self-test produced no COM1 output"
grep -q 'RAW64 EXC vec=0000000e' "$R/exc.com" || {
  echo "exception COM1:"; cat -v "$R/exc.com" >&2
  fail "exception self-test did not report vector 14"
}
grep -q 'err=00000000' "$R/exc.com" || fail "exception self-test error code"
grep -q 'cr2=0000000040000000' "$R/exc.com" || {
  echo "exception COM1:"; cat -v "$R/exc.com" >&2
  fail "exception self-test CR2"
}
if grep -q 'RAW64 PASS' "$R/exc.com"; then
  fail "exception self-test did not halt"
fi
echo "noc_raw64_smp_gate: exception/IST1 self-test:"
cat "$R/exc.com"

# --------------------------------------------------------------- C audit
if ! c_out=$(sh tools/no_c_outside_tests.sh 2>&1); then
  printf '%s\n' "$c_out" >&2
  fail "no_c_outside_tests"
fi
printf '%s\n' "$c_out"

echo "noc_raw64_smp_gate: PASS (4/2 real CPUs, per-AP GDT/TSS/IST, shared IDT, one-shot LAPIC timer, reschedule IPI, exact EOI, immutable NaN block, no C linked)"
echo "O"
