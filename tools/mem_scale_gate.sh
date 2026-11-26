#!/bin/sh
# mem_scale_gate.sh - the product boot must never compile a RAM size in.
#
# Boots the raw-NaN16 kernel image at two different QEMU memory sizes and asks
# the NANIX shell (`mem`) for the word count.  The count is the MEMQ value the
# kernel read from CPUID 0x4E4D00FF, not a constant in the guest.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/mem_scale.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_sched_boot.nas \
  > "$T/gui_sched.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/gui_sched.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "mem_scale: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

# PS/2 set-1 make codes: m e m ENTER.
KEYS='\x32\x12\x32\x1c'
check_mem() {
  mb="$1"
  want=$((mb * 1024 * 1024 / 4))       # guest words at 8 bytes each
  words=65536
  while [ "$words" -lt "$want" ]; do words=$((words * 2)); done
  S1_FB_DELAY=8 \
  sh tools/s1_runner.sh --img "$T/gui_sched.nan" --mem "$mb" \
      --steps 2000000000 --serial --key-delay 5000000 --keys "$KEYS" \
      --dump-mem "0x400000:0x40000:$T/term-$mb.bin" \
      > "$T/run-$mb.out" 2> "$T/run-$mb.err" || true
  [ -s "$T/term-$mb.bin" ] || {
    echo "mem_scale: FAIL (no Terminal dump at $mb MiB)"; tail -8 "$T/run-$mb.err"; exit 1; }
  got=$(python3 - "$T/term-$mb.bin" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
for r in range(64):
    ch = []
    for c in range(128):
        off = (r * 128 + c) * 8
        v = (int.from_bytes(d[off:off+8], 'little') >> 16) & 0xffffffff
        ch.append(chr(v) if 0 < v < 128 else ' ')
    line = ''.join(ch).rstrip()
    if line.startswith('mem '):
        print(line)
        raise SystemExit(0)
raise SystemExit(1)
PY
) || {
    echo "mem_scale: FAIL (no 'mem' response at $mb MiB)"; exit 1; }
  if [ "$got" != "mem $words free 0" ]; then
    echo "mem_scale: FAIL ($mb MiB: got '$got', want 'mem $words free 0')"
    exit 1
  fi
  echo "mem_scale: $mb MiB -> $got"
}

check_mem 64
check_mem 128
echo "mem_scale: PASS (runtime MEMQ word count at 64 MiB and 128 MiB)"
