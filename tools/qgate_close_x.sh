#!/bin/sh
# End-to-end guest-native close button proof. Outside-guest test only:
# window rendering and close behavior remain entirely in raw NaN16.
set -eu
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nan0s_close_x_$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
cp build/nan0s.img "$T/hda.img"
(
  sleep 7
  echo "screendump $T/open.ppm"
  # The initial terminal is at (60,40), 560px wide: X control is at
  # approximately (612,47), mouse initial guest position (512,384).
  echo "mouse_move 100 0"
  sleep 0.2
  for delta in -100 -100 -100 -37; do
    echo "mouse_move 0 $delta"
    sleep 0.17
  done
  sleep 0.45
  echo "screendump $T/hover.ppm"
  echo "mouse_button 1"
  sleep 0.35
  echo "mouse_button 0"
  sleep 0.9
  echo "screendump $T/closed.ppm"
  sleep 5
  echo "screendump $T/still-closed.ppm"
  echo "sendkey f1"
  sleep 1.0
  echo "screendump $T/relaunch.ppm"
  echo quit
) | timeout 32 qemu-system-i386 -m 128 -boot order=a \
  -drive format=raw,if=floppy,file=build/nan0s.img \
  -drive format=raw,if=ide,file="$T/hda.img" \
  -display none -serial "file:$T/com1.txt" -monitor stdio \
  > "$T/monitor.txt" 2> "$T/qemu.txt"
grep -q 'NaN/0S' "$T/com1.txt"
if grep -Eqi 'unknown command|invalid command' "$T/monitor.txt"; then
  echo "FAIL: PS/2 mouse/keyboard commands unsupported"
  exit 1
fi
python3 - "$T" <<'PY'
from pathlib import Path
import sys
folder=Path(sys.argv[1])
def read(name):
    with (folder/f'{name}.ppm').open('rb') as f:
        assert f.readline().strip()==b'P6'
        size=f.readline().strip()
        while size.startswith(b'#'): size=f.readline().strip()
        assert size==b'1024 768'
        assert f.readline().strip()==b'255'
        pixels=f.read()
    assert len(pixels)==1024*768*3
    return pixels
opened, hovered, closed, still_closed, relaunched=(read(x) for x in
    ('open','hover','closed','still-closed','relaunch'))
def differences(a,b,region):
    x0,y0,x1,y1=region
    return sum(a[(y*1024+x)*3:(y*1024+x)*3+3] !=
               b[(y*1024+x)*3:(y*1024+x)*3+3]
               for y in range(y0,y1) for x in range(x0,x1))
rect=(50,30,630,420)
removed=differences(hovered,closed,rect)
idle=differences(closed,still_closed,rect)
reopened=differences(still_closed,relaunched,(170,110,850,560))
print(f'Native X close: {removed} window pixels changed')
print(f'After 5 seconds closed: {idle} window pixels changed')
print(f'Guest launcher survives final close: {reopened} pixels changed')
assert removed>12000, 'Native X button did not close the last terminal window'
# No window may reappear after the button is released; the only changing
# pixels in the window region should be the animated guest mouse cursor.
assert idle<300, 'Closed window revived or re-rendered itself without an open event'
assert reopened>10000, 'Guest desktop/launcher did not survive closing final window'
print('PASS: pure NaN16 title-bar X closes last window; F1 launcher remains functional')
PY
