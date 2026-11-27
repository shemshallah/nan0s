#!/bin/sh
# tools/manifest_build.sh - F16b deterministic product manifest + OTS signer.
#
# Usage: sh tools/manifest_build.sh IMAGE
#
# Image layout (unchanged from F16):
#   LBA 0        boot sector                     512 bytes
#   LBA 1..119   kernel code                     60,928 bytes
#   LBA 120..127 manifest                        4,096 bytes (this script)
#   LBA 128      OTS anchor block                512 bytes (this script)
#   LBA 129..    guest words                     8 * LMAX bytes
#
# The 128-sector kernel window is still 512 + 65,024 bytes; the manifest and
# anchor occupy its last 4,608 bytes, so the boot sector, ATA guest LBA and
# guest offset do not move.  Kernel code must fit below 60,928 bytes.
#
# The manifest carries SHA-256 digests over the emitted boot, kernel and guest
# bytes.  The root covers the header/table only.  It is signed with a
# Winternitz-4 one-time signature over SHA-256; the one-time chains are
# derived from an offline 32-byte master seed in build/ots (git-ignored, mode
# 0600) and are never embedded in the image.  The public key and key id go in
# the manifest, and a copy of the expected key id/public key is patched into
# the 512-byte anchor block at 0x1FE00.  The HMAC tag is retained only as
# defense in depth.
#
# Deterministic: for a fixed master seed and emitted bytes the signature,
# manifest and anchor are byte-identical.  No timestamps, UUIDs or entropy in
# the image.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
[ $# -eq 1 ] || { echo "usage: manifest_build.sh IMAGE" >&2; exit 2; }
IMG=$1
[ -f "$IMG" ] || { echo "manifest_build: missing $IMG" >&2; exit 1; }

# 32-byte HMAC key.  Deliberately public: it is tamper detection only, not
# the signature key.  The OTS master seed is the secret and is never here.
KEY=4e614e30532d4631362d6e6d616e69666573742d6275696c642d6b65792d3031
KIPAD=78577806651b7007001b585b57585f505345421b54435f5a521b5d534f1b06073636363636363636363636363636363636363636363636363636363636363636
KOPAD=123d126c0f711a6d6a7132313d32353a392f28713e2935303871373925716c6d5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c

MANOFF=61440              # LBA 120, physical 0x1EE00
MANSZ=4096
ANCHOROFF=65536           # LBA 128, physical 0x1FE00
KERNOFF=512
KERNSZ=60928
GUESTOFF=66048
GUESTSZ_MAX=512000        # 512 KiB floppy-staged fallback window

sz=$(wc -c < "$IMG")
[ "$sz" -ge $((GUESTOFF + 8)) ] || {
  echo "manifest_build: $IMG is only $sz bytes" >&2; exit 1; }
LMAX=$(od -An -tu4 -j504 -N4 "$IMG" | tr -d ' \n')
case "$LMAX" in ''|*[!0-9]*) echo "manifest_build: bad LMAX at image offset 504" >&2; exit 1;; esac
[ "$LMAX" -gt 0 ] || { echo "manifest_build: zero guest length" >&2; exit 1; }
GSZ=$((LMAX * 8))
[ $((GUESTOFF + GSZ)) -le "$sz" ] || {
  echo "manifest_build: guest $GSZ bytes does not fit in $IMG" >&2; exit 1; }

if [ ! -f "${OTS_MASTER:-build/ots/master.hex}" ]; then
  echo "manifest_build: no OTS master; using the public development seed (build/ots/master.hex, 0600)" >&2
  OTS_SEED=$(tr -d ' \r\n' < tools/ots_dev_seed.hex) sh tools/ots_keygen.sh
fi

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

Z32=$(printf '%064d' 0)
# Pass 1: header + table with zero root/tag/OTS fields.  Root is
# SHA-256(manifest[0..0xE7]); OTS key/signature fields start at 0xE8.
gawk -f tools/manifest_mk.awk -v HB="$HB" -v HK="$HK" -v HG="$HG" \
  -v GSZ="$GSZ" -v BID="$BID" -v ROOT="$Z32" -v TAG="$Z32" \
  -v KID="$Z32" -v PK="$Z32" -v SIG="$(printf '%04288d' 0)" > "$T/m0.bin"
[ "$(wc -c < "$T/m0.bin")" -eq "$MANSZ" ] || {
  echo "manifest_build: manifest is not $MANSZ bytes" >&2; exit 1; }
ROOT=$(dd if="$T/m0.bin" bs=1 count=232 status=none | sha256sum | awk '{print $1}')

# Sign the root with the offline per-root Winternitz key.
sh tools/ots_sign.sh "$ROOT" "$T/ots" >/dev/null
KID=$(sed -n '1p' "$T/ots/kid.hex")
PK=$(sed -n '1p' "$T/ots/pub.hex")
SIG=$(sed -n '1p' "$T/ots/sig.hex")
ANCHORHEX=$(sed -n '1p' "$T/ots/anchor.hex")
case "$KID$PK$SIG" in *[!0-9a-f]*) echo "manifest_build: signer emitted non-hex" >&2; exit 1;; esac
[ "${#KID}" -eq 32 ] || { echo "manifest_build: bad key id" >&2; exit 1; }
[ "${#PK}" -eq 64 ] || { echo "manifest_build: bad public key" >&2; exit 1; }
[ "${#SIG}" -eq 4288 ] || { echo "manifest_build: bad signature length" >&2; exit 1; }

# HMAC-SHA-256(key, root), defense in depth.
{ hexbin "$KIPAD" 64; hexbin "$ROOT" 32; } > "$T/in.bin"
INNER=$(sha256sum "$T/in.bin" | awk '{print $1}')
{ hexbin "$KOPAD" 64; hexbin "$INNER" 32; } > "$T/out.bin"
TAG=$(sha256sum "$T/out.bin" | awk '{print $1}')

gawk -f tools/manifest_mk.awk -v HB="$HB" -v HK="$HK" -v HG="$HG" \
  -v GSZ="$GSZ" -v BID="$BID" -v ROOT="$ROOT" -v TAG="$TAG" \
  -v KID="$KID" -v PK="$PK" -v SIG="$SIG" > "$T/manifest.bin"
[ "$(wc -c < "$T/manifest.bin")" -eq "$MANSZ" ] || {
  echo "manifest_build: final manifest is not $MANSZ bytes" >&2; exit 1; }

# 512-byte anchor block: OTSA0001 | keyid | pubkey | zero.
hexbin "$ANCHORHEX" 512 > "$T/anchor.bin"
[ "$(wc -c < "$T/anchor.bin")" -eq 512 ] || {
  echo "manifest_build: anchor block is not 512 bytes" >&2; exit 1; }

dd if="$T/manifest.bin" of="$IMG" bs=1 seek="$MANOFF" conv=notrunc status=none
dd if="$T/anchor.bin" of="$IMG" bs=1 seek="$ANCHOROFF" conv=notrunc status=none

short() { printf '%s' "$1" | awk '{print substr($0,1,8)}'; }
echo "manifest: boot $(short "$HB") kernel $(short "$HK") guest $(short "$HG") root $(short "$ROOT") tag $(short "$TAG") build $BID"
echo "ots: keyid $(printf '%s' "$KID" | awk '{print substr($0,1,16)}') pub $(printf '%s' "$PK" | awk '{print substr($0,1,16)}') sig 2144 bytes (Winternitz-4/SHA-256)"
