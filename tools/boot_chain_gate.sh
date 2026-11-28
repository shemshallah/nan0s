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
[ "$(wc -c < build/nan0s.img)" -ge 1474560 ] || {
  echo "boot_chain: FAIL (image is smaller than the 1.44 MiB boot window)"; exit 1; }
sig=$(od -An -tx1 -j510 -N2 build/nan0s.img | tr -d ' \n')
[ "$sig" = "55aa" ] || {
  echo "boot_chain: FAIL (missing 55 AA boot signature: $sig)"; exit 1; }

if LC_ALL=C grep -aq "$(printf '\177ELF')" build/nan0s.img; then
  echo "boot_chain: FAIL (ELF object inside product image)"; exit 1
fi

head -1 src/native/nan16_x86.nan | grep -q 'NaN16 gold' || {
  echo "boot_chain: FAIL (native NaN gold core missing)"; exit 1; }
[ -f src/nan/nixsched.nan ] || {
  echo "boot_chain: FAIL (generated guest image missing; run tools/build.sh)"; exit 1; }
grep -qE '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' src/nan/nixsched.nan || {
  echo "boot_chain: FAIL (generated guest is not a .nan word stream)"; exit 1; }
# GUI cart: one source, reused at word 8192 by both the 32-bit and 64-bit
# host images (the guest ISA is unchanged).
[ -f src/gui/gui_cart.nas ] &&
  grep -q 'NaN/0S GUI CARTRIDGE' src/gui/gui_cart.nas &&
  grep -q 'include "gui_cart.nas"' src/gui/gui_sched_boot.nas || {
  echo "boot_chain: FAIL (GUI cart source not embedded by gui_sched_boot)"; exit 1; }
gui=$(grep -E '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' src/nan/nixsched.nan | sed -n '8193p')
case "$gui" in
  ''|0000_00000000_0000|7FF8_00000000_F87F)
    echo "boot_chain: FAIL (GUI cart word 8192 missing from the guest)"; exit 1 ;;
esac

if grep -nE 'clang|gcc|(^|[^A-Za-z])cc([^A-Za-z]|$)|s1_kabi|nan_cli' \
    tools/build.sh tools/mkall.sh tools/mkbase.sh tools/nmkfs.sh tools/rootfs_seed.sh \
    >/dev/null 2>&1; then
  echo "boot_chain: FAIL (C compiler, S1 harness or nan_cli adapter referenced by product build)"
  grep -nE 'clang|gcc|(^|[^A-Za-z])cc([^A-Za-z]|$)|s1_kabi|nan_cli' \
    tools/build.sh tools/mkall.sh tools/mkbase.sh tools/nmkfs.sh tools/rootfs_seed.sh || true
  exit 1
fi
if LC_ALL=C grep -aq 'nan_cli\|NAN_CLI' build/nan0s.img; then
  echo "boot_chain: FAIL (nan_cli adapter marker inside product image)"; exit 1
fi

# The raw-only gate covers guest source trees and carts.
sh tools/guest_raw_only_gate.sh >/dev/null

echo "boot_chain: PASS (BIOS -> 512-byte boot -> native NaN16 core -> guest .nan; no C/ELF runtime)"
