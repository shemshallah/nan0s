#!/bin/sh
# tools/nansmp_gate.sh - x86_64 S1 multicore prototype gate.
#
# Builds src/tests/native64/s1_smp.c + smp_tramp.S + s1_smp_isr.S, assembles the
# NaN workload src/tests/nansmp_test.nas (which includes src/lib/nansmp.nas),
# boots QEMU with -smp 2 and -smp 4, and requires an exact COM1 transcript.
#
# What the transcript proves:
#   - ACPI MADT discovered exactly N CPUs and INIT-SIPI-SIPI brought every AP
#     online through the real-mode -> long-mode trampoline;
#   - each CPU ran its own LAPIC timer and EOI (ticks=1);
#   - a cross-CPU IPI (vector 0x41) caused a real reschedule on each AP
#     (resched=1: task B ran after the IPI) while task A was still runnable;
#   - every CPU executed the same NaN16 image: task A and task B counts come
#     from guest ST instructions, and the shared counter was advanced through
#     the nansmp.nas CAS spinlock + atomic fetch-add.
#
# No commits, no host services, no nan_cli oracle: the S1 machine runs the
# NaN words directly.  Set QEMU to override the binary.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C

QEMU_BIN=${QEMU:-qemu-system-x86_64}
command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  echo "nansmp: SKIP (no $QEMU_BIN)"; exit 0; }

TMPBASE=${NANSMP_TMP:-${TMPDIR:-/tmp}}
if ! mkdir -p "$TMPBASE" 2>/dev/null; then TMPBASE="$PWD/build"; mkdir -p "$TMPBASE"; fi
T="$TMPBASE/nansmp.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
TIMEOUT=${NANSMP_TIMEOUT:-90}

# ---------------------------------------------------------------- NaN image
awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels.txt" \
  src/tests/nansmp_test.nas > "$T/test.nan" 2> "$T/emit.err"
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || { echo "nansmp: FAIL (no word count)"; cat "$T/emit.err"; exit 1; }
# Guest data starts at word 0x8000; code must stay below it.
[ "$WORDS" -le 32768 ] || { echo "nansmp: FAIL (image $WORDS words overlaps guest data)"; exit 1; }

awk -f tools/nmk.awk -v CMD=check "$T/test.nan" 2> "$T/check.err"
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  echo "nansmp: FAIL (nmk check)"; cat "$T/check.err"; exit 1; }

# The NaN API surface nansched would call must be present in the image.
for sym in nsp_cpu nsp_steps nsp_ipi nsp_fence nsp_cas nsp_fetch_add \
           nsp_lock nsp_unlock nsp_trylock nsp_q_push nsp_q_pop nsp_q_len; do
  grep -q "^$sym " "$T/labels.txt" || {
    echo "nansmp: FAIL (missing nansmp symbol $sym)"; exit 1; }
done

awk '{
  line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
  n=split(line, a, "_")
  if (n==3 && length(a[1])==4 && length(a[2])==8 && length(a[3])==4) {
    printf "%s%s%s%s%s%s%s%s", \
      substr(a[3],3,2), substr(a[3],1,2), \
      substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
      substr(a[1],3,2), substr(a[1],1,2)
  }
}' "$T/test.nan" | xxd -r -p > "$T/test.bin"
[ "$(wc -c < "$T/test.bin")" -eq $((WORDS * 8)) ] || {
  echo "nansmp: FAIL (NaN image conversion)"; exit 1; }

# ------------------------------------------------------------- AP trampoline
clang --target=x86_64-none-elf -c src/native64/smp_tramp.S -o "$T/tramp.o"
ld.lld -m elf_x86_64 --image-base=0 -Ttext=0x8000 -e _start -o "$T/tramp.elf" "$T/tramp.o"
llvm-objcopy -O binary "$T/tramp.elf" "$T/tramp.bin"
TSZ=$(wc -c < "$T/tramp.bin")
[ "$TSZ" -gt 0 ] && [ "$TSZ" -le 4096 ] || {
  echo "nansmp: FAIL (trampoline size $TSZ)"; exit 1; }

