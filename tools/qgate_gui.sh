#!/bin/sh
# qgate_gui.sh - x86 bare-metal GUI gate.
# Boots the floppy image, attaches the same image as the primary IDE master,
# lets the kernel ATA loader pull the full guest stream, and requires the
# 1024x768 GUI mode (the text-mode fallback is 720x400).
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nan0s_qgate_gui"
rm -rf "$T"; mkdir -p "$T"
[ -f build/nan0s.img ] || { echo "qgate_gui: build/nan0s.img missing"; exit 1; }
cp build/nan0s.img "$T/disk.img"
{ sleep 6; echo "screendump $T/gui.ppm"; sleep 1; echo quit; } | \
  timeout 30 qemu-system-i386 -m 32 -boot order=a \
    -drive format=raw,if=floppy,file=build/nan0s.img \
    -drive format=raw,if=ide,file="$T/disk.img" \
    -display none -serial "file:$T/com1.txt" -monitor stdio \
    >"$T/mon.txt" 2>"$T/err" || true
grep -q "NaN/0S" "$T/com1.txt" || { echo "qgate_gui: banner MISSING"; exit 1; }
wh=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$T/gui.ppm" 2>/dev/null || true)
[ "$wh" = "1024,768" ] || { echo "qgate_gui: GUI framebuffer missing (got ${wh:-none})"; exit 1; }
echo "qgate_gui: PASS (x86 GUI + ATA guest loader)"
