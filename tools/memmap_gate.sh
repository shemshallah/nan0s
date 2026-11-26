#!/bin/sh
# memmap_gate.sh - PMEM v1 producer/consumer gate for the S1 x86_64 harness.
#
# Proves, on the raw-NaN16 gui_sched_boot image:
#   1. the S1 producer's map at guest word 0x3F800 has magic PMEM, version 1,
#      the expected ascending entry kinds (RAM/DEVICE/ACPI/RESERVED), and that
#      the highest usable entry is the last RAM range;
#   2. NS_BASE, NP_BASE, NP_VARS and the whole scheduler block sit inside that
#      highest usable range, with the heap ending below it;
#   3. the SVC 2 bump heap has two ranges and excludes the ACPI hole; a
#      9,500,000-word allocation cannot fit before the hole, so it must be
#      placed at the top range base 0x1500000 (22,020,096), not cross it;
#   4. memmap.nas's fallback API returns the legacy {0, MEMQ_words, RAM} range
#      when the magic is removed, then restores the real map.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/memmap_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_sched_boot.nas \
  > "$T/gui_sched.nan" 2> "$T/emit.err"
WORDS=$(sed -n 's/^words //p' "$T/emit.err")
[ -n "$WORDS" ] || { echo "memmap_gate: FAIL (no word count)"; exit 1; }
awk -f tools/nmk.awk -v CMD=check "$T/gui_sched.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "memmap_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }
echo "memmap_gate: image $WORDS words, assembler round-trip clean"

# One dump covers the heap config (0x3F000), runtime pointers (0x3F010),
# and the whole 260-word PMEM block at 0x3F800.
MAPDUMP="0x3F8000:0x4840"

