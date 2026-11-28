#!/bin/sh
# native_nhost_gate.sh - nhost runs on the raw native NaN16 core.
#
# No nan_cli and no S1 KABI: the image is the same raw boot sector + GOLD
# kernel as the product, with nhost as the guest.  The source bundle sits at
# LBA 2048 on the same IDE disk; nhost first probes LBA 0 and falls back to
# the high bundle LBA when it sees boot sectors instead of ;@MAIN.
#
# Phase 1 (always): nhost assembles itself (4,530 words, ~16 s).
# Phase 2 (NHOST_NATIVE_FULL=1): nhost emits the full 530,842-word product
# guest (~30 min on the 32-bit interpreter).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/native_nhost_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

QEMU=${QEMU:-qemu-system-i386}
command -v "$QEMU" >/dev/null 2>&1 || {
  echo "native_nhost_gate: SKIP (qemu-system-i386 absent)"; exit 0; }

words() {
  grep -aE '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' "$1" |
    sed 's/[[:space:]].*//'
}

# make_bundle MAIN OUT: flat ;@MAIN/;@FILE disk image, NUL padded.
make_bundle() {
  awk -f tools/nhost_bundle.awk -v MAIN="$1" > "$2"
  sz=$(wc -c < "$2"); rem=$((sz % 512))
  [ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$2" 2>/dev/null
}

# build_native_image BUNDLE OUT: product-style image with nhost as guest and
# BUNDLE appended at LBA 2048.
build_native_image() {
  b_bundle=$1; b_out=$2
  NAN0S_IMG="$b_out" NAN0S_GUEST="$T/nhost.nan" TMPDIR="$T/mk.$$" \
    sh tools/mkall.sh > "$T/mk.out" 2> "$T/mk.err" ||
    { echo "native_nhost_gate: FAIL (mkall)" >&2; cat "$T/mk.err" >&2; exit 1; }
  truncate -s $((2048 * 512)) "$b_out"
  cat "$b_bundle" >> "$b_out"
  truncate -s 1474560 "$T/floppy.img"
  dd if="$b_out" of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none
}

# run_native BUNDLE TIMEOUT OUT: boot the native core, stop after ;END.
run_native() {
  bundle=$1; limit=$2; out=$3
  build_native_image "$bundle" "$T/native.img"
  rm -f "$out"
  "$QEMU" -m 512 \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$T/native.img" \
    -boot a -display none -serial file:"$out" -no-reboot \
    >/dev/null 2> "$T/q.err" &
  qp=$!
  start=$(date +%s)
  found=0
  while kill -0 "$qp" 2>/dev/null; do
    if grep -aq ';END' "$out" 2>/dev/null; then found=1; break; fi
    now=$(date +%s)
    [ $((now - start)) -lt "$limit" ] || break
    sleep 1
  done
  end=$(date +%s)
  kill "$qp" 2>/dev/null || true
  wait "$qp" 2>/dev/null || true
  [ "$found" -eq 1 ] ||
    { echo "native_nhost_gate: FAIL (no ;END after $((end - start))s)" >&2; tail -3 "$out" >&2; exit 1; }
  grep -q '^;END .* err=00000000' "$out" ||
    { echo "native_nhost_gate: FAIL (nhost errors)" >&2; tail -3 "$out" >&2; exit 1; }
  echo "native_nhost_gate: native run $((end - start))s" >&2
}

awk -f tools/nmk.awk -v CMD=emit src/prog/nhost.nas > "$T/nhost.nan" 2> "$T/emit.err" ||
  { cat "$T/emit.err" >&2; exit 1; }

# Phase 1: self-host fixed point.
make_bundle src/prog/nhost.nas "$T/self.bundle"
run_native "$T/self.bundle" 120 "$T/self.com"
words "$T/self.com" > "$T/self.words"
words "$T/nhost.nan" > "$T/self.nmk.words"
cmp -s "$T/self.words" "$T/self.nmk.words" ||
  { echo "native_nhost_gate: FAIL (self-host differs)" >&2;
    diff -u "$T/self.nmk.words" "$T/self.words" | head -12 >&2; exit 1; }
n=$(wc -l < "$T/self.words")
[ "$n" -eq 4530 ] ||
  { echo "native_nhost_gate: FAIL (self-host is $n words, want 4530)" >&2; exit 1; }
echo "native_nhost_gate: PASS phase 1 ($n words; native core self-host)"

if [ "${NHOST_NATIVE_FULL:-0}" = 1 ]; then
  make_bundle src/gui/gui_sched_boot.nas "$T/guest.bundle"
  run_native "$T/guest.bundle" 3600 "$T/guest.com"
  words "$T/guest.com" > "$T/guest.words"
  awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas > "$T/nmk.nan" 2> "$T/nmk.err" ||
    { cat "$T/nmk.err" >&2; exit 1; }
  words "$T/nmk.nan" > "$T/nmk.words"
  cmp -s "$T/guest.words" "$T/nmk.words" ||
    { echo "native_nhost_gate: FAIL (full guest differs)" >&2;
      diff -u "$T/nmk.words" "$T/guest.words" | head -12 >&2; exit 1; }
  n=$(wc -l < "$T/guest.words")
  [ "$n" -eq 530842 ] ||
    { echo "native_nhost_gate: FAIL (guest is $n words, want 530842)" >&2; exit 1; }
  echo "native_nhost_gate: PASS phase 2 ($n words; native core full guest)"
else
  echo "native_nhost_gate: SKIP phase 2 (set NHOST_NATIVE_FULL=1 for the 530,842-word run)"
fi
echo "native_nhost_gate: PASS"
