#!/bin/sh
# SCAFFOLD build: base image (nasm0 proofs), generated Baby data, then the unified image. See tools/mkall.sh for the image rule (max 2 images in build/).
set -e
cd "$(dirname "$0")/.."
sh tools/mkbase.sh
awk -f tools/nmk.awk -v CMD=emit src/museum/museum.nas > src/nan/museum.nan
# Reassemble the actual GUI source before packing it into the boot image.
# Previously builds reused a stale checked-in gui_cart.nan, so fixing a .nas
# terminal/browser bug did not fix the publicly deployed full guest.
awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_cart.nas > src/nan/gui_cart.nan
# The native compiler and filesystem reserve words 63000..64999.
[ "$(wc -l < src/nan/gui_cart.nan)" -le 63001 ] || { echo "GUI code overlaps native C scratch" >&2; exit 1; }
sh tools/mkall.sh
# default NaNFS volume (raw ATA volume; guest reads it over ATA PIO LBA28 with nanfs_read):
# third kind of disk, NOT one of the two bootable images in the image rule
sh tools/nmkfs.sh src/tests/nfix_test.nas build/disk.nanfs
[ -d aarch64/android/app/src/main/assets ] && cp build/disk.nanfs aarch64/android/app/src/main/assets/disk.nanfs
[ -d x86/build ] && cp build/disk.nanfs x86/build/disk.nanfs
# published live demo (docs/ is the GitHub Pages site): keep nan0s.img beside index.html
[ -d docs ] && cp build/nan0s.img docs/nan0s.img
# the APK ships the same image (assets/ held a stale copy until r29m)
[ -d aarch64/android/app/src/main/assets ] && cp build/nan0s.img aarch64/android/app/src/main/assets/nan0s.img
