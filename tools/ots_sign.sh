#!/bin/sh
# tools/ots_sign.sh - sign a 32-byte manifest root with the offline master seed.
#
# Usage: sh tools/ots_sign.sh ROOTHEX OUTDIR
#   ROOTHEX  64 lowercase/uppercase hex chars (a SHA-256 root)
#   OUTDIR   receives sig.hex (4288 chars), pub.hex, kid.hex, anchor.hex
#
# The one-time chains are derived per root, so signing is deterministic for a
# given (master, root) and two different roots never share a chain.  The
# master seed is read from build/ots/master.hex (or OTS_MASTER); it is never
# written to the image.  The signature is self-verified with the independent
# verifier path before it is returned.
#
# POSIX sh + gawk + sha256sum only, no C.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
[ $# -eq 2 ] || { echo "usage: ots_sign.sh ROOTHEX OUTDIR" >&2; exit 2; }
ROOT=$1
OUT=$2
case "$ROOT" in
  *[!0-9a-fA-F]*) echo "ots_sign: root is not hex" >&2; exit 1 ;;
esac
[ "${#ROOT}" -eq 64 ] || { echo "ots_sign: root must be 32 bytes (64 hex)" >&2; exit 1; }
MASTER=${OTS_MASTER:-build/ots/master.hex}
[ -f "$MASTER" ] || {
  echo "ots_sign: missing $MASTER; run: sh tools/ots_keygen.sh" >&2; exit 1; }
M=$(sed -n '1p' "$MASTER" | tr -d ' \r\n')
case "$M" in
  *[!0-9a-fA-F]*) echo "ots_sign: master is not hex" >&2; exit 1 ;;
esac
[ "${#M}" -eq 64 ] || { echo "ots_sign: master must be 32 bytes" >&2; exit 1; }
mkdir -p "$OUT"

gawk -f tools/ots.awk -v CMD=sign -v MASTER="$M" -v ROOT="$ROOT" \
  -v SIGOUT="$OUT/sig.hex" -v PUBOUT="$OUT/pub.hex" \
  -v KIDOUT="$OUT/kid.hex" -v ANCHORHEXOUT="$OUT/anchor.hex"
PUB=$(sed -n '1p' "$OUT/pub.hex")
gawk -f tools/ots.awk -v CMD=verify -v ROOT="$ROOT" \
  -v SIGFILE="$OUT/sig.hex" -v PUB="$PUB" >/dev/null ||
  { echo "ots_sign: self-verification FAILED" >&2; exit 1; }
echo "ots_sign: root $(printf '%s' "$ROOT" | awk '{print substr($0,1,16)}') keyid $(sed -n '1p' "$OUT/kid.hex") pub $(printf '%s' "$PUB" | awk '{print substr($0,1,16)}') sig 2144 bytes"
