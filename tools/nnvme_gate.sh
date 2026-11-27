#!/bin/sh
# tools/nnvme_gate.sh - F11 NVMe namespace/queue-pair gate.
#
# Builds src/tests/nnvme_test.nas with tools/nmk.awk and runs it twice on the
# aarch64/android nan_cli NaN machine.  No C harness is built or linked: the
# image contains the real nnvme library and the test.
#
# Proves, deterministically:
#   * a namespace with 64-bit capacity/LBAs and an extent table over a caller
#     backing buffer, rejecting overlap, out-of-range, zero-length,
#     outside-backing and 64-bit-wrapping extents;
#   * a controller and 4-deep queue pair with SQE/CQE rings, SQ/CQ doorbells,
#     head/tail wrap and exact queue-full accounting;
#   * WRITE/READ/FLUSH/TRIM with exact bytes, deterministic zero-fill trim and
#     exact byte/count statistics;
#   * a READ/WRITE at LBA 2^32 and a GGUF-style tensor view read at byte
#     offset 2^41 through the same 64-bit path;
#   * invalid LBA/size/address, bad namespace/opcode, read-only namespace,
#     stale CQ index and bad queue id.
#
# On success stdout is exactly one byte: O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nnvme.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "nnvme: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/nnvme.nas ] || fail "missing src/lib/nnvme.nas"
[ -f src/tests/nnvme_test.nas ] || fail "missing test image"
[ -f tools/nmk.awk ] || fail "missing tools/nmk.awk"

# API surface the test must exercise.
for sym in nnvme_ns_init nnvme_ns_add_ext nnvme_ns_info nnvme_ns_stats \
           nnvme_ctrl_init nnvme_qpair_create nnvme_qpair_delete \
           nnvme_submit nnvme_sq_doorbell nnvme_complete nnvme_cqe \
           nnvme_cq_doorbell nnvme_errno nnvme_identify nnvme_view_read; do
  grep -q "^$sym:" src/lib/nnvme.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nnvme_test.nas || fail "test does not call $sym"
done

# Implementation invariants: 64-bit LBA/extent layout, doorbells, opcodes,
# queue depth and exact error codes must be visible in the source.
for f in NVME_NS_MAGIC NVME_QP_MAGIC NVME_CTRL_MAGIC NVME_VIEW_MAGIC \
         NV_NS_CAP NV_NS_EXT NV_NS_BASE NV_NS_SIZE NV_Q_DEPTH NV_Q_SQH \
         NV_Q_SQT NV_Q_CQH NV_Q_CQT NV_Q_DB NV_E_LBA NV_E_PHYS \
         NVME_OP_READ NVME_OP_WRITE NVME_OP_FLUSH NVME_OP_TRIM \
         NVME_EQFULL NVME_ELBA NVME_ESPACE NVME_ERO NVME_EADDR; do
  grep -q "$f" src/lib/nnvme.nas || fail "missing $f"
done
grep -q '64-bit' src/lib/nnvme.nas || fail "no 64-bit contract"
grep -q 'queue pair' src/lib/nnvme.nas || fail "no queue-pair contract"
grep -q 'doorbell' src/lib/nnvme.nas || fail "no doorbell contract"
grep -q 'extent' src/lib/nnvme.nas || fail "no extent contract"
grep -q 'deterministic' src/lib/nnvme.nas || fail "no deterministic trim note"

# The storage boundary must not read host entropy/time/devices.
if grep -nE '\b(RDTSC|TICK|KEY|KEYQ|INL|OUTL|INW|OUTW|INB|OUTB)\b' \
    src/lib/nnvme.nas > "$T/host.err"; then
  cat "$T/host.err" >&2
  fail "host entropy/time/device opcode in the storage boundary"
fi

# The test must keep the exact-byte, wrap, queue-full and streaming paths.
grep -q 'NVME_EQFULL' src/tests/nnvme_test.nas || fail "no queue-full check"
grep -q 'NVME_ELBA' src/tests/nnvme_test.nas || fail "no LBA check"
grep -q 'NVME_ESPACE' src/tests/nnvme_test.nas || fail "no overlap check"
grep -q 'NVME_ERO' src/tests/nnvme_test.nas || fail "no read-only check"
grep -q 'NVME_EADDR' src/tests/nnvme_test.nas || fail "no address check"
grep -q '0xFFFFFFFF' src/tests/nnvme_test.nas || fail "no 64-bit wrap case"
grep -q 'nnvme_view_read' src/tests/nnvme_test.nas || fail "no streaming view"
grep -q 'VIEW_OFF' src/tests/nnvme_test.nas || fail "no 64-bit view offset"
grep -q 'Queue four' src/tests/nnvme_test.nas || fail "no queued batch"
grep -q '0x8F00' src/tests/nnvme_test.nas || fail "no test stack"

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nnvme: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nnvme_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2
    fail "nmk emit"
  }
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || fail "no word count"
[ "$WORDS" -gt 2048 ] || fail "image suspiciously small ($WORDS words)"
[ "$WORDS" -le 16384 ] || fail "image reaches the 0x4000 buffer/data window"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "nmk check"
}
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "assembler round-trip"
}

LAST=$(awk '$2+0 > m { m=$2+0 } END { print m+0 }' "$T/labels")
[ "$LAST" -lt 16384 ] || fail "code/data reaches the 0x4000 buffer window"
for sym in main nnvme_ns_init nnvme_ns_add_ext nnvme_submit nnvme_complete \
           nnvme_view_read chk; do
  grep -q "^$sym " "$T/labels" || fail "missing image symbol $sym"
done

run_once() {
  timeout 120 ./aarch64/android/nan_cli --img "$T/t.nan" --mem 64 \
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
    fail "NVMe self-test did not prove O"
  }
}

run_once "$T/out1"
run_once "$T/out2"
cmp -s "$T/out1" "$T/out2" || fail "two runs differ (non-deterministic image)"

printf 'O'
