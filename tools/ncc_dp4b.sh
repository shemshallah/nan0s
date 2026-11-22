#!/bin/sh
# tools/ncc_dp4b.sh - C-level DP4B builtin gate.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccdp4b.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_dp4b_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 200000000 --serial > "$T/o" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/o" > "$T/got"
cmp -s "$T/got" src/tests/dp4b.expected || { echo "ncc_dp4b: FAIL"; diff -u src/tests/dp4b.expected "$T/got" | head -20; tail -2 "$T/err"; exit 1; }
echo "ncc_dp4b: PASS (C dp4b builtin emits 0x4A, exact vectors)"
