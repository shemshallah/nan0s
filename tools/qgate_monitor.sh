#!/bin/sh
# Outside-guest boot regression: monitor timers must respect native z-order.
set -eu
cd "$(dirname "$0")/.."
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp build/nan0s.img "$T/hda.img"
(
  sleep 7
  echo "screendump $T/base.ppm"
  echo "sendkey f1"
  sleep 0.5
  echo "sendkey 3"
  sleep 1
  echo "screendump $T/open.ppm"
  echo "sendkey ctrl-1"
  sleep 0.8
  echo "screendump $T/behind.ppm"
  sleep 2
  echo "screendump $T/behind-later.ppm"
  echo "sendkey ctrl-2"
  sleep 0.5
  echo "sendkey f8"
  sleep 0.8
  echo "screendump $T/hidden.ppm"
  sleep 2
  echo "screendump $T/hidden-later.ppm"
  echo "sendkey ctrl-2"
  sleep 0.8
  echo "screendump $T/restored.ppm"
  # Centered monitor x=387, width=250; X at (629,47).
  echo "mouse_move 117 0"
  sleep 0.2
  for d in -100 -100 -100 -37; do
    echo "mouse_move 0 $d"
    sleep 0.17
  done
  sleep 0.5
  echo "mouse_button 1"
  sleep 0.3
  echo "mouse_button 0"
  sleep 0.8
  echo "screendump $T/closed.ppm"
  sleep 3
  echo "screendump $T/closed-later.ppm"
  echo "sendkey f1"
  sleep 0.5
  echo "sendkey 3"
  sleep 0.8
  echo "screendump $T/reopened.ppm"
  echo quit
) | timeout 45 qemu-system-i386 -m 128 -boot order=a \
  -drive format=raw,if=floppy,file=build/nan0s.img \
  -drive format=raw,if=ide,file="$T/hda.img" \
  -display none -serial "file:$T/serial" -monitor stdio >"$T/monitor" 2>"$T/qemu"
grep -q 'NaN/0S' "$T/serial"
! grep -Eqi 'unknown command|invalid command' "$T/monitor"
python3 - "$T" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
def read(n):
    with (root/(n+'.ppm')).open('rb') as f:
        assert f.readline().strip()==b'P6'
        dims=f.readline().strip()
        while dims.startswith(b'#'):
            dims=f.readline().strip()
        assert dims==b'1024 768'
        assert f.readline().strip()==b'255'
        data=f.read()
        assert len(data)==1024*768*3
        return data
def diff(a,b,box):
    a,b=read(a),read(b)
    x0,y0,x1,y1=box
    return sum(a[3*(y*1024+x):3*(y*1024+x)+3]!=b[3*(y*1024+x):3*(y*1024+x)+3]
               for y in range(y0,y1) for x in range(x0,x1))
body=(389,60,635,135)
overlap=(389,60,615,135)
assert diff('base','open',body)>1000, 'monitor failed to open'
assert diff('open','behind',overlap)>500, 'terminal failed to cover monitor'
assert diff('behind','behind-later',overlap)<100, 'monitor drew through foreground terminal'
assert diff('hidden','hidden-later',body)<100, 'hidden monitor continued drawing'
assert diff('base','hidden-later',body)<100, 'minimized monitor left visible content'
assert diff('hidden-later','restored',body)>1000, 'monitor failed to restore'
assert diff('restored','closed',body)>1000, 'monitor X did not close'
assert diff('closed','closed-later',body)<100, 'closed monitor revived'
assert diff('base','closed-later',body)<100, 'closed monitor left visible content'
assert diff('closed-later','reopened',body)>1000, 'explicit monitor reopen failed'
print('PASS: monitor respects focus, minimize, restore, close and explicit reopen')
PY
