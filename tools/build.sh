#!/bin/sh
# SCAFFOLD build: base image (nasm0 proofs), generated Baby data, then the unified image. See tools/mkall.sh for the image rule (max 2 images in build/).
set -e
cd "$(dirname "$0")/.."
# Product guest sources are raw NaN16: .nas/.nan (and the native x86 boot
# trampoline .xa).  C, .s/.S assembly or objects in these trees would mean a
# host artifact leaked into the system; refuse to build.
for d in src/nan src/nix src/lib src/gui src/trust src/boot; do
  bad=$(find "$d" -type f \( -name '*.c' -o -name '*.s' -o -name '*.S' -o -name '*.o' \) -print -quit)
  if [ -n "$bad" ]; then
    echo "build: non-NaN source in $d: $bad" >&2
    exit 1
  fi
done
sh tools/mkbase.sh
sh tools/rootfs_seed.sh
# The product guest is the flat scheduler image: GUI desktop at 0x2000,
# kernel/scheduler at 0x10000 and the NANIX shell at 0x80000.  It is packed
# without a cart TOC so the desktop code at word 22000 is not overwritten.
awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas > src/nan/nixsched.nan
# Keep the Trusting Trust cart as a source artifact for the later conversion.
awk -f tools/nmk.awk -v CMD=emit src/trust/trust_cart.nas > src/nan/trust_cart.nan
sh tools/mkall.sh
# default NaNFS volume (raw ATA volume; guest reads it over ATA PIO LBA28 with nanfs_read):
# third kind of disk, NOT one of the two bootable images in the image rule
sh tools/nmkfs.sh src/tests/nfix_test.nas build/disk.nanfs
[ -d aarch64/android/app/src/main/assets ] && cp build/disk.nanfs aarch64/android/app/src/main/assets/disk.nanfs
# published live demo (docs/ is the GitHub Pages site): keep nan0s.img beside index.html
# the APK ships the same image (assets/ held a stale copy until r29m)
[ -d aarch64/android/app/src/main/assets ] && cp build/nan0s.img aarch64/android/app/src/main/assets/nan0s.img
