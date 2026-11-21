#!/bin/sh
# M51 gate: atexit order, exit(), and _Exit().
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm51.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
: > "$T/got"
for n in ncc_m51a ncc_m51b ncc_m51c; do
  awk -f tools/nmk.awk -v CMD=emit "src/tests/$n.nas" > "$T/$n.nan"
  ./aarch64/android/nan_cli --img "$T/$n.nan" --steps 400000000 --serial > "$T/o" 2>"$T/e" || true
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/o" >> "$T/got"
done
if diff -u src/tests/ncc_m51.expected "$T/got"; then echo "ncc_m51: PASS (atexit/exit/_Exit)"; else echo "ncc_m51: FAIL"; cat "$T/got"; exit 1; fi
