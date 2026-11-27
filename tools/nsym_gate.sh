#!/bin/sh
# nsym_gate.sh - symbiotic multi-agent scheduling over 2 CPUs (F13f).
#
# Builds src/tests/nsym_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  The image contains the real
# src/lib/nsym.nas + src/lib/ngen.nas; no C harness is linked.
#
# Proves, in one deterministic run (repeated twice from a cold init and
# compared word-for-word over 1184 words):
#   * three agents with weights 1/2/3 and one shared immutable root run
#     three 20-tick rounds on 2 CPUs; the per-round service ratios satisfy
#     |s_i*W - w_i*S| <= W (W=6), so no agent starves and the bounded
#     fair-share error is one weight quantum;
#   * agent 1 publishes generation 2 onto a second shared root while agents
#     2/3 keep admitted jobs on root 0/generation 1; their queues, vrt,
#     service and ngen records are unchanged, the old root keeps its payload
#     and hash, and its refcount drops by exactly one;
#   * agent 1 drains generation 2, a stale old-generation admission fails
#     closed, generation 3 starts, and agent 3 still admits on generation 1;
#   * agents 4/5/6 show a 6-tick reservation completing by its deadline under
#     contention on 2 CPUs (reserve_met=1, no deadline miss);
#   * agent 7 is capped at its 5-tick budget (job parked with 5 ticks left,
#     budget denial counted) and a later admission at budget 0 is rejected;
#   * agent 4 misses a tight deadline with exact miss/park counters;
#   * shared-root refcounts stay live at one reference and free exactly at
#     zero; a freed root rejects acquire and verify;
#   * every status word, root record, agent record and the last eight trace
#     entries match across two cold runs.
# Success prints exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nsym.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nsym: FAIL ($*)" >&2; exit 1; }

[ -f src/lib/nsym.nas ] || fail "missing src/lib/nsym.nas"
[ -f src/tests/nsym_test.nas ] || fail "missing test image"

for sym in nsym_init nsym_root_create nsym_root_acquire nsym_root_release \
           nsym_root_verify nsym_root_status nsym_agent_create nsym_join \
           nsym_leave nsym_publish nsym_start nsym_drain nsym_admit \
           nsym_dispatch nsym_run nsym_agent_status nsym_global nsym_trace \
           nsym_trace_head nsym_tick nsym_errno; do
  grep -q "^$sym:" src/lib/nsym.nas || fail "missing $sym"
done
for sym in nsym_root_create nsym_root_acquire nsym_root_verify \
           nsym_agent_create nsym_join nsym_leave nsym_publish nsym_start \
           nsym_drain nsym_admit nsym_run nsym_agent_status nsym_global \
           nsym_trace nsym_trace_head nsym_errno; do
  grep -q "@$sym" src/tests/nsym_test.nas || fail "test does not call $sym"
done
grep -q 'include "ngen.nas"' src/lib/nsym.nas || fail "does not reuse ngen"
grep -q 'ngen_enter' src/lib/nsym.nas || fail "no generation admission"
grep -q 'ngen_exit' src/lib/nsym.nas || fail "no generation completion"
grep -q 'ngen_publish' src/lib/nsym.nas || fail "no generation publish"
grep -q 'ngen_drain' src/lib/nsym.nas || fail "no generation drain"
for f in NS_R_REFS NS_R_HASH NS_A_WEIGHT NS_A_VRT NS_A_RESERVE \
         NS_A_DEADLINE NS_A_BLEFT NS_G_DM NS_G_BUDGET NS_G_RMET \
         NS_G_RFREE NS_T_PUBLISH NS_T_DRAIN NS_T_RFREE NS_J_BUDGET \
         NS_J_MISS; do
  grep -q "#$f" src/lib/nsym.nas || fail "missing $f"
done
grep -q 'NS_ROOT_TAB.*0x354000\|0x354000' src/lib/nsym.nas || fail "no root table"
grep -q '0x355000' src/lib/nsym.nas || fail "no agent table"
grep -q '0x356000' src/lib/nsym.nas || fail "no global block"
grep -q 'DIVU' src/lib/nsym.nas || fail "no Q16 virtual runtime divide"
grep -q 'NS_Q16' src/lib/nsym.nas || fail "no Q16 vrt constant"
grep -q 'BFILL' src/lib/nsym.nas || fail "no deterministic clear"
grep -q 'NSNAP   1184\|NSNAP 1184' src/tests/nsym_test.nas || fail "no full snapshot"
grep -q '0x100' src/tests/nsym_test.nas || fail "no first weight root"
grep -q '0x200' src/tests/nsym_test.nas || fail "no second weight root"
grep -q 'LA r3,458752' src/tests/nsym_test.nas || fail "no exact vrt check"
grep -q 'chkle' src/tests/nsym_test.nas || fail "no 2-CPU fairness bound check"
grep -q 'CALL @ratio' src/tests/nsym_test.nas || fail "no per-round ratio check"
grep -q 'NS_J_MISS' src/tests/nsym_test.nas || fail "no deadline-miss job check"
grep -q 'NS_J_BUDGET' src/tests/nsym_test.nas || fail "no budget-parked job check"
grep -q '@nsym_root_verify' src/tests/nsym_test.nas || fail "no root verify"
grep -q 'cmpbuf' src/tests/nsym_test.nas || fail "no deterministic compare"

[ -x ./aarch64/android/nan_cli ] || fail "missing aarch64/android/nan_cli"

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nsym_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "nmk emit"; }
grep -q '^words ' "$T/emit.err" || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
    cat "$T/check.err" >&2; fail "nmk check"; }
grep -q '^check: 0 mismatches$' "$T/check.err" || {
    cat "$T/check.err" >&2; fail "assembler round-trip"; }

timeout 180 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 16 \
  --steps 40000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2; cat -v "$T/out" >&2
  tail -5 "$T/err" >&2; fail "symbiotic scheduler self-test did not prove O"; }
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O\n'
echo "nsym: PASS (3-agent WFQ over 2 CPUs, bounded ratio, no starvation, reservation by deadline, budget park + budget reject, deadline miss, shared-root refcount/join/leave/free, generation publish/drain/start isolation, deterministic rerun)"
