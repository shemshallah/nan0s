#!/bin/sh
# nmem_scale_gate.sh - 2 TB memory object + 1 TB capability view, 64-bit.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/nmem_scale.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/nmem_scale_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
timeout 30 aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 5000000 --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || { echo "nmem_scale: FAIL ('$got')"; tail -3 "$T/err"; exit 1; }
echo "nmem_scale: PASS (2 TiB object, 1 TiB 64-bit view, bounds/rights/node)"
