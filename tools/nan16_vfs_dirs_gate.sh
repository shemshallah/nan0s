#!/bin/sh
# tools/nan16_vfs_dirs_gate.sh - VFS directories and dirent enumeration.
#
# Registers an N16PACK1 archive with only files, then requires /suite and
# /suite/a to behave as implicit directories; checks stat/access, mkdir/rmdir,
# ENOTEMPTY, unlink, and opendir/readdir over both implicit and explicit dirs.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-vfs-dirs.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SRC=src/tests/tcc/vfs_dirs.c
RUNNER=${NAN16_VFS_DIRS_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_VFS_DIRS_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "vfs_dirs: SKIP (no x86_64 S1 runner; set NAN16_VFS_DIRS_RUNNER or NAN16_VFS_DIRS_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "vfs_dirs: FAIL runner not executable: $RUNNER"; exit 1; }

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "vfs_dirs: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "vfs_dirs: build guest"
"$T/tcc0" -nostdlib -o "$T/dirs.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$SRC" > "$T/build.log" 2>&1 || {
    cat "$T/build.log"; exit 1; }

"$RUNNER" --img "$T/dirs.bin" --mem 128 --steps 500000000 \
    --guest-stdout "$T/out" --guest-stderr "$T/err" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run" || true
[ "$(tail -n 1 "$T/peek" 2>/dev/null)" = "00000000" ] || {
    echo "vfs_dirs: FAIL (main result)"; tail -3 "$T/run"; exit 1; }
tr -d '\r' < "$T/out" > "$T/out.norm"

cat > "$T/expected" <<'EOF'
stat suite=1:1
stat a=1:1
stat b=1:1:3
access=0:-1
list /suite=a/ b.txt
list /suite/a=one.txt two.txt
mkdir=0
mkdir2=-1
list /empty=
mkdir-implicit=-1
rmdir-suite=-1
unlink-suite=-1
rmdir-empty=0
absent=1
create=1
rmdir-full=-1
unlink-x=0
rmdir-empty2=0
count=3
VFS DIRS PASS
EOF
if ! diff -u "$T/expected" "$T/out.norm"; then
    echo "vfs_dirs: FAIL (output)"; [ ! -f "$T/err" ] || cat "$T/err"; exit 1
fi

if [ "$MODE" = oracle ]; then
    echo "vfs_dirs: ORACLE MATCH (implicit dirs, mkdir/rmdir, dirent; x86_64 S1 acceptance pending)"
else
    echo "vfs_dirs: PASS (implicit dirs, mkdir/rmdir, dirent)"
fi
