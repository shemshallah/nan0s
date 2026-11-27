#!/bin/sh
# nq4_gate.sh - packed Q4_0/Q8_0 dequant, dot and GEMV, exact f32, pure NaN.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/nq4.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/nq4_test.nas > "$T/t.nan" 2>"$T/e" || {
  cat "$T/e"; exit 1; }
timeout 30 aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 5000000 \
  --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "nq4: FAIL ('$got')"; tail -3 "$T/err"; exit 1; }
echo "nq4: PASS (Q4_0/Q8_0 32-weight blocks, 0.5/-0.5/28.0/-1.25/-128.0 exact dots, 2-row GEMV)"
