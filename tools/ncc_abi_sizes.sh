#!/bin/sh
# tools/ncc_abi_sizes.sh - 64-bit ABI size/alignment audit.
# Prints sizeof and _Alignof for the fundamental types, pointers and three
# representative structs.  The current expected file is the pre-64-bit
# baseline; it must be updated deliberately when the ABI changes.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccabi.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_abi_sizes_test.nas > "$T/a.nan" 2>"$T/e" || {
  echo "ncc_abi_sizes: FAIL (assemble)"; cat "$T/e"; exit 1; }
"$CLI" --img "$T/a.nan" --mem 128 --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if cmp -s "$T/got" src/tests/ncc_abi_sizes.expected; then
  echo "ncc_abi_sizes: PASS (sizeof/align baseline, 4 lines)"
else
  echo "ncc_abi_sizes: FAIL"; diff -u src/tests/ncc_abi_sizes.expected "$T/got" | head -20
  tail -2 "$T/err"; exit 1
fi
