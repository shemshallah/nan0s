#!/bin/sh
# nanpipe_gate.sh - NaN16 byte pipe primitive (write/read/wrap/close).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nanpipe.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
RUNNER=${NANPIPE_RUNNER:-tools/s1_runner.sh}
STEPS=${NANPIPE_STEPS:-10000000}
MEM=${NANPIPE_MEM:-16}
awk -f tools/nmk.awk -v CMD=emit src/tests/nanpipe_test.nas > "$T/p.nan"
"$RUNNER" --img "$T/p.nan" --mem "$MEM" --steps "$STEPS" --serial \
    > "$T/out" 2> "$T/err" || true
if ! grep -qx 'PASS' "$T/out"; then
    echo "nanpipe: FAIL (pipe write/read/wrap/close)"
    tail -5 "$T/out"; tail -3 "$T/err"; exit 1
fi
echo "nanpipe: PASS (NaN16 byte pipes on NPAF memory)"
