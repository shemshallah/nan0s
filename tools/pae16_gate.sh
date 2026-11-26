#!/bin/sh
# tools/pae16_gate.sh - boot the PAE kernel in QEMU and prove the 16 GB bank path.
#
# The gate builds a small NaN16 guest (src/tests/pae16_test.nas), assembles the
# PAE kernel with the native nasm1 (tools/pae16_asm.sh), boots it on QEMU, and
# requires the guest's own PMEM + per-bank isolation + cross-bank BCOPY PASS.
#
# usage:
#   PAE_MEM_MB=3500 sh tools/pae16_gate.sh          # local correctness run
#   PAE_MEM_MB=7168 PAE_MIN_BANKS=7 PAE_MIN_USABLE_MB=7000 \
#       sh tools/pae16_gate.sh                      # 7 GB CI run
#   PAE_MEM_MB=16384 PAE_MIN_BANKS=16 PAE_MIN_USABLE_MB=16000 \
#       sh tools/pae16_gate.sh                      # 16 GiB high-memory run
#
# Environment:
#   PAE_MEM_MB          QEMU -m value (default 3500)
#   PAE_MIN_BANKS       minimum bank count the guest must prove (default 1)
#   PAE_MIN_USABLE_MB   minimum kind-1 RAM in MiB (default 0)
#   PAE_REQUIRE_E820    require PMEM flags bit0 (default 1; QEMU only)
#   PAE_SECS            QEMU wall clock (default 180)
#   PAE_ASM_DIR         reuse an existing pae16_asm output directory
#   PAE_KEEP            keep the build directory for inspection
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
export TMPDIR="${TMPDIR:-$PWD/tmp}"
MEM="${PAE_MEM_MB:-3500}"
MIN_BANKS="${PAE_MIN_BANKS:-1}"
MIN_USABLE_MB="${PAE_MIN_USABLE_MB:-0}"
REQUIRE_E820="${PAE_REQUIRE_E820:-1}"
REQUIRE_KIND2="${PAE_REQUIRE_KIND2:-0}"
MIN_MAP_ENTRIES="${PAE_MIN_MAP_ENTRIES:-1}"
SECS="${PAE_SECS:-180}"
T="$TMPDIR/pae16_gate"
rm -rf "$T"; mkdir -p "$T"
ASM="${PAE_ASM_DIR:-$T/asm}"

if [ ! -f "$ASM/kernel.bin" ] || [ ! -f "$ASM/boot.bin" ] || [ ! -f "$ASM/gold.nan" ]; then
  echo "pae16_gate: assembling boot + PAE kernel with nasm1 (this takes minutes)"
  sh tools/pae16_asm.sh "$ASM"
fi

# Byte-exact nasm1 output.  Two independent assemblies produced this hash
# (fffbc041... at r30); a mismatch means source/tool drift or a stale cache.
if [ -f src/native/kan16_pae.sha256 ]; then
  want=$(awk '{print $1}' src/native/kan16_pae.sha256)
  got=$(sha256sum "$ASM/kernel.bin" | awk '{print $1}')
  if [ "$want" != "$got" ]; then
    echo "pae16_gate: kernel SHA-256 $got != $want" >&2
    echo "pae16_gate: rebuild with tools/pae16_asm.sh and refresh src/native/kan16_pae.sha256" >&2
    exit 1
  fi
fi

echo "pae16_gate: guest=$PWD/src/tests/pae16_test.nas mem=${MEM}MiB"
awk -f tools/nmk.awk -v CMD=emit src/tests/pae16_test.nas > "$T/test.nan"
: > "$T/carts.txt"
awk -f tools/mkimg.awk -v GOLD="$ASM/gold.nan" -v GUEST="$T/test.nan" \
  -v CARTS="$T/carts.txt" -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" >/dev/null
cat "$T/boot.bin" "$T/guest.bin" > "$T/pae16.img"
truncate -s 1474560 "$T/pae16.img" 2>/dev/null || \
  dd if=/dev/zero bs=1 count=$((1474560 - $(wc -c < "$T/pae16.img"))) >> "$T/pae16.img"

QEMU=""
for q in qemu-system-i386 qemu-system-x86_64; do
  command -v "$q" >/dev/null 2>&1 && { QEMU="$q"; break; }
done
[ -n "$QEMU" ] || { echo "pae16_gate: QEMU is required" >&2; exit 1; }

echo "pae16_gate: $QEMU -m $MEM"
rm -f "$T/ser"
"$QEMU" -machine accel=tcg -cpu qemu64 -m "$MEM" \
  -drive format=raw,if=floppy,file="$T/pae16.img" \
  -display none -serial "file:$T/ser" -no-reboot > "$T/qemu.log" 2>&1 &
qpid=$!
# The guest prints PASS/FAIL and halts; QEMU itself does not exit on HLT.
# Stop it as soon as the verdict appears, or at PAE_SECS.
ticks=0
while kill -0 "$qpid" 2>/dev/null; do
  if [ -f "$T/ser" ] && grep -qE '^(PASS|FAIL)' "$T/ser"; then break; fi
  ticks=$((ticks + 1))
  [ "$ticks" -ge "$SECS" ] && break
  sleep 1
