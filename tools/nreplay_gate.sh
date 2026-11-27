#!/bin/sh
# tools/nreplay_gate.sh - F8 deterministic RNG, trace replay, checkpoint replay.
#
# Builds src/tests/nreplay_test.nas with tools/nmk.awk and runs it twice on
# the aarch64/android nan_cli NaN machine.  No C harness is built or linked:
# the image contains the real nreplay/nantrace/nanobj libraries and the test.
#
# Proves, in two identical runs:
#   xorshift32 seed determinism and state save/restore; same seed -> same
#   sequence and trace head; different seed -> different sequence and head;
#   append -> seal -> verify; checkpoint (RNG/head/index/steps/tick/budget/
#   deadline) -> suffix -> restore -> replay -> identical head and chain;
#   mutated and omitted replay events diverge at the exact index with an
#   expected/got record, then fail closed; explicit expect/observe; a
#   tampered sealed trace fails verification; step budget and tick deadline
#   both fail closed.
#
# On success the gate emits exactly one byte: O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nreplay.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "nreplay: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/nreplay.nas ] || fail "missing src/lib/nreplay.nas"
[ -f src/tests/nreplay_test.nas ] || fail "missing test image"
[ -f src/lib/nantrace.nas ] || fail "missing nantrace layer"
[ -f src/lib/nanobj.nas ] || fail "missing nanobj layer"

# API surface the test must exercise.
for sym in nrng_init nrng_next nrng_state_save nrng_state_restore \
           nr_begin nr_event nr_expect nr_observe nr_ref nr_limits nr_cost \
           nr_head nr_index nr_status nr_div_index nr_div_expected \
           nr_div_got nr_head_check nr_checkpoint nr_restore nr_seal \
           nr_verify; do
  grep -q "^$sym:" src/lib/nreplay.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nreplay_test.nas || fail "test does not call $sym"
done

# Implementation invariants: explicit RNG state, divergence record, checkpoint
# format and trace-head comparison must be visible in the source.
for f in NR_G_RNG NR_G_STATUS NR_G_DIVIDX NR_G_DIVEXP NR_G_DIVGOT \
         NR_CK_WORDS NR_G_TRACE NR_G_HEAD; do
  grep -q "#$f" src/lib/nreplay.nas || fail "missing $f"
done
grep -q 'trace head' src/lib/nreplay.nas || fail "no trace-head contract"
grep -q 'fail-closed' src/lib/nreplay.nas || fail "no fail-closed contract"

# No host entropy or host time/device reads may appear in the replay library.
if grep -nE '\b(RDTSC|TICK|KEY|KEYQ|INL|OUTL|INW|OUTW|INB|OUTB)\b' \
    src/lib/nreplay.nas > "$T/host.err"; then
  cat "$T/host.err" >&2
  fail "host entropy/time/device opcode in nreplay"
fi

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nreplay: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nreplay_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2
    fail "nmk emit"
  }
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || fail "no word count"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "nmk check"
}
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "assembler round-trip"
}

# Guest map: code below the 0x2800 nreplay block, test data at 0x3000, stack
# at 0x7000, image ends at 0x7080 words.
[ "$WORDS" -eq 28800 ] || fail "unexpected image layout ($WORDS words)"
CODE_END=$(awk '$2 < 10240 { if ($2+0 > m) m=$2+0 } END { print m+0 }' "$T/labels")
[ "$CODE_END" -lt 10240 ] || fail "code reaches the 0x2800 nreplay globals"
[ "$(awk '$1=="seed1" { print $2 }' "$T/labels")" = "12288" ] || \
  fail "test data is not at 0x3000"
[ "$(awk '$1=="stack" { print $2 }' "$T/labels")" = "28672" ] || \
  fail "stack is not at 0x7000"
LOWBAD=$(awk '$2 >= 928 && $2 <= 978 { print $1 }' "$T/labels" | head -1)
[ -z "$LOWBAD" ] || fail "label $LOWBAD overlaps nanobj/nantrace low globals"
for sym in nrng_next nr_begin nr_event nr_observe nr_checkpoint nr_restore \
           nr_seal nr_verify; do
  grep -q "^$sym " "$T/labels" || fail "missing image symbol $sym"
done

run_once() {
  timeout 60 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 64 \
    --steps 5000000 --serial > "$1" 2> "$1.err" || true
  [ -s "$1" ] || {
    echo "--- nan_cli stderr ---" >&2
    tail -5 "$1.err" >&2
    fail "guest produced no output"
  }
  grep -q "trap=''" "$1.err" || {
    echo "--- nan_cli stderr ---" >&2
    tail -5 "$1.err" >&2
    fail "guest trapped"
  }
  [ "$(cat "$1")" = "O" ] || {
    echo "--- nan_cli output ---" >&2
    cat -v "$1" >&2
    tail -5 "$1.err" >&2
    fail "replay self-test did not prove O"
  }
  [ "$(wc -c < "$1")" -eq 1 ] || fail "output is not exactly one byte"
}

run_once "$T/out1"
run_once "$T/out2"
cmp -s "$T/out1" "$T/out2" || fail "two runs differ (non-deterministic image)"

printf 'O'
