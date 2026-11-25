#!/bin/sh
# tools/tcc_sqlite.sh - SQLite 3.54.1 on NaN16 (differential gate).
#
# tcc0 compiles the vendored SQLite amalgamation plus the in-memory NaN16 VFS
# and a test program.  The same test is compiled natively and every 32-bit
# result word must match.  A second build uses SQLITE_DEBUG with all SQLite
# assertions enabled; it must also match native and complete.
#
#   sh tools/tcc_sqlite.sh
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/tcc_sqlite.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SQL=third_party/sqlite
CLI=aarch64/android/nan_cli
INC="-I$LIBC/include -I$TT/include -I$TT"

[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)

BASE="-DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
-DSQLITE_TEMP_STORE=3 -DSQLITE_OMIT_WAL -DSQLITE_OMIT_LOCALTIME \
-DSQLITE_OMIT_DEPRECATED -DSQLITE_DQS=0 -DSQLITE_OMIT_SHARED_CACHE \
-DSQLITE_MAX_MMAP_SIZE=0"
FLAGS="$BASE -DNDEBUG"

echo "tcc_sqlite: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

guest() { # guest NAME [extra flags...]
    name=$1
    shift
    "$T/tcc0" -nostdlib -DGUEST -o "$T/$name.bin" -I"$SQL" $INC "$@" $FLAGS \
        "$SQL/sqlite3.c" "$SQL/nan16_vfs.c" "src/tests/sqlite/$name.c" \
        "$LIBC/src/libc.c"
}

echo "tcc_sqlite: build guest suite and stress cartridges"
guest suite
guest stress

# Build the native reference once, then link both tests against it.
echo "tcc_sqlite: build native reference"
$CC -O2 -I"$SQL" $FLAGS -c "$SQL/sqlite3.c" -o "$T/sqlite3.o"
$CC -O2 -I"$SQL" $FLAGS -c "$SQL/nan16_vfs.c" -o "$T/vfs.o"
for t in suite stress; do
    $CC -O2 -I"$SQL" $FLAGS -c "src/tests/sqlite/$t.c" -o "$T/$t.o"
    $CC -O2 "$T/$t.o" "$T/sqlite3.o" "$T/vfs.o" -o "$T/$t.native" -lm
    "$T/$t.native" > "$T/$t.native.out" 2> "$T/$t.native.err"
    if [ -s "$T/$t.native.err" ]; then
        echo "tcc_sqlite: FAIL (native $t: $(cat "$T/$t.native.err"))"
        exit 1
    fi
done

run() { # run NAME REF STEPS WORDS
    name=$1
    ref=$2
    steps=$3
    words=$4
    "$CLI" --img "$T/$name.bin" --mem 256 --steps "$steps" \
        --dump-bytes "0x03000000:0x1100:$T/$name.guest" \
        --peek '0x0BFFFFC:1' > "$T/$name.marker" 2> "$T/$name.err" || true
    marker=$(tail -n 1 "$T/$name.marker")
    [ "$marker" = "00000001" ] || {
        echo "tcc_sqlite: FAIL ($name did not finish: marker=$marker)"
        tail -n 5 "$T/$name.err" || true
        exit 1
    }
    head -c $((words * 4)) "$T/$name.guest" > "$T/$name.guest.out"
    cmp "$T/$name.guest.out" "$T/$ref.native.out" || {
        echo "tcc_sqlite: FAIL ($name guest output differs from native)"
        exit 1
    }
    if dd if="$T/$name.guest" bs=1 skip=4096 count=200 2>/dev/null \
        | tr -d '\000' | grep -q .; then
        echo "tcc_sqlite: FAIL ($name reported:"
        dd if="$T/$name.guest" bs=1 skip=4096 count=200 2>/dev/null | tr -d '\000'
        echo ")"
        exit 1
    fi
}

echo "tcc_sqlite: run suite"
run suite suite 900000000 96
echo "tcc_sqlite: run stress"
run stress stress 1200000000 256

echo "tcc_sqlite: build and run SQLITE_DEBUG assert suite"
"$T/tcc0" -nostdlib -DGUEST -o "$T/suite_debug.bin" -I"$SQL" $INC \
    $BASE -DSQLITE_DEBUG -DNAN16_ASSERT_DIAG \
    "$SQL/sqlite3.c" "$SQL/nan16_vfs.c" "src/tests/sqlite/suite.c" \
    "$LIBC/src/libc.c"
run suite_debug suite 1200000000 96

echo "tcc_sqlite: PASS (SQLite 3.54.1; suite/stress/debug match native; integrity ok)"