done
kill "$qpid" 2>/dev/null || true
wait "$qpid" 2>/dev/null || true
tr -d '\r' < "$T/ser" > "$T/ser.txt" 2>/dev/null || : > "$T/ser.txt"

show_fail() {
  echo "pae16_gate: FAIL ($1)" >&2
  echo "--- serial ---" >&2
  cat "$T/ser.txt" >&2 2>/dev/null || true
  echo "--- qemu ---" >&2
  tail -20 "$T/qemu.log" >&2 2>/dev/null || true
  exit 1
}

grep -q '^PMEM PASS$'  "$T/ser.txt" || show_fail "PMEM PASS missing"
grep -q '^BANKS PASS$' "$T/ser.txt" || show_fail "BANKS PASS missing"
grep -q '^PASS$'       "$T/ser.txt" || show_fail "PASS missing"
grep -q '^DP$'         "$T/ser.txt" || show_fail "cross-bank BCOPY DP missing"

get() { sed -n "s/^$1\([0-9A-Fa-f]*\)$/\1/p" "$T/ser.txt" | tail -1; }
h2d() {
  awk -v h="$1" 'BEGIN {
    n=0
    for (i=1; i<=length(h); i++) {
      c=toupper(substr(h,i,1)); v=index("0123456789ABCDEF",c)-1
      if (v < 0) exit 1
      n=n*16+v
    }
    printf "%d\n", n
  }'
}
WORDS_H=$(get W); BANKS_H=$(get B); USABLE_H=$(get U); KINDS_H=$(get Q)
MASK_H=$(get M); COUNT_H=$(get C); FLAGS_H=$(get G)
[ -n "$WORDS_H" ] && [ -n "$BANKS_H" ] && [ -n "$USABLE_H" ] && \
  [ -n "$KINDS_H" ] && [ -n "$MASK_H" ] && [ -n "$COUNT_H" ] && [ -n "$FLAGS_H" ] || \
  show_fail "missing MEMQ/PMEM summary lines"
WORDS=$(h2d "$WORDS_H"); BANKS=$(h2d "$BANKS_H"); USABLE=$(h2d "$USABLE_H")
KINDS=$(h2d "$KINDS_H"); MASK=$(h2d "$MASK_H")
COUNT=$(h2d "$COUNT_H"); FLAGS=$(h2d "$FLAGS_H")
[ "$WORDS" -gt 0 ] || show_fail "zero words"
[ "$BANKS" -ge "$MIN_BANKS" ] || show_fail "banks $BANKS < $MIN_BANKS"
# The effective mask must cover the last bank, not the 32 MiB legacy default.
[ "$MASK" -ge $(( (BANKS - 1) * 134217728 )) ] || \
  show_fail "mask 0x$MASK_H does not cover $BANKS banks (legacy fallback?)"
USABLE_MB=$((USABLE / 131072))
[ "$USABLE_MB" -ge "$MIN_USABLE_MB" ] || show_fail "usable ${USABLE_MB}MiB < ${MIN_USABLE_MB}MiB"
[ "$COUNT" -ge "$MIN_MAP_ENTRIES" ] && [ "$COUNT" -le 64 ] || \
  show_fail "PMEM count $COUNT < $MIN_MAP_ENTRIES (or > 64)"
[ $((KINDS & 2)) -ne 0 ] || show_fail "PMEM has no kind-1 usable entry"
if [ "$REQUIRE_KIND2" = "1" ]; then
  [ $((KINDS & 4)) -ne 0 ] || show_fail "PMEM has no kind-2 reserved/hole entry"
fi
if [ "$REQUIRE_E820" = "1" ]; then
  [ $((FLAGS & 1)) -ne 0 ] || show_fail "PMEM flags=$FLAGS lacks E820 bit"
fi

# Pair each K<bank> line with the following P/F/- result.
set -- $(awk '
  /^K[0-9A-Fa-f]+$/ { getline r; if (r=="P") p++; else if (r=="F") f++; else if (r=="-") n++; else b++ }
  END { printf "%d %d %d %d\n", p+0, f+0, n+0, b+0 }
' "$T/ser.txt")
P=$1; F=$2; N=$3; BAD=$4
[ "$F" -eq 0 ] && [ "$BAD" -eq 0 ] || show_fail "bank result F=$F bad=$BAD"
[ "$N" -eq 0 ] || show_fail "bank with no kind-1 word: $N"
[ "$P" -eq "$BANKS" ] || show_fail "proved banks $P != bank count $BANKS"

echo "pae16_gate: PASS mem=${MEM}MiB mask=0x$MASK_H words=0x$WORDS_H banks=$BANKS usable=${USABLE_MB}MiB kinds=0x$KINDS_H PMEM=$COUNT flags=$FLAGS"
echo "pae16_gate: serial: $T/ser.txt"
if [ "${PAE_KEEP:-0}" != "1" ]; then
  rm -rf "$T/asm" "$T/boot.bin" "$T/guest.bin" "$T/pae16.img" 2>/dev/null || true
fi