check_boot() { # $1 = MiB (64 or 128)
  mb="$1"
  S1_FB_DELAY=8 \
  sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem "$mb" \
      --steps 800000000 --dump-mem "$MAPDUMP:$T/mem-$mb.bin" \
      > "$T/run-$mb.out" 2> "$T/run-$mb.err" || true
  [ -s "$T/mem-$mb.bin" ] || {
    echo "memmap_gate: FAIL (no map/pointer dump at $mb MiB)"; tail -8 "$T/run-$mb.err"; exit 1; }
  python3 - "$T/mem-$mb.bin" "$mb" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
mb = int(sys.argv[2])
def w(word):
    off = (word - 0x3F000) * 8
    if off < 0 or off + 8 > len(d):
        raise SystemExit("memmap_gate: FAIL (dump short at word 0x%X)" % word)
    return (struct.unpack_from('<Q', d, off)[0] >> 16) & 0xffffffff

MAGIC = 0x4D454D50
BASE = 0x3F800
mem_words = w(0x3F013)
want_words = {64: 0x1000000, 128: 0x2000000}[mb]
if mem_words != want_words:
    raise SystemExit("memmap_gate: FAIL (%d MiB MEMQ=%d, want %d)" %
                     (mb, mem_words, want_words))
if w(BASE + 0) != MAGIC:
    raise SystemExit("memmap_gate: FAIL (bad magic 0x%08X)" % w(BASE + 0))
if w(BASE + 2) != 1:
    raise SystemExit("memmap_gate: FAIL (version != 1)")
count = w(BASE + 1)
if not 1 <= count <= 64:
    raise SystemExit("memmap_gate: FAIL (bad entry count %d)" % count)
if w(BASE + 3) & 2 == 0:
    raise SystemExit("memmap_gate: FAIL (synthetic source flag missing)")

top_end = mem_words - 0x40000
# Expected entries are the S1 producer layout, clipped to MEM_WORDS.
expect = []
def add(base, nw, kind):
    if base >= top_end:
        return
    nw = min(nw, top_end - base)
    if nw:
        expect.append((base, nw, kind))
add(0x000000, 0x800000, 1)
add(0x800000, 0x100000, 4)
add(0x900000, 0xB00000, 1)
add(0x1400000, 0x100000, 3)
if top_end > 0x1500000:
    add(0x1500000, top_end - 0x1500000, 1)
expect.append((top_end, mem_words - top_end, 2))
if count != len(expect):
    raise SystemExit("memmap_gate: FAIL (count %d, expected %d)" % (count, len(expect)))
entries = []
for i in range(count):
    b, n, k, f = [w(BASE + 4 + i * 4 + j) for j in range(4)]
    entries.append((b, n, k))
    if (b, n, k) != expect[i]:
        raise SystemExit("memmap_gate: FAIL (entry %d %r, expected %r)" %
                         (i, (b, n, k), expect[i]))
    if f != 0:
        raise SystemExit("memmap_gate: FAIL (entry %d flags=%d)" % (i, f))
    if i and b < entries[i - 1][0]:
        raise SystemExit("memmap_gate: FAIL (entries not ascending)")
    if k not in (1, 2, 3, 4, 5):
        raise SystemExit("memmap_gate: FAIL (bad kind %d)" % k)
kinds = {e[2] for e in entries}
for need in {e[2] for e in expect}:
    if need not in kinds:
        raise SystemExit("memmap_gate: FAIL (missing kind %d)" % need)
ram = [e for e in entries if e[2] == 1]
tb, tn, _ = max(ram, key=lambda e: e[0] + e[1])
te = tb + tn

NS, NP, NPV = w(0x3F010), w(0x3F011), w(0x3F012)
NS_BYTES = 65648
if not (NS > NP > NPV > 0xB00000):
    raise SystemExit("memmap_gate: FAIL (bad pointer order NS=%d NP=%d NPV=%d)" %
                     (NS, NP, NPV))
if not (tb <= NPV and NS + NS_BYTES <= te):
    raise SystemExit("memmap_gate: FAIL (scheduler not in top usable "
                     "0x%X..0x%X: NS=0x%X NP=0x%X NPV=0x%X)" %
                     (tb, te, NS, NP, NPV))
# The block from NP_BASE through NS_BASE+NS_BYTES must also stay inside.
if NP < tb:
    raise SystemExit("memmap_gate: FAIL (nanproc table below top usable)")

nextp, range_end, nrange, ridx = w(0x3F000), w(0x3F001), w(0x3F002), w(0x3F003)
heap_end = NPV - 0x1000
if mem_words == 0x2000000:
    want_ranges = [(0xB00000, 0x1400000), (0x1500000, heap_end)]
else:
    want_ranges = [(0xB00000, heap_end)]
if nrange != len(want_ranges):
    raise SystemExit("memmap_gate: FAIL (heap ranges=%d, expected %d)" %
                     (nrange, len(want_ranges)))
for i, want in enumerate(want_ranges):
    got = (w(0x3F040 + i * 2), w(0x3F041 + i * 2))
    if got != want:
        raise SystemExit("memmap_gate: FAIL (heap range%d %r, want %r)" %
                         (i, got, want))
if nextp != want_ranges[0][0] or range_end != want_ranges[0][1] or ridx != 0:
    raise SystemExit("memmap_gate: FAIL (heap cursor next=0x%X end=0x%X ridx=%d)" %
                     (nextp, range_end, ridx))
print("memmap_gate: %d MiB map PMEM count=%d kinds=%s top=0x%X..0x%X "
      "NS=0x%X NP=0x%X NPV=0x%X heap=%s" %
      (mb, count, sorted(kinds), tb, te, NS, NP, NPV,
       " ".join("[0x%X..0x%X]" % r for r in want_ranges)))
PY
}

check_boot 64
check_boot 128

# SVC 2 cannot cross the ACPI hole 0x1400000..0x1500000.  A 9.5M-word grant
# does not fit in the first heap range (0x900000 words), so it must start at
# the second range base 0x1500000.  A crossing allocator would return 0xB00000.
KEYS='\x1e\x26\x26\x18\x2e\x39\x0a\x06\x0b\x0b\x0b\x0b\x0b\x1c' # alloc 9500000\n
S1_FB_DELAY=8 \
sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem 128 \
    --steps 2000000000 --serial --key-delay 5000000 --keys "$KEYS" \
    --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/alloc.out" 2> "$T/alloc.err" || true
