#!/bin/sh
# tools/xmemgate.sh - native x86 runtime-memory gate.
# The kernel sizes guest RAM from the BIOS E820 map and exposes it through
# CPUID 0x4E4D00FF.  The same gold image must report 8M/32M/64M words at
# qemu -m 128/512/1024, and the guest C runtime must get a 100 MB heap on
# the 32M-word machine.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "xmemgate: SKIP (no qemu-system-i386)"; exit 0; }
T="${TMPDIR:-/tmp}/xmemgate.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
run_img() {  # img mb outfile
  rm -f "$3"
  timeout 60 qemu-system-i386 -m "$2" -drive format=raw,if=floppy,file="$1" \
    -display none -serial "file:$3" -no-reboot >/dev/null 2>&1 & qp=$!
  i=0
  while [ $i -lt 30 ]; do
    sleep 1; i=$((i+1))
    grep -q "PASS" "$3" 2>/dev/null && break
  done
  kill $qp 2>/dev/null || true
  wait $qp 2>/dev/null || true
}
build_guest() {  # src outimg
  awk -f tools/nmk.awk -v CMD=emit "$1" > "$T/g.nan" 2>"$T/ge" || { cat "$T/ge"; exit 1; }
  gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/g.nan" \
       -v CARTS=/dev/null -v OUTB="$T/b.bin" -v OUTG="$T/g.bin" 2>"$T/me" || { cat "$T/me"; exit 1; }
  cat "$T/b.bin" "$T/g.bin" > "$2"
  truncate -s 1474560 "$2"
}
build_guest src/tests/memtest.nas "$T/mem.img"
for spec in "128:007FFFFF:00800000:02000000" "512:01FFFFFF:02000000:08000000" "1024:03FFFFFF:04000000:10000000"; do
  mb=${spec%%:*}; rest=${spec#*:}
  mask=${rest%%:*}; rest=${rest#*:}
  words=${rest%%:*}; bytes=${rest#*:}
  run_img "$T/mem.img" "$mb" "$T/com.txt"
  got=$(sed -n '2,5p' "$T/com.txt" | tr '\n' ' ')
  want="M$mask W$words F4E160001 S$bytes "
  if [ "$got" != "$want" ]; then
    echo "xmemgate: FAIL at -m $mb"; echo "want: $want"; echo "got:  $got"; cat "$T/com.txt"; exit 1
  fi
done
build_guest src/tests/ncc_heap_test.nas "$T/heap.img"
run_img "$T/heap.img" 512 "$T/heap.txt"
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/heap.txt" > "$T/heap.got"
printf 'BIG 1\nEDGE 11 22\nMB 1\nREUSE 1\nHEAP PASS\n' > "$T/heap.want"
cmp -s "$T/heap.want" "$T/heap.got" || { echo "xmemgate: FAIL (C heap on native x86)"; diff -u "$T/heap.want" "$T/heap.got" | head -20; exit 1; }
echo "xmemgate: PASS (x86 E820 8M/32M/64M words; 100 MB C heap at 512 MiB)"
