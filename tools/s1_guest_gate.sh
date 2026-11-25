#!/bin/sh
# tools/s1_guest_gate.sh - x86_64 S1 flat-cartridge acceptance (this slice).
#
# Assembles NaN16 source with tools/nmk.awk, runs the C-core oracle, then runs
# the same text image through tools/s1_runner.sh on the bare-metal x86_64 S1.
# COM1 guest bytes must match exactly.  This is guest-cartridge acceptance for
# the implemented op subset, not full op/device parity.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
ROOT=$(pwd)
T="${TMPDIR:-/tmp}/s1_guest.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

make -s -C aarch64/android nan_cli

run_guest() {
  name=$1; src=$2
  awk -f tools/nmk.awk -v CMD=emit "$src" > "$T/$name.nan" 2>"$T/$name.asm"
  words=$(awk '{
    line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
    n=split(line, a, "_")
    if (n==3 && length(a[1])==4 && length(a[2])==8 && length(a[3])==4) c++
  } END{print c+0}' "$T/$name.nan")
  [ "$words" -gt 0 ] || { echo "s1_guest: FAIL ($name: empty cartridge)"; exit 1; }
  bytes=$((words * 8))
  ./aarch64/android/nan_cli --img "$T/$name.nan" --steps 20000000 \
    --serial > "$T/$name.oracle" 2>/dev/null
  if ! "$ROOT/tools/s1_runner.sh" --img "$T/$name.nan" --mem 64 \
      --steps 20000000 --serial > "$T/$name.s1" 2> "$T/$name.err"; then
    echo "s1_guest: FAIL ($name: runner)"
    cat -v "$T/$name.err" | tail -20
    exit 1
  fi
  if ! cmp -s "$T/$name.oracle" "$T/$name.s1"; then
    echo "s1_guest: FAIL ($name: COM1 differs from C oracle)"
    echo "--- oracle ---"; cat -v "$T/$name.oracle"; echo
    echo "--- x86_64 S1 ---"; cat -v "$T/$name.s1"; echo
    exit 1
  fi
  echo "s1_guest: PASS $name ($words words, $bytes bytes)"
}

run_guest focused src/tests/s1_guest_test.nas
run_guest fp src/tests/s1_fp_test.nas
run_guest nfs2 src/tests/nfs2_test.nas
run_guest far src/tests/far_test.nas
echo "s1_guest: PASS (flat cartridges execute on x86_64 S1; COM1 == C oracle)"
