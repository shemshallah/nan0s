#!/bin/sh
# tools/source_gold_gate.sh - F18 source-derived GOLD, no C oracle in the producer.
#
# Two source-derived paths are exercised:
#
#   1. raw n16i slice: nasm1 (NaN) runs under src/tools/n16i.nas (NaN) on the
#      native kan16 core booted from the checked-in GOLD on QEMU.  It assembles
#      x86/boot/kboot0.xa and the emitted 512 bytes are compared byte-for-byte
#      with the boot region of src/native/nan16_x86.nan.
#   2. full GOLD: tools/xgold.sh runs nasm1 on the native kan16 core (again
#      QEMU, no C/Python) and regenerates src/native/nan16_x86.nan.  The
#      checked-in GOLD must equal the source-derived rebuild.
#
# nan_cli is only an optional byte comparator for path 1.  It never produces
# the GOLD and the gate runs without it when it is absent.
#
# The stale 532-row xgold expectation is replaced by a derived row count:
# kernel rows = ceil(kernel bytes / 16).  At the F18 baseline this is 32 boot
# + 620 kernel rows for a 9913-byte kernel; the rule follows the source.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/source_gold.$$"
mkdir -p "$T"
STAGE_H="src/prog/_b11_f18_h.nas"
STAGE_O="src/prog/_b11_f18_outer.nas"
cleanup() {
  [ "${SOURCE_GOLD_KEEP:-0}" = 1 ] || rm -rf "$T"
  rm -f "$STAGE_H" "$STAGE_O"
}
trap cleanup EXIT INT TERM

