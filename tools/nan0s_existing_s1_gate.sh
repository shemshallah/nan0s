#!/bin/sh
# nan0s_existing_s1_gate.sh - boot the EXISTING nan0s system guest on x86_64 S1.
#
# Extracts the guest region from build/nan0s.img (the same bytes the 32-bit
# kboot0 image boots) and runs it on tools/s1_runner.sh.  Requires the real
# system banner on COM1.  This is the 64-bit path for the existing system, not
# a separate CLI.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nan0s_existing.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

sh tools/mkall.sh > "$T/mkall.log" 2>&1
python3 - "$T/guest.bin" <<'PY'
import sys
d = open('build/nan0s.img', 'rb').read()
words = int.from_bytes(d[504:508], 'little')
off = 512 + 65536
open(sys.argv[1], 'wb').write(d[off:off + words * 8])
PY

S1_KEEP=1 TMPDIR="$T" sh tools/s1_runner.sh --img "$T/guest.bin" \
    --mem "${NAN0S_EXISTING_MEM:-128}" \
    --steps "${NAN0S_EXISTING_STEPS:-3000000}" --serial \
    > "$T/run.out" 2> "$T/run.err" || true

COM=$(find "$T" -path '*/s1_runner.*/com' -type f | head -1)
if [ -z "$COM" ]; then
    echo "nan0s_existing: FAIL (no COM1 capture)"
    tail -5 "$T/run.err"; exit 1
fi
if ! grep -q 'NaN/0S' "$COM" || ! grep -q 'READY MENU=S' "$COM"; then
    echo "nan0s_existing: FAIL (real system banner missing)"
    head -10 "$COM" | cat -v; exit 1
fi
echo "nan0s_existing: PASS (existing nan0s guest on x86_64 S1: $(head -1 "$COM" | tr -d '\r'))"
