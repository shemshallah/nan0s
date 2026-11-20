#!/bin/sh
# M15 gate: math built-ins (sqrt/fabs/pow/exp/log/tanh/floor/ceil/fmod/fmin/fmax).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm15.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m15_test.nas > "$T/m15.nan"
./aarch64/android/nan_cli --img "$T/m15.nan" --steps 300000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m15.expected "$T/got"; then echo "ncc_m15: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m15: FAIL"; tail -3 "$T/err"; exit 1; fi
