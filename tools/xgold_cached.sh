#!/bin/sh
# xgold_cached.sh - source-keyed GOLD cache around the slow native rebuild.
#
# The raw xgold/n16i path is a verification path: it interprets nasm1 inside
# the native NaN core under QEMU TCG.  A source-identical rebuild should not
# pay that cost again.  The key covers the kernel source, nasm1 and the GOLD
# producer scripts; a hit restores the checked-in GOLD atomically.
#
# This is an artifact cache, not the block cache.  The block cache (nasm1
# basic blocks -> x86-64, PC-indexed table) is specified in spec/BLOCK_CACHE.md.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
[ "${XGOLD_FORCE:-0}" = 1 ] && exec sh tools/xgold.sh

KEY=$(sha256sum src/native/kan16.xa src/prog/nasm.nas src/prog/nasm0.nas src/prog/nasm0_tables.nas tools/xgold.sh \
      tools/manifest_build.sh tools/manifest_mk.awk 2>/dev/null |
      sha256sum | awk '{print $1}')
CACHE="build/xgold_cache/$KEY"
if [ -f "$CACHE/nan16_x86.nan" ] && [ -f "$CACHE/native64.nan" ]; then
  cp "$CACHE/nan16_x86.nan" src/native/nan16_x86.nan
  cp "$CACHE/native64.nan" x86/native/nan16_x86.nan
  echo "xgold_cached: HIT $KEY"
  exit 0
fi

echo "xgold_cached: MISS $KEY (running raw xgold)"
sh tools/xgold.sh
mkdir -p "$CACHE"
cp src/native/nan16_x86.nan "$CACHE/nan16_x86.nan"
cp x86/native/nan16_x86.nan "$CACHE/native64.nan"
echo "xgold_cached: STORE $KEY"
