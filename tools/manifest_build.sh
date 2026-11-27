#!/bin/sh
# tools/manifest_build.sh - F16 deterministic product manifest writer.
#
# Usage: sh tools/manifest_build.sh IMAGE
#
# The image layout produced by tools/mkall.sh is:
#   LBA 0        boot sector (512 bytes)
#   LBA 1..127   kernel window (65024 bytes)
#   LBA 128      manifest (512 bytes, this script)
#   LBA 129..    guest words (8 * LMAX bytes, LMAX at image offset 504)
#
# The manifest stores SHA-256 digests over the emitted boot, kernel and guest
# bytes, a root hash over the header/table, and an HMAC-SHA-256
# authentication tag keyed by the build key.  This is symmetric tamper
# detection with an embedded build key, NOT a public-key signature.
#
# Deterministic: no timestamps, UUIDs, or entropy.  The same emitted image
# always produces the same manifest.  The guest digest covers exactly
# 8 * LMAX bytes; the final sector padding is not covered.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
[ $# -eq 1 ] || { echo "usage: manifest_build.sh IMAGE" >&2; exit 2; }
IMG=$1
[ -f "$IMG" ] || { echo "manifest_build: missing $IMG" >&2; exit 1; }

# 32-byte build key.  It is deliberately public in the repository: this is a
# tamper-detection key, not a secret and not a public-key signing key.
KEY=4e614e30532d4631362d6e6d616e69666573742d6275696c642d6b65792d3031
# 64-byte HMAC ipad/opad blocks (key || 32 zero bytes, xor 0x36 / 0x5c).
KIPAD=78577806651b7007001b585b57585f505345421b54435f5a521b5d534f1b06073636363636363636363636363636363636363636363636363636363636363636
KOPAD=123d126c0f711a6d6a7132313d32353a392f28713e2935303871373925716c6d5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c

MANOFF=65536              # LBA 128
KERNOFF=512
KERNSZ=65024
GUESTOFF=66048

sz=$(wc -c < "$IMG")
[ "$sz" -ge $((GUESTOFF + 8)) ] || {
  echo "manifest_build: $IMG is only $sz bytes" >&2; exit 1; }
LMAX=$(od -An -tu4 -j504 -N4 "$IMG" | tr -d ' \n')
case "$LMAX" in ''|*[!0-9]*) echo "manifest_build: bad LMAX at image offset 504" >&2; exit 1;; esac
[ "$LMAX" -gt 0 ] || { echo "manifest_build: zero guest length" >&2; exit 1; }
GSZ=$((LMAX * 8))
[ $((GUESTOFF + GSZ)) -le "$sz" ] || {
  echo "manifest_build: guest $GSZ bytes does not fit in $IMG" >&2; exit 1; }

T="${TMPDIR:-/tmp}/nmanifest.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

hash_range() { # skip count
  dd if="$IMG" bs=1 skip="$1" count="$2" status=none | sha256sum | awk '{print $1}'
}
HB=$(hash_range 0 512)
HK=$(hash_range "$KERNOFF" "$KERNSZ")
HG=$(hash_range "$GUESTOFF" "$GSZ")
BID=$(printf '%s\n' "$HB" "$HK" "$HG" | sha256sum | awk '{print substr($1,1,8)}')

hexbin() { # hexbytes count
  gawk -v H="$1" -v N="$2" 'BEGIN {
    for (i = 1; i <= N; i++) printf "%c", strtonum("0x" substr(H, 2*i-1, 2))
  }'
}

# Pass 1: header + table with zero root/tag.  The root covers [0, 0xE8).
gawk -f tools/manifest_mk.awk -v HB="$HB" -v HK="$HK" -v HG="$HG" \
  -v GSZ="$GSZ" -v BID="$BID" -v ROOT="$(printf '%064d' 0)" \
  -v TAG="$(printf '%064d' 0)" > "$T/m0.bin"
[ "$(wc -c < "$T/m0.bin")" -eq 512 ] || {
  echo "manifest_build: manifest is not 512 bytes" >&2; exit 1; }
ROOT=$(dd if="$T/m0.bin" bs=1 count=232 status=none | sha256sum | awk '{print $1}')

# tag = HMAC-SHA-256(key, root) = SHA256(opad || SHA256(ipad || root)).
{ hexbin "$KIPAD" 64; hexbin "$ROOT" 32; } > "$T/in.bin"
INNER=$(sha256sum "$T/in.bin" | awk '{print $1}')
{ hexbin "$KOPAD" 64; hexbin "$INNER" 32; } > "$T/out.bin"
TAG=$(sha256sum "$T/out.bin" | awk '{print $1}')

gawk -f tools/manifest_mk.awk -v HB="$HB" -v HK="$HK" -v HG="$HG" \
  -v GSZ="$GSZ" -v BID="$BID" -v ROOT="$ROOT" -v TAG="$TAG" > "$T/manifest.bin"
[ "$(wc -c < "$T/manifest.bin")" -eq 512 ] || {
  echo "manifest_build: final manifest is not 512 bytes" >&2; exit 1; }
dd if="$T/manifest.bin" of="$IMG" bs=1 seek="$MANOFF" conv=notrunc status=none

short() { printf '%s' "$1" | awk '{print substr($0,1,8)}'; }
echo "manifest: boot $(short "$HB") kernel $(short "$HK") guest $(short "$HG") root $(short "$ROOT") tag $(short "$TAG") build $BID"
