#!/bin/sh
# ncscale_gate.sh - F4 4096-core x2APIC topology/scale gate.
#
# Pure-NaN proof:
#   - 4096 logical cores with APIC ids 0x10000000 + 2*i (sparse, all > 255);
#   - count taken from the table header; 3-core and 4-core dynamic shrinks;
#   - APIC -> logical hash map and logical -> APIC record, including
#     0xFFFFFFFE and 0xF0000000, duplicate/reserved rejection, map/unmap;
#   - online/offline and dispatch-ready bitmaps + per-core flag word;
#   - all 4096 stack ranges are 16 KiB, 16 KiB aligned, non-overlapping with
#     a 16 KiB guard between them;
#   - the nansmp atomic seam (fetch-add, CAS, fence) is exercised and no
#     spinlock symbol is present in the library.
# Then the x86_64 2-CPU/4-CPU S1 regression is re-run.  Its C is the test
# bench only (src/tests/native64); no product C is added or used here.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"; T="$TMPDIR/ncscale.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

fail() { echo "ncscale: FAIL ($1)"; exit 1; }

# ---------------------------------------------------------------- NaN image
awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels.txt" \
  src/tests/ncscale_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
  cat "$T/emit.err"; fail "emit"; }
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || fail "no word count"
[ "$WORDS" -le 28672 ] || fail "image $WORDS words overlaps the 0x7000 stack"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err"
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err"; fail "nmk check"; }

# ------------------------------------------------------------------- symbols
for sym in ncs_init ncs_count ncs_index ncs_apic ncs_map ncs_unmap \
           ncs_online_set ncs_online_clear ncs_online_test ncs_online_count \
           ncs_ready_set ncs_ready_clear ncs_ready_test ncs_ready_count \
           ncs_dispatch_ready ncs_stack_base ncs_stack_top ncs_set_node \
           ncs_node ncs_map_count; do
  grep -q "^$sym " "$T/labels.txt" || fail "missing symbol $sym"
done
for sym in nsp_fetch_add nsp_cas nsp_fence; do
  grep -q "^$sym " "$T/labels.txt" || fail "missing atom seam $sym"
done
if grep -Eq 'nsp_(lock|trylock)' src/lib/ncscale.nas; then
  fail "library references a global spinlock"
fi
grep -q '@nsp_cas' src/lib/ncscale.nas || fail "bitmap publish is not CAS"
grep -q '@nsp_fetch_add' src/lib/ncscale.nas || fail "per-core counters are not atomic"

# --------------------------------------------------------------- pure-NaN run
timeout 90 aarch64/android/nan_cli --img "$T/t.nan" --mem 128 --steps 20000000 \
  --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "ncscale: FAIL (guest marker '$got')"
  tail -5 "$T/err"
  exit 1
}
echo "ncscale: PASS (4096 cores, x2APIC 0x10000000+2i, map/unmap, online/ready flags, 16 KiB stacks, $WORDS-word image)"

# ------------------------------------------------------- 2/4-CPU regression
sh tools/nansmp_gate.sh
echo "ncscale: RESULT PASS (4096-core scale + x86_64 S1 2/4-CPU regression)"
