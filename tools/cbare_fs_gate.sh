#!/bin/sh
# cbare_fs_gate.sh - C-port guest calls NaN16 machine FS through C-ABI trampolines.
set -eu; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/cbarefs.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}; TT=third_party/tinycc
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" -o "$T/tcc_nan16" -lm -ldl
awk -f tools/nmk.awk -v CMD=emit src/tests/cbare_fs_stub.nas > "$T/blob.nan" 2>"$T/blob.err"
python3 - "$T/blob.nan" "$T/blob.bin" <<'PY'
import re, sys
W = 0x10000
out = bytearray()
for line in open(sys.argv[1], encoding="latin1"):
    m = re.match(r'([0-9A-Fa-f]{4})_([0-9A-Fa-f]{8})_([0-9A-Fa-f]{4})\s+;\s+([0-9]+)', line)
    if not m: continue
    idx = int(m.group(4))
    if idx < W: continue
    g1 = int(m.group(1),16); p = int(m.group(2),16); g3 = int(m.group(3),16)
    out += bytes((g3 & 255, g3 >> 8, p & 255, (p >> 8) & 255,
                  (p >> 16) & 255, (p >> 24) & 255, g1 & 255, g1 >> 8))
open(sys.argv[2], "wb").write(out)
PY
"$T/tcc_nan16" -c src/tests/cbare_fs_call.c -o "$T/call.bin"
python3 - "$T/call.bin" "$T/blob.bin" "$T/image.bin" <<'PY'
import sys
img = bytearray(open(sys.argv[1],"rb").read()); blob = open(sys.argv[2],"rb").read()
need = 0x10000 * 8
if len(img) > need: raise SystemExit("cbare_fs: compiler image overlaps the blob")
img += b"\0" * (need - len(img)); img += blob
open(sys.argv[3],"wb").write(img)
PY
"$CLI" --img "$T/image.bin" --mem 128 --steps 20000000 --peek "0x40000:2" \
  > "$T/out" 2> "$T/err" || true
cat "$T/out"
if ! grep -qx '0000002A' "$T/out"; then
  echo "cbare_fs: FAIL (NaN FS read/write did not return 42)"; tail -8 "$T/err"; exit 1
fi
echo "cbare_fs: PASS (C-port guest wrote/read through NaN16 filesystem trampolines)"
