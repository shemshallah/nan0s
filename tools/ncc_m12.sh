#!/bin/sh
# M12 gate: user variadic functions (va_list/va_start/va_arg/va_end),
# including int/char/float/struct arguments.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm12.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m12_test.nas > "$T/m12.nan"
./aarch64/android/nan_cli --img "$T/m12.nan" --steps 300000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m12.expected "$T/got"; then echo "ncc_m12: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m12: FAIL"; tail -3 "$T/err"; exit 1; fi
