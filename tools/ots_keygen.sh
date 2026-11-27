#!/bin/sh
# tools/ots_keygen.sh - F16b offline Winternitz-4 OTS master seed generator.
#
# The 32-byte master seed is the signing secret.  It is written to
# build/ots/master.hex with mode 0600 and must never enter the image or git.
# Per-manifest one-time keys are derived from it:
#
#   sk_i = SHA-256(master || root || LE32(i) || "NaN0S-F16b-OTS-sk-v1")
#
# so two different manifest roots never share a Winternitz chain.  Rebuilding
# the same root reuses the same one-time key on the same message, which is
# safe; signing two different roots with one derived key is impossible by
# construction.
#
# Usage:
#   sh tools/ots_keygen.sh [--force] [--seed HEX64]
#   OTS_SEED=HEX64 sh tools/ots_keygen.sh --force
#
# No C, no Python: od/tr/gawk/sha256sum only (git/chmod optional).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
umask 077

FORCE=0
SEED=${OTS_SEED:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --seed) shift; [ $# -gt 0 ] || { echo "ots_keygen: --seed needs a value" >&2; exit 2; }; SEED=$1 ;;
    *) echo "usage: ots_keygen.sh [--force] [--seed HEX64]" >&2; exit 2 ;;
  esac
  shift
done

DIR=build/ots
MASTER="$DIR/master.hex"
if [ -e "$MASTER" ] && [ "$FORCE" -ne 1 ]; then
  echo "ots_keygen: $MASTER already exists (use --force to REPLACE the signing key)" >&2
  exit 1
fi

if [ -z "$SEED" ]; then
  command -v od >/dev/null 2>&1 || { echo "ots_keygen: od missing" >&2; exit 1; }
  SEED=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
fi
case "$SEED" in
  *[!0-9a-fA-F]*) echo "ots_keygen: seed is not hex" >&2; exit 1 ;;
esac
[ "${#SEED}" -eq 64 ] || { echo "ots_keygen: seed must be 32 bytes (64 hex chars)" >&2; exit 1; }
# Reject all-zero / constant seeds; they are almost certainly a mistake.
if ! gawk -v S="$SEED" 'BEGIN {
  if (S == sprintf("%064d", 0)) exit 1
  first = substr(S, 1, 2)
  for (i = 1; i <= length(S); i += 2)
    if (substr(S, i, 2) != first) exit 0
  exit 1
}'; then
  echo "ots_keygen: refusing degenerate seed" >&2; exit 1
fi

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git check-ignore -q "$MASTER"; then
    echo "ots_keygen: $MASTER is not git-ignored; refusing to write a secret" >&2
    exit 1
  fi
fi

mkdir -p "$DIR"
printf '%s\n' "$SEED" > "$MASTER"
command -v chmod >/dev/null 2>&1 && chmod 600 "$MASTER"

FP=$(gawk -f tools/ots.awk -v CMD=fingerprint -v MASTER="$SEED")
echo "ots_keygen: wrote $MASTER (0600, git-ignored)"
echo "ots_keygen: master fingerprint $FP"
echo "ots_keygen: next: sh tools/ots_sign.sh <root-hex> <outdir>  (or sh tools/mkall.sh)"
