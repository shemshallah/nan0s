#!/bin/sh
# tools/kabi_sched_gate.sh - timer-preempted two-process scheduler demo.
#
# src/prog/kabi_sched_demo.nas gives A and B separate code/data regions and
# trap frames.  The kernel starts A, switches on every timer IRQ, and switches
# again when a process exits.  Output is instruction-timed and must match
# exactly between the C oracle and the x86_64 S1.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/kabi_sched.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli
awk -f tools/nmk.awk -v CMD=emit src/prog/kabi_sched_demo.nas > "$T/sched.nan"
printf 'AAAABBBBAABB' > "$T/expect"

./aarch64/android/nan_cli --img "$T/sched.nan" --mem 64 --steps 4000000 \
  --serial > "$T/c.out" 2>/dev/null
if ! cmp -s "$T/expect" "$T/c.out"; then
  echo "kabi_sched: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expect"; echo
  echo "--- actual ---"; cat -v "$T/c.out"; echo
  exit 1
fi

sh tools/s1_runner.sh --img "$T/sched.nan" --mem 64 --steps 4000000 \
  --serial > "$T/s1.out" 2> "$T/s1.err"
if ! cmp -s "$T/c.out" "$T/s1.out"; then
  echo "kabi_sched: FAIL (x86_64 S1 differs from C oracle)"
  echo "--- C ---"; cat -v "$T/c.out"; echo
  echo "--- S1 ---"; cat -v "$T/s1.out"; echo
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi

echo "kabi_sched: PASS (timer preemption + per-process regions, C oracle == x86_64 S1)"
