#!/bin/sh
# native_product_smp_gate.sh - the shipped product boots on 1/2/4 native CPUs.
#
# The 32-bit core starts APs before entering the guest.  gui_sched_boot.nas
# reads the logical CPU count (0x4E0F) and AP bitmap (0x4E0E), initialises the
# F2 scheduler with the real nansmp ops, and runs one add/push/pop on CPU 0.
# It prints "SMP <ncpu> AP <bitmap-hex>" only when that binding succeeds;
# with one CPU the boot transcript is unchanged.  Every run must reach the
# NANIX shell with no trap marker.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/native_product_smp.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

[ -f build/nan0s.img ] || {
  echo "native_product_smp: FAIL (build/nan0s.img missing; run tools/build.sh)"; exit 1; }
command -v qemu-system-i386 >/dev/null 2>&1 || {
  echo "native_product_smp: SKIP (no i386 qemu)"; exit 0; }

run() { # ncpu out
  n=$1; com=$2
  cp build/nan0s.img "$T/ide.img"
  truncate -s 1474560 "$T/floppy.img"
  dd if=build/nan0s.img of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none
  rm -f "$com"
  timeout 30 qemu-system-i386 -m 512 -smp "$n" \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$T/ide.img" \
    -boot a -display none -serial "file:$com" -no-reboot \
    > "$T/out" 2> "$T/err" || true
}

check_common() { # label com
  label=$1; com=$2
  [ -s "$com" ] || {
    echo "native_product_smp: FAIL ($label, no COM1 output)"; exit 1; }
  grep -q 'NaN/0S' "$com" || {
    echo "native_product_smp: FAIL ($label, banner missing)"; cat -v "$com" >&2; exit 1; }
  grep -q 'NANIX SHELL READY' "$com" || {
    echo "native_product_smp: FAIL ($label, shell missing)"; cat -v "$com" >&2; exit 1; }
  [ "$(grep -c 'NANIX SHELL READY' "$com")" -eq 1 ] || {
    echo "native_product_smp: FAIL ($label, shell started more than once)"; cat -v "$com" >&2; exit 1; }
  if grep -q '!O\|!G' "$com"; then
    echo "native_product_smp: FAIL ($label, native trap)"; cat -v "$com" >&2; exit 1
  fi
}

run 1 "$T/com.1"
check_common "smp 1" "$T/com.1"
if grep -q '^SMP ' "$T/com.1"; then
  echo "native_product_smp: FAIL (smp 1 printed an SMP line)"; cat -v "$T/com.1" >&2; exit 1
fi

run 2 "$T/com.2"
check_common "smp 2" "$T/com.2"
grep -qx 'SMP 2 AP 2' "$T/com.2" || {
  echo "native_product_smp: FAIL (smp 2 line missing)"; cat -v "$T/com.2" >&2; exit 1; }

run 4 "$T/com.4"
check_common "smp 4" "$T/com.4"
grep -qx 'SMP 4 AP E' "$T/com.4" || {
  echo "native_product_smp: FAIL (smp 4 line missing)"; cat -v "$T/com.4" >&2; exit 1; }

echo "native_product_smp: PASS (product boots on 1/2/4 CPUs; nansched_nansmp binds on CPU 0)"