# Embed the flat NaN image and the trampoline blob in the kernel image.
cat > "$T/blob.S" <<EOF
.section .rodata
.p2align 3
.global smp_nan_image
smp_nan_image:
.incbin "$T/test.bin"
.global smp_nan_image_end
smp_nan_image_end:
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
clang --target=x86_64-none-elf -std=gnu99 -O2 -Wall -Wextra \
  -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone \
  -mno-sse -mno-mmx -mno-avx \
  -c src/tests/native64/s1_smp.c -o "$T/smp.o"
clang --target=x86_64-none-elf -c "$T/blob.S" -o "$T/blob.o"
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$T/s1.elf" "$T/boot.o" "$T/smp.o" "$T/isr.o" "$T/blob.o"
llvm-objcopy -O binary "$T/s1.elf" "$T/s1.bin"
[ "$(wc -c < "$T/s1.bin")" -le 65536 ] || {
  echo "nansmp: FAIL (S1 SMP image > 64 KiB)"; exit 1; }
BSS_END=$(llvm-nm "$T/s1.elf" | awk '$3=="__bss_end"{print $1}')
[ -n "$BSS_END" ] || { echo "nansmp: FAIL (no __bss_end)"; exit 1; }
[ $((0x$BSS_END)) -le $((0x30000)) ] || {
  echo "nansmp: FAIL (BSS overlaps page tables)"; exit 1; }

# 512-byte boot fixture + 64 KiB kernel window.
clang --target=i386-none-elf -c src/native64/s1_bootsec.S -o "$T/bootsec.o"
ld.lld -m elf_i386 --image-base=0 -Ttext=0x7C00 -e _start \
  -o "$T/bootsec.elf" "$T/bootsec.o"
llvm-objcopy -O binary "$T/bootsec.elf" "$T/bootsec.bin"
[ "$(wc -c < "$T/bootsec.bin")" -eq 512 ] || {
  echo "nansmp: FAIL (bad boot fixture size)"; exit 1; }
cat "$T/bootsec.bin" "$T/s1.bin" > "$T/img"
truncate -s 1474560 "$T/img"

# --------------------------------------------------------------- transcript
expected() {
  n=$1
  echo "NAN0S SMP x86_64"
  echo "SMP BSP apic=0 cpus=$n"
  i=1
  while [ "$i" -lt "$n" ]; do
    echo "SMP AP cpu=$i apic=$i online timer=1"
    echo "SMP IPI cpu=0 -> cpu=$i vec=0x41"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    echo "SMP TIMER cpu=$i ticks=1"
    i=$((i + 1))
  done
  echo "SMP IPI cpu=0 -> cpu=0 vec=0x41"
  i=0
  while [ "$i" -lt "$n" ]; do
    echo "SMP WORK cpu=$i task=A count=5000"
    echo "SMP WORK cpu=$i task=B count=1000"
    echo "SMP RESCHED cpu=$i ipi=1 resched=1"
    echo "SMP ATOM cpu=$i total=6000 q=12/12"
    i=$((i + 1))
  done
  echo "SMP SHARED atomic=$((n * 6000)) locked=$((n * 100))"
  echo "SMP PASS cpus=$n atomic=$((n * 6000)) locked=$((n * 100))"
}

run_smp() {
  n=$1
  rm -f "$T/com$n"
  timeout "$TIMEOUT" "$QEMU_BIN" -m 256 -smp "$n" \
    -drive format=raw,if=floppy,file="$T/img" -boot a \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -display none -serial "file:$T/com$n" -no-reboot >/dev/null 2>&1 || true
  expected "$n" > "$T/expect$n"
  if ! diff -u "$T/expect$n" "$T/com$n" > "$T/diff$n" 2>&1; then
    echo "nansmp: FAIL (-smp $n COM1 transcript differs)"
    cat "$T/diff$n"
    echo "--- actual ---"; cat -v "$T/com$n"
    exit 1
  fi
  echo "nansmp: PASS (-smp $n: $n CPUs, NaN A/B, IPI reschedule, LAPIC timer, atoms, $WORDS-word image)"
}

run_smp 2
run_smp 4
echo "nansmp: RESULT PASS (x86_64 S1 2-CPU and 4-CPU prototype, exact transcripts)"
