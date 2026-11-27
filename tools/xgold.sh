#!/bin/sh
# tools/xgold.sh - rebuild the native x86 gold stream with the native S1 core.
#
# No C and no Python: gawk stages the source, the prebuilt native S1 runs the
# NaN assembler (nasm1), QEMU captures its serial bytes, and awk emits the gold
# text.  The S1 core is the only native layer; every instruction above it is
# NaN16.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/xgold_native.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

command -v qemu-system-i386 >/dev/null 2>&1 || {
  echo "xgold: qemu-system-i386 is required" >&2; exit 1;
}
[ -f src/native/nan16_x86.nan ] || { echo "xgold: missing native gold core" >&2; exit 1; }

asm_one() { # src out.bin
  src="$1"; out="$2"
  awk -v SRC="$src" 'BEGIN {
    printf ".org 0\n.include \"nasm1.nas\"\n.org 0x20000\n.str \""
    while ((getline line < SRC) > 0) {
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      printf "%s\\n", line
    }
    print "\""
  }' > src/prog/_xgold_h.nas
  awk -f tools/nmk.awk -v CMD=emit src/prog/_xgold_h.nas > "$T/h.nan"
  rm -f src/prog/_xgold_h.nas

  # Full guest bytes, not the 512 KiB floppy limit.
  awk '{
    line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
    n=split(line, a, "_")
    if (n==3 && length(a[1])==4 && length(a[2])==8 && length(a[3])==4)
      printf "%s%s%s%s%s%s%s%s", \
        substr(a[3],3,2), substr(a[3],1,2), \
        substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
        substr(a[1],3,2), substr(a[1],1,2)
  }' "$T/h.nan" | xxd -r -p > "$T/guest.bin"
  [ -s "$T/guest.bin" ] || { echo "xgold: empty guest for $src" >&2; exit 1; }

  # Boot floppy = current gold boot+kernel+manifest.  The ATA loader reads
  # the full guest from IDE LBA 129, so the 512 KiB floppy limit does not
  # apply.  F16: the kernel verifies the manifest before fetching the guest,
  # so stage a full boot+kernel+guest image, write the manifest, then split.
  : > "$T/carts.txt"
  awk -f tools/mkimg.awk -v NOTOC=1 -v GOLD=src/native/nan16_x86.nan \
    -v GUEST="$T/h.nan" -v CARTS="$T/carts.txt" \
    -v OUTB="$T/boot.bin" -v OUTG="$T/junk.bin" >/dev/null
  cat "$T/boot.bin" "$T/junk.bin" > "$T/full.img"
  fsz=$(wc -c < "$T/full.img"); frem=$((fsz % 512))
  [ "$frem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - frem)) >> "$T/full.img"
  sh tools/manifest_build.sh "$T/full.img" >/dev/null
  cat "$T/full.img" > "$T/floppy.img"
  truncate -s 1474560 "$T/floppy.img"
  dd if=/dev/zero of="$T/disk.img" bs=512 count=129 status=none
  cat "$T/guest.bin" >> "$T/disk.img"
  truncate -s 1474560 "$T/disk.img"

  rm -f "$T/ser"
  timeout 180 qemu-system-i386 -m 64 \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,index=0,file="$T/disk.img" \
    -boot a -display none -serial "file:$T/ser" -no-reboot >/dev/null 2>&1 || true
  [ "$(head -c 1 "$T/ser" 2>/dev/null)" = "Y" ] || {
    echo "xgold: native assembler rejected $src" >&2
    head -c 200 "$T/ser" | cat -v >&2 || true
    exit 1
  }
  tail -c +3 "$T/ser" > "$out"
}

asm_one x86/boot/kboot0.xa "$T/boot.bin.sector"
asm_one src/native/kan16.xa "$T/kern.bin"
[ "$(wc -c < "$T/boot.bin.sector")" -eq 512 ] || { echo "xgold: boot is not 512 bytes" >&2; exit 1; }
[ "$(wc -c < "$T/kern.bin")" -le 65536 ] || { echo "xgold: kernel exceeds 128 boot sectors" >&2; exit 1; }

# Pack the two byte streams as the gold text consumed by tools/mkimg.awk.
{
  echo "; NaN16 gold: boot 512 + kernel $(wc -c < "$T/kern.bin") bytes (native S1 rebuild)"
  for pair in "boot:$T/boot.bin.sector:0" "kernel:$T/kern.bin:512"; do
    name=${pair%%:*}; rest=${pair#*:}; file=${rest%%:*}; base=${rest##*:}
    xxd -p -c 16 "$file" | awk -v name="$name" -v base="$base" '{
      s=""
      for (i=1; i<=length($0); i+=2) s = s (s==""?"":" ") substr($0,i,2)
      printf "%s   ; %s+%04X\n", s, name, base + (NR-1)*16
    }'
  done
} > src/native/nan16_x86.nan
cp src/native/nan16_x86.nan x86/native/nan16_x86.nan
echo "xgold: boot 512 + kernel $(wc -c < "$T/kern.bin") bytes (no C/Python)"
