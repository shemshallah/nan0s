#!/bin/sh
# M61 gate: strtof/strtold, llabs, strncat, remquo, and the restartable
# multibyte conversions (mbsinit/mbrlen/mbrtowc/wcrtomb/mbsrtowcs/wcsrtombs).
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm61.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m61_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 60000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m61.expected "$T/got"; then echo "ncc_m61: PASS (remaining stdio/math/multibyte names)"; else echo "ncc_m61: FAIL"; tail -2 "$T/err"; exit 1; fi
