#!/bin/sh
# blockcache_gate.sh - verify the nasm1 block cache against the GOLD.
#
# The cache is rebuilt from scratch, then used to assemble the boot sector and
# the full kernel.  Both byte streams must equal the source-derived GOLD that
# source_gold_gate.sh checks.  Determinism is checked by a second rebuild.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/blockcache_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "blockcache_gate: FAIL: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }

[ -f src/native/nan16_x86.nan ] || fail "missing source-derived GOLD"
hdr=$(head -1 src/native/nan16_x86.nan)
kernel_bytes=$(printf '%s\n' "$hdr" | sed -n 's/.*kernel \([0-9][0-9]*\) bytes.*/\1/p')
[ -n "$kernel_bytes" ] || fail "cannot read kernel size from GOLD header"

# Recover the checked-in GOLD bytes from its grid.
awk '/; (boot|kernel)\+/ {
  line=$0; sub(/;.*/, "", line); gsub(/[^0-9a-fA-F]/, "", line); printf "%s", line
}' src/native/nan16_x86.nan | xxd -r -p > "$T/gold.bin"
[ "$(wc -c < "$T/gold.bin")" -eq "$((512 + kernel_bytes))" ] || fail "bad GOLD grid"
dd if="$T/gold.bin" of="$T/boot.gold" bs=1 count=512 2>/dev/null
dd if="$T/gold.bin" of="$T/kern.gold" bs=1 skip=512 2>/dev/null

echo "== 1. deterministic cache rebuild =="
sh tools/blockcache_build.sh --force > "$T/build1.log" 2>&1 || { cat "$T/build1.log" >&2; fail "cache build 1"; }
h1=$(sha build/cache/nasm1.cache); m1=$(sha build/cache/nasm1.masks); e1=$(sha build/cache/cache.elf)
cp build/cache/nasm1.cache "$T/cache1"
sh tools/blockcache_build.sh --force > "$T/build2.log" 2>&1 || { cat "$T/build2.log" >&2; fail "cache build 2"; }
[ "$h1" = "$(sha build/cache/nasm1.cache)" ] || fail "cache bytes are not deterministic"
[ "$m1" = "$(sha build/cache/nasm1.masks)" ] || fail "mask bytes are not deterministic"
echo "cache $h1 masks $m1 dispatcher $e1"

echo "== 2. boot sector through the cache =="
t0=$(date +%s%N)
sh tools/blockcache_run.sh x86/boot/kboot0.xa "$T/boot.bin"
t1=$(date +%s%N)
[ "$(wc -c < "$T/boot.bin")" -eq 512 ] || fail "boot output is not 512 bytes"
cmp -s "$T/boot.bin" "$T/boot.gold" || fail "cached boot differs from GOLD"
echo "boot: 512/512 bytes match ($(( (t1-t0)/1000000 )) ms)"

echo "== 3. full kernel through the cache =="
t0=$(date +%s%N)
sh tools/blockcache_run.sh src/native/kan16.xa "$T/kern.bin"
t1=$(date +%s%N)
[ "$(wc -c < "$T/kern.bin")" -eq "$kernel_bytes" ] || \
  fail "kernel output is $(wc -c < "$T/kern.bin") bytes, expected $kernel_bytes"
cmp -s "$T/kern.bin" "$T/kern.gold" || fail "cached kernel differs from GOLD"
echo "kernel: $kernel_bytes/$kernel_bytes bytes match ($(( (t1-t0)/1000000 )) ms)"

echo "blockcache_gate: PASS (2 deterministic cache builds; boot $(sha "$T/boot.bin"); kernel $(sha "$T/kern.bin"); predication masks verified by byte equality with GOLD)"
