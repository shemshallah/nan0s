#!/bin/sh
# End-to-end x86 GUI test: type 'n' ENTER (NaNNet) and 'b' ENTER (browser),
# then ESC each. Distinct framebuffer states prove guest GUI continues to
# process input rather than trapping or hanging in a window initializer.
set -eu
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nan0s_gui_commands_$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
test -s build/nan0s.img
cp build/nan0s.img "$T/ide.img"
(
  sleep 5
  echo "screendump $T/start.ppm"
  sleep 0.4
  echo "sendkey n"
  sleep 0.4
  echo "sendkey ret"
  sleep 4
  echo "screendump $T/net.ppm"
  sleep 0.4
  echo "sendkey esc"
  sleep 3
  echo "screendump $T/after-net.ppm"
  sleep 0.4
  echo "sendkey b"
  sleep 0.4
  echo "sendkey ret"
  sleep 4
  echo "screendump $T/browser.ppm"
  sleep 0.4
  echo "sendkey esc"
  sleep 3
  echo "screendump $T/after-browser.ppm"
  sleep 0.4
  echo quit
) | timeout 45 qemu-system-i386 -m 512 -boot order=a \
  -drive format=raw,if=floppy,file=build/nan0s.img \
  -drive format=raw,if=ide,file="$T/ide.img" \
  -display none -serial "file:$T/com1.txt" -monitor stdio \
  > "$T/monitor.txt" 2> "$T/error.txt" || {
    cat "$T/error.txt"
    exit 1
  }
grep -q 'NaN/0S' "$T/com1.txt"
python3 - "$T" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])

def ppm(name):
    path = root / (name + ".ppm")
    assert path.is_file(), "Missing QEMU framebuffer " + str(path)
    with path.open("rb") as f:
        assert f.readline().strip() == b"P6", "Expected P6 framebuffer"
        size = f.readline().split()
        while size[0].startswith(b"#"):
            size = f.readline().split()
        w, h = map(int, size)
        assert f.readline().strip() == b"255"
        data = f.read()
    assert (w, h) == (1024, 768), f"{name}: GUI size is {w}x{h}"
    assert len(data) == w * h * 3, f"{name}: incomplete image"
    return data

frames = {name: ppm(name) for name in
          ("start", "net", "after-net", "browser", "after-browser")}
def changed(before, after):
    # Ignore clock and title bar; compare pixels in the guest window area.
    start, end = 80 * 1024 * 3, 760 * 1024 * 3
    a, b = frames[before][start:end], frames[after][start:end]
    return sum(a[i:i+3] != b[i:i+3] for i in range(0, len(a), 3))

for a, b in (("start", "net"), ("net", "after-net"),
             ("after-net", "browser"), ("browser", "after-browser")):
    count = changed(a, b)
    print(f"{a} -> {b}: {count} changed GUI pixels")
    assert count > 2000, f"Guest did not visibly handle {a} -> {b}"
print("PASS: n + Enter, Esc, b + Enter, Esc all responsive with 1024x768 GUI")
PY
