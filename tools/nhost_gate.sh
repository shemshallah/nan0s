#!/bin/sh
# nhost_gate.sh - the NaN-native self-hosting assembler matches nmk.awk.
# nhost.nas (NaN) expands .include and assembles a bundle read from ATA; the
# output must be the exact .nan word stream nmk.awk produces for the same tree.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nhost_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || { echo "nhost_gate: SKIP (nan_cli absent)"; exit 0; }

awk -f tools/nmk.awk -v CMD=emit src/prog/nhost.nas > "$T/nhost.nan" 2>"$T/nhost.err" ||
  { cat "$T/nhost.err" >&2; exit 1; }

# Bundle the nrun_test include tree: tests/nrun_test.nas -> tools/n16i.nas,
# prog/nasm0.nas -> prog/nasm.nas -> prog/nasm0_tables.nas.
{
  echo ';@MAIN tests/nrun_test.nas'
  echo ';@FILE tests/nrun_test.nas'; cat src/tests/nrun_test.nas
  echo ';@FILE tools/n16i.nas'; cat src/tools/n16i.nas
  echo ';@FILE prog/nasm0.nas'; cat src/prog/nasm0.nas
  echo ';@FILE prog/nasm.nas'; cat src/prog/nasm.nas
  echo ';@FILE prog/nasm0_tables.nas'; cat src/prog/nasm0_tables.nas
} > "$T/bundle.txt"
sz=$(wc -c < "$T/bundle.txt"); rem=$((sz % 512))
[ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$T/bundle.txt" 2>/dev/null
cp "$T/bundle.txt" "$T/bundle.img"

timeout 180 "$CLI" --img "$T/nhost.nan" --disk "$T/bundle.img" --mem 64 \
  --steps 8000000000 --serial > "$T/nhost.out" 2>"$T/nhost.run" || true
grep -q '^;END .* err=00000000' "$T/nhost.out" ||
  { echo "nhost_gate: FAIL (nhost errors)"; tail -3 "$T/nhost.out"; exit 1; }

awk -f tools/nmk.awk -v CMD=emit src/tests/nrun_test.nas > "$T/nmk.nan" 2>"$T/nmk.err" ||
  { cat "$T/nmk.err" >&2; exit 1; }
grep -E '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' "$T/nhost.out" |
  sed 's/[[:space:]].*//' > "$T/nhost.words"
grep -E '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' "$T/nmk.nan" |
  sed 's/[[:space:]].*//' > "$T/nmk.words"
cmp -s "$T/nhost.words" "$T/nmk.words" ||
  { echo "nhost_gate: FAIL (word stream differs)"; diff -u "$T/nmk.words" "$T/nhost.words" | head -12; exit 1; }
n=$(wc -l < "$T/nhost.words")
echo "nhost_gate: PASS ($n words; nhost .include expansion == nmk.awk)"
