#!/bin/sh
# nixsh_asm_gate.sh - in-shell nasm0 assembles operand/label source and n16i runs it.
#
# The Terminal creates /y.nas, then `asm /y.nas` assembles and runs it:
#   MOVI r1,66
#   JMP @done
#   MOVI r1,88
# done:
#   PUTC r1
#   HALT
# Serial must show "ASM OK" and the program's 'B' (not 'X'), then the
# scheduler's "!S" halt marker.  This covers the decimal/term path (the old
# tn_d label hijack hung pass 1), label definition and pass-2 resolution.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nixsh_asm_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas \
  > "$T/gui.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nixsh_asm_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 scancodes.  Uppercase mnemonics and shifted punctuation are
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
        elif ch.isupper() and ch.lower() in plain:
            out += bytes((SHIFT_MAKE, plain[ch.lower()], SHIFT_BREAK))
        elif ch.lower() in plain:
            out.append(plain[ch.lower()])
        elif ch in plain:
            out.append(plain[ch])
        else:
            raise SystemExit("no scancode for %r" % ch)
    out.append(plain['\n'])
    return out

commands = [
    "echo MOVI r1,66 > /y.nas",
    "echo JMP @done >> /y.nas",
    "echo MOVI r1,88 >> /y.nas",
    "echo done: >> /y.nas",
    "echo PUTC r1 >> /y.nas",
    "echo HALT >> /y.nas",
    "asm /y.nas",
]
script = bytearray()
for line in commands:
    script += encode(line)
open(sys.argv[1], "wb").write(script)
PY

sh tools/s1_runner.sh --img "$T/gui.nan" --mem 128 --steps 12000000000 \
    --serial --key-delay 5000000 --guest-input "$T/keys.bin" \
    > "$T/run.out" 2> "$T/run.err" || true
grep -q '^ASM OK$' "$T/run.out" || {
  echo "nixsh_asm_gate: FAIL (no ASM OK)"; tail -8 "$T/run.out"; tail -5 "$T/run.err"; exit 1; }
grep -q 'ASM ERR' "$T/run.out" && {
  echo "nixsh_asm_gate: FAIL (assembler error)"; tail -8 "$T/run.out"; exit 1; }
grep -q 'B!S' "$T/run.out" || {
  echo "nixsh_asm_gate: FAIL (program did not print B and halt)"; tail -8 "$T/run.out"; exit 1; }
echo "nixsh_asm_gate: PASS (in-shell asm: operands, label, pass 2, n16i run)"
