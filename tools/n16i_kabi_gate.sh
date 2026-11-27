#!/bin/sh
# n16i_kabi_gate.sh - custom NaN ABI (SVC/SVCRET + control words) under n16i.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR/n16i_gate.$$"; T="$TMPDIR/n16i_gate.$$"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/n16i_kabi_test.nas > "$T/t.nan" 2>"$T/e"
timeout 30 aarch64/android/nan_cli --img "$T/t.nan" --mem 8 --steps 5000000 --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "GKOD" ] || {
  echo "n16i_kabi: FAIL (serial '$got', expected GKOD)"
  tail -3 "$T/err"; exit 1; }
echo "n16i_kabi: PASS (n16i custom NaN ABI: SVC/SVCRET, control words, guest kernel)"
