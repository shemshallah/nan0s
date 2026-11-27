#!/bin/sh
# tools/nsecure_gate.sh - F9 isolation/security gate.
#
# Builds src/tests/nsecure_test.nas with tools/nmk.awk and runs it twice on the
# aarch64/android nan_cli NaN machine.  No C harness is built or linked: the
# image contains the real nanobj/nagent/nsecure libraries and the test.
#
# Proves, deterministically:
#   two per-agent address spaces with root capabilities, code RX and data
#   RW/NX; guarded stack/heap RW/NX; W|X rejection, stack/heap NX, 64-bit
#   overflow/wrap, the 64 PiB ceiling, alignment, overlap and guard placement;
#   guard hits distinguished from plain unmapped accesses; nanobj and nagent
#   revocation (old handle fails, nsec_rebind with the new generation works,
#   root revoke fails closed then recovers); rights downgrade and per-agent
#   capability isolation; deny-by-default sandbox op/window policy with
#   per-agent isolation; 1024 deterministic malformed requests all denied and
#   160 well-formed requests admitted.
#
# On success the gate emits exactly one byte: O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nsecure.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "nsecure: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/nsecure.nas ] || fail "missing src/lib/nsecure.nas"
[ -f src/tests/nsecure_test.nas ] || fail "missing test image"
[ -f src/lib/nanobj.nas ] || fail "missing nanobj layer"
[ -f src/lib/nagent.nas ] || fail "missing nagent layer"

# API surface the test must exercise.
for sym in nsec_init nsec_agent_create nsec_root_set nsec_map nsec_unmap \
           nsec_rebind nsec_check nsec_sandbox_init nsec_sandbox_allow_op \
           nsec_sandbox_window nsec_sandbox_check nsec_verify nsec_errno; do
  grep -q "^$sym:" src/lib/nsecure.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nsecure_test.nas || fail "test does not call $sym"
done

# Implementation invariants: rights/live layout, 64-bit limit, guards,
# sandbox op bitmap and all denial codes must be visible in the source.
for f in NS_LIVE NS_R_ALL NSEC_LIMIT_HI NSEC_EPAGE NSEC_EWX NSEC_EGUARD \
         NSEC_ECAP NSEC_ENX NSEC_EDENY NSEC_EWIN NSEC_RANGE_OFF; do
  grep -q "$f" src/lib/nsecure.nas || fail "missing $f"
done
grep -q 'W|X' src/lib/nsecure.nas || fail "no W|X contract"
grep -q 'deny-by-default\|deny by default' src/lib/nsecure.nas || \
  fail "no deny-by-default contract"
grep -q 'nsec_sandbox_check' src/lib/nsecure.nas || fail "no sandbox check"
grep -q 'nsq_ck_guardhit' src/lib/nsecure.nas || fail "no guard-hit path"

# The isolation layer must not read host entropy/time/devices.
if grep -nE '\b(RDTSC|TICK|KEY|KEYQ|INL|OUTL|INW|OUTW|INB|OUTB)\b' \
    src/lib/nsecure.nas > "$T/host.err"; then
  cat "$T/host.err" >&2
  fail "host entropy/time/device opcode in nsecure"
fi

# Determinism corpus: 1024 malformed requests, 160 admitted requests.
grep -q '1024' src/tests/nsecure_test.nas || fail "no 1024-request corpus"
grep -q 'mal_loop' src/tests/nsecure_test.nas || fail "no corpus loop"
grep -q 'allow_l' src/tests/nsecure_test.nas || fail "no allowed-request loop"
grep -q 'NSEC_EGUARD' src/tests/nsecure_test.nas || fail "no guard-hit test"
grep -q 'NSEC_EOVER' src/tests/nsecure_test.nas || fail "no overflow test"
grep -q 'nsec_rebind' src/tests/nsecure_test.nas || fail "no rebind test"

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nsecure: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nsecure_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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

# Guest map: code starts at 0x400 (above nanobj's 0x3A0..0x3D2 scratch),
# data ends below nagent's 0x6800 generation tables, nsecure uses 0x6C00,
# and the 128-word stack sits at 0x7000.  The image ends at 0x7080 words.
[ "$WORDS" -eq 28800 ] || fail "unexpected image layout ($WORDS words)"
LAST=$(awk '$2 < 28672 { if ($2+0 > m) m=$2+0 } END { print m+0 }' "$T/labels")
[ "$LAST" -lt 26624 ] || fail "code/data reaches the 0x6800 nagent tables"
[ "$LAST" -gt 1024 ] || fail "code did not start above the nanobj low globals"
[ "$(awk '$1=="stack" { print $2 }' "$T/labels")" = "28672" ] || \
  fail "stack is not at 0x7000"
BAD=$(awk '($2 >= 928 && $2 <= 978) || ($2 >= 26624 && $2 <= 26687) || \
           ($2 >= 27648 && $2 <= 27711) { print $1, $2 }' "$T/labels" | head -1)
[ -z "$BAD" ] || fail "label $BAD overlaps a reserved low/global block"
for sym in nsec_init nsec_map nsec_check nsec_sandbox_check nsec_rebind; do
  grep -q "^$sym " "$T/labels" || fail "missing image symbol $sym"
done

run_once() {
  timeout 90 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 64 \
    --steps 20000000 --serial > "$1" 2> "$1.err" || true
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
  [ "$(wc -c < "$1")" -eq 1 ] || fail "output is not exactly one byte"
  [ "$(cat "$1")" = "O" ] || {
    echo "--- nan_cli output ---" >&2
    cat -v "$1" >&2
    tail -5 "$1.err" >&2
    fail "security self-test did not prove O"
  }
}

run_once "$T/out1"
run_once "$T/out2"
cmp -s "$T/out1" "$T/out2" || fail "two runs differ (non-deterministic image)"

printf 'O'
