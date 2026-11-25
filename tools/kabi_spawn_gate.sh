#!/bin/sh
# tools/kabi_spawn_gate.sh - process table + spawn/wait lifecycle.
#
# src/prog/kabi_spawn_demo.nas creates a parent process and two children.
# SVC 9 allocates a slot, builds the child's trap frame and three-region
# address space, and returns a pid.  SVC 10 blocks the parent until the child
# exits with SVC 1.  Timer IRQs rotate the run queue.  The demo is ~401 KiB,
# so it also exercises the IDE loader path above the 384 KiB staging window.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/kabi_spawn.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli
awk -f tools/nmk.awk -v CMD=emit src/prog/kabi_spawn_demo.nas > "$T/spawn.nan"
printf '12OK\n' > "$T/expect"

./aarch64/android/nan_cli --img "$T/spawn.nan" --mem 64 --steps 8000000 \
  --serial > "$T/c.out" 2>/dev/null
if ! cmp -s "$T/expect" "$T/c.out"; then
  echo "kabi_spawn: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/c.out"
  exit 1
fi

sh tools/s1_runner.sh --img "$T/spawn.nan" --mem 64 --steps 8000000 \
  --serial > "$T/s1.out" 2> "$T/s1.err"
if ! cmp -s "$T/expect" "$T/s1.out"; then
  echo "kabi_spawn: FAIL (x86_64 S1 transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/s1.out"
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi

echo "kabi_spawn: PASS (process table + spawn/wait + timer round-robin, C oracle == x86_64 S1)"
