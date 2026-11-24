#!/bin/sh
# tools/s1_guest_gate.sh - x86_64 S1 flat-cartridge acceptance (this slice).
#
# Assembles a NaN16 program with tools/nmk.awk, converts its .nan words to
# the flat little-endian 8-byte guest word image, links it into the
# freestanding S1 (src/native64/s1_kabi.c -DS1_GUEST), boots with the
# self-contained boot fixture and compares COM1 byte-for-byte with the C
# core oracle.  Machine status goes to QEMU's debug console (0xE9), not COM1.
# This is guest-cartridge acceptance for the implemented op subset, not full
# op/device parity and not a filesystem loader.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
QEMU_BIN="${QEMU:-qemu-system-x86_64}"
command -v "$QEMU_BIN" >/dev/null 2>&1 || { echo "s1_guest: SKIP (no $QEMU_BIN)"; exit 0; }
: "${S1_GUEST_MEM:=0x10000}"
: "${S1_GUEST_STEPS:=20000000}"
: "${QEMU_MEM:=128}"
STACK_DEF=""
[ -n "${S1_GUEST_STACK:-}" ] && STACK_DEF="-DS1_GUEST_STACK=$S1_GUEST_STACK"
T="${TMPDIR:-/tmp}/s1_guest.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli

# .nan -> flat 8-byte guest words (far BE head, payload LE, near LE head).
nan_to_bin() {
  awk '{
    line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
    n=split(line, a, "_")
    if (n==3 && length(a[1])==4 && length(a[2])==8 && length(a[3])==4) {
      printf "%s%s%s%s%s%s%s%s", \
        substr(a[3],3,2), substr(a[3],1,2), \
        substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
        substr(a[1],3,2), substr(a[1],1,2)
    }
  }' "$1" | xxd -r -p > "$2"
}

clang --target=i386-none-elf -c src/native64/s1_bootsec.S -o "$T/bootsec.o"
ld.lld -m elf_i386 --image-base=0 -Ttext=0x7C00 -e _start -o "$T/bootsec.elf" "$T/bootsec.o"
llvm-objcopy -O binary "$T/bootsec.elf" "$T/bootsec.bin"
[ "$(wc -c < "$T/bootsec.bin")" -eq 512 ]

run_guest() {
  name=$1; src=$2
  awk -f tools/nmk.awk -v CMD=emit "$src" > "$T/$name.nan" 2>"$T/$name.asm"
  nan_to_bin "$T/$name.nan" "$T/$name.bin"
  bytes=$(wc -c < "$T/$name.bin")
  [ "$bytes" -gt 0 ] || { echo "s1_guest: FAIL ($name: empty cartridge)"; exit 1; }
  [ $((bytes % 8)) -eq 0 ] || { echo "s1_guest: FAIL ($name: not word aligned)"; exit 1; }
  words=$((bytes / 8))
  cat > "$T/$name.S" <<EOF
.section .rodata
.global s1_guest_bin
s1_guest_bin:
.incbin "$T/$name.bin"
.global s1_guest_bin_end
s1_guest_bin_end:
.text
EOF
  clang --target=x86_64-none-elf -c "$T/$name.S" -o "$T/$name.guest.o"
  clang --target=x86_64-none-elf -std=gnu99 -O2 -Wall -Wextra \
    -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone \
    -DS1_GUEST -DS1_GUEST_MEM="$S1_GUEST_MEM" -DS1_GUEST_STEPS="$S1_GUEST_STEPS" \
    $STACK_DEF -c src/native64/s1_kabi.c -o "$T/$name.s1.o"
  clang --target=x86_64-none-elf -c src/native64/s1_boot.S -o "$T/$name.boot.o"
  ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
    -o "$T/$name.elf" "$T/$name.boot.o" "$T/$name.s1.o" "$T/$name.guest.o"
  llvm-objcopy -O binary "$T/$name.elf" "$T/$name.img.bin"
  [ "$(wc -c < "$T/$name.img.bin")" -le 65536 ] || {
    echo "s1_guest: FAIL ($name: image > 64 KiB)"; exit 1; }
  cat "$T/bootsec.bin" "$T/$name.img.bin" > "$T/$name.img"
  truncate -s 1474560 "$T/$name.img"

  ./aarch64/android/nan_cli --img "$T/$name.nan" --steps "$S1_GUEST_STEPS" \
    --serial > "$T/$name.oracle" 2>/dev/null
  rm -f "$T/$name.com" "$T/$name.dbg"
  timeout 30 "$QEMU_BIN" -m "$QEMU_MEM" \
    -drive format=raw,if=floppy,file="$T/$name.img" \
    -display none -serial "file:$T/$name.com" \
    -debugcon "file:$T/$name.dbg" -no-reboot >/dev/null 2>&1 || true
  if ! cmp -s "$T/$name.oracle" "$T/$name.com"; then
    echo "s1_guest: FAIL ($name: COM1 differs from C oracle)"
    echo "--- oracle ---"; cat -v "$T/$name.oracle"; echo
    echo "--- x86_64 S1 ---"; cat -v "$T/$name.com"; echo
    echo "--- debugcon ---"; cat -v "$T/$name.dbg"; echo
    exit 1
  fi
  grep -q "S1GUEST LOAD $words WORDS" "$T/$name.dbg" || {
    echo "s1_guest: FAIL ($name: loader count mismatch)"; cat -v "$T/$name.dbg"; exit 1; }
  grep -q 'S1GUEST HALT rc=3' "$T/$name.dbg" || {
    echo "s1_guest: FAIL ($name: HALT status)"; cat -v "$T/$name.dbg"; exit 1; }
  echo "s1_guest: PASS $name ($words words, $bytes bytes, image $(wc -c < "$T/$name.img.bin") bytes)"
}

run_guest focused src/tests/s1_guest_test.nas
run_guest nfs2 src/tests/nfs2_test.nas
echo "s1_guest: PASS (flat cartridges execute on x86_64 S1; COM1 == C oracle)"
