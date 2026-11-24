#!/bin/sh
# tools/tcl_nan16_port_gate.sh - milestone 1: tcc0-built tclsh on NaN16.
#
# Requires TCL_SRC to point at an extracted Tcl 9.0.3 source tree.  The gate
# builds tcc0, then compiles the Tcl generic core, libtommath, zlib, the
# tclNan16 platform layer and the NaN16 libc into one flat guest cartridge.
# The guest mounts an N16PACK1 VFS containing /test.tcl and a minimal
# /usr/lib/tcl9.0/init.tcl, evaluates /test.tcl, and must print exactly:
#
#   hello 42
#   2
#
# Product acceptance is an x86_64 S1 runner supplied with
# TCL_NAN16_PORT_RUNNER.  The portable C core is only used when
# TCL_NAN16_PORT_ALLOW_ORACLE=1 and its result is labelled oracle evidence.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
PORT=src/tests/tcl_sqlite/nan16
STEPS=${TCL_NAN16_PORT_STEPS:-8000000000}

TCL_SRC=${TCL_SRC:-}
if [ -z "$TCL_SRC" ]; then
    if [ "${TCL_NAN16_PORT_ALLOW_DEFAULT_TCL_SRC:-0}" = 1 ]; then
	TCL_SRC=${TMPDIR:-$ROOT/build}/tcl-sqlite/tcl9.0.3
    else
	echo "tcl_nan16_port: ERROR: set TCL_SRC to an extracted Tcl 9.0.3 tree" >&2
	echo "tcl_nan16_port: (fetch with: tools/fetch_tcl_sqlite_suite.sh DIR)" >&2
	exit 2
    fi
fi
[ -f "$TCL_SRC/generic/tcl.h" ] || {
    echo "tcl_nan16_port: ERROR: TCL_SRC=$TCL_SRC is not a Tcl source tree" >&2
    exit 2
}
grep -Eq 'TCL_PATCH_LEVEL[[:space:]]+"9\.0\.3"' "$TCL_SRC/generic/tcl.h" || {
    echo "tcl_nan16_port: ERROR: TCL_SRC is not Tcl 9.0.3" >&2
    exit 2
}

T=${TMPDIR:-$ROOT/build}/tcl-nan16-port.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

MODE=product
RUNNER=${TCL_NAN16_PORT_RUNNER:-}
if [ -z "$RUNNER" ]; then
    if [ "${TCL_NAN16_PORT_ALLOW_ORACLE:-0}" = 1 ]; then
	RUNNER=$ROOT/aarch64/android/nan_cli
	MODE=oracle
	[ -x "$RUNNER" ] || (cd aarch64/android && make -s nan_cli)
    else
	echo "tcl_nan16_port: SKIP (no x86_64 S1 runner; set TCL_NAN16_PORT_RUNNER or TCL_NAN16_PORT_ALLOW_ORACLE=1)"
	exit 77
    fi
fi

echo "tcl_nan16_port: build tcc0"
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || \
  (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

echo "tcl_nan16_port: pack guest VFS"
cat > "$T/test.tcl" <<'EOS'
puts "hello [expr {6*7}]"
set x 1
incr x
puts $x
EOS
python3 tools/nan16_suite_pack.py "$T/suite.n16pack" \
    --file /test.tcl="$T/test.tcl" \
    --tree "$TCL_SRC/library=/usr/lib/tcl9.0"
python3 tools/nan16_embed.py "$T/tcl_nan16_pack.h" \
    tcl_nan16_pack="$T/suite.n16pack"

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
PORT_SRCS=$(ls "$PORT"/tclNan16*.c | grep -v '/tclNan16Test')
NGEN=$(echo $GEN | wc -w)
NOO=$(echo $OO | wc -w)
NTM=$(echo $TM | wc -w)
NPORT=$(echo $PORT_SRCS | wc -w)

echo "tcl_nan16_port: compile guest ($NGEN generic + $NOO OO + $NTM tommath + 11 zlib + $NPORT port)"
"$T/tcc0" -nostdlib -DNDEBUG -o "$T/tclsh.bin" \
    -I"$T" -I"$PORT" -I"$PORT/include" -I"$LIBC/include" -I"$TT/include" \
    -I"$TCL_SRC/generic" -I"$TCL_SRC/compat/zlib" \
    -I"$TCL_SRC/compat/zlib/contrib/minizip" -I"$TCL_SRC/libtommath" \
    -DTCL_THREADS=0 -DHAVE_TCL_CONFIG_H=1 \
    $GEN $OO $TM $ZL $PORT_SRCS \
    "$TCL_SRC/libtommath/bn_cutoffs.c" "$LIBC/src/libc.c"

echo "tcl_nan16_port: run guest"
"$RUNNER" --img "$T/tclsh.bin" --mem 128 --steps "$STEPS" \
    --guest-stdout "$T/stdout" --guest-stderr "$T/stderr" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run.err" || true

FAIL=
if [ "$(tail -n 1 "$T/peek" 2>/dev/null)" != "00000000" ]; then
    echo "tcl_nan16_port: FAIL (main result)"
    tail -n 3 "$T/run.err" 2>/dev/null || true
    FAIL=1
fi
printf 'hello 42\n2\n' > "$T/expected"
if ! cmp -s "$T/stdout" "$T/expected"; then
    echo "tcl_nan16_port: FAIL (stdout)"
    echo "--- expected"; cat "$T/expected"
    echo "--- actual"; cat "$T/stdout" 2>/dev/null
    FAIL=1
fi
if [ -s "$T/stderr" ]; then
    echo "tcl_nan16_port: FAIL (stderr)"
    cat "$T/stderr"
    FAIL=1
fi
[ -z "$FAIL" ] || exit 1

SIZE=$(wc -c < "$T/tclsh.bin" | tr -d ' ')
HASH=$(sha256sum "$T/tclsh.bin" | cut -d' ' -f1)
echo "tcl_nan16_port: cartridge $SIZE bytes sha256 $HASH"
if [ "$MODE" = oracle ]; then
    echo "tcl_nan16_port: ORACLE MATCH (x86_64 S1 acceptance pending)"
else
    echo "tcl_nan16_port: PASS (guest VFS tclsh, exact stdout + main result 0)"
fi
