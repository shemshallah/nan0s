#!/bin/sh
# nnuma_gate.sh - pure-NaN E820/SRAT/NUMA topology and nheap integration proof.
#
# The guest image parses a synthetic sorted E820/SRAT-like table with sparse
# nodes 0 and 2, low RAM, reserved/hole/MMIO/ACPI spans, and RAM above 4 GiB.
# It answers phys->node and APIC->node, checks declared node totals, then feeds
# only RAM into nheap's per-node 4K/2M/1G classes.  Exhausting each RAM class
# proves no reserved/hole/MMIO/ACPI page was ever added or allocated.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/nnuma.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/nnuma_test.nas > "$T/t.nan" 2>"$T/e" || {
  cat "$T/e"; exit 1; }
timeout 60 aarch64/android/nan_cli --img "$T/t.nan" --mem 16 --steps 5000000 \
  --serial > "$T/out" 2>"$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "nnuma: FAIL ('$got')"; tail -3 "$T/err"; exit 1; }
echo "nnuma: PASS (sparse nodes 0/2, 5 GiB bases, holes/reserved/ACPI/MMIO skipped, APIC->node, per-node 4K/2M/1G heap stats + exhaustive allocation)"
