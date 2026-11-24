#!/bin/sh
# tools/nan16_time_gate.sh - guest monotonic time, nanosleep and UTC calendar.
#
# The runner publishes ms/steps at guest byte 0x03EFF010.  This gate requires
# time to advance, nanosleep to wait, and gmtime(0)/gmtime(1700000000) to match
# the UTC calendar exactly.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-time.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SRC=src/tests/tcc/time_probe.c
RUNNER=${NAN16_TIME_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_TIME_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "nan16_time: SKIP (no x86_64 S1 runner; set NAN16_TIME_RUNNER or NAN16_TIME_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "nan16_time: FAIL runner not executable: $RUNNER"; exit 1; }

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "nan16_time: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl 2> "$T/tcc0.log" || { cat "$T/tcc0.log"; exit 1; }

echo "nan16_time: build guest"
"$T/tcc0" -nostdlib -o "$T/time.bin" \
    -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$SRC" > "$T/build.log" 2>&1 || {
    cat "$T/build.log"; exit 1; }

"$RUNNER" --img "$T/time.bin" --mem 128 --steps 3000000000 \
    --guest-stdout "$T/out" --guest-stderr "$T/err" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run" || true
[ "$(tail -n 1 "$T/peek" 2>/dev/null)" = "00000000" ] || {
    echo "nan16_time: FAIL (main result)"; tail -3 "$T/run"; exit 1; }
tr -d '\r' < "$T/out" > "$T/out.norm"

cat > "$T/expected" <<'EOF'
advance=1
epoch=1970:1:1:0:0:0:4:0
date=2023:11:14:22:13:20:2:317
clock=1
sleep=1
TIME PASS
EOF
if ! diff -u "$T/expected" "$T/out.norm"; then
    echo "nan16_time: FAIL (output)"; [ ! -f "$T/err" ] || cat "$T/err"; exit 1
fi

if [ "$MODE" = oracle ]; then
    echo "nan16_time: ORACLE MATCH (monotonic time + UTC calendar; x86_64 S1 acceptance pending)"
else
    echo "nan16_time: PASS (monotonic time + UTC calendar)"
fi
