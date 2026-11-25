#!/bin/sh
# nanfs_svc_gate.sh - bare-metal NaN SVC filesystem gate.
#
# kinit programs the S1 kernel ports; user code calls SVC 4..8.  The NaN
# kernel entry dispatches into NPAF.  No C service code is in the path.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nanfs_svc.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
RUNNER=${NANFS_SVC_RUNNER:-tools/s1_runner.sh}
STEPS=${NANFS_SVC_STEPS:-10000000}
MEM=${NANFS_SVC_MEM:-16}

awk -f tools/nmk.awk -v CMD=emit src/tests/nanfs_svc_test.nas > "$T/svc.nan"
"$RUNNER" --img "$T/svc.nan" --mem "$MEM" --steps "$STEPS" --serial \
    > "$T/out" 2> "$T/err" || true
if ! grep -qx 'PASS' "$T/out"; then
    echo "nanfs_svc: FAIL (SVC open/write/read/seek/close did not pass)"
    tail -5 "$T/out"; tail -3 "$T/err"; exit 1
fi
echo "nanfs_svc: PASS (SVC 4..8 -> NaN kernel -> NPAF filesystem)"
