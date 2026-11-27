#!/bin/sh
# tools/naccel_gate.sh - F10 accelerator-boundary gate.
#
# Builds src/tests/naccel_test.nas with tools/nmk.awk and runs it twice on the
# aarch64/android nan_cli NaN machine.  No C harness is built or linked: the
# image contains the real niommu/naccel libraries and the test.
#
# Proves, deterministically:
#   * IOMMU domains with 64-bit IOVAs, R/W/X rights, map/unmap/rebind,
#     generation, invalidation epoch and 4-entry fault records;
#   * wrap, overlap, alignment, W|X, zero-size and duplicate-device rejection;
#   * a caller-supplied DMA ring with submit/cancel/complete/fence, exact
#     statuses and fence ordering that stops completion at the barrier;
#   * software DMA copy and GEMV placeholder through mapped IOVAs, byte-exact
#     source/destination comparison;
#   * invalid IOVA, permission and revoked-generation DMA faults;
#   * a 64-bit VRAM/BAR bitmap allocator, weight/KV placement above 4 GiB,
#     exhaustion and unmapped-BAR host fallback with exact accounting;
#   * unmap/rebind/revoke invalidation of old mappings.
#
# On success stdout is exactly one byte: O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/naccel.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "naccel: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/niommu.nas ] || fail "missing src/lib/niommu.nas"
[ -f src/lib/naccel.nas ] || fail "missing src/lib/naccel.nas"
[ -f src/tests/naccel_test.nas ] || fail "missing test image"
[ -f tools/nmk.awk ] || fail "missing tools/nmk.awk"

# API surface the test must exercise.
for sym in niom_init niom_domain_create niom_map niom_unmap niom_rebind \
           niom_translate niom_revoke niom_generation niom_epoch \
           niom_fault niom_fault_count niom_errno \
           nacc_ring_init nacc_submit nacc_cancel nacc_complete nacc_fence \
           nacc_result nacc_counters nacc_vram_init nacc_vram_alloc \
           nacc_vram_free nacc_vram_place nacc_vram_stats; do
  grep -q "^$sym:" src/lib/niommu.nas src/lib/naccel.nas 2>/dev/null || \
    grep -q "^$sym:" src/lib/niommu.nas || \
    grep -q "^$sym:" src/lib/naccel.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/naccel_test.nas || fail "test does not call $sym"
done

# Implementation invariants: domain/map layout, epochs, fault ring, DMA flags,
# VRAM tiers and explicit fallback counters must be visible in the source.
for f in NIOM_MAX_DOM NIOM_MAX_MAP NI_D_EPOCH NI_D_FLOG NI_M_RIGHTS \
         NIOM_ESTALE NIOM_ESPACE NIOM_EOVER NIOM_ERIGHT \
         NACC_F_FENCE NACC_F_GEMV NACC_TIER_HOST NACC_TIER_VRAM \
         NACC_POL_WEIGHT NACC_POL_KV NACC_OP_COPY NACC_OP_GEMV \
         NACC_MAXCOPY NV_MAX_GRAN NV_FB_EXH NV_FB_UNMAP; do
  grep -q "$f" src/lib/niommu.nas src/lib/naccel.nas || fail "missing $f"
done
grep -q 'W|X' src/lib/niommu.nas || fail "no W|X contract"
grep -q '64-bit IOVA' src/lib/niommu.nas || fail "no 64-bit IOVA contract"
grep -q 'fault record' src/lib/niommu.nas || fail "no fault record contract"
grep -q 'fence' src/lib/naccel.nas || fail "no fence contract"
grep -q 'host-only' src/lib/naccel.nas || fail "no host placement policy"
grep -q 'fallback' src/lib/naccel.nas || fail "no software fallback contract"

# The boundary must not read host entropy/time/devices.
if grep -nE '\b(RDTSC|TICK|KEY|KEYQ|INL|OUTL|INW|OUTW|INB|OUTB)\b' \
    src/lib/niommu.nas src/lib/naccel.nas > "$T/host.err"; then
  cat "$T/host.err" >&2
  fail "host entropy/time/device opcode in the accelerator boundary"
fi

# The test must keep the exact-byte, fault, revoke, exhaustion and fence paths.
grep -q 'NACC_EBUSY' src/tests/naccel_test.nas || fail "no EBUSY fence check"
grep -q 'NACC_ECANCEL' src/tests/naccel_test.nas || fail "no cancel check"
grep -q 'NIOM_ESTALE' src/tests/naccel_test.nas || fail "no stale-generation check"
grep -q 'NIOM_ERIGHT' src/tests/naccel_test.nas || fail "no permission check"
grep -q 'NIOM_ESPACE' src/tests/naccel_test.nas || fail "no overlap check"
grep -q 'NIOM_EOVER' src/tests/naccel_test.nas || fail "no wrap check"
grep -q 'chkmap' src/tests/naccel_test.nas || fail "no map-rejection check"
grep -q 'Ring capacity' src/tests/naccel_test.nas || fail "no ring-capacity check"
grep -q 'nacc_vram_place' src/tests/naccel_test.nas || fail "no placement check"
grep -q 'nacc_vram_stats' src/tests/naccel_test.nas || fail "no VRAM accounting"
grep -q 'chk_pat' src/tests/naccel_test.nas || fail "no exact-byte compare"
grep -q '0x8F00' src/tests/naccel_test.nas || fail "no test stack"

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "naccel: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/naccel_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2
    fail "nmk emit"
  }
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || fail "no word count"
[ "$WORDS" -gt 4096 ] || fail "image suspiciously small ($WORDS words)"
[ "$WORDS" -le 16384 ] || fail "image reaches the 0x4000 buffer/data window"

awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "nmk check"
}
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  cat "$T/check.err" >&2
  fail "assembler round-trip"
}

# Code/data labels must stay below the byte-buffer window at word 0x4000;
# the ring/VRAM contexts begin at word 0x6000 and the stack at 0x8F00.
LAST=$(awk '$2+0 > m { m=$2+0 } END { print m+0 }' "$T/labels")
[ "$LAST" -lt 16384 ] || fail "code/data reaches the 0x4000 buffer window"
for sym in main niom_map niom_translate nacc_submit nacc_complete \
           nacc_vram_place nacc_vram_stats chk; do
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
    fail "accelerator self-test did not prove O"
  }
}

run_once "$T/out1"
run_once "$T/out2"
cmp -s "$T/out1" "$T/out2" || fail "two runs differ (non-deterministic image)"

printf 'O'
