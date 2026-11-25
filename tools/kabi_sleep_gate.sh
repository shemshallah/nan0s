#!/bin/sh
# tools/kabi_sleep_gate.sh - tick time, blocking sleep, wakeup, idle process.
#
# The parent spawns a child.  The child reads SVC 11 time, sleeps three ticks
# with SVC 24, reads time again, and verifies the tick delta before printing S
# and exiting 30.  An idle process keeps the machine running while both real
# processes are blocked, so timer IRQs can advance the tick counter.  The
# parent waits, checks status 30, and prints OK.  Exact transcript: SOK.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/kabi_sleep.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli
awk -f tools/nmk.awk -v CMD=emit src/prog/kabi_sleep_demo.nas > "$T/sleep.nan"
printf 'SOK\n' > "$T/expect"

./aarch64/android/nan_cli --img "$T/sleep.nan" --mem 64 --steps 8000000 \
  --serial > "$T/c.out" 2>/dev/null
if ! cmp -s "$T/expect" "$T/c.out"; then
  echo "kabi_sleep: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/c.out"
  exit 1
fi

sh tools/s1_runner.sh --img "$T/sleep.nan" --mem 64 --steps 8000000 \
  --serial > "$T/s1.out" 2> "$T/s1.err"
if ! cmp -s "$T/expect" "$T/s1.out"; then
  echo "kabi_sleep: FAIL (x86_64 S1 transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/s1.out"
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi

echo "kabi_sleep: PASS (ticks + blocking sleep + wakeup + idle, C oracle == x86_64 S1)"
