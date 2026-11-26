#!/bin/sh
# tools/nfs_persist_gate.sh - NPAF snapshot persistence across a same-disk reboot.
#
# Native x86 image path (qemu-system-i386).  The gold boot loader pulls the
# guest payload from the primary IDE master, so the disk starts as a copy of
# the boot image; the NPAF snapshot lives at LBA 2048, past that payload.
#
# Boot 1: no snapshot -> gui_cart-equivalent nfs_load miss, nfs_format, seed
#         the committed nanfs/ root, create /persist.txt, nfs_save.
# Host:   tools/rootfs_sync.sh --check parses the snapshot header/arena and
#         --out unpacks it; every seeded file is byte-compared with nanfs/.
# Boot 2: same disk -> nfs_load hit, /persist.txt is read from the snapshot.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T="${TMPDIR:-$ROOT/tmp}/nfs_persist_gate.$$"
rm -rf "$T"; mkdir -p "$T"
if [ "${NFS_PERSIST_KEEP:-0}" = 1 ]; then
  trap 'echo "nfs_persist: kept $T" >&2' EXIT INT TERM
else
  trap 'rm -rf "$T"' EXIT INT TERM
fi
QEMU_BIN=${QEMU:-qemu-system-i386}
command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  echo "nfs_persist: FAIL (no $QEMU_BIN)" >&2; exit 1; }
TIMEOUT=${NFS_PERSIST_TIMEOUT:-20}

# 1. Assemble the boot probe and a bootable x86 image around the gold core.
gawk -f tools/nmk.awk -v CMD=emit src/tests/nfs_persist_test.nas > "$T/persist.nan" 2>/dev/null
gawk -f tools/nmk.awk -v CMD=check "$T/persist.nan" >/dev/null 2>&1
: > "$T/carts.txt"
gawk -f tools/mkimg.awk \
  -v GOLD=src/native/nan16_x86.nan \
  -v GUEST="$T/persist.nan" -v CARTS="$T/carts.txt" \
  -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" >/dev/null 2>&1
cat "$T/boot.bin" "$T/guest.bin" > "$T/boot.img"
truncate -s 1474560 "$T/boot.img"
# The disk boots the same guest payload and leaves LBA 2048+ for the store.
cp "$T/boot.img" "$T/disk.img"

run_disk() { # $1 = serial log
  timeout "$TIMEOUT" "$QEMU_BIN" -m 512 -boot order=a \
    -drive format=raw,if=floppy,file="$T/boot.img" \
    -drive format=raw,if=ide,index=0,file="$T/disk.img" \
    -display none -serial "file:$1" -no-reboot >/dev/null 2>&1 || true
}

# 2. First boot creates the seeded store plus a runtime file and snapshots it.
run_disk "$T/boot1.log"
grep -qx 'PERSIST FIRST OK' "$T/boot1.log" || {
  echo "nfs_persist: FAIL (first boot did not format+seed+save)" >&2
  cat "$T/boot1.log" >&2; exit 1; }
echo "nfs_persist: first boot -> PERSIST FIRST OK"

# 3. Direct host parse of the snapshot written by the guest.
PARSE=$(sh tools/rootfs_sync.sh --disk "$T/disk.img" --check)
echo "nfs_persist: host parse -> $PARSE"
sh tools/rootfs_sync.sh --disk "$T/disk.img" --out "$T/unpack" >/dev/null
[ "$(cat "$T/unpack/persist.txt")" = "persist-ok-2026" ] || {
  echo "nfs_persist: FAIL (host unpack has the wrong /persist.txt)" >&2; exit 1; }
SEEDED=0
for f in nanfs/*; do
  [ -f "$f" ] || continue
  cmp -s "$f" "$T/unpack/$(basename "$f")" || {
    echo "nfs_persist: FAIL (seed file $(basename "$f") differs after round-trip)" >&2
    exit 1; }
  SEEDED=$((SEEDED + 1))
done
[ "$SEEDED" -gt 0 ] || { echo "nfs_persist: FAIL (nanfs/ is empty)" >&2; exit 1; }
echo "nfs_persist: host unpack -> $SEEDED seeded files byte-identical, /persist.txt present"

# 4. Reboot the same disk: only nfs_load may restore the store.
run_disk "$T/boot2.log"
grep -qx 'PERSIST LOADED' "$T/boot2.log" || {
  echo "nfs_persist: FAIL (second boot took the format path)" >&2
  cat "$T/boot2.log" >&2; exit 1; }
grep -qx 'persist-ok-2026' "$T/boot2.log" || {
  echo "nfs_persist: FAIL (/persist.txt missing after reboot)" >&2
  cat "$T/boot2.log" >&2; exit 1; }
grep -qx 'PERSIST REBOOT OK' "$T/boot2.log" || {
  echo "nfs_persist: FAIL (second boot did not report success)" >&2
  cat "$T/boot2.log" >&2; exit 1; }
echo "nfs_persist: reboot same disk -> $(tr '\n' ' ' < "$T/boot2.log")"
echo "nfs_persist: PASS (NPAF LBA 2048 snapshot, 2 boots, $SEEDED seed files)"
