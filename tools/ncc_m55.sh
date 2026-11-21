#!/bin/sh
# M55 gate: wide numeric conversions (wcstol/wcstoul/wcstoll/wcstoull/wcstod).
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm55.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m55_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 40000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m55.expected "$T/got"; then echo "ncc_m55: PASS (wide numeric conversions)"; else echo "ncc_m55: FAIL"; tail -2 "$T/err"; exit 1; fi
