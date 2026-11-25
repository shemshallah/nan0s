#!/bin/sh
# tools/nan16_lock_gate.sh - SQLite VFS lock/readonly/path semantics on NaN16.
#
# Builds a tcc0 guest with SQLite, the libc-backed VFS and lock_probe.c.  The
# probe checks: a second connection's write gets SQLITE_BUSY while the first
# holds a write transaction, the writer succeeds after COMMIT, creating a file
# below a missing directory fails with SQLITE_CANTOPEN, and a read-only
# connection's write returns SQLITE_READONLY.  Product acceptance uses an
# x86_64 S1 runner; the portable C core is oracle evidence only.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-lock.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SQL=third_party/sqlite
MEM=${NAN16_LOCK_MEM:-256}
RUNNER=${NAN16_LOCK_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_LOCK_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "nan16_lock: SKIP (no x86_64 S1 runner; set NAN16_LOCK_RUNNER or NAN16_LOCK_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "nan16_lock: FAIL runner not executable: $RUNNER"; exit 1; }

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || \
  (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "nan16_lock: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "nan16_lock: build guest"
"$T/tcc0" -nostdlib -DGUEST -o "$T/lock.bin" \
    -I"$SQL" -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    -DSQLITE_TEST=1 -DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
    -DSQLITE_TEMP_STORE=3 -DSQLITE_OMIT_WAL -DSQLITE_OMIT_LOCALTIME \
    -DSQLITE_OMIT_DEPRECATED -DSQLITE_DQS=0 -DSQLITE_OMIT_SHARED_CACHE \
    -DSQLITE_MAX_MMAP_SIZE=0 -DNDEBUG \
    "$SQL/sqlite3.c" "$SQL/nan16_vfs_libc.c" src/tests/sqlite/lock_probe.c \
    "$LIBC/src/libc.c" > "$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }

echo "nan16_lock: run guest"
"$RUNNER" --img "$T/lock.bin" --mem "$MEM" --steps 1000000000 \
    --guest-stdout "$T/out" --guest-stderr "$T/err" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run.err" || true
[ "$(tail -n 1 "$T/peek" 2>/dev/null)" = "00000000" ] || {
    echo "nan16_lock: FAIL (guest main result)"; tail -5 "$T/run.err"; exit 1; }
tr -d '\r' < "$T/out" > "$T/norm"
for want in 'LOCK PASS' 'second_insert_rc=5' 'nodir_open_rc=14' 'readonly_insert_rc=8' 'lockrow main pending'; do
    grep -qx "$want" "$T/norm" || {
        echo "nan16_lock: FAIL (missing: $want)"; cat "$T/norm"; exit 1; }
done
if [ "$MODE" = oracle ]; then
    echo "nan16_lock: ORACLE MATCH (busy, readonly, missing-dir; x86_64 S1 acceptance via NAN16_LOCK_RUNNER)"
else
    echo "nan16_lock: PASS (busy, readonly, missing-dir)"
fi
