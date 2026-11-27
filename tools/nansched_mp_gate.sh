#!/bin/sh
# tools/nansched_mp_gate.sh - F2 pure-NaN per-CPU NanCore scheduler gate.
#
# Builds src/tests/nansched_mp_test.nas with tools/nmk.awk for TEST_CPUS=2
# and TEST_CPUS=4 and runs both images on the aarch64/android/nan_cli NaN
# machine.  No C harness is built or linked: the test image contains the
# policy layer, the NanCore record layout, a single-thread shim with nansmp
# value semantics, and the real nsp_* binding adapter.
#
# On success the gate emits exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nansched_mp.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "nansched_mp: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/nansched_mp.nas ] || fail "missing src/lib/nansched_mp.nas"
[ -f src/lib/nansched_nansmp.nas ] || fail "missing nansmp binding"
[ -f src/tests/nansched_mp_test.nas ] || fail "missing test image"
grep -q '^\.include "nansched_mp.nas"' src/lib/nansched.nas || \
  fail "src/lib/nansched.nas does not import the per-CPU layer"

for sym in nsched_init nsched_task_add nsched_push nsched_pop nsched_steal \
           nsched_preempt nsched_tick nsched_migrate nsched_affinity \
           nsched_budget nsched_deadline nsched_peek nsched_current \
           nsched_qlen nsched_migrate_request; do
  grep -q "^$sym:" src/lib/nansched_mp.nas || fail "missing $sym"
done
for sym in nsp_cas nsp_fetch_add nsp_fence nsp_trylock nsp_unlock nsp_ipi; do
  grep -q "@$sym" src/lib/nansched_nansmp.nas || \
    fail "nansmp binding does not reference $sym"
done
# The per-CPU FIFO must be the NanCore record fields, not a private array.
for f in NC_QHEAD NC_QTAIL NC_QCOUNT; do
  grep -q "#$f" src/lib/nansched_mp.nas || \
    fail "scheduler does not use $f"
done

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nansched_mp: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

run_one() {
  n=$1
  TEST_CPUS=$n awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels$n" \
    src/tests/nansched_mp_test.nas > "$T/t$n.nan" 2> "$T/emit$n.err" || {
      cat "$T/emit$n.err" >&2
      fail "nmk emit TEST_CPUS=$n"
    }
  WORDS=$(sed -n 's/^words //p' "$T/emit$n.err" | tail -1)
  [ -n "$WORDS" ] || fail "no word count for TEST_CPUS=$n"
  # Code must stay below the test stack at 0x7000 and the arena at 0x21000.
  [ "$WORDS" -lt 28672 ] || fail "image $WORDS words reaches the stack"
  awk -f tools/nmk.awk -v CMD=check "$T/t$n.nan" 2> "$T/check$n.err" || {
    cat "$T/check$n.err" >&2
    fail "nmk check TEST_CPUS=$n"
  }
  grep -q '^check: 0 mismatches$' "$T/check$n.err" || {
    cat "$T/check$n.err" >&2
    fail "assembler round-trip TEST_CPUS=$n"
  }
  for sym in nsched_init nsched_push nsched_pop nsched_steal \
             nsched_migrate nsched_affinity nsched_tick \
             nsched_bind_nansmp; do
    grep -q "^$sym " "$T/labels$n" || \
      fail "missing image symbol $sym (TEST_CPUS=$n)"
  done
  timeout 60 ./aarch64/android/nan_cli --img "$T/t$n.nan" --mem 64 \
    --steps 5000000 --serial > "$T/out$n" 2> "$T/err$n" || true
  got=$(cat "$T/out$n")
  [ "$got" = "O" ] || {
    echo "--- nan_cli TEST_CPUS=$n ---" >&2
    cat -v "$T/out$n" >&2
    tail -5 "$T/err$n" >&2
    fail "TEST_CPUS=$n did not prove O"
  }
  [ "$(wc -c < "$T/out$n")" -eq 1 ] || \
    fail "TEST_CPUS=$n output is not exactly one byte"
}

run_one 2
run_one 4
printf 'O'
