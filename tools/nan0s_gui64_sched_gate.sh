#!/bin/sh
# nan0s_gui64_sched_gate.sh - NaN/0S kernel-boot acceptance.
#
# Boots src/exhibits/gui_sched_boot.nas on x86_64 S1.  The image is raw NaN16:
# a boot trampoline, the GUI desktop at 8192, and nankernel + nansched at
# 65536.  nsch_init creates PID 1 (desktop/window manager) and PID 2 (NANIX
# shell) with the same flat image and independent trap frames/stacks.
#
# The gate requires:
#   1. the desktop framebuffer and Terminal transcript (all NANIX commands);
#   2. PID 1 and PID 2 live in the nanproc table, with timer preemption > 0.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nan0s_gui64_sched.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

# A completed line is written to FNB by the Terminal and consumed by PID 2.
awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_sched_boot.nas \
  > "$T/gui_sched.nan" 2> "$T/emit.err"
WORDS=$(sed -n 's/^words //p' "$T/emit.err")
[ -n "$WORDS" ] || { echo "gui64_sched: FAIL (no word count)"; exit 1; }
[ "$WORDS" -lt 4000000 ] || {
  echo "gui64_sched: FAIL (image $WORDS words exceeds the VM limit)"; exit 1; }
awk -f tools/nmk.awk -v CMD=check "$T/gui_sched.nan" 2> "$T/check.err" || {
  echo "gui64_sched: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "gui64_sched: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 make codes for the NANIX line-discipline transcript.  The first
# line is "help"; the rest exercises create/read/write/stat/truncate/remove.
KEYS='\x23\x12\x26\x19\x1c\x32\x25\x20\x17\x13\x39\x35\x2d\x1c\x11\x13\x17\x14\x12\x39\x35\x2d\x35\x1e\x39\x23\x12\x26\x26\x18\x1c\x2e\x1e\x14\x39\x35\x2d\x35\x1e\x1c\x26\x1f\x39\x35\x2d\x1c\x1f\x14\x1e\x14\x39\x35\x2d\x35\x1e\x1c\x14\x13\x16\x31\x2e\x1e\x14\x12\x39\x35\x2d\x35\x1e\x39\x03\x1c\x2e\x1e\x14\x39\x35\x2d\x35\x1e\x1c\x13\x32\x39\x35\x2d\x35\x1e\x1c\x13\x32\x20\x17\x13\x39\x35\x2d\x1c'

S1_FB_DELAY="${NAN0S_GUI64_SCHED_DELAY:-50}" \
sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem "${NAN0S_GUI64_SCHED_MEM:-128}" \
    --steps "${NAN0S_GUI64_SCHED_STEPS:-4000000000}" --serial \
    --key-delay "${NAN0S_GUI64_SCHED_KEY_DELAY:-5000000}" --keys "$KEYS" \
    --dump-fb "$T/fb.bin" --dump-mem "0x400000:0x40000:$T/term.bin" \
    > "$T/run.out" 2> "$T/run.err" || true

[ -s "$T/fb.bin" ] || { echo "gui64_sched: FAIL (no framebuffer dump)"; tail -8 "$T/run.err"; exit 1; }
[ -s "$T/term.bin" ] || { echo "gui64_sched: FAIL (no Terminal buffer dump)"; tail -8 "$T/run.err"; exit 1; }

python3 - "$T/fb.bin" "$T/term.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
W, H = 1024, 768
fb = d[:W*H]
if len(fb) < W*H:
    raise SystemExit("gui64_sched: FAIL (short framebuffer %d)" % len(fb))
def count(x0, y0, x1, y1):
    n = 0
    for y in range(y0, y1):
        row = fb[y*W:(y+1)*W]
        n += sum(1 for b in row[x0:x1] if b)
    return n
total = sum(1 for b in fb if b)
term = count(60, 40, 624, 392)
if total < 20000:
    raise SystemExit("gui64_sched: FAIL (framebuffer nearly blank: %d pixels)" % total)
if term < 5000:
    raise SystemExit("gui64_sched: FAIL (Terminal window region blank: %d pixels)" % term)

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
missing = [w for w in want if not any(line == w for line in rows)]
if missing:
    raise SystemExit("gui64_sched: FAIL (Terminal transcript missing %r)\n%s" %
                     (missing, '\n'.join(x for x in rows if x)))
print("gui64_sched: desktop+Terminal transcript PASS (total=%d terminal=%d)" % (total, term))
PY

# Second boot: read the runtime base pointers from the fixed config words.
# Guest word memory starts at physical 0x200000; word 0x3F010 is at byte
# 0x3F8080.  The boot kernel writes NS_PTR, NP_PTR, NPV_PTR, MEM_WORDS there.
S1_FB_DELAY="${NAN0S_GUI64_SCHED_PTR_DELAY:-5}" \
sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem "${NAN0S_GUI64_SCHED_MEM:-128}" \
    --steps "${NAN0S_GUI64_SCHED_PTR_STEPS:-200000000}" \
    --dump-mem "0x3F8080:0x20:$T/ptr.bin" \
    > "$T/ptr.out" 2> "$T/ptr.err" || true
[ -s "$T/ptr.bin" ] || { echo "gui64_sched: FAIL (no config dump)"; tail -8 "$T/ptr.err"; exit 1; }
INFO=$(python3 - "$T/ptr.bin" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
vals = [(struct.unpack('<Q', d[i:i+8])[0] >> 16) & 0xffffffff for i in range(0, 32, 8)]
print(*vals[:4])
PY
)
set -- $INFO
NS_W=$1; NP_W=$2; NPV_W=$3; MEM_W=$4
[ "$NS_W" -ne 0 ] && [ "$NP_W" -ne 0 ] && [ "$NPV_W" -ne 0 ] || {
  echo "gui64_sched: FAIL (runtime pointers not published: $INFO)"; exit 1; }
[ "$NS_W" -lt "$MEM_W" ] && [ "$NP_W" -lt "$NS_W" ] && [ "$NPV_W" -lt "$NP_W" ] || {
  echo "gui64_sched: FAIL (bad top-of-RAM layout: $INFO)"; exit 1; }

NSB=$((0x200000 + NS_W * 8))
NPB=$((0x200000 + NP_W * 8))
NSE=$((NSB + 65648 * 8))                 # NS_BYTES
LEN=$((NSE - NPB))
[ "$LEN" -gt 0 ] || { echo "gui64_sched: FAIL (bad NS/NP span)"; exit 1; }

# Third boot: dump nanproc through the whole scheduler block.
S1_FB_DELAY="${NAN0S_GUI64_SCHED_PROC_DELAY:-5}" \
sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem "${NAN0S_GUI64_SCHED_MEM:-128}" \
    --steps "${NAN0S_GUI64_SCHED_PROC_STEPS:-500000000}" \
    --dump-mem "$NPB:$LEN:$T/mem.bin" \
    > "$T/proc.out" 2> "$T/proc.err" || true
[ -s "$T/mem.bin" ] || { echo "gui64_sched: FAIL (no kernel memory dump)"; tail -8 "$T/proc.err"; exit 1; }

python3 - "$T/mem.bin" "$NSB" "$NPB" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ns_off = int(sys.argv[2]) - int(sys.argv[3])
def w(i):
    o = i * 8
    if o + 8 > len(d):
        raise SystemExit("gui64_sched: FAIL (kernel dump short at word %d)" % i)
    return (struct.unpack('<Q', d[o:o+8])[0] >> 16) & 0xffffffff
nsb = ns_off // 8
cur = w(nsb + 4160)
preempt = w(nsb + 4167)
if cur not in (1, 2):
    raise SystemExit("gui64_sched: FAIL (NS_CUR=%d, expected PID 1/2)" % cur)
if preempt == 0:
    raise SystemExit("gui64_sched: FAIL (timer preemption counter is zero)")
npw = 0
for slot, want_pid in ((0, 1), (1, 2)):
    base = npw + slot * 96
    pid = w(base)
    state = w(base + 2)
    threads = w(base + 8)
    if pid != want_pid:
        raise SystemExit("gui64_sched: FAIL (slot %d pid=%d, expected %d)" %
                         (slot, pid, want_pid))
    if state not in (1, 2):
        raise SystemExit("gui64_sched: FAIL (PID %d state=%d, not ready/running)" %
                         (pid, state))
    if threads < 1:
        raise SystemExit("gui64_sched: FAIL (PID %d has no thread)" % pid)
print("gui64_sched: kernel PASS (NS=%s NP=%s cur=%d preempt=%d PID1=live PID2=live)" %
      (sys.argv[2], sys.argv[3], cur, preempt))
PY

echo "nan0s_gui64_sched: PASS (raw-NaN16 boot kernel, PID 1 desktop, PID 2 NANIX shell, x86_64 S1)"
