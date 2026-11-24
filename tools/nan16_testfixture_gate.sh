#!/bin/sh
# tools/nan16_testfixture_gate.sh - official SQLite 3.54.1 testfixture on NaN16.
#
# Requires TCL_SRC (Tcl 9.0.3) and SQLITE_SRC (sqlite-src-3540100).  Builds
# tcc0, packs the official test tree and Tcl library into one N16PACK1 VFS,
# compiles the official testfixture C sources with the NaN16 Tcl port, and
# runs test/select1.test through tester.tcl.
#
# Product acceptance is an x86_64 S1 runner supplied in
# TCL_NAN16_TESTFIXTURE_RUNNER.  The portable C core is oracle evidence and is
# only used when TCL_NAN16_TESTFIXTURE_ALLOW_ORACLE=1.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
PORT=src/tests/tcl_sqlite/nan16
MEM=${TCL_NAN16_TESTFIXTURE_MEM:-256}
TEST=${TCL_NAN16_TESTFIXTURE_TEST:-/sqlite/test/select1.test}
if [ -n "${TCL_NAN16_TESTFIXTURE_STEPS:-}" ]; then
    STEPS=$TCL_NAN16_TESTFIXTURE_STEPS
else
    case "$TEST" in
	*veryquick*|*quick*|*all.test*) STEPS=60000000000 ;;
	*) STEPS=4000000000 ;;
    esac
fi

TCL_SRC=${TCL_SRC:-}
SQLITE_SRC=${SQLITE_SRC:-}
if [ -z "$TCL_SRC" ]; then
    if [ "${TCL_NAN16_TESTFIXTURE_ALLOW_DEFAULT_SRC:-0}" = 1 ]; then
	TCL_SRC=${TMPDIR:-$ROOT/build}/tcl-sqlite/tcl9.0.3
    else
	echo "tcl_testfixture: ERROR: set TCL_SRC to an extracted Tcl 9.0.3 tree" >&2
	exit 2
    fi
fi
if [ -z "$SQLITE_SRC" ]; then
    if [ "${TCL_NAN16_TESTFIXTURE_ALLOW_DEFAULT_SRC:-0}" = 1 ]; then
	SQLITE_SRC=${TMPDIR:-$ROOT/build}/tcl-sqlite/sqlite-src-3540100
    else
	echo "tcl_testfixture: ERROR: set SQLITE_SRC to sqlite-src-3540100" >&2
	exit 2
    fi
fi
[ -f "$TCL_SRC/generic/tcl.h" ] || {
    echo "tcl_testfixture: ERROR: TCL_SRC is not a Tcl source tree" >&2
    exit 2
}
grep -Eq 'TCL_PATCH_LEVEL[[:space:]]+"9\.0\.3"' "$TCL_SRC/generic/tcl.h" || {
    echo "tcl_testfixture: ERROR: TCL_SRC is not Tcl 9.0.3" >&2
    exit 2
}
[ -f "$SQLITE_SRC/src/tclsqlite.c" ] && [ -f "$SQLITE_SRC/test/select1.test" ] || {
    echo "tcl_testfixture: ERROR: SQLITE_SRC is not sqlite-src-3540100" >&2
    exit 2
}
[ "$(cat "$SQLITE_SRC/VERSION" 2>/dev/null)" = "3.54.1" ] || {
    echo "tcl_testfixture: ERROR: SQLITE_SRC is not SQLite 3.54.1" >&2
    exit 2
}

T=${TMPDIR:-$ROOT/build}/tcl-testfixture.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

MODE=product
RUNNER=${TCL_NAN16_TESTFIXTURE_RUNNER:-}
if [ -z "$RUNNER" ]; then
    if [ "${TCL_NAN16_TESTFIXTURE_ALLOW_ORACLE:-0}" = 1 ]; then
	RUNNER=$ROOT/aarch64/android/nan_cli
	MODE=oracle
	[ -x "$RUNNER" ] || (cd aarch64/android && make -s nan_cli)
    else
	echo "tcl_testfixture: SKIP (no x86_64 S1 runner; set TCL_NAN16_TESTFIXTURE_RUNNER or TCL_NAN16_TESTFIXTURE_ALLOW_ORACLE=1)"
	exit 77
    fi
fi

