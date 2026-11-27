#!/bin/sh
# tools/nagent_gate.sh - F5 AI-native agent ABI gate.
#
# Builds src/tests/nagent_test.nas with tools/nmk.awk and runs it on the
# aarch64/android nan_cli NaN machine.  No C harness is built or linked: the
# image contains the real nagent policy library and its test.
#
# Proves, in one deterministic run:
#   create/grant/check/revoke; an old handle fails, the new generation works;
#   checkpoint -> mutate frame/KV/trace/budget -> restore returns the sealed
#   frame/caps/roots/trace; fork shares the immutable weight root with
#   independent child id/KV/trace; CPU0->CPU1 and node0->node1 migration
#   preserves caps/roots/trace and bumps the migration epoch; stale
#   destination generations, tampered checkpoint hashes, resealed bad cap
#   generations, stale capability epochs and a tampered live record all fail.
#
# On success the gate emits exactly O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nagent.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "nagent: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/nagent.nas ] || fail "missing src/lib/nagent.nas"
[ -f src/tests/nagent_test.nas ] || fail "missing test image"

for sym in nagent_create nagent_cap_grant nagent_cap_revoke nagent_cap_check \
           nagent_checkpoint nagent_restore nagent_fork nagent_migrate \
           nagent_trace_append nagent_verify; do
  grep -q "^$sym:" src/lib/nagent.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nagent_test.nas || fail "test does not call $sym"
done
# The checkpoint must carry caps with generations and a hash chain over them.
for f in NAG_C_GEN NAG_C_HANDLE CK_CAPEPOCH CK_HASH; do
  grep -q "#$f" src/lib/nagent.nas || fail "missing $f"
done
# Checkpoints are caller supplied, not a hidden heap.
grep -q 'CKWORDS 512' src/tests/nagent_test.nas || fail "no caller checkpoint storage"

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nagent: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nagent_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2
    fail "nmk emit"
  }
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || fail "no word count"
# Code/data must stay below the 0x6800 destination-generation tables; the
# 256-word stack sits at 0x7000 and the image ends at 0x7100.
[ "$WORDS" -ge 28672 ] && [ "$WORDS" -le 28928 ] || \
  fail "unexpected image layout ($WORDS words)"
LAST=$(awk '$2 < 28672 { if ($2+0 > m) m=$2+0 } END { print m+0 }' "$T/labels")
[ "$LAST" -lt 26624 ] || fail "code/data reaches 0x6800 generation tables"
[ "$(awk '$1=="stack" { print $2 }' "$T/labels")" = "28672" ] || \
  fail "stack is not at 0x7000"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "nmk check"
}
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "assembler round-trip"
}
for sym in nagent_init nagent_create nagent_cap_grant nagent_cap_revoke \
           nagent_cap_check nagent_checkpoint nagent_restore nagent_fork \
           nagent_migrate nagent_trace_append nagent_verify; do
  grep -q "^$sym " "$T/labels" || fail "missing image symbol $sym"
done

timeout 60 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 64 \
  --steps 5000000 --serial > "$T/out" 2> "$T/err" || true
got=$(cat "$T/out")
[ "$got" = "O" ] || {
  echo "--- nan_cli ---" >&2
  cat -v "$T/out" >&2
  tail -5 "$T/err" >&2
  fail "agent ABI self-test did not prove O"
}
[ "$(wc -c < "$T/out")" -eq 1 ] || fail "output is not exactly one byte"

printf 'O'
