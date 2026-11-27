#!/bin/sh
# nkcas_gate.sh - pure-NaN content-addressed store persistence/cold hydration.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/nkcas.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
awk -f tools/nmk.awk -v CMD=emit src/tests/nkcas_test.nas > "$T/t.nan" 2>"$T/e" || {
  echo "nkcas: FAIL (emit)"; cat "$T/e"; exit 1; }
awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2>"$T/c" || {
  echo "nkcas: FAIL (check)"; cat "$T/c"; exit 1; }
grep -q '^check: 0 mismatches$' "$T/c" || { echo "nkcas: FAIL (roundtrip)"; cat "$T/c"; exit 1; }
timeout 180 aarch64/android/nan_cli --img "$T/t.nan" --mem 64 --steps 200000000 \
  --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "nkcas: FAIL ('$got')"; tail -5 "$T/err"; exit 1; }
# second cold run must be byte-identical
timeout 180 aarch64/android/nan_cli --img "$T/t.nan" --mem 64 --steps 200000000 \
  --serial > "$T/out2" 2>/dev/null || true
[ "$(cat "$T/out2")" = "O" ] || { echo "nkcas: FAIL (rerun)"; exit 1; }
echo "nkcas: PASS (persist, cold mount, dedup, hydrate/proofs, registry hydrate, collision/corruption fail-closed, deterministic)"
