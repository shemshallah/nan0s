#!/bin/sh
# tools/nfabric_gate.sh - F11 emulated two-node RDMA/KV/checkpoint gate.
#
# Builds src/tests/nfabric_test.nas with tools/nmk.awk and runs it twice on the
# aarch64/android nan_cli NaN machine.  No C harness is built or linked: the
# image contains the real nfabric, nkv, nheap and nanobj libraries.
#
# Proves, deterministically:
#   * two node records and queue pairs with posted receives and credits;
#     send/recv matching, FIFO completions, no-credit rejection;
#   * RDMA write/read with remote keys, rights, bounds and 64-bit offsets in
#     both directions, exact byte equality;
#   * rkey revoke makes every older key fail ESTALE and the new key work;
#   * remote KV put/get over real nkv slabs, stale slab-generation rejection;
#   * nagent-style checkpoint push/pull, NAGC seal verification, exact word
#     equality, epoch rollback rejection and corrupted-seal rejection.
#
# On success stdout is exactly one byte: O.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPBASE=${TMPDIR:-$PWD/tmp}
mkdir -p "$TMPBASE" 2>/dev/null || TMPBASE="$PWD/build"
T="$TMPBASE/nfabric.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() {
  echo "nfabric: FAIL ($*)" >&2
  exit 1
}

[ -f src/lib/nfabric.nas ] || fail "missing src/lib/nfabric.nas"
[ -f src/tests/nfabric_test.nas ] || fail "missing test image"
[ -f tools/nmk.awk ] || fail "missing tools/nmk.awk"

for sym in nfab_init nfab_node_init nfab_mr_register nfab_mr_revoke \
           nfab_mr_key nfab_mr_info nfab_qp_create nfab_qp_connect \
           nfab_recv_post nfab_credits nfab_send nfab_write nfab_read \
           nfab_poll nfab_cq_count nfab_errno nfab_kv_put nfab_kv_get \
           nfab_ck_seal nfab_ck_verify nfab_ck_send nfab_ck_recv; do
  grep -q "^$sym:" src/lib/nfabric.nas || fail "missing $sym"
  grep -q "@$sym" src/tests/nfabric_test.nas || fail "test does not call $sym"
done

for f in NFAB_MAGIC NFAB_NODE_MAGIC NFAB_QP_MAGIC NFAB_RKEY_TAG \
         NF_Q_RQT NF_Q_CQH NF_Q_DEPTH NF_N_CKEPOCH NF_M_KEY \
         NF_OP_SEND NF_OP_RECV NF_OP_WRITE NF_OP_READ \
         NFAB_ECREDIT NFAB_ERIGHT NFAB_ESTALE NFAB_EBOUNDS NFAB_ECK \
         NFCK_MAGIC NFCK_SEED NFCK_HASH; do
  grep -q "$f" src/lib/nfabric.nas || fail "missing $f"
done
grep -q 'loopback' src/lib/nfabric.nas || fail "no loopback contract"
grep -q 'rkey' src/lib/nfabric.nas || fail "no remote-key contract"
grep -q 'credits' src/lib/nfabric.nas || fail "no credit contract"
grep -q 'nagent' src/lib/nfabric.nas || fail "no nagent wire contract"
grep -q 'not reentrant' src/lib/nfabric.nas || fail "no scratch contract"

if grep -nE '\b(RDTSC|TICK|KEY|KEYQ|INL|OUTL|INW|OUTW|INB|OUTB)\b' \
    src/lib/nfabric.nas > "$T/host.err"; then
  cat "$T/host.err" >&2
  fail "host entropy/time/device opcode in the fabric boundary"
fi

# The test must keep the exact-byte, credit, stale-key and rollback paths.
grep -q 'NFAB_ECREDIT' src/tests/nfabric_test.nas || fail "no credit check"
grep -q 'NFAB_ESTALE' src/tests/nfabric_test.nas || fail "no stale-key check"
grep -q 'NFAB_ERIGHT' src/tests/nfabric_test.nas || fail "no rights check"
grep -q 'NFAB_EBOUNDS' src/tests/nfabric_test.nas || fail "no bounds check"
grep -q 'NFAB_ECK' src/tests/nfabric_test.nas || fail "no seal check"
grep -q 'nkv_slab_create' src/tests/nfabric_test.nas || fail "no nkv slab path"
grep -q 'nfab_ck_recv' src/tests/nfabric_test.nas || fail "no checkpoint pull"
grep -q 'nfab_ck_send' src/tests/nfabric_test.nas || fail "no checkpoint push"
grep -q '0x40000' src/tests/nfabric_test.nas || fail "no nheap slab backing"
grep -q '0x8F00' src/tests/nfabric_test.nas || fail "no test stack"

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nfabric: note: oracle build unavailable; using existing nan_cli" >&2
  else
    cat "$T/make.err" >&2
    fail "cannot build nan_cli"
  fi
fi

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/labels" \
  src/tests/nfabric_test.nas > "$T/t.nan" 2> "$T/emit.err" || {
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

LAST=$(awk '$2+0 > m { m=$2+0 } END { print m+0 }' "$T/labels")
[ "$LAST" -lt 16384 ] || fail "code/data reaches the 0x4000 buffer window"
for sym in main nfab_send nfab_write nfab_read nfab_kv_put nfab_kv_get \
           nfab_ck_send nfab_ck_recv chk; do
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
    fail "fabric self-test did not prove O"
  }
}

run_once "$T/out1"
run_once "$T/out2"
cmp -s "$T/out1" "$T/out2" || fail "two runs differ (non-deterministic image)"

printf 'O'
