#!/bin/sh
# nansmp_native_gate.sh - nansmp CAS/fetch-add/CPU-id on both native cores.
#
# The same deterministic guest runs on nan16_x86.nan (i386) and
# nan16_x64.nan (x86_64).  It prints "~0YYYY\nOK"; the x64 core's SPEL
# stage marker is stripped.  This proves the native control-port ABI used by
# nansmp/nansched_mp, not just the S1 prototype.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nansmp_native.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

CLI32=qemu-system-i386
CLI64=qemu-system-x86_64
command -v "$CLI32" >/dev/null 2>&1 || { echo "nansmp_native: SKIP (no i386 qemu)"; exit 0; }
command -v "$CLI64" >/dev/null 2>&1 || { echo "nansmp_native: SKIP (no x86_64 qemu)"; exit 0; }

awk -f tools/nmk.awk -v CMD=emit src/tests/nansmp_native_test.nas > "$T/test.nan" 2> "$T/e" ||
  { cat "$T/e" >&2; exit 1; }

build() { # gold out
  g=$1; out=$2
  LC_ALL=C gawk -f tools/mkimg.awk -v NOTOC=1 -v GOLD="$g" \
    -v GUEST="$T/test.nan" -v CARTS=/dev/null \
    -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" >/dev/null 2> "$T/mk.err" ||
    { cat "$T/mk.err" >&2; exit 1; }
  cat "$T/b.bin" "$T/g.bin" > "$out"
  sz=$(wc -c < "$out"); rem=$((sz % 512))
  [ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$out"
  sh tools/manifest_build.sh "$out" >/dev/null 2> "$T/man.err" ||
    { cat "$T/man.err" >&2; exit 1; }
}

run() { # qemu img com
  q=$1; img=$2; com=$3
  truncate -s 1474560 "$T/floppy.img"
  dd if="$img" of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none
  rm -f "$com"
  timeout 30 "$q" -m 512 \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$img" \
    -boot a -display none -serial file:"$com" -no-reboot >/dev/null 2>&1 || true
}

build src/native/nan16_x86.nan "$T/i386.img"
build src/native/nan16_x64.nan "$T/x64.img"
run "$CLI32" "$T/i386.img" "$T/i386.com"
run "$CLI64" "$T/x64.img" "$T/x64.com"
sed 's/^SPEL//' "$T/x64.com" > "$T/x64.got"
cp "$T/i386.com" "$T/i386.got"
printf '~0YYYY\nOK\n' > "$T/want"
cmp -s "$T/i386.got" "$T/want" ||
  { echo "nansmp_native: FAIL (i386)"; cat -v "$T/i386.got" >&2; exit 1; }
cmp -s "$T/x64.got" "$T/want" ||
  { echo "nansmp_native: FAIL (x64)"; cat -v "$T/x64.got" >&2; exit 1; }
cmp -s "$T/i386.got" "$T/x64.got" ||
  { echo "nansmp_native: FAIL (32/64 differ)"; exit 1; }
echo "nansmp_native: PASS (CAS, fetch-add, CPU id on both native cores)"
