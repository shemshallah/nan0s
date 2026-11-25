#!/bin/sh
# tools/kabi_load_gate.sh - load a position-independent program image into a
# nalloc-backed extent and spawn it.
#
# The parent holds an in-memory NIMG header plus code/data payload.  SVC 23
# allocates code+data from the nalloc heap, copies the image to the new base,
# builds a three-region space, and returns a pid.  The child prints L and exits
# with status 30; the parent checks the status and prints OK.  Exact LOK.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/kabi_load.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli
awk -f tools/nmk.awk -v CMD=emit src/prog/kabi_load_demo.nas > "$T/load.nan"
printf 'LOK\n' > "$T/expect"

./aarch64/android/nan_cli --img "$T/load.nan" --mem 64 --steps 8000000 \
  --serial > "$T/c.out" 2>/dev/null
if ! cmp -s "$T/expect" "$T/c.out"; then
  echo "kabi_load: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/c.out"
  exit 1
fi

sh tools/s1_runner.sh --img "$T/load.nan" --mem 64 --steps 8000000 \
  --serial > "$T/s1.out" 2> "$T/s1.err"
if ! cmp -s "$T/expect" "$T/s1.out"; then
  echo "kabi_load: FAIL (x86_64 S1 transcript)"
  echo "--- expected ---"; cat -v "$T/expect"
  echo "--- actual ---"; cat -v "$T/s1.out"
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi

echo "kabi_load: PASS (allocate + copy + relocate + spawn, C oracle == x86_64 S1)"
