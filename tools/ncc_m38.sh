#!/bin/sh
# M38 gate: strtol/strtoul/strtoll/strtoull with bases and endptr.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm38.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m38_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m38.expected "$T/got"; then echo "ncc_m38: PASS (strto* family)"; else echo "ncc_m38: FAIL"; tail -2 "$T/err"; exit 1; fi
