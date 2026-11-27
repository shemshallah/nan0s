#!/bin/sh
# tools/mkall.sh - builds THE unified image build/nan0s.img (boot + hw kernel + shell + every
# cartridge listed in tools/carts.txt). Outer stack: POSIX sh + gawk + xxd only. Overwrites; keeps no history.
# IMAGE RULE: build/ holds at most TWO images: nan0s.img (the system) and base.img (scaffold
# input for nasm0 proofs). All test/mutant images go to $TMPDIR and are deleted.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
export TMPDIR="${TMPDIR:-/tmp}"
# Hermetic gates may redirect the output image and the generated guest without
# touching the tracked build/nan0s.img.  Defaults are the published product.
IMG=${NAN0S_IMG:-build/nan0s.img}
GUEST=${NAN0S_GUEST:-src/nan/nixsched.nan}
T="$TMPDIR/nan0s_build.$$"
rm -rf "$T"; mkdir -p "$T"
mkdir -p "$(dirname "$IMG")"
gawk -f tools/mkimg.awk -v NOTOC=1 \
     -v GOLD=src/native/nan16_x86.nan \
     -v GUEST="$GUEST" \
     -v CARTS=/dev/null \
     -v OUTB="$T/n0sb.bin" -v OUTG="$T/n0sg.bin"
cat "$T/n0sb.bin" "$T/n0sg.bin" > "$IMG"
# Full raw IDE image: boot 512 + kernel 64 KiB + guest words.  Pad to a
# 512-byte sector boundary; do not truncate to a 1.44 MiB floppy.
sz=$(wc -c < "$IMG")
rem=$((sz % 512))
[ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$IMG"
ls build/*.img | wc -l | sed 's/^/images in build\/: /'
