#!/bin/sh
# M45 gate: getchar/getc/putc/ungetc/clearerr/setvbuf.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm45.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m45_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 20000000 --keys "Z" --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/ncc_m45.expected "$T/got"; then echo "ncc_m45: PASS (stdio wrappers)"; else echo "ncc_m45: FAIL"; tail -2 "$T/err"; exit 1; fi
