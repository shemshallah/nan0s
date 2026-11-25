#!/bin/sh
# cbare_sqlite_gate.sh - SQLite stores a database through NaN16 services.
#
# The C guest (SQLite + TCC-compiled libc) uses nan16_vfs_nan.c, whose only
# persistence boundary is the C-ABI table in cbare_sqlite_stub.nas.  The stub
# contains the NaN NPAF filesystem (ncc's bare_fs_* services).  The probe
# creates a database, closes it, reopens it, updates it and reopens again.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/cbarsql.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}; TT=third_party/tinycc
SQL=third_party/sqlite; LIBC=third_party/nan16-libc
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
STEPS=${NANFS_SQLITE_STEPS:-400000000}
BASE=2621440

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "cbare_sqlite: compile guest"
"$T/tcc0" -nostdlib -DGUEST -o "$T/guest.bin" \
    -I"$SQL" -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    -DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_TEMP_STORE=3 \
    -DSQLITE_OMIT_WAL -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 \
    -DSQLITE_MAX_MMAP_SIZE=0 -DNDEBUG \
    "$SQL/sqlite3.c" "$SQL/nan16_vfs_nan.c" \
    src/tests/sqlite/nanfs_probe.c "$LIBC/src/libc.c" \
    > "$T/build.log" 2>&1 || { tail -20 "$T/build.log"; exit 1; }

N=$(( $(wc -c < "$T/guest.bin") / 8 ))
[ "$N" -lt "$BASE" ] || {
    echo "cbare_sqlite: FAIL (C image $N words overlaps the service stub at $BASE)"
    exit 1
}
echo "cbare_sqlite: C image $N words, stub at $BASE"

awk -f tools/nmk.awk -v CMD=emit src/tests/cbare_sqlite_stub.nas > "$T/blob.nan" 2> "$T/blob.err"
python3 - "$T/blob.nan" "$T/blob.bin" <<'PY'
import re, sys
BASE = 0x280000
out = bytearray()
for line in open(sys.argv[1], encoding="latin1"):
    m = re.match(r'([0-9A-Fa-f]{4})_([0-9A-Fa-f]{8})_([0-9A-Fa-f]{4})\s+;\s+(\d+)', line)
    if not m: continue
    idx = int(m.group(4))
    if idx < BASE: continue
    g1 = int(m.group(1), 16); p = int(m.group(2), 16); g3 = int(m.group(3), 16)
    out += bytes((g3 & 255, g3 >> 8, p & 255, (p >> 8) & 255,
                  (p >> 16) & 255, (p >> 24) & 255, g1 & 255, g1 >> 8))
open(sys.argv[2], "wb").write(out)
PY

python3 - "$T/guest.bin" "$T/blob.bin" "$T/image.bin" "$BASE" <<'PY'
import sys
img = bytearray(open(sys.argv[1], "rb").read())
blob = open(sys.argv[2], "rb").read()
base = int(sys.argv[4], 0)
pad = base * 8
if len(img) > pad:
    raise SystemExit("cbare_sqlite: compiler image overlaps the stub")
img += b"\0" * (pad - len(img))
img += blob
open(sys.argv[3], "wb").write(img)
PY

echo "cbare_sqlite: run probe"
set +e
"$CLI" --img "$T/image.bin" --mem 256 --steps "$STEPS" --serial \
    --peek "0xC00000:16,0xBFFFFC:1" > "$T/out" 2> "$T/err"
RC=$?
set -e
cat "$T/out"
if [ "$RC" -ne 0 ]; then
    echo "cbare_sqlite: FAIL (runner rc=$RC)"; tail -5 "$T/err"; exit 1
fi
check() {
    want=$1; got=$2; what=$3
    [ "$got" = "$want" ] || {
        echo "cbare_sqlite: FAIL ($what: got $got want $want)"; exit 1; }
}
check 00000006 "$(sed -n "1p" "$T/out")" "initial sum"
check 00000003 "$(sed -n '2p' "$T/out")" "initial count"
check 006F7774 "$(sed -n '3p' "$T/out")" "max(s)=two"
check 53514C50 "$(sed -n '4p' "$T/out")" "magic"
check 00000000 "$(sed -n '5p' "$T/out")" "first failing rc"
check 00000003 "$(sed -n '7p' "$T/out")" "reopened count"
check 00000006 "$(sed -n '8p' "$T/out")" "reopened sum"
check 00000004 "$(sed -n '9p' "$T/out")" "updated count"
check 00000013 "$(sed -n '10p' "$T/out")" "updated sum"
check 00000001 "$(sed -n '11p' "$T/out")" "verification flag"
check 00000001 "$(sed -n '17p' "$T/out")" "completion marker"
echo "cbare_sqlite: PASS (SQLite create/insert/reopen/update through NaN services)"
