#!/bin/sh
# cbare_gate.sh - C-port guest calls an assembled NaN16 service table.
set -eu; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/cbare.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
CLI=${CBARE_RUNNER:-aarch64/android/nan_cli}
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc_nan16" -lm -ldl

awk -f tools/nmk.awk -v CMD=emit src/tests/cbare_stub.nas > "$T/stub.nan" 2>"$T/stub.err"
python3 - "$T/stub.nan" "$T/stub.bin" <<'PY'
import re, sys
out = bytearray()
for line in open(sys.argv[1], encoding="latin1"):
    m = re.match(r'([0-9A-Fa-f]{4})_([0-9A-Fa-f]{8})_([0-9A-Fa-f]{4})', line)
    if not m: continue
    g1 = int(m.group(1), 16); p = int(m.group(2), 16); g3 = int(m.group(3), 16)
    # .nan text: near head _ payload _ byte-swapped far head.
    # Raw word: far head hi,lo; payload LE; near head lo,hi.
    out += bytes((g3 & 255, g3 >> 8, p & 255, (p >> 8) & 255,
                  (p >> 16) & 255, (p >> 24) & 255, g1 & 255, g1 >> 8))
open(sys.argv[2], "wb").write(out)
PY
"$T/tcc_nan16" -c src/tests/cbare_call.c -o "$T/call.bin"
python3 - "$T/call.bin" "$T/stub.bin" "$T/image.bin" <<'PY'
import sys
img = bytearray(open(sys.argv[1], "rb").read())
stub = open(sys.argv[2], "rb").read()
W = 0x00C00000
need = W * 8
if len(img) > need:
    raise SystemExit("cbare: compiler image overlaps the service blob")
img += b"\0" * (need - len(img))
img += stub
open(sys.argv[3], "wb").write(img)
PY
"$CLI" --img "$T/image.bin" --mem 128 --steps 1000000 --serial --peek 0x100:1 \
  > "$T/out" 2> "$T/err" || true
cat "$T/out"
if ! grep -q '^NaN$' "$T/out"; then
  echo "cbare: FAIL (NaN service console output missing)"; tail -5 "$T/err"; exit 1
fi
if ! grep -qx '0000002A' "$T/out"; then
  echo "cbare: FAIL (C main did not return 42 after tick)"; tail -5 "$T/err"; exit 1
fi
echo "cbare: PASS (C-port guest called NaN console + tick table)"
