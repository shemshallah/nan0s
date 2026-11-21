#!/bin/sh
# M48 gate: wide-string and multibyte helpers.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm48.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m48_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m48.expected "$T/got"; then echo "ncc_m48: PASS (wide/multibyte helpers)"; else echo "ncc_m48: FAIL"; tail -2 "$T/err"; exit 1; fi
