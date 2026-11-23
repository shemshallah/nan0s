#!/usr/bin/env bash
# Host-only acceptance harness. The image builder itself is exclusively
# NaN16 code in src/lib/bootbuild.nas, executing inside the booted guest.
# Prove: guest receives 'build nan0s', writes an independent IDE slave,
# verifies every sector, and the resulting disk boots in a fresh QEMU VM.
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nan0s_bootbuild_$$_$RANDOM"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
test -s build/nan0s.img
cp build/nan0s.img "$T/master.img"
truncate -s 1474560 "$T/output.img"
: > "$T/serial.txt"
echo "nanbuild: boot original, keep master separate, build on IDE slave"
(
  sleep 5
  # Enter the complete command into the GUI's NaN16 terminal.
  for key in b u i l d spc n a n 0 s ret; do
    echo "sendkey $key"
    sleep 0.2
  done
  # Do not terminate the guest until it reports the NaN-side readback check.
  i=0
  while [ "$i" -lt 170 ]; do
    if grep -q 'NANBUILD OK' "$T/serial.txt"; then
      echo "screendump $T/finished.ppm"
      sleep 0.4
      break
    fi
    if grep -q 'NANBUILD FAIL' "$T/serial.txt"; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  echo quit
) | timeout 205 qemu-system-i386 -m 128 -boot order=a \
  -drive format=raw,if=floppy,file=build/nan0s.img \
  -drive format=raw,if=ide,index=0,file="$T/master.img" \
  -drive format=raw,if=ide,index=1,file="$T/output.img" \
  -display none -serial "file:$T/serial.txt" -monitor stdio \
  > "$T/monitor.log" 2> "$T/qemu.log"

if ! grep -q 'NANBUILD OK' "$T/serial.txt"; then
  echo "nanbuild: guest did not verify complete output"
  tail -c 2000 "$T/serial.txt" || :
  tail -c 2000 "$T/qemu.log" || :
  exit 1
fi
test "$(stat -c %s "$T/output.img")" -eq 1474560
test "$(dd if="$T/output.img" bs=1 skip=510 count=2 status=none | od -An -tx1 | tr -d ' \n')" = 55aa
if ! cmp "$T/master.img" "$T/output.img"; then
  echo "nanbuild: output differs from the guest's IDE source"
  exit 1
fi
echo "nanbuild: NaN16 guest verified all 2880 sectors; complete images match"
sha256sum "$T/master.img" "$T/output.img"

# Independently reboot the resulting image from its own boot sector.
cp "$T/output.img" "$T/second-stage-ide.img"
(
  sleep 7
  echo "screendump $T/reboot.ppm"
  sleep 1
  echo quit
) | timeout 24 qemu-system-i386 -m 128 -boot order=a \
  -drive format=raw,if=floppy,file="$T/output.img" \
  -drive format=raw,if=ide,index=0,file="$T/second-stage-ide.img" \
  -display none -serial "file:$T/reboot-serial.txt" -monitor stdio \
  > "$T/reboot-monitor.log" 2> "$T/reboot-qemu.log"
grep -q 'NaN/0S' "$T/reboot-serial.txt"
test -s "$T/reboot.ppm"
dimensions=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$T/reboot.ppm")
test "$dimensions" = "1024,768"
echo "PASS: raw NaN16 created a complete, verified, independently bootable NaN/0S replica"
