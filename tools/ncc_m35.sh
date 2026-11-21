#!/bin/sh
# M35 gate: memchr/strcoll/strxfrm/strerror/perror.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm35.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m35_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m35.expected "$T/got"; then echo "ncc_m35: PASS (memchr/strcoll/strxfrm/strerror/perror)"; else echo "ncc_m35: FAIL"; tail -2 "$T/err"; exit 1; fi
