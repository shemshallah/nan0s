#!/bin/sh
# tools/nan16_vfs_capacity_gate.sh - dynamic guest VFS capacity directives.
#
# Registers a synthetic 5,000-file N16PACK1 archive with
# -DNAN16_VFS_INIT_CAP=2 (many table doublings) and reads the first and last
# files back.  A second build with -DNAN16_VFS_MAXFILES=4096 must refuse the
# same pack and leave the table empty.
#
# Product acceptance is an x86_64 S1 runner.  The C core is allowed only with
# NAN16_VFS_CAPACITY_ALLOW_ORACLE=1 and is labelled oracle evidence.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-vfs-cap.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SRC=src/tests/tcc/vfs_capacity.c
STEPS=${VFS_CAPACITY_STEPS:-3000000000}
RUNNER=${NAN16_VFS_CAPACITY_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_VFS_CAPACITY_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "vfs_capacity: SKIP (no x86_64 S1 runner; set NAN16_VFS_CAPACITY_RUNNER or NAN16_VFS_CAPACITY_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "vfs_capacity: FAIL runner not executable: $RUNNER"; exit 1; }

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "vfs_capacity: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "vfs_capacity: build guest (unbounded, INIT_CAP=2)"
"$T/tcc0" -nostdlib -o "$T/unbounded.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    -DNAN16_VFS_INIT_CAP=2 \
    "$LIBC/src/libc.c" "$SRC" > "$T/build1.log" 2>&1 || {
    cat "$T/build1.log"; exit 1; }

echo "vfs_capacity: build guest (MAXFILES=4096)"
"$T/tcc0" -nostdlib -o "$T/capped.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    -DNAN16_VFS_INIT_CAP=2 -DNAN16_VFS_MAXFILES=4096 \
    -DVFS_TEST_EXPECT_FAIL \
    "$LIBC/src/libc.c" "$SRC" > "$T/build2.log" 2>&1 || {
    cat "$T/build2.log"; exit 1; }

run_case() {
    name=$1; bin=$2
    "$RUNNER" --img "$bin" --mem 128 --steps "$STEPS" \
        --guest-stdout "$T/$name.out" --guest-stderr "$T/$name.err" \
        --peek '0x100:1' > "$T/$name.peek" 2> "$T/$name.run" || true
    [ "$(tail -n 1 "$T/$name.peek" 2>/dev/null)" = "00000000" ] || {
        echo "vfs_capacity: FAIL ($name main result)"; tail -3 "$T/$name.run"; exit 1; }
    tr -d '\r' < "$T/$name.out" > "$T/$name.norm"
}

run_case unbounded "$T/unbounded.bin"
cat > "$T/unbounded.expected" <<'EOF'
add=5000
count=5000
first=8:00
last=8:87:13:00:00:87:13:00:00
EOF
if ! diff -u "$T/unbounded.expected" "$T/unbounded.norm"; then
    echo "vfs_capacity: FAIL (unbounded output)"; cat "$T/unbounded.err"; exit 1
fi

run_case capped "$T/capped.bin"
cat > "$T/capped.expected" <<'EOF'
add=-1
count=0
capped=1
EOF
if ! diff -u "$T/capped.expected" "$T/capped.norm"; then
    echo "vfs_capacity: FAIL (capped output)"; cat "$T/capped.err"; exit 1
fi

if [ "$MODE" = oracle ]; then
    echo "vfs_capacity: ORACLE MATCH (5000 files, INIT_CAP=2, MAXFILES enforced; x86_64 S1 acceptance pending)"
else
    echo "vfs_capacity: PASS (5000 files, INIT_CAP=2, MAXFILES enforced)"
fi
