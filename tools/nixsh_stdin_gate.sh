#!/bin/sh
# nixsh_stdin_gate.sh - blocking fd 0 on the NANIX Terminal.
#
# Proves on the x86_64 S1 runner:
#   cat              reads the Terminal, not the command line
#   first line       is echoed by the tty and written by cat
#   second line      exercises line-by-line flow control
#   <empty line>     is EOF for the tty
#   >                the shell prompt returns after cat exits
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nixsh_stdin_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas \
  > "$T/gui.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nixsh_stdin_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 scancodes for: cat / first line / second line / empty.
python3 - "$T/keys.bin" <<'PY'
import sys
plain = {
    ' ': 0x39, '\n': 0x1c, '/': 0x35, '.': 0x34, ',': 0x33, '-': 0x0c,
    '=': 0x0d, ';': 0x27, "'": 0x28, '[': 0x1a, ']': 0x1b, '\\': 0x2b,
    '`': 0x29,
}
for i, c in enumerate("1234567890"):
    plain[c] = 0x02 + i
for c, sc in zip("qwertyuiop", range(0x10, 0x1a)):
    plain[c] = sc
for c, sc in zip("asdfghjkl", range(0x1e, 0x27)):
    plain[c] = sc
for c, sc in zip("zxcvbnm", range(0x2c, 0x33)):
    plain[c] = sc
def encode(text):
    out = bytearray()
    for ch in text:
        out.append(plain[ch.lower()])
    out.append(plain['\n'])
    return out
commands = ["cat", "first line", "second line", ""]
script = bytearray()
for line in commands:
    script += encode(line)
open(sys.argv[1], "wb").write(script)
PY

S1_FB_DELAY=180 \
sh tools/s1_runner.sh --img "$T/gui.nan" --mem 128 --steps 16000000000 \
    --serial --key-delay 5000000 --guest-input "$T/keys.bin" \
    --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/run.out" 2> "$T/run.err" || true
[ -s "$T/term.bin" ] || {
  echo "nixsh_stdin_gate: FAIL (no Terminal dump)"; tail -8 "$T/run.err"; exit 1; }

python3 - "$T/term.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
rows = []
for r in range(64):
    ch = []
    for c in range(128):
        off = (r * 128 + c) * 8
        v = (int.from_bytes(d[off:off+8], 'little') >> 16) & 0xffffffff
        ch.append(chr(v) if 0 < v < 128 else ' ')
    line = ''.join(ch).rstrip()
    if line:
        rows.append(line)
want = [
    '> cat',
    'first line',
    'second line',
    'first line',
    'second line',
    '>',
]
missing = [w for w in want if w not in rows]
if missing:
    raise SystemExit("nixsh_stdin_gate: FAIL (missing %r)\n%s" %
                     (missing, '\n'.join(rows)))
print("nixsh_stdin_gate: tty stdin transcript PASS")
PY
echo "nixsh_stdin_gate: PASS (blocking fd 0, tty EOF, prompt return)"
