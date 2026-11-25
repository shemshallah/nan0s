#!/bin/sh
# nan0s_gui64_gate.sh - GUI desktop + Terminal window on x86_64 S1.
#
# Boots the existing OS guest (extracted from build/nan0s.img) on the S1
# machine, lets the GUI cart draw, dumps the 1024x768 8bpp framebuffer via
# QEMU pmemsave, and requires the desktop/Terminal pixels.  The GUI cart
# opens one Terminal window at boot by design.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nan0s_gui64.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

sh tools/mkall.sh > "$T/mkall.log" 2>&1
python3 - "$T/guest.bin" <<'PY'
import sys
d = open('build/nan0s.img', 'rb').read()
words = int.from_bytes(d[504:508], 'little')
open(sys.argv[1], 'wb').write(d[512 + 65536:512 + 65536 + words * 8])
PY

S1_FB_DELAY="${NAN0S_GUI64_DELAY:-10}" \
sh tools/s1_runner.sh --img "$T/guest.bin" --mem "${NAN0S_GUI64_MEM:-128}" \
    --steps "${NAN0S_GUI64_STEPS:-100000000}" --serial \
    --dump-fb "$T/fb.bin" > "$T/run.out" 2> "$T/run.err" || true

[ -s "$T/fb.bin" ] || { echo "nan0s_gui64: FAIL (no framebuffer dump)"; tail -5 "$T/run.err"; exit 1; }
python3 - "$T/fb.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
W, H = 1024, 768
fb = d[:W*H]
if len(fb) < W*H:
    raise SystemExit("nan0s_gui64: FAIL (short framebuffer %d)" % len(fb))
def count(x0, y0, x1, y1):
    n = 0
    for y in range(y0, y1):
        row = fb[y*W:(y+1)*W]
        n += sum(1 for b in row[x0:x1] if b)
    return n
total = sum(1 for b in fb if b)
term = count(60, 40, 624, 392)
if total < 20000:
    raise SystemExit("nan0s_gui64: FAIL (framebuffer nearly blank: %d pixels)" % total)
if term < 5000:
    raise SystemExit("nan0s_gui64: FAIL (Terminal window region blank: %d pixels)" % term)
print("nan0s_gui64: PASS (GUI desktop + Terminal window on x86_64 S1; total=%d terminal=%d)" % (total, term))
PY
