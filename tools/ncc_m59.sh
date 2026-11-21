#!/bin/sh
# M59 gate: div/ldiv/lldiv aggregate returns.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm59.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m59_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 40000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m59.expected "$T/got"; then echo "ncc_m59: PASS (div/ldiv/lldiv)"; else echo "ncc_m59: FAIL"; tail -2 "$T/err"; exit 1; fi
