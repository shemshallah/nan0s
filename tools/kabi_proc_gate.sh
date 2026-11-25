#!/bin/sh
# tools/kabi_proc_gate.sh - region-isolated SVC process + MEMQ heap on both
# the portable C oracle and the x86_64 bare-metal S1.
#
# src/prog/kabi_proc_demo.nas configures code/data regions, receives a heap
# grant through SVC region_map (backed by nalloc), writes inside the grant,
# and deliberately touches an unmapped table word.  The kernel handles the
# fault and resumes at a recovery label.  Exact COM1 text is the oracle.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/kabi_proc.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli
awk -f tools/nmk.awk -v CMD=emit src/prog/kabi_proc_demo.nas > "$T/proc.nan"
printf 'MAPPED\r\nFAULT\r\nISOLATED\r\nOK\r\n' > "$T/expect"

./aarch64/android/nan_cli --img "$T/proc.nan" --mem 64 --steps 4000000 \
  --serial > "$T/c.out" 2>/dev/null
if ! cmp -s "$T/expect" "$T/c.out"; then
  echo "kabi_proc: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/c.out"
  exit 1
fi

sh tools/s1_runner.sh --img "$T/proc.nan" --mem 64 --steps 4000000 \
  --serial > "$T/s1.out" 2> "$T/s1.err"
if ! cmp -s "$T/expect" "$T/s1.out"; then
  echo "kabi_proc: FAIL (x86_64 S1 transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/s1.out"
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi

echo "kabi_proc: PASS (region_map + nalloc grant + fault isolation, C oracle == x86_64 S1)"
