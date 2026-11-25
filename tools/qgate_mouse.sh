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
  sleep 0.5
  # Guest pointer is now (22,754). Click the Lattice app tile:
  # first row, second column of native 4x2 launcher at (422,284).
  for shift in 100 100 100 100; do
    echo "mouse_move $shift 0"
    sleep 0.13
  done
  for shift in -100 -100 -100 -100 -70; do
    echo "mouse_move 0 $shift"
    sleep 0.13
  done
  sleep 0.5
  echo "screendump $T/app-hover.ppm"
  echo "mouse_button 1"
  sleep 0.25
  echo "mouse_button 0"
  sleep 1.3
  echo "screendump $T/app-click.ppm"
  # Single-instance launcher centers Lattice at (322,40), 380x300.
  # Move from (422,284) to its actual title bar (422,48).
  for shift in -100 -100 -36; do
    echo "mouse_move 0 $shift"
    sleep 0.16
  done
  sleep 0.7
  echo "screendump $T/before-drag.ppm"
  echo "mouse_button 1"
  sleep 0.2
  echo "mouse_move 80 65"
  sleep 0.6
  echo "mouse_button 0"
  sleep 1.1
  echo "screendump $T/after-drag.ppm"
  sleep 0.5
  # The dragged lattice is now (402,105), 380x300. Its grip is (775,398).
  # Current pointer is (502,113), so use bounded relative movements.
  for shift in 100 100 73; do
    echo "mouse_move $shift 0"
    sleep 0.14
  done
  for shift in 100 100 85; do
    echo "mouse_move 0 $shift"
    sleep 0.14
  done
  sleep 0.5
  echo "screendump $T/before-resize.ppm"
  echo "mouse_button 1"
  sleep 0.25
  echo "mouse_move 45 35"
  sleep 0.65
  echo "mouse_button 0"
  sleep 1.1
  echo "screendump $T/after-resize.ppm"
  # Two windows now overlap. Select the original terminal through taskbar
  # slot zero, then restore the Lattice (slot one) and click its focused
  # taskbar button again to reveal the terminal without closing anything.
  # Pointer after resize is (820,433). Terminal dock target is (190,750).
  for shift in -100 -100 -100 -100 -100 -100 -30; do
    echo "mouse_move $shift 0"
    sleep 0.13
  done
  for shift in 100 100 100 17; do
    echo "mouse_move 0 $shift"
    sleep 0.13
  done
  sleep 0.4
  echo "screendump $T/before-under-focus.ppm"
  echo "mouse_button 1"
  sleep 0.25
  echo "mouse_button 0"
  sleep 0.9
  echo "screendump $T/terminal-focused.ppm"
  echo "mouse_move 106 0"
  sleep 0.25
  echo "mouse_button 1"
  sleep 0.25
  echo "mouse_button 0"
  sleep 0.9
  echo "screendump $T/lattice-refocused.ppm"
  echo "mouse_button 1"
  sleep 0.25
  echo "mouse_button 0"
  sleep 0.9
  echo "screendump $T/lattice-minimized.ppm"
  # Restore the same hidden lattice with another taskbar click.
  echo "mouse_button 1"
  sleep 0.25
  echo "mouse_button 0"
  sleep 0.9
  echo "screendump $T/lattice-restored.ppm"
  # A right click directly in the overlapping content selects the lower
  # window even though the upper window completely covers that point.
  # Slot one pointer is (296,750); the two windows overlap at (500,200).
  for shift in 100 100 4; do
    echo "mouse_move $shift 0"
    sleep 0.13
  done
  for shift in -100 -100 -100 -100 -100 -50; do
    echo "mouse_move 0 $shift"
    sleep 0.13
  done
  sleep 0.5
  echo "screendump $T/before-right-cycle.ppm"
  echo "mouse_button 2"
  sleep 0.28
  echo "mouse_button 0"
  sleep 0.9
  echo "screendump $T/after-right-cycle.ppm"
  # F4 confirmation must be modal. Escape cancels and leaves windows
  # untouched; a later Enter confirms. This also exercises the close API.
  echo "sendkey f4"
  sleep 0.8
  echo "screendump $T/close-dialog.ppm"
  echo "sendkey esc"
  sleep 0.8
  echo "screendump $T/close-canceled.ppm"
  echo "sendkey f4"
  sleep 0.35
  echo "sendkey ret"
  sleep 0.9
  echo "screendump $T/close-confirmed.ppm"
  # Closing the remaining terminal must preserve the native desktop. The
  # guest's launcher remains usable after its last app window disappears.
  echo "sendkey f4"
  sleep 0.35
  echo "sendkey ret"
  sleep 0.9
  echo "screendump $T/final-window-closed.ppm"
  echo "sendkey f1"
  sleep 0.9
  echo "screendump $T/launcher-after-last-close.ppm"
  sleep 0.2
  echo quit
) | timeout 105 qemu-system-i386 -m 128 -boot order=a \
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
a,b,c,hover,clicked,app_hover,app_clicked,before_drag,after_drag,before_resize,after_resize,under_before,under_focus,refocus,minimized,restored,right_before,right_after,dialog,canceled,confirmed,final_closed,launcher_after=(read(n) for n in (
    "initial","moved","returned","taskbar-hover","taskbar-click",
    "app-hover","app-click","before-drag","after-drag","before-resize","after-resize",
    "before-under-focus","terminal-focused","lattice-refocused",
    "lattice-minimized","lattice-restored","before-right-cycle","after-right-cycle",
    "close-dialog","close-canceled","close-confirmed","final-window-closed","launcher-after-last-close"))
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
launched=changed(app_hover,app_clicked,launcher_region)
dragged=changed(before_drag,after_drag,(710,110,780,395))
print(f"NaN16 launcher app-tile activation: {launched} pixels; native title drag: {dragged} pixels")
assert launched>10000, "Native grid click failed to launch an application"
assert dragged>10000, "Native PS/2 title-bar drag did not move a window"
resized=changed(before_resize,after_resize,(787,110,823,400))
print(f"NaN16 window resize grip: {resized} changed framebuffer pixels")
assert resized>1000, "Native PS/2 bottom-right resize grip did not resize the window"
area=(65,56,640,525)
below=changed(under_before,under_focus,area)
back=changed(under_focus,refocus,area)
hidden=changed(refocus,minimized,area)
unhidden=changed(minimized,restored,area)
cycled=changed(right_before,right_after,area)
print(f"NaN16 overlapping-window selection: focus underlying {below}, focus upper {back}, hide upper {hidden}, restore {unhidden}, right-click cycle {cycled}")
assert below>2500, "Taskbar did not raise the fully overlapped terminal window"
assert back>2500, "Taskbar did not restore focus to the upper application"
assert hidden>2500, "Clicking the active taskbar slot did not reveal the underlying window"
assert unhidden>2500, "Clicking minimized slot did not restore the upper window"
assert cycled>2500, "Right-click on overlapping window did not bring the lower window to front"
dialog_change=changed(right_after,dialog,area)
cancel_change=changed(dialog,canceled,area)
close_change=changed(canceled,confirmed,area)
last_change=changed(confirmed,final_closed,area)
relaunch_change=changed(final_closed,launcher_after,(178,115,835,550))
print(f"NaN16 close F4 dialog {dialog_change}; cancel {cancel_change}; confirm {close_change}; final close {last_change}; still-running launcher {relaunch_change}")
assert dialog_change>1000, "F4 did not display a native modal dialog"
assert cancel_change>1000, "Esc did not dismiss a native close dialog"
assert close_change>2500, "Enter did not confirm native window closing"
assert last_change>2500, "Final native window could not be closed"
assert relaunch_change>10000, "Desktop did not survive final window closing and reopen its launcher"
print("PASS: native NaN16 overlap selection, F4 close dialog, Esc cancel, Enter close and desktop relaunch")
PY
