#!/bin/sh
# tools/kabi_kill_gate.sh - SVC 22 kill(pid, signal) with waiter wakeup.
#
# The parent spawns a child that sleeps for 100 ticks, kills it with signal 9,
# and waits.  The kernel terminates the target, records status 128+signal,
# decrements the live count, and wakes the waiting parent.  Exact transcript:
# KOK.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/kabi_kill.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli
awk -f tools/nmk.awk -v CMD=emit src/prog/kabi_kill_demo.nas > "$T/kill.nan"
printf 'KOK\n' > "$T/expect"

./aarch64/android/nan_cli --img "$T/kill.nan" --mem 64 --steps 8000000 \
  --serial > "$T/c.out" 2>/dev/null
if ! cmp -s "$T/expect" "$T/c.out"; then
  echo "kabi_kill: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/c.out"
  exit 1
fi

sh tools/s1_runner.sh --img "$T/kill.nan" --mem 64 --steps 8000000 \
  --serial > "$T/s1.out" 2> "$T/s1.err"
if ! cmp -s "$T/expect" "$T/s1.out"; then
  echo "kabi_kill: FAIL (x86_64 S1 transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/s1.out"
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi

echo "kabi_kill: PASS (kill + status 128+sig + waiter wakeup, C oracle == x86_64 S1)"
