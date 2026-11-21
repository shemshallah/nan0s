#!/bin/sh
# Py-M1 gate: a Python-subset interpreter (C compiled by ncc, running on NaN16).
# Supports numbers, variables, arithmetic, print(...), and one-line/indented if bodies.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/pym1.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/py_m1_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 40000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/py_m1.expected "$T/got"; then echo "py_m1: PASS (Python subset on NaN16)"; else echo "py_m1: FAIL"; tail -2 "$T/err"; exit 1; fi