fail() { echo "source_gold: FAIL: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }

# Driver: n16i lives at word 0; the whole nasm1 guest is relocated to INNER so
# nasm1's absolute SRC/OUT/LAB/STACK addresses keep their xgold.sh meaning.
make_n16i_outer() { # h_nan inner out
  {
    echo ".org 0"
    echo "JMP @drv"
    echo '.include "../tools/n16i.nas"'
    echo "drv:"
    echo "MOVI r13,1"
    echo "MOVI r1,0"
    echo "LA r2,$2"
    echo "LA r3,0x7FFFFF"
    echo "CALL @n16i_run"
    echo "MOVI r5,79"
    echo "PUTC r5"
    echo "MOVI r5,75"
    echo "PUTC r5"
    echo "MOVI r5,10"
    echo "PUTC r5"
    echo "HALT"
    echo ".org $2"
    awk 'NF && $0 !~ /^;/ {print ".raw " $1}' "$1"
  } > "$3"
}

# F16-aware raw image: boot, kernel+manifest and the guest are staged as one
# padded image; manifest_build.sh writes the 512-byte manifest at LBA 128; the
# boot floppy carries the verified window and the IDE disk starts the guest at
# LBA 129.  Older trees without the manifest tool still boot (the kernel
# ignores the unused window padding).
stage_n16i_image() { # boot guest tag
  cat "$1" "$2" > "$T/full_$3.img"
  fsz=$(wc -c < "$T/full_$3.img")
  frem=$((fsz % 512))
  [ "$frem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - frem)) >> "$T/full_$3.img" 2>/dev/null
  if [ -f tools/manifest_build.sh ]; then
    sh tools/manifest_build.sh "$T/full_$3.img" >/dev/null ||
      fail "tools/manifest_build.sh rejected the $3 image"
  fi
  cat "$T/full_$3.img" > "$T/floppy_$3.img"
  truncate -s 1474560 "$T/floppy_$3.img"
  dd if=/dev/zero of="$T/disk_$3.img" bs=512 count=129 status=none
  cat "$2" >> "$T/disk_$3.img"
  truncate -s 4194304 "$T/disk_$3.img"
}

command -v qemu-system-i386 >/dev/null 2>&1 ||
  fail "qemu-system-i386 is required (native bare-metal path)"
command -v xxd >/dev/null 2>&1 || fail "xxd is required"
[ -f src/native/nan16_x86.nan ] || fail "missing src/native/nan16_x86.nan"
[ -f src/native/kan16.xa ] || fail "missing src/native/kan16.xa"
[ -f src/prog/nasm.nas ] || fail "missing src/prog/nasm.nas"
[ -f src/tools/n16i.nas ] || fail "missing src/tools/n16i.nas"
GOLD=src/native/nan16_x86.nan

# ---- 1. producer provenance: no C/Python in the GOLD path -------------------
echo "== 1. producer provenance (no C oracle in the GOLD path) =="
if grep -nE '(^|[^A-Za-z0-9_])(nan_cli|python3?|clang|gcc|ld\.lld|llvm-objcopy)([^A-Za-z0-9_]|$)' \
     tools/xgold.sh tools/mkall.sh tools/mkimg.awk > "$T/prov" 2>/dev/null; then
  cat "$T/prov" >&2
  fail "C/toolchain token in a GOLD producer"
fi
echo "producer: tools/xgold.sh + tools/mkimg.awk + QEMU native kan16 only; nan_cli/compiler/Python absent"
# The 64-bit GOLD producer may call nan_cli only as the optional nc.ser
# comparator.  Join backslash continuations and reject any nan_cli --img
# command that writes the native producer stream.
if ! awk '
  { line = line $0
    if (substr($0, length($0), 1) == "\\") next
    if (line ~ /nan_cli/ && line ~ /--img/ && line !~ /nc\.ser/) bad = 1
    line = ""
  }
  END { exit bad ? 1 : 0 }
' tools/xgold64.sh; then
  fail "tools/xgold64.sh still invokes nan_cli as a GOLD producer"
fi
echo "xgold64 producer: native QEMU nasm1; nan_cli only writes the optional nc.ser comparator"

# ---- 2. full GOLD: source-derived rebuild with the native core --------------
echo "== 2. full GOLD regeneration (nasm x86 mode on native kan16, QEMU) =="
cp "$GOLD" "$T/gold.before"
cp x86/native/nan16_x86.nan "$T/gold.x86.before"
if [ "${SOURCE_GOLD_FAST:-0}" = 1 ]; then
  echo "SKIP tools/xgold.sh (SOURCE_GOLD_FAST=1): checked-in GOLD used as-is, not re-derived"
else
  if ! sh tools/xgold.sh > "$T/xgold.log" 2>&1; then
    cat "$T/xgold.log" >&2
    fail "tools/xgold.sh"
  fi
  tail -1 "$T/xgold.log"
  cmp -s "$T/gold.before" "$GOLD" || fail \
    "checked-in GOLD differed from the source-derived rebuild (file has been regenerated; rerun the gate to confirm the new bytes)"
  cmp -s "$GOLD" x86/native/nan16_x86.nan || fail \
    "x86/native/nan16_x86.nan is not the source-derived GOLD"
  echo "checked-in GOLD == native xgold.sh rebuild: $(sha "$GOLD")"
fi

# ---- 3. GOLD grid: boot 32 rows, kernel ceil(bytes/16), 620 at baseline ----
echo "== 3. GOLD grid and the stale row-count fix =="
hdr=$(head -1 "$GOLD")
kernel_bytes=$(printf '%s\n' "$hdr" | sed -n 's/.*kernel \([0-9][0-9]*\) bytes.*/\1/p')
[ -n "$kernel_bytes" ] || fail "cannot read kernel byte count from GOLD header: $hdr"
boot_rows=$(grep -c '; boot+' "$GOLD" || true)
kernel_rows=$(grep -c '; kernel+' "$GOLD" || true)
want_kernel_rows=$(( (kernel_bytes + 15) / 16 ))
[ "$boot_rows" -eq 32 ] || fail "boot grid has $boot_rows rows, expected 32"
[ "$kernel_rows" -eq "$want_kernel_rows" ] || fail \
  "kernel grid has $kernel_rows rows, derived count is $want_kernel_rows for $kernel_bytes bytes"
awk '/; (boot|kernel)\+/ {
  line=$0; sub(/;.*/, "", line); gsub(/[^0-9a-fA-F]/, "", line); printf "%s", line
}' "$GOLD" | xxd -r -p > "$T/gold.bin"
[ "$(wc -c < "$T/gold.bin")" -eq $((512 + kernel_bytes)) ] || fail \
  "GOLD grid does not contain 512 + $kernel_bytes bytes"
dd if="$T/gold.bin" of="$T/boot.gold" bs=1 count=512 2>/dev/null
echo "GOLD grid: 32 boot + $kernel_rows kernel rows ($kernel_bytes kernel bytes; old 532 expectation removed)"

# ---- 4. raw n16i slice: nasm1 assembles the boot sector ---------------------
echo "== 4. raw n16i slice: nasm assembles x86/boot/kboot0.xa under n16i =="
# xgold.sh stages the source next to nasm1 so .include "nasm1.nas" resolves.
awk -v SRC=x86/boot/kboot0.xa 'BEGIN {
  printf ".org 0\n.include \"nasm.nas\"\n.org 0x20000\n.str \""
  while ((getline line < SRC) > 0) {
    gsub(/\\/, "\\\\", line); gsub(/"/, "\\\"", line)
    printf "%s\\n", line
  }
  print "\""
}' > "$STAGE_H"
if ! awk -f tools/nmk.awk -v CMD=emit "$STAGE_H" > "$T/h.nan" 2>"$T/h.err"; then
  cat "$T/h.err" >&2
  fail "nmk could not emit the nasm1/n16i slice"
