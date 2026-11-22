#!/bin/sh
# tools/nan_bench.sh - packed-i8 MAC throughput: VDP4B (64 MACs/op) vs
# scalar DP4B (4 MACs/op), identical loop shape.  Checksums must be exact;
# timings are the guest millisecond clock and are indicative (qemu TCG).
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nanbench.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/bench_vec_test.nas > "$T/b.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }

check() { # file, core
  v=$(sed -n 's/^V\([0-9A-F]\{8\}\)\([0-9A-F]\{8\}\)$/\1 \2/p' "$1")
  d=$(sed -n 's/^D\([0-9A-F]\{8\}\)\([0-9A-F]\{8\}\)$/\1 \2/p' "$1")
  [ -n "$v" ] && [ -n "$d" ] || { echo "nan_bench: FAIL ($2 output)"; cat "$1"; exit 1; }
  vms=$(echo "$v" | cut -d' ' -f1); vsum=$(echo "$v" | cut -d' ' -f2)
  dms=$(echo "$d" | cut -d' ' -f1); dsum=$(echo "$d" | cut -d' ' -f2)
  [ "$vsum" = "007A1200" ] || { echo "nan_bench: FAIL ($2 VDP4B sum $vsum)"; exit 1; }
  [ "$dsum" = "007A1200" ] || { echo "nan_bench: FAIL ($2 DP4B sum $dsum)"; exit 1; }
  vms=$((0x$vms)); dms=$((0x$dms))
  [ "$vms" -gt 0 ] || vms=1; [ "$dms" -gt 0 ] || dms=1
  # 1e6 iterations: VDP4B 64e6 MACs, DP4B 4e6 MACs
  vmac=$((64000000 / vms)); dmac=$((4000000 / dms))
  echo "nan_bench $2: VDP4B ${vms}ms ${vmac} kMAC/s | DP4B ${dms}ms ${dmac} kMAC/s" >&2
  echo "$vmac $dmac"
}

./aarch64/android/nan_cli --img "$T/b.nan" --mem 16 --steps 100000000 --serial > "$T/c.out" 2>/dev/null || true
cvals=$(check "$T/c.out" "C-reference(guest-clock)")
if command -v qemu-system-i386 >/dev/null 2>&1; then
  gawk -f tools/mkimg.awk -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/b.nan" \
       -v CARTS=/dev/null -v OUTB="$T/bb.bin" -v OUTG="$T/bg.bin" 2>/dev/null
  cat "$T/bb.bin" "$T/bg.bin" > "$T/b.img"; truncate -s 1474560 "$T/b.img"
  rm -f "$T/b.com"
  timeout 60 qemu-system-i386 -m 512 -drive format=raw,if=floppy,file="$T/b.img" \
    -display none -serial "file:$T/b.com" -no-reboot >/dev/null 2>&1 || true
  nvals=$(check "$T/b.com" "native-x86(guest-clock)")
  nv=$(echo "$nvals" | tail -1 | cut -d' ' -f1)
  nd=$(echo "$nvals" | tail -1 | cut -d' ' -f2)
  [ "$nd" -gt 0 ] || nd=1
  echo "nan_bench ratio: VDP4B/DP4B = $((nv / nd))x MAC throughput (guest clock)"
  echo "nan_bench: PASS (VDP4B and DP4B checksums exact on C and native x86)"
else
  echo "nan_bench: PASS (C reference; native skipped, no qemu)"
fi
