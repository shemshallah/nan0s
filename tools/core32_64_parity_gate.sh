#!/bin/sh
# core32_64_parity_gate.sh - same guest, native 32-bit and 64-bit host cores.
#
# 1. A deterministic guest (core_parity_test.nas) prints "~ABC\nOK".
# 2. The full product guest prints "NaN/0S BOOT" + "NANIX SHELL READY".
# Both images use the checked-in native cores (nan16_x86.nan / nan16_x64.nan)
# and the same guest; the x64 host core's "SPEL" stage marker is stripped.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/core_parity.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

CLI32=qemu-system-i386
CLI64=qemu-system-x86_64
command -v "$CLI32" >/dev/null 2>&1 || { echo "core_parity: SKIP (no i386 qemu)"; exit 0; }
command -v "$CLI64" >/dev/null 2>&1 || { echo "core_parity: SKIP (no x86_64 qemu)"; exit 0; }

build_image() { # gold guest out
  b_gold=$1; b_guest=$2; b_out=$3
  LC_ALL=C gawk -f tools/mkimg.awk -v NOTOC=1 -v GOLD="$b_gold" \
    -v GUEST="$b_guest" -v CARTS=/dev/null \
    -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" >/dev/null 2> "$T/mkimg.err" ||
    { cat "$T/mkimg.err" >&2; exit 1; }
  cat "$T/boot.bin" "$T/guest.bin" > "$b_out"
  sz=$(wc -c < "$b_out"); rem=$((sz % 512))
  [ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$b_out" 2>/dev/null
  sh tools/manifest_build.sh "$b_out" >/dev/null 2> "$T/man.err" ||
    { cat "$T/man.err" >&2; exit 1; }
}

run_core() { # qemu image serial
  r_qemu=$1; r_img=$2; r_ser=$3
  rm -f "$r_ser" "$T/floppy.img"
  truncate -s 1474560 "$T/floppy.img"
  dd if="$r_img" of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none
  timeout 30 "$r_qemu" -m 512 \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$r_img" \
    -boot a -display none -serial file:"$r_ser" -no-reboot \
    >/dev/null 2> "$T/q.err" || true
}

penny=0
for guest in core_parity_test nixsched; do
  case "$guest" in
    core_parity_test)
      awk -f tools/nmk.awk -v CMD=emit src/tests/core_parity_test.nas > "$T/test.nan" 2> "$T/emit.err" ||
        { cat "$T/emit.err" >&2; exit 1; }
      g="$T/test.nan" ;;
    nixsched)
      g=src/nan/nixsched.nan
      [ -f "$g" ] || { echo "core_parity: FAIL (missing $g; run tools/build.sh)"; exit 1; } ;;
  esac
  build_image src/native/nan16_x86.nan "$g" "$T/i386.img"
  build_image src/native/nan16_x64.nan "$g" "$T/x64.img"
  run_core "$CLI32" "$T/i386.img" "$T/i386.ser"
  run_core "$CLI64" "$T/x64.img" "$T/x64.ser"
  sed 's/^SPEL//' "$T/x64.ser" > "$T/x64.guest"
  cp "$T/i386.ser" "$T/i386.guest"
  if [ "$guest" = core_parity_test ]; then
    grep -aq '~ABC' "$T/i386.guest" || {
      echo "core_parity: FAIL (32-bit guest output missing ~ABC)"; cat -v "$T/i386.guest" >&2; exit 1; }
    grep -aq '~ABC' "$T/x64.guest" || {
      echo "core_parity: FAIL (64-bit guest output missing ~ABC)"; cat -v "$T/x64.guest" >&2; exit 1; }
    cmp -s "$T/i386.guest" "$T/x64.guest" ||
      { echo "core_parity: FAIL (32/64 guest output differs)"; diff -u "$T/i386.guest" "$T/x64.guest" | head -20 >&2; exit 1; }
    echo "core_parity: PASS ISA guest (32-bit/64-bit output identical)"
  else
    grep -aq 'NANIX SHELL READY' "$T/i386.guest" ||
      { echo "core_parity: FAIL (32-bit product missing shell banner)"; cat -v "$T/i386.guest" >&2; exit 1; }
    grep -aq 'NANIX SHELL READY' "$T/x64.guest" ||
      { echo "core_parity: FAIL (64-bit product missing shell banner)"; cat -v "$T/x64.guest" >&2; exit 1; }
    grep -aq 'NaN/0S BOOT' "$T/i386.guest" && grep -aq 'NaN/0S BOOT' "$T/x64.guest" ||
      { echo "core_parity: FAIL (product banner differs)"; exit 1; }
    echo "core_parity: PASS product guest (both cores reach NANIX SHELL READY)"
  fi
done
echo "core_parity: PASS (native 32-bit and 64-bit cores, same guest)"
