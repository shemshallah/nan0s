#!/bin/sh
# nantensor_gate.sh - M1b tensor metadata, zero-copy views and namespace.
#
# Proves on x86_64 S1:
#   tensor create over a storage BLOB capability
#   shape/stride/count/storage metadata
#   zero-copy view with shared storage and view flag
#   capability namespace set/get and miss
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nantensor_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/tests/nantensor_test.nas \
  > "$T/nantensor.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/nantensor.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nantensor_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

S1_KEEP=1 TMPDIR="$T" sh tools/s1_runner.sh --img "$T/nantensor.nan" \
    --mem 128 --steps 3000000 --serial \
    > "$T/run.out" 2> "$T/run.err" || true

COM=$(find "$T" -path '*/s1_runner.*/com' -type f | head -1)
[ -n "$COM" ] || {
  echo "nantensor_gate: FAIL (no COM1 capture)"; tail -8 "$T/run.err"; exit 1; }
grep -q 'NTENSOR PASS' "$COM" || {
  echo "nantensor_gate: FAIL (self-test)"; cat -v "$COM"; exit 1; }
grep -q '@@NAN16 END 3' "$COM" || {
  echo "nantensor_gate: FAIL (guest did not halt cleanly)"; cat -v "$COM"; exit 1; }

echo "nantensor_gate: PASS (tensor shape/stride/storage, zero-copy view, namespace)"