fi
h_words=$(sed -n 's/^words \([0-9][0-9]*\)$/\1/p' "$T/h.err")
[ -n "$h_words" ] || fail "cannot read inner guest word count"
echo "inner guest: nasm + kboot0.xa at 0x20000, $h_words words"

INNER=135168
make_n16i_outer "$T/h.nan" "$INNER" "$STAGE_O"
if ! awk -f tools/nmk.awk -v CMD=emit "$STAGE_O" > "$T/outer.nan" 2>"$T/outer.err"; then
  cat "$T/outer.err" >&2
  fail "nmk could not emit the n16i driver"
fi
outer_words=$(sed -n 's/^words \([0-9][0-9]*\)$/\1/p' "$T/outer.err")
[ "$outer_words" -eq $((INNER + h_words)) ] || fail \
  "n16i driver is $outer_words words, expected INNER($INNER) + inner($h_words)"
echo "n16i driver: $outer_words words; interpreted guest base word $INNER"

# Raw image: GOLD boot+kernel on the boot floppy, the n16i guest on IDE LBA 129.
: > "$T/carts.txt"
if ! LC_ALL=C awk -f tools/mkimg.awk -v GOLD="$GOLD" -v GUEST="$T/outer.nan" \
     -v CARTS="$T/carts.txt" -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" \
     >/dev/null 2>"$T/mk.err"; then
  cat "$T/mk.err" >&2
  fail "mkimg.awk could not stage the source-derived slice"
fi
[ "$(wc -c < "$T/boot.bin")" -eq 66048 ] || fail "boot+kernel window is not 66048 bytes"
stage_n16i_image "$T/boot.bin" "$T/guest.bin" slice

# Boot the native substrate and stop as soon as the expected 517 bytes exist.
rm -f "$T/qemu.ser"
qemu-system-i386 -m 64 \
  -drive format=raw,if=floppy,file="$T/floppy_slice.img" \
  -drive format=raw,if=ide,index=0,file="$T/disk_slice.img" \
  -boot a -display none -serial "file:$T/qemu.ser" -no-reboot \
  >/dev/null 2>"$T/qemu.err" &
qpid=$!
i=0
wait_s=${SOURCE_GOLD_QEMU_WAIT:-300}
while [ "$i" -lt "$wait_s" ]; do
  if [ -f "$T/qemu.ser" ] && [ "$(wc -c < "$T/qemu.ser")" -ge 517 ]; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
kill "$qpid" 2>/dev/null || true
wait "$qpid" 2>/dev/null || true
[ -s "$T/qemu.ser" ] || fail "no COM1 output from the native n16i slice"

[ "$(wc -c < "$T/qemu.ser")" -eq 517 ] || fail \
  "n16i slice emitted $(wc -c < "$T/qemu.ser") bytes, expected 517 (Y\\n + 512 GOLD bytes + OK\\n)"
