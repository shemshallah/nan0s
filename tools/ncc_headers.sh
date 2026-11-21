#!/bin/sh
# tools/ncc_headers.sh - C89/C99 header-macro and fixed-width typedef gate.
# ncc has no host headers: the names are installed by src/lib/headers.nas.
# This gate checks the ILP32/32-bit-double values and the int8_t..uint64_t
# typedef sizes in the guest.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccheaders.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_headers_test.nas > "$T/a.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/a.nan" --steps 100000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if cmp -s "$T/got" src/tests/ncc_headers.expected; then
  echo "ncc_headers: PASS (limits/stdint/float/stdio/locale/signal/math macros)"
else
  echo "ncc_headers: FAIL"; diff -u src/tests/ncc_headers.expected "$T/got" | head -20; tail -2 "$T/err"; exit 1
fi
