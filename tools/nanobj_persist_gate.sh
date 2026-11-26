#!/bin/sh
# nanobj_persist_gate.sh - M1c object snapshot save/load validation.
#
# Uses a RAM hook to prove: create/write, save, wipe, load, read; and a
# corrupted snapshot magic is rejected before the live table is replaced.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nanobj_persist_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

awk -f tools/nmk.awk -v CMD=emit src/tests/nanobj_persist_test.nas \
  > "$T/nanobj_persist.nan" 2> "$T/emit.err"
awk -f tools/nmk.awk -v CMD=check "$T/nanobj_persist.nan" 2> "$T/check.err"
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nanobj_persist_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

S1_KEEP=1 TMPDIR="$T" sh tools/s1_runner.sh --img "$T/nanobj_persist.nan" \
    --mem 128 --steps 4000000 --serial \
    > "$T/run.out" 2> "$T/run.err" || true

COM=$(find "$T" -path '*/s1_runner.*/com' -type f | head -1)
[ -n "$COM" ] || {
  echo "nanobj_persist_gate: FAIL (no COM1 capture)"; tail -8 "$T/run.err"; exit 1; }
grep -q 'NOBJ PERSIST PASS' "$COM" || {
  echo "nanobj_persist_gate: FAIL (self-test)"; cat -v "$COM"; exit 1; }
grep -q '@@NAN16 END 3' "$COM" || {
  echo "nanobj_persist_gate: FAIL (guest did not halt cleanly)"; cat -v "$COM"; exit 1; }

echo "nanobj_persist_gate: PASS (snapshot save/load, magic validation, tamper rejection)"
