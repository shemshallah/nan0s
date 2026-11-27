#!/bin/sh
# nixsh_gate.sh - phase 1 standalone NANIX shell on x86_64 S1.
#
# Proves a real cwd and path-aware file commands in the separate PID 2 shell:
# mkdir /x, cd /x, pwd=/x, echo, touch, cp, ls, rm, cd /, rmdir, pwd=/.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nixsh_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas \
  > "$T/gui.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nixsh_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# mkdir /x; cd /x; pwd; echo hello; touch a; cp a b; ls;
# rm /x/a; rm /x/b; cd /; rmdir /x; pwd
KEYS='\x32\x25\x20\x17\x13\x39\x35\x2d\x1c\x2e\x20\x39\x35\x2d\x1c\x19\x11\x20\x1c\x12\x2e\x23\x18\x39\x23\x12\x26\x26\x18\x1c\x14\x18\x16\x2e\x23\x39\x1e\x1c\x2e\x19\x39\x1e\x39\x30\x1c\x26\x1f\x1c\x13\x32\x39\x35\x2d\x35\x1e\x1c\x13\x32\x39\x35\x2d\x35\x30\x1c\x2e\x20\x39\x35\x1c\x13\x32\x20\x17\x13\x39\x35\x2d\x1c\x19\x11\x20\x1c'
S1_FB_DELAY=60 \
sh tools/s1_runner.sh --img "$T/gui.nan" --mem 128 --steps 6000000000 \
    --serial --key-delay 5000000 --keys "$KEYS" \
    --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/run.out" 2> "$T/run.err" || true
[ -s "$T/term.bin" ] || {
  echo "nixsh_gate: FAIL (no Terminal dump)"; tail -8 "$T/run.err"; exit 1; }

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
    '> pwd', '/x',
    '> echo hello', 'hello',
    '> touch a', 'ok',
    '> cp a b', 'ok',
    '> ls', 'a', 'b',
    '> rm /x/a', 'removed',
    '> rm /x/b', 'removed',
    '> rmdir /x', 'removed',
    '> pwd', '/',
]
missing = [w for w in want if not any(line == w for line in rows)]
if missing:
    raise SystemExit("nixsh_gate: FAIL (missing %r)\n%s" %
                     (missing, '\n'.join(x for x in rows if x)))
print("nixsh_gate: cwd/file transcript PASS")
PY
echo "nixsh_gate: PASS (standalone NANIX shell phase 1)"
