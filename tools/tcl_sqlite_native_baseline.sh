#!/bin/sh
# tools/tcl_sqlite_native_baseline.sh
#
# Build Tcl 9.0.3 and the SQLite 3.54.1 official testfixture, then run the
# native reference tests.  This is the acceptance baseline for the x86_64
# product target.  It refuses non-x86_64 hosts unless TCL_SQLITE_ORACLE=1 is
# set for a development-only oracle run.
#
#   sh tools/tcl_sqlite_native_baseline.sh
#   TCL_SQLITE_JOBS=8 ...              # build parallelism
#   TCL_SQLITE_TESTS="test/select1.test test/quick.test" ...
#   TCL_SQLITE_ORACLE=1 ...            # allow a non-x86_64 dev host
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ;;
    *)
        [ "${TCL_SQLITE_ORACLE:-0}" = 1 ] || {
            echo "tcl_sqlite_native: SKIP (host $ARCH is not x86_64; set TCL_SQLITE_ORACLE=1 only for a dev oracle)" >&2
            exit 1
        }
        echo "tcl_sqlite_native: WARNING non-x86_64 development oracle ($ARCH)"
        ;;
esac
DEST=${TCL_SQLITE_DIR:-${TMPDIR:-$PWD/build}/tcl-sqlite}
JOBS=${TCL_SQLITE_JOBS:-4}
TESTS=${TCL_SQLITE_TESTS:-"test/select1.test test/veryquick.test"}
OUT=${TCL_SQLITE_OUT:-$DEST/native-result.txt}

sh tools/fetch_tcl_sqlite_suite.sh "$DEST"

TCLSRC=$DEST/tcl9.0.3
SQLSRC=$DEST/sqlite-src-3540100
TCLINST=$DEST/tcl-inst

if [ ! -x "$TCLSRC/unix/tclsh" ]; then
    echo "tcl_sqlite_native: build Tcl 9.0.3"
    ( cd "$TCLSRC/unix" && ./configure --disable-shared --prefix="$TCLINST" \
        > "$DEST/tcl-configure.log" 2>&1 && make -j"$JOBS" > "$DEST/tcl-build.log" 2>&1 && make install > "$DEST/tcl-install.log" 2>&1 )
    [ -x "$TCLSRC/unix/tclsh" ] || { echo "tcl_sqlite_native: FAIL Tcl build"; exit 1; }
fi

if [ ! -x "$SQLSRC/testfixture" ]; then
    echo "tcl_sqlite_native: build SQLite testfixture"
    ( cd "$SQLSRC" && ./configure --with-tcl="$TCLINST/lib" --disable-shared \
        > "$DEST/sqlite-configure.log" 2>&1 && \
      PATH="$TCLSRC/unix:$PATH" make -j"$JOBS" testfixture \
        > "$DEST/sqlite-build.log" 2>&1 )
    [ -x "$SQLSRC/testfixture" ] || { echo "tcl_sqlite_native: FAIL testfixture build"; exit 1; }
fi

# Tcl's installed library can be incomplete in staged builds; the source
# library directory is the canonical copy for this test tree.
export TCL_LIBRARY="$TCLSRC/library"
: > "$OUT"
echo "host=$ARCH tcl=9.0.3 sqlite=3.54.1" | tee -a "$OUT"
for t in $TESTS; do
    name=$(basename "$t" .test)
    log=$DEST/native-$name.log
    echo "tcl_sqlite_native: run $t"
    if ( cd "$SQLSRC" && timeout "${TCL_SQLITE_TIMEOUT:-1800}" ./testfixture "$t" ) \
        > "$log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    summary=$(grep -E 'errors? out of|All tests|FAILED|Error' "$log" | tail -n 3 | tr '\n' ';')
    echo "$t rc=$rc $summary" | tee -a "$OUT"
    if [ "$rc" -ne 0 ]; then
        echo "tcl_sqlite_native: FAIL $t (rc=$rc; see $log)" >&2
        exit 1
    fi
    if grep -qE 'errors out of [1-9]|FAILED' "$log"; then
        echo "tcl_sqlite_native: FAIL $t (test errors; see $log)" >&2
        exit 1
    fi
done
echo "tcl_sqlite_native: PASS ($OUT)"
