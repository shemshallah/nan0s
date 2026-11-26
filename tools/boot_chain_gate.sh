#!/bin/sh
# boot_chain_gate.sh - enforce the minimal runtime boot boundary.
#
# Product runtime: BIOS -> 512-byte boot -> native NaN16 core -> guest .nan.
# No C harness, POSIX runtime, awk or ELF object between them.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C

[ -f build/nan0s.img ] || {
  echo "boot_chain: FAIL (build/nan0s.img missing; run tools/build.sh)"; exit 1; }
[ "$(wc -c < build/nan0s.img)" -eq 1474560 ] || {
  echo "boot_chain: FAIL (image is not a 1.44 MiB floppy)"; exit 1; }
sig=$(od -An -tx1 -j510 -N2 build/nan0s.img | tr -d ' \n')
[ "$sig" = "55aa" ] || {
  echo "boot_chain: FAIL (missing 55 AA boot signature: $sig)"; exit 1; }

if LC_ALL=C grep -aq "$(printf '\177ELF')" build/nan0s.img; then
  echo "boot_chain: FAIL (ELF object inside product image)"; exit 1
fi

head -1 src/native/nan16_x86.nan | grep -q 'NaN16 gold' || {
  echo "boot_chain: FAIL (native NaN gold core missing)"; exit 1; }
head -1 src/nan/gui_cart.nan | grep -q 'NaN16 guest program' || {
  echo "boot_chain: FAIL (guest cart is not a .nan image)"; exit 1; }

if grep -nE 'clang|gcc|(^|[^A-Za-z])cc([^A-Za-z]|$)|s1_kabi' \
    tools/build.sh tools/mkall.sh tools/mkbase.sh tools/nmkfs.sh tools/rootfs_seed.sh \
    >/dev/null 2>&1; then
  echo "boot_chain: FAIL (C compiler or S1 C harness referenced by product build)"
  grep -nE 'clang|gcc|(^|[^A-Za-z])cc([^A-Za-z]|$)|s1_kabi' \
    tools/build.sh tools/mkall.sh tools/mkbase.sh tools/nmkfs.sh tools/rootfs_seed.sh || true
  exit 1
fi

# The raw-only gate covers guest source trees and carts.
sh tools/guest_raw_only_gate.sh >/dev/null

echo "boot_chain: PASS (BIOS -> 512-byte boot -> native NaN16 core -> guest .nan; no C/ELF runtime)"