dd if="$T/qemu.ser" of="$T/head2" bs=1 count=2 2>/dev/null
[ "$(xxd -p "$T/head2")" = "590a" ] || fail "n16i slice did not start with 'Y\\n'"
dd if="$T/qemu.ser" of="$T/slice.bin" bs=1 skip=2 count=512 2>/dev/null
dd if="$T/qemu.ser" of="$T/tail3" bs=1 skip=514 count=3 2>/dev/null
[ "$(xxd -p "$T/tail3")" = "4f4b0a" ] || fail "n16i driver did not reach the OK marker"
cmp -s "$T/slice.bin" "$T/boot.gold" || {
  echo "got  $(xxd -p "$T/slice.bin" | tr -d '\n' | cut -c1-64)..." >&2
  echo "want $(xxd -p "$T/boot.gold" | tr -d '\n' | cut -c1-64)..." >&2
  fail "n16i-assembled boot sector differs from the GOLD boot region"
}
echo "n16i slice: 512/512 boot GOLD bytes match; slice sha256 $(sha "$T/slice.bin"); marker OK"

# ---- 5. optional nan_cli comparator (never the producer) --------------------
echo "== 5. optional nan_cli comparator =="
if [ -x aarch64/android/nan_cli ] && [ "${SOURCE_GOLD_NO_ORACLE:-0}" != 1 ]; then
  if ! ./aarch64/android/nan_cli --img "$T/outer.nan" --mem 64 \
       --steps 4000000000 --serial > "$T/cli.ser" 2>"$T/cli.err"; then
    tail -3 "$T/cli.err" >&2
    fail "nan_cli comparator did not finish"
  fi
  cmp -s "$T/qemu.ser" "$T/cli.ser" || fail \
    "native n16i output differs from the nan_cli oracle byte stream"
  echo "nan_cli comparator: MATCH (517/517 bytes; oracle only, not a producer)"
else
  echo "nan_cli comparator: SKIP (absent or SOURCE_GOLD_NO_ORACLE=1)"
fi

# ---- 6. optional x86-64 GOLD (native xgold64.sh, no C producer) ------------
if [ "${SOURCE_GOLD_64:-0}" = 1 ]; then
  echo "== 6. x86-64 GOLD regeneration (nasm x86 mode on native kan16, QEMU) =="
  cp src/native/nan16_x64.nan "$T/x64.before"
  if ! sh tools/xgold64.sh > "$T/x64.log" 2>&1; then
    cat "$T/x64.log" >&2
    fail "tools/xgold64.sh"
  fi
  tail -1 "$T/x64.log"
  cmp -s "$T/x64.before" src/native/nan16_x64.nan || fail \
    "checked-in src/native/nan16_x64.nan differed from the native rebuild"
  echo "checked-in x86-64 GOLD == native xgold64.sh rebuild: $(sha src/native/nan16_x64.nan)"
fi

