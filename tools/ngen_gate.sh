#!/bin/sh
# ngen_gate.sh - live generation publish/drain/start + epoch fences (F13e).
#
# Builds src/tests/ngen_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image contains the real
# src/lib/ngen.nas; no C harness is linked.
#
# Proves, in one deterministic run (repeated twice and compared word-for-word):
#   generation 1 admits two in-flight requests; publish generation 2 emits
#   publish -> drain -> start under one epoch and returns the publish epoch;
#   a new gen1 admission is rejected with EDRAIN while the old requests stay
#   in flight; a gen2 admission succeeds immediately; both old requests
#   complete; the drained gen1 slot then rejects with ESTALE; gen2 auto-drains
#   while publishing gen3; two gen3 requests drain under publish gen4 and are
#   force-aborted with exact counters; duplicate/stale/future/zero/missing
#   publishes fail closed; a second agent runs an independent
#   start/drain/abort/start cycle and cross-agent future/stale checks; the
#   status words, per-CPU accepts/rejects and trace tails are byte-identical
#   across two cold runs.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/ngen.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "ngen: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/ngen.nas ] || fail "missing src/lib/ngen.nas"
[ -f src/tests/ngen_test.nas ] || fail "missing test image"

for sym in ngen_init ngen_create ngen_start ngen_drain ngen_publish \
           ngen_enter ngen_exit ngen_abort ngen_roots ngen_fence \
           ngen_status ngen_slot ngen_trace ngen_trace_head ngen_cpu \
           ngen_inflight ngen_epoch ngen_errno; do
  grep -q "^$sym:" src/lib/ngen.nas || fail "missing $sym"
done
for sym in ngen_create ngen_start ngen_drain ngen_publish ngen_enter \
           ngen_exit ngen_abort ngen_fence ngen_status ngen_slot \
           ngen_trace ngen_cpu ngen_errno; do
  grep -q "@$sym" src/tests/ngen_test.nas || fail "test does not call $sym"
done
# Exact stale/drain/duplicate/future errors and the fence ordering markers.
for f in NG_ESTALE NG_EDRAIN NG_EFUTURE NG_EDUP NG_EBUSY \
         NG_S_CURRENT NG_S_DRAINING NG_S_DRAINED NG_S_ABORTED_ST \
         NG_FENCE_F NG_T_PUBLISH NG_T_DRAIN NG_T_START; do
  grep -q "#$f" src/lib/ngen.nas || fail "missing $f"
done
grep -q 'NG_T_ACCEPT' src/lib/ngen.nas || fail "no accept trace"
grep -q 'NG_T_REJECT' src/lib/ngen.nas || fail "no reject trace"
grep -q 'NG_CPUSTATS' src/lib/ngen.nas || fail "no per-CPU counters"
grep -q 'NG_TAB.*0x352000\|0x352000' src/lib/ngen.nas || fail "no generation table"
grep -q 'BOOL.14' src/lib/ngen.nas || fail "no OR fence composition"
grep -q '0x3000' src/tests/ngen_test.nas || fail "no weight-root generation case"
grep -q '0x4000' src/tests/ngen_test.nas || fail "no KV-root generation case"
grep -q '0xA000' src/tests/ngen_test.nas || fail "no second-agent isolation"
grep -q '0x1000' src/tests/ngen_test.nas || fail "no first weight root"

[ -x ./aarch64/android/nan_cli ] || fail "missing aarch64/android/nan_cli"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/ngen_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

timeout 120 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 \
  --steps 20000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2; cat -v "$T/out" >&2
  tail -5 "$T/err" >&2; fail "generation self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "ngen: PASS (gen1 in flight, publish gen2, drain coexist, gen2 admit, old complete, post-drain stale reject, auto-drain, forced abort, dup/stale publish reject, 2-agent isolation, deterministic rerun)"
