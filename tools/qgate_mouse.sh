#!/bin/sh
# PS/2 AUX mouse framebuffer acceptance gate. This is an OUTSIDE-guest
# QEMU test driver; the mouse stack, cursor, hit tests, drag and resize
# operate ONLY in native raw NaN16 src/lib/mouse.nas.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nan0s_mouse_$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
cp build/nan0s.img "$T/source.img"
(
  sleep 7
  echo "screendump $T/initial.ppm"
  sleep 1
  echo "mouse_move 90 30"
  sleep 3
  echo "screendump $T/moved.ppm"
  sleep 1
  echo "mouse_move -60 -20"
  sleep 2
  echo "screendump $T/returned.ppm"
  sleep 0.4
  # The NaN16 mouse begins at (512,384). After the two movements it is
  # near (542,394). Move to the bottom-left taskbar launcher by several
  # bounded PS/2 packets (large deltas would set overflow bits).
  for shift in -120 -120 -120 -120 -40; do
    echo "mouse_move $shift 0"
    sleep 0.18
  done
  for shift in 90 90 90 90; do
    echo "mouse_move 0 $shift"
    sleep 0.18
  done
  sleep 1
  echo "screendump $T/taskbar-hover.ppm"
  echo "mouse_button 1"
  sleep 0.3
  echo "mouse_button 0"
  sleep 2
  echo "screendump $T/taskbar-click.ppm"
  sleep 0.2
  echo quit
) | timeout 45 qemu-system-i386 -m 128 -boot order=a \
  -drive format=raw,if=floppy,file=build/nan0s.img \
  -drive format=raw,if=ide,file="$T/source.img" \
  -display none -serial "file:$T/serial.txt" -monitor stdio \
  > "$T/monitor.log" 2> "$T/qemu.log"

grep -q 'NaN/0S' "$T/serial.txt"
if grep -Eqi 'unknown command|invalid command|has not been found' "$T/monitor.log"; then
  echo "FAIL: QEMU monitor cannot inject virtual PS/2 mouse movement"
  tail -35 "$T/monitor.log"
  exit 1
fi

python3 - "$T" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def read(name):
    with (root / f"{name}.ppm").open("rb") as stream:
        assert stream.readline().strip() == b"P6"
        head = stream.readline().strip()
        while head.startswith(b"#"): head = stream.readline().strip()
        assert head == b"1024 768", (name, head)
        assert stream.readline().strip() == b"255"
        data = stream.read()
    assert len(data) == 1024 * 768 * 3
    return data
a,b,c,hover,clicked=(read(n) for n in ("initial","moved","returned","taskbar-hover","taskbar-click"))
def changed(x,y,box):
    x0,y0,x1,y1=box
    count=0
    for yy in range(y0,y1):
        for xx in range(x0,x1):
            i=(yy*1024+xx)*3
            if x[i:i+3]!=y[i:i+3]: count+=1
    return count
# Cursor begins at guest (512,384). Relative movement should redraw
# native pointer pixels in this central region. Ignore the top bar clock.
central=(480,320,650,450)
ab=changed(a,b,central)
bc=changed(b,c,central)
print(f"NaN16 PS/2 mouse framebuffer: initial->moved {ab} pixels, moved->returned {bc} pixels")
assert ab>30, "Moving real PS/2 mouse did not change NaN/0S framebuffer"
assert bc>30, "Second PS/2 movement did not redraw NaN/0S framebuffer"
launcher_region=(178,115,835,550)
opened=changed(hover,clicked,launcher_region)
print(f"NaN16 taskbar launcher click: {opened} pixels changed in native app-grid region")
assert opened>10000, "Clicking the native taskbar launcher did not open the guest NaN16 app grid"
print("PASS: real PS/2 AUX movement, click transition, native taskbar hit test and app-grid opening")
PY
