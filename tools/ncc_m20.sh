#!/bin/sh
# M20 gate: function-like macros: arguments, nesting, # stringification,
# ## pasting, zero-argument macros, multi-line bodies, #undef/redefine.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm20.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m20_test.nas > "$T/m20.nan"
./aarch64/android/nan_cli --img "$T/m20.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m20.expected "$T/got"; then echo "ncc_m20: PASS ($(wc -l < "$T/got") lines, exact)"; else echo "ncc_m20: FAIL"; tail -3 "$T/err"; exit 1; fi
