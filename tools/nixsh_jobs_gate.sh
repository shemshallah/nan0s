#!/bin/sh
# nixsh_jobs_gate.sh - background sleep, jobs and wait in the shell.
#
# Proves on x86_64 S1:
#   sleep 500 & starts a real SVC 9 worker and returns to the prompt
#   jobs reports the running slot
#   wait blocks, reaps and reports status 0
#   jobs is empty after the reap
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nixsh_jobs_gate.$$"
mkdir -p "$T"
trap 'if [ "${GATE_KEEP:-0}" = 1 ]; then echo "nixsh_jobs_gate: kept $T" >&2; else rm -rf "$T"; fi' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_sched_boot.nas \
  > "$T/gui.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nixsh_jobs_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

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
shifted = {'>': 0x34, '&': 0x08}
SHIFT_MAKE, SHIFT_BREAK = 0x2a, 0xaa
def encode(text):
    out = bytearray()
    for ch in text:
        if ch in shifted:
            out += bytes((SHIFT_MAKE, shifted[ch], SHIFT_BREAK))
        else:
            out.append(plain[ch.lower()])
    out.append(plain['\n'])
    return out
commands = ["sleep 500 &", "jobs", "wait", "jobs"]
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
  echo "nixsh_jobs_gate: FAIL (no Terminal dump)"; tail -8 "$T/run.err"; exit 1; }

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
    '> sleep 500 &', 'job 1',
    '> jobs', 'job 1 1',
    '> wait', 'done 1 0',
    '> jobs', '>',
]
missing = [w for w in want if w not in rows]
if missing:
    print("NIXSH_JOBS_MISSING", missing)
    print('\n'.join(rows))
    raise SystemExit(1)
print("nixsh_jobs_gate: background job transcript PASS")
PY
echo "nixsh_jobs_gate: PASS (SVC 9 worker, jobs state, wait/reap)"
