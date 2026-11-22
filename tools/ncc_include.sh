#!/bin/sh
# ncc_include.sh - #include gate.
# Positive: quoted project header (struct/macro/prototype), nested relative
# include, include guards, <stdio.h>/<stdint.h>, and a nonstandard <...> header
# from NPAF.  Negative: missing include, recursive include, and the line number
# reported for an error inside an included file.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccinc.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)

run() {
  awk -f tools/nmk.awk -v CMD=emit "src/tests/$1.nas" > "$T/$1.nan" 2>"$T/$1.e" || {
    cat "$T/$1.e"; exit 1; }
  "$CLI" --img "$T/$1.nan" --steps 50000000 --serial > "$T/$1.out" 2>"$T/$1.err" || true
}

run ncc_include_test
if diff -u src/tests/ncc_include.expected "$T/ncc_include_test.out"; then
  echo "ncc_include: PASS (quoted/nested/guarded/standard headers, $(wc -l < "$T/ncc_include_test.out") line)"
else
  echo "ncc_include: FAIL (positive)"; exit 1
fi

run ncc_include_missing
if grep -q '^!C0090@0003\[' "$T/ncc_include_missing.out"; then
  echo "ncc_include: PASS (missing include -> !C0090@0003)"
else
  echo "ncc_include: FAIL (missing include)"; cat "$T/ncc_include_missing.out"; exit 1
fi

run ncc_include_recur
if grep -q '^!C0092@0004\[' "$T/ncc_include_recur.out"; then
  echo "ncc_include: PASS (recursive include -> !C0092@0004)"
else
  echo "ncc_include: FAIL (recursive include)"; cat "$T/ncc_include_recur.out"; exit 1
fi

run ncc_include_lines
if grep -Eq '^!C[0-9A-F]+@0003\[' "$T/ncc_include_lines.out"; then
  echo "ncc_include: PASS (error in header reports header line 3)"
else
  echo "ncc_include: FAIL (header line number)"; cat "$T/ncc_include_lines.out"; exit 1
fi
