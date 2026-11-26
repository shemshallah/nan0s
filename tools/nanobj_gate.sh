#!/bin/sh
# nanobj_gate.sh - M1a typed object table and capability checks.
#
# Proves on x86_64 S1:
#   create/write/read a typed object
#   grant a read-only capability; write is rejected, read succeeds
#   a forged generation is rejected
#   the last release frees the table entry
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nanobj_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/tests/nanobj_test.nas \
  > "$T/nanobj.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/nanobj.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nanobj_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

S1_KEEP=1 TMPDIR="$T" sh tools/s1_runner.sh --img "$T/nanobj.nan" \
    --mem 128 --steps 2000000 --serial \
    > "$T/run.out" 2> "$T/run.err" || true

COM=$(find "$T" -path '*/s1_runner.*/com' -type f | head -1)
[ -n "$COM" ] || {
  echo "nanobj_gate: FAIL (no COM1 capture)"; tail -8 "$T/run.err"; exit 1; }
grep -q 'NOBJ PASS' "$COM" || {
  echo "nanobj_gate: FAIL (self-test)"; cat -v "$COM"; exit 1; }
grep -q '@@NAN16 END 3' "$COM" || {
  echo "nanobj_gate: FAIL (guest did not halt cleanly)"; cat -v "$COM"; exit 1; }

echo "nanobj_gate: PASS (typed objects, capability rights, forged-generation rejection, free)"
