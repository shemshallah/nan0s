#!/bin/sh
# nixsh_vars_gate.sh - POSIX-style variables and read on the NANIX Terminal.
#
# Proves on the x86_64 S1 runner:
#   name=world        assignment is consumed before command dispatch
#   echo hello $name  $NAME expansion in an argument
#   read answer       blocking fd 0 line, newline stripped, stored
#   echo got $answer  the read value expands again
#   env               insertion-order NAME=value dump
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nixsh_vars_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas \
  > "$T/gui.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nixsh_vars_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 scancodes for the one-boot transcript.  '$' is shifted 0x05,
# emitted as shift-make, key, shift-break so kbd.nas tracks the modifier.
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

shifted = {'$': 0x05}
SHIFT_MAKE, SHIFT_BREAK = 0x2a, 0xaa

def encode(text):
    out = bytearray()
    for ch in text:
        if ch in shifted:
            out += bytes((SHIFT_MAKE, shifted[ch], SHIFT_BREAK))
        elif ch.lower() in plain:
            out.append(plain[ch.lower()])
        elif ch in plain:
            out.append(plain[ch])
        else:
            raise SystemExit("no scancode for %r" % ch)
    out.append(plain['\n'])
    return out

commands = [
    "name=world",
    "echo hello $name",
    "read answer",
    "typed line",
    "echo got $answer",
    "env",
]
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
  echo "nixsh_vars_gate: FAIL (no Terminal dump)"; tail -8 "$T/run.err"; exit 1; }

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
    rows.append(''.join(ch).rstrip())
want = [
    '> name=world',
    '> echo hello $name',
    'hello world',
    '> read answer',
    'typed line',
    '> echo got $answer',
    'got typed line',
    '> env',
    'PWD=/',
    'HOME=/',
    'PATH=/',
    'SHELL=/nixsh',
    'name=world',
    'answer=typed line',
    '>',
]
lines = [x for x in rows if x]
found = False
for i in range(len(lines) - len(want) + 1):
    if lines[i:i + len(want)] == want:
        found = True
        break
if not found:
    raise SystemExit("nixsh_vars_gate: FAIL (transcript mismatch)\n"
                     "want:\n%s\ngot:\n%s" %
                     ('\n'.join(want), '\n'.join(lines)))
print("nixsh_vars_gate: variable/read transcript PASS")
PY
echo 'nixsh_vars_gate: PASS (assignment, $NAME expansion, read, env)'
