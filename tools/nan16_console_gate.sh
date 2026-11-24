#!/bin/sh
# tools/nan16_console_gate.sh - guest stdout/stderr control-block ABI.
#
# A tcc0-built guest program writes through printf; nan_cli reads the fixed
# guest control block (0x03EFF000) and dumps the captured buffers.  This is
# the terminal-client path the Tcl/testfixture harness will use.
#
# Product acceptance is an x86_64 runner.  The C core is allowed only with
# NAN16_CONSOLE_ALLOW_ORACLE=1 and is labelled as oracle evidence.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nan16-console.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
RUNNER=${NAN16_CONSOLE_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NAN16_CONSOLE_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "nan16_console: SKIP (no x86_64 S1 runner; set NAN16_CONSOLE_RUNNER or NAN16_CONSOLE_ALLOW_ORACLE=1)"
        exit 77
    fi
fi

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "nan16_console: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

cat > "$T/hello.c" <<'EOC'
#include <stdio.h>
int main(void)
{
    printf("hello %d %s\n", 42, "ok");
    fprintf(stderr, "err %d\n", 7);
    return 0;
}
EOC

echo "nan16_console: build guest"
"$T/tcc0" -nostdlib -o "$T/hello.bin" -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$T/hello.c"

"$RUNNER" --img "$T/hello.bin" --mem 128 --steps 5000000 \
    --guest-stdout "$T/stdout" --guest-stderr "$T/stderr" \
    --peek '0x100:1' > "$T/peek" 2> "$T/run.err" || true

[ "$(tail -n 1 "$T/peek")" = "00000000" ] || {
    echo "nan16_console: FAIL (main result)"; cat "$T/run.err"; exit 1; }
[ "$(cat "$T/stdout" 2>/dev/null)" = "hello 42 ok" ] || {
    echo "nan16_console: FAIL (stdout: $(cat "$T/stdout" 2>/dev/null))"; exit 1; }
[ "$(cat "$T/stderr" 2>/dev/null)" = "err 7" ] || {
    echo "nan16_console: FAIL (stderr: $(cat "$T/stderr" 2>/dev/null))"; exit 1; }

if [ "$MODE" = oracle ]; then
    echo "nan16_console: ORACLE MATCH (x86_64 S1 acceptance pending)"
else
    echo "nan16_console: PASS (guest stdout/stderr control block)"
fi
