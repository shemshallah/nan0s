#!/bin/sh
# alloc_scale_gate.sh - the kernel heap must allocate arbitrary sizes from the
# MEMQ-discovered RAM, not from a fixed linker window.
#
# Boots the raw-NaN16 kernel image and asks the NANIX shell for 4,096 words
# and then 8,388,608 words (64 MiB) through SVC 2.  Both regions come from the
# bump heap that starts at HEAP_BASE and ends at the top of real RAM.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/alloc_scale.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas \
  > "$T/gui_sched.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui_sched.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "alloc_scale: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 make codes: "alloc 4096\n" then "alloc 8388608\n".
KEYS='\x1e\x26\x26\x18\x2e\x39\x05\x0b\x0a\x07\x1c\x1e\x26\x26\x18\x2e\x39\x09\x04\x09\x09\x07\x0b\x09\x1c'
S1_FB_DELAY=15 \
sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem 128 \
    --steps 2000000000 --serial --key-delay 5000000 --keys "$KEYS" \
    --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/run.out" 2> "$T/run.err" || true
[ -s "$T/term.bin" ] || {
  echo "alloc_scale: FAIL (no Terminal dump)"; tail -8 "$T/run.err"; exit 1; }

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
want = ['base 11534336', 'base 11538432']
missing = [w for w in want if not any(line == w for line in rows)]
if missing:
    raise SystemExit("alloc_scale: FAIL (missing %r)\n%s" %
                     (missing, '\n'.join(x for x in rows if x)))
print("alloc_scale: 4096 words @11534336, 8388608 words @11538432")
PY
echo "alloc_scale: PASS (SVC 2 bump heap sized from runtime MEMQ)"
