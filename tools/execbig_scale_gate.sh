#!/bin/sh
# execbig_scale_gate.sh - execute a program larger than the 64K code window.
#
# The NANIX shell allocates a 70,000-word RWX region from the runtime heap,
# fills it with valid NOP words, copies a base-relative tail, calls it through
# r12, and verifies the result the tail wrote through that base.  This is the
# relocatable executable path: the program is not linked at 8192 and does not
# depend on the GUI cart slot.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/execbig_scale.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_sched_boot.nas \
  > "$T/gui_sched.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui_sched.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "execbig_scale: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 make codes: "execbig 70000\n".
KEYS='\x12\x2d\x12\x2e\x30\x17\x22\x39\x08\x0b\x0b\x0b\x0b\x1c'
S1_FB_DELAY=10 \
sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem 128 \
    --steps 2000000000 --serial --key-delay 5000000 --keys "$KEYS" \
    --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/run.out" 2> "$T/run.err" || true
[ -s "$T/term.bin" ] || {
  echo "execbig_scale: FAIL (no Terminal dump)"; tail -8 "$T/run.err"; exit 1; }

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
want = ['> execbig 70000', 'big ok']
missing = [w for w in want if not any(line == w for line in rows)]
if missing:
    raise SystemExit("execbig_scale: FAIL (missing %r)\n%s" %
                     (missing, '\n'.join(x for x in rows if x)))
print("execbig_scale: 70,000-word program executed from a runtime heap base")
PY
echo "execbig_scale: PASS (base-relative executable loader, >64K words)"
