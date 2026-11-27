#!/bin/sh
# mkn16iimg.sh - pack the n16i runtime after the scheduler on the 64-bit disk.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-$PWD/tmp}/mkn16i.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
[ -f src/native/nan16_x64.nan ] || { echo "mkn16i: missing nan16_x64.nan (run tools/xgold64.sh)" >&2; exit 1; }
GUEST="${GUEST:-src/nan/nixsched.nan}"
[ "$GUEST" = "src/nan/nixsched.nan" ] && awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas > src/nan/nixsched.nan
awk -f tools/nmk.awk -v CMD=emit src/nan/n16i_runtime.nas > src/nan/n16i_runtime.nan
gawk -f tools/mkimg.awk -v NOTOC=1 -v GOLD=src/native/nan16_x64.nan \
  -v GUEST="$GUEST" -v CARTS=/dev/null \
  -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" 2>"$T/mk.err"
awk '{
  line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
  n=split(line, a, "_")
  if (n==3) printf "%s%s%s%s%s%s%s%s", \
    substr(a[3],3,2), substr(a[3],1,2), \
    substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
    substr(a[1],3,2), substr(a[1],1,2)
}' src/nan/n16i_runtime.nan | xxd -r -p > "$T/n16i.bin"
[ "$(wc -c < "$T/n16i.bin")" -le 32768 ] || { echo "mkn16i: n16i runtime > 32 KiB" >&2; exit 1; }
truncate -s 32768 "$T/n16i.bin"
cat "$T/boot.bin" "$T/guest.bin" > "$T/img"
sz=$(wc -c < "$T/img"); rem=$((sz % 512))
[ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512-rem)) >> "$T/img" 2>/dev/null
cat "$T/n16i.bin" >> "$T/img"
cp "$T/img" build/nan0s_n16i.img
echo "image: n16i $(wc -c < build/nan0s_n16i.img) bytes; system $(wc -l < "$GUEST") words; n16i $(wc -l < src/nan/n16i_runtime.nan) words"
