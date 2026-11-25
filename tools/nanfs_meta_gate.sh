#!/bin/sh
# nanfs_meta_gate.sh - POSIX metadata implemented in NaN on NPAF.
# mkdir, stat, readdir, rmdir, access and truncate run on S1 (or the
# portable core with NANFS_META_RUNNER=aarch64/android/nan_cli).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nanfs_meta.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
RUNNER=${NANFS_META_RUNNER:-tools/s1_runner.sh}
STEPS=${NANFS_META_STEPS:-10000000}
MEM=${NANFS_META_MEM:-16}

awk -f tools/nmk.awk -v CMD=emit src/tests/nanfs_meta_test.nas > "$T/meta.nan"
"$RUNNER" --img "$T/meta.nan" --mem "$MEM" --steps "$STEPS" --serial \
    > "$T/out" 2> "$T/err" || true
if ! grep -qx 'PASS' "$T/out"; then
    echo "nanfs_meta: FAIL (mkdir/stat/readdir/rmdir/access/truncate)"
    tail -5 "$T/out"; tail -3 "$T/err"; exit 1
fi
echo "nanfs_meta: PASS (POSIX metadata implemented in NaN on NPAF)"
