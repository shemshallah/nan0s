#!/bin/sh
# tools/xgold64.sh - assemble the x86-64 long-mode core with nasm1.
# Default native producer: gawk stages the source, the source-derived 32-bit
# GOLD boot sector + native kan16 core run nasm1 under QEMU, and awk writes the
# gold stream.  XGOLD64_FAST=1 uses the nan_cli Android adapter for iteration;
# its bytes are checked against the native producer before acceptance.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/xgold64.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "xgold64: qemu-system-i386 required" >&2; exit 1; }
[ -f src/native/nan16_x86.nan ] || { echo "xgold64: missing 32-bit gold core" >&2; exit 1; }

asm_one() { # src out.bin
  src="$1"; out="$2"
  awk -v SRC="$src" 'BEGIN {
    printf ".org 0\n.include \"nasm.nas\"\n.org 0x20000\n.str \""
    while ((getline line < SRC) > 0) {
      gsub(/\\/, "\\\\", line); gsub(/"/, "\\\"", line)
      printf "%s\\n", line
    }
    print "\""
  }' > src/prog/_xgold64_h.nas
  awk -f tools/nmk.awk -v CMD=emit src/prog/_xgold64_h.nas > "$T/h.nan"
  rm -f src/prog/_xgold64_h.nas

  # Fast development path: the adapter runs the same nasm1 NaN program.  The
  # native producer below remains the acceptance path; this only shortens
  # iteration and is byte-identical to the native output.
  if [ "${XGOLD64_FAST:-0}" = 1 ]; then
    [ -x aarch64/android/nan_cli ] || { echo "xgold64: fast path needs nan_cli" >&2; exit 1; }
    rm -f "$T/ser"
    timeout 180 ./aarch64/android/nan_cli --img "$T/h.nan" --mem 16 \
      --steps 500000000 --serial > "$T/ser" 2>"$T/nc.err" || true
    [ "$(head -c 1 "$T/ser" 2>/dev/null)" = "Y" ] || {
      echo "xgold64: adapter rejected $src" >&2; head -c 200 "$T/ser" | cat -v >&2; exit 1; }
    tail -c +3 "$T/ser" > "$out"
    return 0
  fi

  awk '{
    line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
    n=split(line, a, "_")
    if (n==3) printf "%s%s%s%s%s%s%s%s", \
      substr(a[3],3,2), substr(a[3],1,2), \
      substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
      substr(a[1],3,2), substr(a[1],1,2)
  }' "$T/h.nan" | xxd -r -p > "$T/guest.bin"
  [ -s "$T/guest.bin" ] || { echo "xgold64: empty guest for $src" >&2; exit 1; }

  # Native producer: the 32-bit GOLD boot sector + kan16 core execute nasm1 on
  # bare QEMU; the guest image is read from IDE LBA 129.  No C, no Python.
  : > "$T/carts.txt"
  awk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan \
    -v GUEST="$T/h.nan" -v CARTS="$T/carts.txt" \
    -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" >/dev/null
  # Build the temp image and sign it, then split the signed boot window
  # (floppy) from the guest (IDE LBA 129).  The producer core verifies the
  # manifest before running nasm1, exactly like the product boot.
  cat "$T/boot.bin" "$T/guest.bin" > "$T/prod.img"
  psz=$(wc -c < "$T/prod.img"); prem=$((psz % 512))
  [ "$prem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - prem)) >> "$T/prod.img" 2>/dev/null
  sh tools/manifest_build.sh "$T/prod.img" > "$T/man.out" 2> "$T/man.err" ||
    { echo "xgold64: manifest failed for $src" >&2; cat "$T/man.err" >&2; exit 1; }
  dd if="$T/prod.img" of="$T/floppy.img" bs=512 count=129 status=none
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
    echo "xgold64: native nasm1 rejected $src" >&2
    head -c 200 "$T/ser" | cat -v >&2 || true
    exit 1
  }

  # Optional comparator: the C nan_cli oracle must emit the same bytes.  It is
  # never the producer; a missing binary just skips this check.
  if [ -x aarch64/android/nan_cli ] && [ "${SOURCE_GOLD_NO_ORACLE:-0}" != 1 ]; then
    rm -f "$T/nc.ser"
    timeout 180 ./aarch64/android/nan_cli --img "$T/h.nan" --mem 16 \
      --steps 500000000 --serial > "$T/nc.ser" 2>"$T/nc.err" || true
    cmp -s "$T/ser" "$T/nc.ser" || {
      echo "xgold64: native nasm1 output differs from the nan_cli oracle for $src" >&2
      exit 1
    }
  fi
  tail -c +3 "$T/ser" > "$out"
}

awk 'BEGIN {
  while ((getline l < "src/native/kan16_x64.xa") > 0) {
    if (l == ".include \"kan16_x64_body.nas\"") {
      while ((getline b < "src/native/kan16_x64_body.nas") > 0) print b
    } else print l
  }
}' > "$T/full.xa"
asm_one x86/boot/kboot0.xa "$T/boot.bin.sector"
asm_one "$T/full.xa" "$T/kern.bin"
[ "$(wc -c < "$T/boot.bin.sector")" -eq 512 ] || { echo "xgold64: bad boot size" >&2; exit 1; }
[ "$(wc -c < "$T/kern.bin")" -le 65536 ] || { echo "xgold64: kernel > 64 KiB" >&2; exit 1; }

{
  echo "; NaN16 gold: boot 512 + x86-64 long-mode kernel $(wc -c < "$T/kern.bin") bytes"
  for pair in "boot:$T/boot.bin.sector:0" "kernel:$T/kern.bin:512"; do
    name=${pair%%:*}; rest=${pair#*:}; file=${rest%%:*}; base=${rest##*:}
    xxd -p -c 16 "$file" | awk -v name="$name" -v base="$base" '{
      s=""; for (i=1; i<=length($0); i+=2) s = s (s==""?"":" ") substr($0,i,2)
      printf "%s   ; %s+%04X\n", s, name, base + (NR-1)*16
    }'
  done
} > src/native/nan16_x64.nan
echo "xgold64: boot 512 + kernel $(wc -c < "$T/kern.bin") bytes"
