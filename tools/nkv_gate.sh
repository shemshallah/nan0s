#!/bin/sh
# nkv_gate.sh - 64-bit zero-copy tensor views + per-agent KV slabs, pure NaN.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/nkv.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/nkv_test.nas > "$T/t.nan" 2>"$T/e" || {
  cat "$T/e"; exit 1; }
timeout 30 aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 5000000 \
  --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "nkv: FAIL ('$got')"; tail -3 "$T/err"; exit 1; }
echo "nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)"