[ -s "$T/term.bin" ] || {
  echo "memmap_gate: FAIL (no Terminal dump for alloc)"; tail -8 "$T/alloc.err"; exit 1; }
python3 - "$T/term.bin" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
rows = []
for r in range(64):
    ch = []
    for c in range(128):
        off = (r * 128 + c) * 8
        v = (int.from_bytes(d[off:off + 8], 'little') >> 16) & 0xffffffff
        ch.append(chr(v) if 0 < v < 128 else ' ')
    rows.append(''.join(ch).rstrip())
want = ['> alloc 9500000', 'base 22020096']
missing = [x for x in want if not any(line == x for line in rows)]
if missing:
    raise SystemExit("memmap_gate: FAIL (missing %r)\n%s" %
                     (missing, '\n'.join(x for x in rows if x)))
if any(line == 'alloc fail' for line in rows):
    raise SystemExit("memmap_gate: FAIL (alloc failed across hole)")
print("memmap_gate: alloc 9500000 -> base 22020096 (0x1500000), hole skipped")
PY

# Rollback: a failed oversized grant must not move the bump pointer.  A
# following 4,096-word grant must still start at HEAP_BASE (11,534,336).
KEYS='\x1e\x26\x26\x18\x2e\x39\x0a\x0a\x0a\x0a\x0a\x0a\x0a\x0a\x1c\x1e\x26\x26\x18\x2e\x39\x05\x0b\x0a\x07\x1c'
S1_FB_DELAY=90 \
sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem 128 \
    --steps 8000000000 --serial --key-delay 5000000 --keys "$KEYS" \
    --dump-mem "0x400000:0x40000:$T/term2.bin" \
    > "$T/rollback.out" 2> "$T/rollback.err" || true
[ -s "$T/term2.bin" ] || {
  echo "memmap_gate: FAIL (no Terminal dump for rollback)"; tail -8 "$T/rollback.err"; exit 1; }
python3 - "$T/term2.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
rows = []
for r in range(64):
    ch = []
    for c in range(128):
        off = (r * 128 + c) * 8
        v = (int.from_bytes(d[off:off + 8], 'little') >> 16) & 0xffffffff
        ch.append(chr(v) if 0 < v < 128 else ' ')
    rows.append(''.join(ch).rstrip())
want = ['> alloc 99999999', 'alloc fail', '> alloc 4096', 'base 11534336']
missing = [x for x in want if not any(line == x for line in rows)]
if missing:
    raise SystemExit("memmap_gate: FAIL (rollback missing %r)\n%s" %
                     (missing, '\n'.join(x for x in rows if x)))
print("memmap_gate: oversized alloc fail leaves heap at 0xB00000 (rollback)")
PY

# memmap.nas unit path: real map + magic-removed fallback.
awk -f tools/nmk.awk -v CMD=emit src/tests/memmap_test.nas \
  > "$T/memmap_test.nan" 2> "$T/mt.emit"
awk -f tools/nmk.awk -v CMD=check "$T/memmap_test.nan" 2> "$T/mt.check"
grep -q 'check: 0 mismatches' "$T/mt.check" || {
  echo "memmap_gate: FAIL (memmap_test round-trip)"; cat "$T/mt.check"; exit 1; }
S1_FB_DELAY=2 \
sh tools/s1_runner.sh --img "$T/memmap_test.nan" --mem 128 \
    --steps 20000000 --peek '0x2000:0x0F' \
    > "$T/mt.out" 2> "$T/mt.err" || true
python3 - "$T/mt.out" <<'PY'
import sys
vals = [int(x, 16) for x in open(sys.argv[1]).read().split()]
want = [1, 6, 0x1500000, 0x1FC0000, 4, 1,
        0, 0x2000000, 0xFFFFFFFF, 0,
        0, 0x2000000, 1, 1, 1]
if vals != want:
    raise SystemExit("memmap_gate: FAIL (memmap_test %r, want %r)" % (vals, want))
print("memmap_gate: memmap.nas real map + legacy fallback PASS")
PY

echo "memmap_gate: PASS (PMEM map, top-usable scheduler, hole-safe SVC 2 heap)"