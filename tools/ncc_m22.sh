#!/bin/sh
# M22 gate: time.h (gmtime/mktime/asctime/ctime/difftime/time/clock),
# locale.h, signal.h, atof/strtod, and standard limits constants.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm22.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m22_test.nas > "$T/m22.nan"
./aarch64/android/nan_cli --img "$T/m22.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m22.expected "$T/got"; then echo "ncc_m22: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m22: FAIL"; tail -3 "$T/err"; exit 1; fi
