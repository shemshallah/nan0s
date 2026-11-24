#!/bin/sh
# tools/nan16_vfs_paths_gate.sh - guest cwd, relative paths, normalization.
#
# Checks chdir/getcwd, relative open/stat/access, "." and ".." folding,
# realpath, and mkdir/rmdir through the cwd.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-vfs-paths.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SRC=src/tests/tcc/vfs_paths.c
RUNNER=${NAN16_VFS_PATHS_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_VFS_PATHS_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "vfs_paths: SKIP (no x86_64 S1 runner; set NAN16_VFS_PATHS_RUNNER or NAN16_VFS_PATHS_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "vfs_paths: FAIL runner not executable: $RUNNER"; exit 1; }

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "vfs_paths: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "vfs_paths: build guest"
"$T/tcc0" -nostdlib -o "$T/paths.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$SRC" > "$T/build.log" 2>&1 || {
    cat "$T/build.log"; exit 1; }

"$RUNNER" --img "$T/paths.bin" --mem 128 --steps 500000000 \
    --guest-stdout "$T/out" --guest-stderr "$T/err" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run" || true
[ "$(tail -n 1 "$T/peek" 2>/dev/null)" = "00000000" ] || {
    echo "vfs_paths: FAIL (main result)"; tail -3 "$T/run"; exit 1; }
tr -d '\r' < "$T/out" > "$T/out.norm"

cat > "$T/expected" <<'EOF'
cwd0=1
chdir1=0
cwd1=/suite
cwd2=/suite/a
one=1:1
dotdot=1:3
abs=/suite/b.txt
access=0
read=1
mkdir=0
tmpdir=1
cwdtmp=/suite/a/tmp
up=/suite/a
rmtmp=0
bad=-1
final=/suite/a
env0=1
set=0
get=1:one
noover=0:one
over=0:two
unset=1
PATHS PASS
EOF
if ! diff -u "$T/expected" "$T/out.norm"; then
    echo "vfs_paths: FAIL (output)"; [ ! -f "$T/err" ] || cat "$T/err"; exit 1
fi

if [ "$MODE" = oracle ]; then
    echo "vfs_paths: ORACLE MATCH (cwd + normalized relative paths; x86_64 S1 acceptance pending)"
else
    echo "vfs_paths: PASS (cwd + normalized relative paths)"
fi
