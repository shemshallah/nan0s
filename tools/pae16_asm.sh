#!/bin/sh
# tools/pae16_asm.sh - assemble the PAE kernel and/or boot sector with nasm1.
#
# Outer box only: gawk stages the source, the native S1 core runs nasm1 inside
# QEMU, and the serial byte stream is split into boot/kernel binaries.  No C,
# no Python.  This is the PAE-path equivalent of tools/xgold.sh, but it writes
# only under $TMPDIR and never touches src/native/nan16_x86.nan.
#
# usage: sh tools/pae16_asm.sh [OUTDIR]
#   OUTDIR defaults to $TMPDIR/pae16_asm (or ./tmp/pae16_asm).
#   outputs: $OUTDIR/boot.bin (512 bytes), $OUTDIR/kernel.bin,
#            $OUTDIR/gold.nan (mkimg.awk GOLD stream)
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${1:-${TMPDIR:-$PWD/tmp}/pae16_asm}"
rm -rf "$T"; mkdir -p "$T"

QEMU=""
for q in qemu-system-i386 qemu-system-x86_64; do
  command -v "$q" >/dev/null 2>&1 && { QEMU="$q"; break; }
done
[ -n "$QEMU" ] || { echo "pae16_asm: qemu-system-i386/x86_64 is required" >&2; exit 1; }
[ -f src/native/nan16_x86.nan ] || { echo "pae16_asm: missing host gold core" >&2; exit 1; }

# Expand .include directives relative to the including file.  nasm1 has no
# .include, so the PAE kernel names src/lib/memmap_defs.nas and this stage
# inlines it before the source is handed to the assembler.
expand_includes() { # src out
  _src="$1"; _out="$2"
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      .include[[:space:]]*)
        _inc=$(printf '%s\n' "$_line" | sed -n 's/^[[:space:]]*\.include[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$_inc" ] || { echo "pae16_asm: bad .include: $_line" >&2; exit 1; }
        case "$_inc" in
          /*) _ip="$_inc" ;;
          *)  _ip="$(dirname "$_src")/$_inc" ;;
        esac
        [ -f "$_ip" ] || { echo "pae16_asm: missing include $_ip" >&2; exit 1; }
        expand_includes "$_ip" "$_out"
        ;;
      *) printf '%s\n' "$_line" >> "$_out" ;;
    esac
  done < "$_src"
}

asm_one() { # src out.bin
  src="$1"; out="$2"
  exp="$T/$(basename "$src").expanded"
  : > "$exp"
  expand_includes "$src" "$exp"
  # nasm1 runs as a guest; the source travels in a .str after nasm1.nas.
  awk -v SRC="$exp" 'BEGIN {
    printf ".org 0\n.include \"nasm.nas\"\n.org 0x20000\n.str \""
    while ((getline line < SRC) > 0) {
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      printf "%s\\n", line
    }
    print "\""
  }' > src/prog/_pae16_h.nas
  awk -f tools/nmk.awk -v CMD=emit src/prog/_pae16_h.nas > "$T/h.nan"
  rm -f src/prog/_pae16_h.nas
  awk '{
    line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
    n=split(line, a, "_")
    if (n==3 && length(a[1])==4 && length(a[2])==8 && length(a[3])==4)
      printf "%s%s%s%s%s%s%s%s", \
        substr(a[3],3,2), substr(a[3],1,2), \
        substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
        substr(a[1],3,2), substr(a[1],1,2)
  }' "$T/h.nan" | xxd -r -p > "$T/guest.bin"
  : > "$T/carts.txt"
  awk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan \
    -v GUEST="$T/h.nan" -v CARTS="$T/carts.txt" \
    -v OUTB="$T/host_boot.bin" -v OUTG="$T/junk.bin" >/dev/null
  cat "$T/host_boot.bin" > "$T/floppy.img"
  truncate -s 1474560 "$T/floppy.img"
  dd if=/dev/zero of="$T/disk.img" bs=512 count=129 status=none
  cat "$T/guest.bin" >> "$T/disk.img"
  truncate -s 1474560 "$T/disk.img"
  rm -f "$T/ser"
  "$QEMU" -machine accel=tcg -cpu qemu64 -m 256 \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,index=0,file="$T/disk.img" \
    -boot a -display none -serial "file:$T/ser" -no-reboot >/dev/null 2>&1 &
  qpid=$!
  # nasm1 writes 'Y' then the binary and halts.  Stop QEMU when the serial
  # byte stream has been stable for a few seconds; otherwise cap at 300 s.
  last=-1; stable=0; ticks=0
  while kill -0 "$qpid" 2>/dev/null; do
    if [ -f "$T/ser" ]; then sz=$(wc -c < "$T/ser"); else sz=0; fi
    if [ "$sz" -gt 0 ] && [ "$sz" -eq "$last" ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    last=$sz
    ticks=$((ticks + 1))
    [ "$stable" -ge 20 ] && break
    [ "$ticks" -ge 300 ] && break
    sleep 1
  done
  kill "$qpid" 2>/dev/null || true
  wait "$qpid" 2>/dev/null || true
  if [ "$(head -c 1 "$T/ser" 2>/dev/null)" != "Y" ]; then
    echo "pae16_asm: nasm1 REJECTED $src" >&2
    head -c 400 "$T/ser" 2>/dev/null | cat -v >&2 || true
    exit 1
  fi
  tail -c +3 "$T/ser" > "$out"
}

asm_one src/boot/kboot0.xa "$T/boot.bin"
asm_one src/native/kan16_pae.xa "$T/kernel.bin"
[ "$(wc -c < "$T/boot.bin")" -eq 512 ] || { echo "pae16_asm: boot is not 512 bytes" >&2; exit 1; }
[ "$(wc -c < "$T/kernel.bin")" -le 65536 ] || { echo "pae16_asm: kernel exceeds 64 KiB" >&2; exit 1; }

# Pack boot+kernel as the gold text stream mkimg.awk consumes.
{
  echo "; NaN16 gold: boot 512 + kernel $(wc -c < "$T/kernel.bin") bytes (PAE nasm1 rebuild)"
  for pair in "boot:$T/boot.bin:0" "kernel:$T/kernel.bin:512"; do
    name=${pair%%:*}; rest=${pair#*:}; file=${rest%%:*}; base=${rest##*:}
    xxd -p -c 16 "$file" | awk -v name="$name" -v base="$base" '{
      s=""
      for (i=1; i<=length($0); i+=2) s = s (s==""?"":" ") substr($0,i,2)
      printf "%s   ; %s+%04X\n", s, name, base + (NR-1)*16
    }'
  done
} > "$T/gold.nan"

echo "pae16_asm: boot 512 + kernel $(wc -c < "$T/kernel.bin") bytes; $T"
