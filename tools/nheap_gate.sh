#!/bin/sh
# nheap_gate.sh - pure-NaN 64-bit per-NUMA 4K/2M/1G page allocator proof.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/nheap.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/nheap_test.nas > "$T/t.nan" 2>"$T/e" || {
  cat "$T/e"; exit 1; }
timeout 30 aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 5000000 \
  --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "nheap: FAIL ('$got')"; tail -3 "$T/err"; exit 1; }
echo "nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)"
