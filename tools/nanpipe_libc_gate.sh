#!/bin/sh
# nanpipe_libc_gate.sh - guest libc pipe()/dup2() over the NaN16 np_* pipe.
#
# Builds the test exactly like the existing NaN16 libc guests (tcc0 with
# third_party/nan16-libc/src/libc.c), then links src/tests/cbare_pipe_stub.nas
# at word 0x280000 (table 0x296400 / C byte 0xA59000) and runs on x86_64 S1.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nanpipe_libc.$$"; mkdir -p "$T"
if [ "${NANPIPE_LIBC_KEEP:-0}" = 1 ]; then
    trap 'echo "nanpipe_libc: kept $T" >&2' EXIT
else
    trap 'rm -rf "$T"' EXIT
fi
CC=${HOST_CC:-cc}; TT=third_party/tinycc
LIBC=third_party/nan16-libc
RUNNER=${NANPIPE_LIBC_RUNNER:-tools/s1_runner.sh}
STEPS=${NANPIPE_LIBC_STEPS:-100000000}
MEM=${NANPIPE_LIBC_MEM:-128}
BASE=0x280000

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || \
  (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "nanpipe_libc: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc.log" || { cat "$T/tcc.log"; exit 1; }

echo "nanpipe_libc: compile guest libc + pipe test"
# Same command shape as the testfixture/shell gates: they already compile
# third_party/nan16-libc/src/libc.c; -DNAN16_PIPE_LIBC pulls in the pipe layer.
"$T/tcc0" -nostdlib -o "$T/guest.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    -DNAN16_HEAP_SIZE=33554432 -DNAN16_PIPE_LIBC \
    "$LIBC/src/libc.c" src/tests/nanpipe_libc_test.c > "$T/build.log" 2>&1 || {
        cat "$T/build.log"; exit 1; }

echo "nanpipe_libc: assemble NaN pipe service stub"
LC_ALL=C awk -f tools/nmk.awk -v CMD=emit src/tests/cbare_pipe_stub.nas \
    > "$T/stub.nan" 2>"$T/stub.err"
python3 - "$T/stub.nan" "$T/stub.bin" "$BASE" <<'PY'
import re, sys
base = int(sys.argv[3], 0)
out = bytearray()
for line in open(sys.argv[1], encoding="latin1"):
    m = re.match(r'([0-9A-Fa-f]{4})_([0-9A-Fa-f]{8})_([0-9A-Fa-f]{4})\s+;\s+(\d+)', line)
    if not m: continue
    if int(m.group(4)) < base: continue
    g1, p, g3 = (int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16))
    out += bytes((g3 & 255, g3 >> 8, p & 255, (p >> 8) & 255,
                  (p >> 16) & 255, (p >> 24) & 255, g1 & 255, g1 >> 8))
open(sys.argv[2], "wb").write(out)
PY

python3 - "$T/guest.bin" "$T/stub.bin" "$T/image.bin" "$BASE" <<'PY'
import sys
img = bytearray(open(sys.argv[1], "rb").read())
stub = open(sys.argv[2], "rb").read()
need = int(sys.argv[4], 0) * 8
if len(img) > need:
    raise SystemExit("nanpipe_libc: C image overlaps the pipe service stub")
img += b"\0" * (need - len(img)) + stub
open(sys.argv[3], "wb").write(img)
PY

echo "nanpipe_libc: run on x86_64 S1"
"$RUNNER" --img "$T/image.bin" --mem "$MEM" --steps "$STEPS" \
    --guest-stdout "$T/out" --guest-stderr "$T/err" --peek '0x100:1' \
    > "$T/peek" 2> "$T/run.err" || true

if ! grep -qx 'PIPE PASS' "$T/out" 2>/dev/null; then
    echo "nanpipe_libc: FAIL (no PIPE PASS)"
    echo "--- main result (word 0x100) ---"; cat "$T/peek" 2>/dev/null
    echo "--- stdout ---"; head -20 "$T/out" 2>/dev/null
    echo "--- stderr ---"; head -20 "$T/err" 2>/dev/null
    echo "--- run ---"; tail -20 "$T/run.err" 2>/dev/null
    exit 1
fi
if ! grep -qx '00000000' "$T/peek" 2>/dev/null; then
    echo "nanpipe_libc: FAIL (main did not return 0)"; cat "$T/peek"; exit 1
fi
echo "nanpipe_libc: PASS (libc pipe/dup2 over NaN16 np_* primitive)"