# ---- 7. optional full kernel under raw n16i (slow path) --------------------
if [ "${SOURCE_GOLD_FULL_N16I:-0}" = 1 ]; then
  echo "== 7. full GOLD kernel under raw n16i (slow path) =="
  awk -v SRC=src/native/kan16.xa 'BEGIN {
    printf ".org 0\n.include \"nasm.nas\"\n.org 0x20000\n.str \""
    while ((getline line < SRC) > 0) {
      gsub(/\\/, "\\\\", line); gsub(/"/, "\\\"", line)
      printf "%s\\n", line
    }
    print "\""
  }' > "$STAGE_H"
  if ! awk -f tools/nmk.awk -v CMD=emit "$STAGE_H" > "$T/hfull.nan" 2>"$T/hfull.err"; then
    cat "$T/hfull.err" >&2
    fail "nmk could not emit the full-kernel n16i guest"
  fi
  hf_words=$(sed -n 's/^words \([0-9][0-9]*\)$/\1/p' "$T/hfull.err")
  [ -n "$hf_words" ] || fail "cannot read full-kernel inner guest word count"
  HF_INNER=135168
  make_n16i_outer "$T/hfull.nan" "$HF_INNER" "$STAGE_O"
  if ! awk -f tools/nmk.awk -v CMD=emit "$STAGE_O" > "$T/outer_full.nan" 2>"$T/outer_full.err"; then
    cat "$T/outer_full.err" >&2
    fail "nmk could not emit the full-kernel n16i driver"
  fi
  of_words=$(sed -n 's/^words \([0-9][0-9]*\)$/\1/p' "$T/outer_full.err")
  [ "$of_words" -eq $((HF_INNER + hf_words)) ] || fail \
    "full n16i driver is $of_words words, expected $((HF_INNER + hf_words))"
  echo "full kernel inner guest $hf_words words; driver $of_words words"

  : > "$T/carts.txt"
  if ! LC_ALL=C awk -f tools/mkimg.awk -v GOLD="$GOLD" -v GUEST="$T/outer_full.nan" \
       -v CARTS="$T/carts.txt" -v OUTB="$T/boot_full.bin" -v OUTG="$T/guest_full.bin" \
       >/dev/null 2>"$T/mk_full.err"; then
    cat "$T/mk_full.err" >&2
    fail "mkimg.awk could not stage the full n16i guest"
  fi
  stage_n16i_image "$T/boot_full.bin" "$T/guest_full.bin" full
  rm -f "$T/qemu_full.ser"
  qemu-system-i386 -m 64 \
    -drive format=raw,if=floppy,file="$T/floppy_full.img" \
    -drive format=raw,if=ide,index=0,file="$T/disk_full.img" \
    -boot a -display none -serial "file:$T/qemu_full.ser" -no-reboot \
    >/dev/null 2>&1 &
  qfpid=$!
  fi=0
  full_wait=${SOURCE_GOLD_FULL_WAIT:-1500}
  want_full=$((2 + kernel_bytes + 3))
  while [ "$fi" -lt "$full_wait" ]; do
    if [ -f "$T/qemu_full.ser" ] && [ "$(wc -c < "$T/qemu_full.ser")" -ge "$want_full" ]; then
      break
    fi
    sleep 1
    fi=$((fi + 1))
  done
  kill "$qfpid" 2>/dev/null || true
  wait "$qfpid" 2>/dev/null || true
  [ "$(wc -c < "$T/qemu_full.ser")" -eq "$want_full" ] || fail \
    "full n16i kernel emitted $(wc -c < "$T/qemu_full.ser") bytes, expected $want_full"
  dd if="$T/qemu_full.ser" of="$T/full_head2" bs=1 count=2 2>/dev/null
  [ "$(xxd -p "$T/full_head2")" = "590a" ] || fail "full n16i kernel did not start with 'Y\\n'"
  dd if="$T/qemu_full.ser" of="$T/full_tail3" bs=1 skip=$((2 + kernel_bytes)) count=3 2>/dev/null
  [ "$(xxd -p "$T/full_tail3")" = "4f4b0a" ] || fail "full n16i driver did not reach the OK marker"
  dd if="$T/qemu_full.ser" of="$T/full_kernel.bin" bs=1 skip=2 count="$kernel_bytes" 2>/dev/null
  dd if="$T/gold.bin" of="$T/full_kernel.gold" bs=1 skip=512 count="$kernel_bytes" 2>/dev/null
  cmp -s "$T/full_kernel.bin" "$T/full_kernel.gold" || fail \
    "full-kernel n16i output differs from the GOLD kernel region"
  echo "full n16i kernel: $kernel_bytes/$kernel_bytes GOLD bytes match; sha256 $(sha "$T/full_kernel.bin")"
fi

if [ "${SOURCE_GOLD_FAST:-0}" = 1 ]; then
  echo "source_gold_gate: PASS (raw n16i assembles the 512-byte boot GOLD; checked-in GOLD grid 32+$kernel_rows; full xgold.sh skipped by SOURCE_GOLD_FAST=1)"
else
  echo "source_gold_gate: PASS (raw n16i assembles the 512-byte boot GOLD; native xgold.sh reproduces the checked-in 512+$kernel_bytes GOLD; rows 32+$kernel_rows)"
fi
echo "O"
