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

# PS/2 set-1 scancodes: the GUI keyboard driver reads raw make codes, unlike
# the text shell's BYTE KEY stream.  Type the NANIX POSIX command transcript
# after kbd_init so the desktop's Terminal exercises the same native
# bare_fs_* service layer as the ESC text shell.
KEYS='\x23\x12\x26\x19\x1c\x32\x25\x20\x17\x13\x39\x35\x2d\x1c\x11\x13\x17\x14\x12\x39\x35\x2d\x35\x1e\x39\x23\x12\x26\x26\x18\x1c\x2e\x1e\x14\x39\x35\x2d\x35\x1e\x1c\x26\x1f\x39\x35\x2d\x1c\x1f\x14\x1e\x14\x39\x35\x2d\x35\x1e\x1c\x14\x13\x16\x31\x2e\x1e\x14\x12\x39\x35\x2d\x35\x1e\x39\x03\x1c\x2e\x1e\x14\x39\x35\x2d\x35\x1e\x1c\x13\x32\x39\x35\x2d\x35\x1e\x1c\x13\x32\x20\x17\x13\x39\x35\x2d\x1c'

S1_FB_DELAY="${NAN0S_GUI64_DELAY:-30}" \
sh tools/s1_runner.sh --img "$T/guest.bin" --mem "${NAN0S_GUI64_MEM:-128}" \
    --steps "${NAN0S_GUI64_STEPS:-400000000}" --serial \
    --key-delay 5000000 --keys "$KEYS" \
    --dump-fb "$T/fb.bin" --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/run.out" 2> "$T/run.err" || true

[ -s "$T/fb.bin" ] || { echo "nan0s_gui64: FAIL (no framebuffer dump)"; tail -5 "$T/run.err"; exit 1; }
[ -s "$T/term.bin" ] || { echo "nan0s_gui64: FAIL (no Terminal buffer dump)"; tail -5 "$T/run.err"; exit 1; }
python3 - "$T/fb.bin" "$T/term.bin" <<'PY'
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

# Terminal private buffer: 128 cells x 64 rows, one character per NaN word.
tb = open(sys.argv[2], 'rb').read()
rows = []
for r in range(64):
    ch = []
    for c in range(128):
        off = (r * 128 + c) * 8
        w = int.from_bytes(tb[off:off+8], 'little')
        v = (w >> 16) & 0xffffffff
        ch.append(chr(v) if 0 < v < 128 else ' ')
    rows.append(''.join(ch).rstrip())
want = [
    'NANIX POSIX shell',
    '> mkdir /x', 'ok',
    '> write /x/a hello', 'saved',
    '> cat /x/a', 'hello',
    '> ls /x', 'a',
    '> stat /x/a', 'file size=5 mode=33188',
    '> truncate /x/a 2', 'ok',
    '> cat /x/a', 'he',
    '> rm /x/a', 'removed',
    '> rmdir /x', 'removed',
]
for w in want:
    if not any(line == w for line in rows):
        raise SystemExit("nan0s_gui64: FAIL (Terminal transcript missing %r)\n%s" %
                         (w, '\n'.join(x for x in rows if x)))
print("nan0s_gui64: PASS (NaN/0S desktop + NANIX POSIX Terminal on x86_64 S1; total=%d terminal=%d)" % (total, term))
PY
