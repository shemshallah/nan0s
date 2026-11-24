#!/bin/sh
# tools/s1_big_guest_gate.sh - large flat-cartridge acceptance.
#
# Generates a >16 MiB NaN16 image whose guest sums every payload word and
# compares it with a host-computed checksum, then prints BIG PASS.  The S1
# must load the whole image through the IDE/ATA PIO path (no 768 KiB cap).
set -eu; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/s1_big.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

python3 tools/s1_big_guest_gen.py "$T/big.bin" > "$T/info"
SIZE=$(wc -c < "$T/big.bin")
[ "$SIZE" -gt $((16 * 1024 * 1024)) ] || {
    echo "s1_big_guest: FAIL (image only $SIZE bytes)"; exit 1; }

if ! S1_QEMU_MEM=${S1_QEMU_MEM:-256} ./tools/s1_runner.sh --img "$T/big.bin" --mem 128 --steps 200000000 \
      --serial > "$T/out" 2> "$T/err"; then
    echo "s1_big_guest: FAIL (runner)"
    tail -20 "$T/err"
    exit 1
fi
if [ "$(cat "$T/out")" != "BIG PASS" ]; then
    echo "s1_big_guest: FAIL (guest checksum/output)"
    cat -v "$T/out"; echo
    tail -20 "$T/err"
    exit 1
fi
cat "$T/info"
echo "s1_big_guest: PASS ($SIZE bytes byte-exact through the IDE loader)"
