#!/bin/sh
# nhost_product_gate.sh - nhost's guest packs to the exact shipped image.
#
# The guest is emitted by the self-hosted nhost bootstrap
# (tools/nhost_emit_guest.sh), packed with the hermetic tools/mkall.sh, and
# compared byte-for-byte with build/nan0s.img.  nan_cli is an ORACLE machine
# here; this gate does not replace the committed product build.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nhost_product.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

[ -f build/nan0s.img ] || {
  echo "nhost_product_gate: FAIL (build/nan0s.img missing; run tools/build.sh)"; exit 1; }

# NHOST_NATIVE=1 runs the complete stage0 -> stage1 -> full guest chain on the
# raw native core (~21 min); the default uses the nan_cli bootstrap oracle.
[ "${NHOST_NATIVE:-0}" = 1 ] && export NHOST_NATIVE
sh tools/nhost_emit_guest.sh src/gui/gui_sched_boot.nas "$T/nixsched.nan"
n=$(wc -l < "$T/nixsched.nan")
[ "$n" -eq 530842 ] ||
  { echo "nhost_product_gate: FAIL (guest is $n words, want 530842)"; exit 1; }

NAN0S_IMG="$T/nan0s.img" NAN0S_GUEST="$T/nixsched.nan" TMPDIR="$T/tmp" \
  sh tools/mkall.sh > "$T/mkall.out" 2> "$T/mkall.err" ||
  { cat "$T/mkall.err" >&2; exit 1; }

cmp -s "$T/nan0s.img" build/nan0s.img || {
  echo "nhost_product_gate: FAIL (nhost guest packs to a different image)"; exit 1; }
echo "nhost_product_gate: ORACLE MATCH ($n words; nhost guest packs to the shipped build/nan0s.img)"
