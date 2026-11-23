#!/bin/sh
# tools/ncc_abi_ll.sh - 64-bit long long ABI runtime gate.
# struct { char; long long } layout, 64-bit varargs (%llx/%lld), long long
# argument passing and return.  Complements ncc_abi_sizes.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccabill.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_abi_ll_test.nas > "$T/a.nan" 2>"$T/e" || {
  echo "ncc_abi_ll: FAIL (assemble)"; cat "$T/e"; exit 1; }
"$CLI" --img "$T/a.nan" --mem 128 --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if cmp -s "$T/got" src/tests/ncc_abi_ll.expected; then
  echo "ncc_abi_ll: PASS (struct layout, %llx/%lld varargs, 64-bit call/return)"
else
  echo "ncc_abi_ll: FAIL"; diff -u src/tests/ncc_abi_ll.expected "$T/got" | head -20
  tail -2 "$T/err"; exit 1
fi
