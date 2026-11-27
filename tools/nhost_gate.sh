#!/bin/sh
# nhost_gate.sh - the NaN-native self-hosting assembler matches nmk.awk.
# nhost.nas (NaN) expands .include and assembles a bundle read from ATA; the
# output must be the exact .nan word stream nmk.awk produces for the same tree.
# Phase 1 is the small nrun_test tree; phase 2 is the full 51-file product
# guest (530,842 words, ~35 s).
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
echo "nhost_gate: PASS phase 1 ($n words; nhost .include expansion == nmk.awk)"

# ---- phase 2: the full 51-file product guest (530,842 words) ----------------
# nmk.awk is still the oracle here; nhost must reproduce its stream exactly,
# including duplicate-name last-definition semantics, LDS/STS promotion and
# far JMP/CALL -> JMPF/CALLF promotion.
awk -f tools/nhost_bundle.awk -v MAIN=src/gui/gui_sched_boot.nas > "$T/guest.bundle" ||
  { echo "nhost_gate: FAIL (bundler)"; exit 1; }
sz=$(wc -c < "$T/guest.bundle"); rem=$((sz % 512))
[ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$T/guest.bundle" 2>/dev/null
cp "$T/guest.bundle" "$T/guest.img"

timeout 600 "$CLI" --img "$T/nhost.nan" --disk "$T/guest.img" --mem 128 \
  --steps 80000000000 --serial > "$T/guest.out" 2> "$T/guest.run" || true
grep -q '^;END .* err=00000000' "$T/guest.out" ||
  { echo "nhost_gate: FAIL (full guest errors)"; tail -3 "$T/guest.out"; exit 1; }

awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas > "$T/guest.nmk" 2> "$T/guest.nmk.err" ||
  { cat "$T/guest.nmk.err" >&2; exit 1; }
grep -E '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' "$T/guest.out" |
  sed 's/[[:space:]].*//' > "$T/guest.nhost.words"
grep -E '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' "$T/guest.nmk" |
  sed 's/[[:space:]].*//' > "$T/guest.nmk.words"
cmp -s "$T/guest.nhost.words" "$T/guest.nmk.words" ||
  { echo "nhost_gate: FAIL (full guest word stream differs)";
    diff -u "$T/guest.nmk.words" "$T/guest.nhost.words" | head -12; exit 1; }
n=$(wc -l < "$T/guest.nhost.words")
[ "$n" -eq 530842 ] ||
  { echo "nhost_gate: FAIL (full guest is $n words, want 530842)"; exit 1; }
echo "nhost_gate: PASS phase 2 ($n words; full guest == nmk.awk)"
echo "nhost_gate: PASS"
