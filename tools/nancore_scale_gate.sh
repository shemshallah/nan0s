#!/bin/sh
# nancore_scale_gate.sh - 4096-core NanCore layout/online-bitmap proof.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/nancore_scale.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/nancore_scale_test.nas > "$T/t.nan" 2>"$T/e"
timeout 30 aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 5000000 --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "nancore_scale: FAIL ('$got')"; tail -3 "$T/err"; exit 1; }
echo "nancore_scale: PASS (4096 records, bounds, online bitmap)"
