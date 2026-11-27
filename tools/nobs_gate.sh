#!/bin/sh
# tools/nobs_gate.sh - F12 pure-NaN observability/ops gate.
#
# Builds src/tests/nobs_test.nas with tools/nmk.awk and runs it twice on the
# aarch64/android nan_cli NaN machine.  No C harness is built or linked: the
# image contains the real nobs layer, the real nansched_mp policy, the real
# nnuma/nheap topology and allocator, and a single-thread nansmp shim.
#
# Proves, in one deterministic run:
#   * four NanCore CPU records sampled after push/pop/steal/migrate/preempt
#     activity, with exact ticks/tasks/steals/migrations/faults/IPIs/queue
#     depth/budget/deadline counters and NC_TICKS publication;
#   * per-(NUMA node, 4K/2M/1G class) allocator stats over nheap, including
#     exact live pages/bytes, high water, OOM and eviction accounting;
#   * node/class exhaustion: pressure evicts a cold extent and retries, then
#     a second pressure request denies with an OOM event;
#   * per-agent CPU-step/tick/memory/KV quotas: admit, deny-on-exceed, check
#     and a trace event for every denial;
#   * a bounded 8-entry trace ring that wraps after 24 events, fails closed
#     for overwritten indices, returns an exact snapshot and a deterministic
#     hash for the last entry;
#   * a health snapshot with exact magic/version and totals.
#
# On success the gate emits exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nobs.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "nobs: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/nobs.nas ] || fail "missing src/lib/nobs.nas"
[ -f src/tests/nobs_test.nas ] || fail "missing test image"

for sym in nobs_init nobs_tick nobs_core_sample nobs_core_event nobs_core_get \
           nobs_mem_alloc nobs_mem_free nobs_mem_cold nobs_mem_pressure \
           nobs_mem_stats nobs_quota_set nobs_quota_check \
           nobs_quota_account nobs_quota_get nobs_trace nobs_trace_at \
           nobs_trace_snapshot nobs_trace_last nobs_health; do
  grep -q "^$sym:" src/lib/nobs.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nobs_test.nas || fail "test does not call $sym"
done
# The layer must consume the real NanCore record, nansched_mp stats, nheap and
# nnuma topology, not a private duplicate.
for f in NC_TICKS NC_QCOUNT NC_IPI NC_STATE NSD_C_STATS NSD_S_POP \
         NSD_S_STEAL_IN NSD_S_MIG_IN NB_RINGWRAPS NB_K_QUOTA NB_K_OOM \
         NB_K_EVICT NB_HMAGIC NB_H_VERSION; do
  grep -q "#$f" src/lib/nobs.nas || fail "missing $f reference"
done
grep -q '^\.include "nansched_mp.nas"' src/lib/nobs.nas || \
  fail "nobs does not include nansched_mp"
grep -q '^\.include "nnuma.nas"' src/lib/nobs.nas || \
  fail "nobs does not include nnuma (and nheap)"
grep -q '^\.equ TEST_CPUS 4' src/tests/nobs_test.nas || \
  fail "test is not pinned to 4 CPUs"
grep -q 'MOVI r1,8' src/tests/nobs_test.nas || fail "ring capacity is not 8"
for ev in NB_K_PUSH NB_K_POP NB_K_STEAL NB_K_MIG; do
  grep -q "#$ev" src/tests/nobs_test.nas || fail "no $ev trace event"
done
for op in nsched_push nsched_pop nsched_steal nsched_migrate; do
  grep -q "@$op" src/tests/nobs_test.nas || fail "test does not call $op"
done
grep -q 'NB_RINGWRAPS' src/tests/nobs_test.nas || fail "no wrap assertion"
grep -q 'NB_Q_DENIED' src/tests/nobs_test.nas || fail "no quota deny assertion"
grep -q 'NB_M_EVICTS' src/tests/nobs_test.nas || fail "no eviction assertion"
grep -q 'NB_M_OOM' src/tests/nobs_test.nas || fail "no OOM assertion"
grep -q 'NB_H_STATUS' src/tests/nobs_test.nas || fail "no health assertion"
if ls src/lib/nobs*.c >/dev/null 2>&1; then
  fail "C file next to nobs"
fi

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nobs: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nobs_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2
    fail "nmk emit"
  }
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || fail "no word count"
# Code/data must stay below the test stack at 0x7000 (28672 words).
[ "$WORDS" -lt 28672 ] || fail "image $WORDS words reaches the stack"
LAST=$(awk '$2 < 28672 { if ($2+0 > m) m=$2+0 } END { print m+0 }' "$T/labels")
[ "$LAST" -lt 28672 ] || fail "code/data reaches the stack (last=$LAST)"
[ "$(awk '$1=="main" { print $2 }' "$T/labels")" -gt 0 ] || fail "no main"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "nmk check"
}
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "assembler round-trip"
}
for sym in nobs_init nobs_core_sample nobs_mem_pressure nobs_quota_account \
           nobs_trace nobs_trace_snapshot nobs_health; do
  grep -q "^$sym " "$T/labels" || fail "missing image symbol $sym"
done

run_one() {
  timeout 60 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 64 \
    --steps 5000000 --serial > "$T/out$1" 2> "$T/err$1" || true
  got=$(cat "$T/out$1")
  [ "$got" = "O" ] || {
    echo "--- nan_cli run $1 ---" >&2
    cat -v "$T/out$1" >&2
    tail -5 "$T/err$1" >&2
    fail "run $1 did not prove O"
  }
  [ "$(wc -c < "$T/out$1")" -eq 1 ] || fail "run $1 output is not one byte"
}

run_one 1
run_one 2
cmp -s "$T/out1" "$T/out2" || fail "two runs are not byte-identical"
printf 'O'