echo "tcl_testfixture: build tcc0"
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || \
  (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

echo "tcl_testfixture: pack official VFS"
python3 tools/nan16_suite_pack.py "$T/suite.n16pack" \
    --tree "$SQLITE_SRC/test=/sqlite/test" \
    --tree "$TCL_SRC/library=/usr/lib/tcl9.0" --check
PACK_LEN=$(wc -c < "$T/suite.n16pack" | tr -d ' ')
PACK_COUNT=$(python3 - "$T/suite.n16pack" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
print(struct.unpack_from("<I", d, 8)[0])
PY
)
[ "$PACK_COUNT" = 2133 ] && [ "$PACK_LEN" = 25806592 ] || {
    echo "tcl_testfixture: FAIL (unexpected pack: $PACK_COUNT files, $PACK_LEN bytes; expected 2133 / 25806592)" >&2
    exit 1
}
python3 tools/nan16_pack_image.py "$T/suite.n16pack" \
    --header "$T/tcl_nan16_fixture_pack.h" --base 0x01000000 > "$T/layout.txt"
cat "$T/layout.txt"

echo "tcl_testfixture: generate SQLite build headers"
python3 - third_party/sqlite/sqlite3.c "$T" <<'PY'
import sys
text = open(sys.argv[1], encoding="latin1").read()
for name in ("parse.h", "opcodes.h"):
    begin = "/************** Begin file %s " % name
    end = "/************** End of %s " % name
    a = text.index(begin)
    a = text.index("\n", a) + 1
    b = text.index(end)
    open(sys.argv[2] + "/" + name, "w").write(text[a:b])
PY

GEN=$(sed -n '/^GENERIC_OBJS/,/^$/p' "$TCL_SRC/unix/Makefile.in" \
    | tr ' \\\n\t' '\n' | grep '\.o$' | grep -v '^tclIOSock.o$' \
    | sed "s|^|$TCL_SRC/generic/|;s|\.o$|.c|")
OO=$(sed -n '/^OO_OBJS/,/^$/p' "$TCL_SRC/unix/Makefile.in" \
    | tr ' \\\n\t' '\n' | grep '\.o$' \
    | sed "s|^|$TCL_SRC/generic/|;s|\.o$|.c|")
TM=$(sed -n '/^TOMMATH_OBJS/,/^$/p' "$TCL_SRC/unix/Makefile.in" \
    | tr ' \\\n\t' '\n' | grep '\.o$' \
    | sed "s|^|$TCL_SRC/libtommath/|;s|\.o$|.c|")
ZL=$(for f in adler32 compress crc32 deflate infback inffast inflate \
	inftrees trees uncompr zutil; do
    echo "$TCL_SRC/compat/zlib/$f.c"
done)
PORT_SRCS=$(ls "$PORT"/tclNan16*.c \
    | grep -v 'tclNan16AppInit.c' | grep -v 'tclNan16TestTclsh.c')
TESTS=$(sed -n '/^TESTSRC =/,/^$/p; /^TESTSRC +=/,/^$/p' "$SQLITE_SRC/main.mk" \
    | grep -oE '\$\(TOP\)/[^ ]+\.c' \
    | sed "s|\$(TOP)|$SQLITE_SRC|" | grep -v '/src/test_tclsh.c$')

SQLFLAGS="-DNAN16_HEAP_SIZE=134217728 -DNAN16_SQLITE_VFS_FILES=256 -DNAN16_SQLITE_VFS_NAME=256 -DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_TEMP_STORE=3 \
 -DSQLITE_OMIT_WAL -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_LOCALTIME \
 -DSQLITE_OMIT_DEPRECATED -DSQLITE_DQS=0 -DSQLITE_OMIT_SHARED_CACHE \
 -DSQLITE_MAX_MMAP_SIZE=0 -DNDEBUG \
 -DSQLITE_TEST=1 -DSQLITE_CRASH_TEST=1 \
 -DSQLITE_SERVER=1 -DSQLITE_PRIVATE= -DSQLITE_CORE -DBUILD_sqlite \
 -DSQLITE_SERIES_CONSTRAINT_VERIFY=1 -DSQLITE_DEFAULT_PAGE_SIZE=1024 \
 -DSQLITE_ENABLE_STMTVTAB -DSQLITE_ENABLE_DBPAGE_VTAB \
 -DSQLITE_ENABLE_BYTECODE_VTAB -DSQLITE_ENABLE_CARRAY \
 -DSQLITE_ENABLE_PERCENTILE -DSQLITE_CKSUMVFS_STATIC \
 -DSQLITE_STATIC_RANDOMJSON -DSQLITE_STRICT_SUBTYPE=1 \
 -DSQLITE_NO_SYNC=1"

echo "tcl_testfixture: compile fixture"
"$T/tcc0" -nostdlib -DNDEBUG -o "$T/testfixture.raw.bin" \
    -I"$T" -I"$PORT" -I"$PORT/include" -I"$LIBC/include" -I"$TT/include" \
    -I"$TCL_SRC/generic" -I"$TCL_SRC/compat/zlib" \
    -I"$TCL_SRC/compat/zlib/contrib/minizip" -I"$TCL_SRC/libtommath" \
    -Ithird_party/sqlite -I"$SQLITE_SRC/src" -I"$SQLITE_SRC/ext/qrf" \
    -I"$SQLITE_SRC/ext/misc" -I"$SQLITE_SRC/ext/rtree" \
    -I"$SQLITE_SRC/ext/icu" -I"$SQLITE_SRC/ext/fts3" \
    -I"$SQLITE_SRC/ext/session" \
    -include sqlite_nan16_compat.h \
    -DTCL_THREADS=0 -DTCL_UTF_MAX=4 -DHAVE_TCL_CONFIG_H=1 \
    -DUSE_TCLALLOC=1 \
    -DTCLSH_INIT_PROC=sqlite3TestInit -DTCLSH_MAIN=Sqlite3TestMain \
    $SQLFLAGS \
    third_party/sqlite/sqlite3.c third_party/sqlite/nan16_vfs_libc.c \
    "$SQLITE_SRC/ext/qrf/qrf.c" "$SQLITE_SRC/src/tclsqlite.c" \
    $TESTS "$PORT/tclNan16TestTclsh.c" $GEN $OO $TM $ZL $PORT_SRCS \
    "$TCL_SRC/libtommath/bn_cutoffs.c" "$LIBC/src/libc.c"

python3 tools/nan16_pack_image.py "$T/suite.n16pack" \
    --header "$T/tcl_nan16_fixture_pack.h" --base 0x01000000 \
    --stack-floor 0x01000000 --image "$T/testfixture.raw.bin" \
    --out "$T/testfixture.bin"

echo "tcl_testfixture: run test/select1.test"
"$RUNNER" --img "$T/testfixture.bin" --mem "$MEM" --steps "$STEPS" \
    --guest-script "$TEST" --guest-stdout "$T/stdout" --guest-stderr "$T/stderr" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run.err" || true

SUMMARY=$(grep -E '^[0-9]+ errors out of [0-9]+ tests on ' "$T/stdout" | tail -1 || true)
if [ -z "$SUMMARY" ]; then
    echo "tcl_testfixture: FAIL (official harness did not finish)"
    echo "--- stdout tail"; tail -30 "$T/stdout" 2>/dev/null || true
    echo "--- stderr tail"; tail -20 "$T/stderr" 2>/dev/null || true
    tail -3 "$T/run.err" 2>/dev/null || true
    exit 1
fi
ERRORS=$(echo "$SUMMARY" | awk '{print $1}')
TESTSRUN=$(echo "$SUMMARY" | sed -n 's/.*out of \([0-9][0-9]*\) tests.*/\1/p')
OMITTED=$(awk '/^Omitted test cases:/{f=1;next} f && /^\.  /{n++} END{print n+0}' "$T/stdout")
MAIN=$(tail -n 1 "$T/peek" 2>/dev/null || true)
STEPS_USED=$(sed -n 's/.*: \([0-9][0-9]*\) steps,.*/\1/p' "$T/run.err" | tail -1)
SIZE=$(wc -c < "$T/testfixture.bin" | tr -d ' ')
HASH=$(sha256sum "$T/testfixture.bin" | cut -d' ' -f1)
echo "tcl_testfixture: test=$TEST"
echo "tcl_testfixture: $SUMMARY"
echo "tcl_testfixture: steps=$STEPS_USED memory=${MEM}MiB"
SKIPWARN=$(grep -m1 'WARNING: Multi-threaded tests skipped' "$T/stdout" 2>/dev/null || true)
[ -z "$SKIPWARN" ] || echo "tcl_testfixture: $SKIPWARN"
echo "tcl_testfixture: omitted=$OMITTED cartridge=$SIZE sha256=$HASH main=$MAIN"
if [ "$ERRORS" != 0 ]; then
    echo "tcl_testfixture: FAIL (official harness reported $ERRORS errors)"
    echo "--- first failure context"
    grep -n -m1 -B2 -A8 'FAILED\|Expected:\|!Failures' "$T/stdout" 2>/dev/null || true
    echo "--- stdout tail"; tail -20 "$T/stdout"
    echo "--- stderr tail"; tail -10 "$T/stderr" 2>/dev/null || true
    exit 1
fi
if [ "$MAIN" != "00000000" ]; then
    echo "tcl_testfixture: FAIL (main result $MAIN)"
    tail -10 "$T/stderr" 2>/dev/null || true
    exit 1
fi
echo "tcl_testfixture: omitted test cases:"
awk '/^Omitted test cases:/{f=1;next} f && /^\.  /{print}' "$T/stdout"
if [ "$MODE" = oracle ]; then
    echo "tcl_testfixture: ORACLE MATCH ($TEST: $TESTSRUN tests, 0 errors, x86_64 S1 acceptance pending)"
else
    echo "tcl_testfixture: PASS ($TEST: $TESTSRUN tests, 0 errors)"
fi
