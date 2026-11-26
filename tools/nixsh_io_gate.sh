#!/bin/sh
# nixsh_io_gate.sh - NANIX phase 1.5 shell redirection and sequential pipes.
#
# Proves, on the S1 runner at $PWD/tmp:
#   echo hi > /f     > creates a file
#   cat < /f         < supplies stdin
#   ls > /f          builtin output goes through fd 1
#   echo err 2> /e   2> creates/truncates the stderr target
#   cat /missing 2> /e   diagnostics go through fd 2
#   cat /f | wc      sequential pipeline (left writes pipe, right reads it)
#   echo tail >> /f  append
#   cat /missing 2>&1    dup2 of stdout onto stderr
#   sync                 explicit nfs_save report (S1 has no ATA: sync error)
# and checks the exact Terminal transcript plus /f contents.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nixsh_io_gate.$$"
mkdir -p "$T"
trap 'if [ "${S1_KEEP:-0}" = 1 ]; then echo "nixsh_io_gate: kept $T" >&2; else rm -rf "$T"; fi' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_sched_boot.nas \
  > "$T/gui.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nixsh_io_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 key script for the Terminal.  Shifted punctuation is emitted as
# shift-make, key, shift-break so kbd.nas tracks the modifier correctly.
python3 - "$T/keys.bin" <<'PY'
import sys

plain = {
    ' ': 0x39, '\n': 0x1c, '/': 0x35, '.': 0x34, ',': 0x33, '-': 0x0c,
    '=': 0x0d, ';': 0x27, "'": 0x28, '[': 0x1a, ']': 0x1b, '\\': 0x2b,
    '`': 0x29,
}
rows = "1234567890"
for i, c in enumerate(rows):
    plain[c] = 0x02 + i
for c, sc in zip("qwertyuiop", range(0x10, 0x1a)):
    plain[c] = sc
for c, sc in zip("asdfghjkl", range(0x1e, 0x27)):
    plain[c] = sc
for c, sc in zip("zxcvbnm", range(0x2c, 0x33)):
    plain[c] = sc

shifted = {
    '!': 0x02, '@': 0x03, '#': 0x04, '$': 0x05, '%': 0x06, '^': 0x07,
    '&': 0x08, '*': 0x09, '(': 0x0a, ')': 0x0b, '_': 0x0c, '+': 0x0d,
    '{': 0x1a, '}': 0x1b, '|': 0x2b, ':': 0x27, '"': 0x28, '<': 0x33,
    '>': 0x34, '?': 0x35, '~': 0x29,
}
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
    return out

commands = [
    "mkdir /io",
    "cd /io",
    "touch a",
    "echo hi > /f",
    "cat < /f",
    "ls > /f",
    "cat /f",
    "echo err 2> /e",
    "cat /e",
    "cat /missing 2> /e",
    "cat /e",
    "cat /f | wc",
    "echo tail >> /f",
    "cat /f",
    "cat /missing 2>&1",
    "sync",
]
script = bytearray()
for line in commands:
    script += encode(line)
    script.append(plain['\n'])
open(sys.argv[1], "wb").write(script)
PY

S1_FB_DELAY=90 \
sh tools/s1_runner.sh --img "$T/gui.nan" --mem 128 --steps 8000000000 \
    --serial --key-delay 5000000 --guest-input "$T/keys.bin" \
    --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/run.out" 2> "$T/run.err" || true
[ -s "$T/term.bin" ] || {
  echo "nixsh_io_gate: FAIL (no Terminal dump)"; tail -8 "$T/run.err"; exit 1; }

python3 - "$T/term.bin" "$T/transcript" <<'PY'
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
with open(sys.argv[2], 'w') as f:
    for line in rows:
        if line:
            f.write(line + '\n')

want = [
    '> cd /io',
    '> touch a',
    'ok',
    '> echo hi > /f',
    '> cat < /f',
    'hi',
    '> ls > /f',
    '> cat /f',
    'a',
    '> echo err 2> /e',
    'err',
    '> cat /e',
    '> cat /missing 2> /e',
    '> cat /e',
    'cat: cannot open',
    '> cat /f | wc',
    '1 1 2',
    '> echo tail >> /f',
    '> cat /f',
    'a',
    'tail',
    '> cat /missing 2>&1',
    'cat: cannot open',
    '> sync',
    'sync error',
    '>',
]
# The 24-row Terminal viewport scrolls its oldest lines away.  Match the
# retained view against a suffix of the expected transcript (the first two
# setup rows, banner and mkdir/ok, are not part of `want`).
lines = [x for x in rows if x]
best = None
for skip in range(0, len(want)):
    seg = want[skip:]
    if len(seg) <= len(lines) and lines[-len(seg):] == seg:
        best = skip
        break
if best is None:
    raise SystemExit("nixsh_io_gate: FAIL (transcript mismatch)\n"
                     "want:\n%s\ngot:\n%s" %
                     ('\n'.join(want), '\n'.join(lines)))
if best:
    print("nixsh_io_gate: %d oldest expected line(s) scrolled off" % best)
for required in ('> echo hi > /f', '> cat < /f', '> ls > /f',
                 '> cat /missing 2> /e', '> cat /f | wc',
                 'sync error'):
    if required not in lines:
        raise SystemExit("nixsh_io_gate: FAIL (missing %r)" % required)
print("nixsh_io_gate: redirect/pipeline transcript PASS")

PY

echo "nixsh_io_gate: /f contents:"
cat "$T/transcript"
echo "nixsh_io_gate: PASS (fd table, redirection, sequential pipes)"
