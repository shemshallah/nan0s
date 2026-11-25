#!/bin/sh
# nancli64_gate.sh - 64-bit NaN/0S command line over the NaN POSIX table.
#
# A C guest (compiled by TCC to NaN) implements a small command shell:
# mkdir, write, cat, ls, stat, truncate, rm, rmdir, help, exit.  Every
# filesystem call goes through cbare_cli_stub.nas -> bare_fs_* -> NPAF.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nancli64.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}; TT=third_party/tinycc
LIBC=third_party/nan16-libc
RUNNER=${NANCLI64_RUNNER:-tools/s1_runner.sh}
STEPS=${NANCLI64_STEPS:-50000000}
BASE=0x280000

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc.log" || { cat "$T/tcc.log"; exit 1; }

echo "nancli64: compile guest"
"$T/tcc0" -nostdlib -o "$T/guest.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    -DNAN16_HEAP_SIZE=33554432 \
    src/tests/nancli64.c "$LIBC/src/libc.c" > "$T/build.log" 2>&1 || {
        tail -20 "$T/build.log"; exit 1; }

awk -f tools/nmk.awk -v CMD=emit src/tests/cbare_cli_stub.nas > "$T/stub.nan" 2>/dev/null
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
    raise SystemExit("nancli64: C image overlaps the service stub")
img += b"\0" * (need - len(img)) + stub
open(sys.argv[3], "wb").write(img)
PY

echo "nancli64: run on x86_64 S1"
"$RUNNER" --img "$T/image.bin" --mem 128 --steps "$STEPS" \
    --guest-stdout "$T/out" --peek '0x100:1' \
    > "$T/peek" 2> "$T/run.err" || true

fail=0
for want in 'nancli64> mkdir /cli' 'nancli64> write /cli/a hello' \
            'hello' 'nancli64> ls /cli' 'file size=5' \
            'nancli64> truncate /cli/a 2' 'he' \
            'nancli64> mkdir /cli2' 'world' 'nancli64> exit'; do
    grep -q "$want" "$T/out" 2>/dev/null || {
        echo "nancli64: missing '$want'"; fail=1; }
done
if [ "$fail" -ne 0 ]; then
    echo "--- stdout ---"; head -40 "$T/out" 2>/dev/null
    echo "--- stderr ---"; tail -5 "$T/run.err" 2>/dev/null
    exit 1
fi
if ! grep -qx '00000000' "$T/peek"; then
    echo "nancli64: FAIL (main did not return 0)"; cat "$T/peek"; exit 1
fi
echo "nancli64: PASS (64-bit CLI over NaN POSIX services)"
