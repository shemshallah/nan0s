#!/bin/sh
# tools/nfs2_extra_gate.sh - NPAF stat/readdir/rename/truncate gate.
#
# Product acceptance is an x86_64 S1 NaN runner.  The portable C core is
# oracle evidence only and must be opted in.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T=${TMPDIR:-$ROOT/build}/nfs2-extra.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM
RUNNER=${NFS2_EXTRA_RUNNER:-}
MODE=product
if [ -z "$RUNNER" ]; then
    if [ "${NFS2_EXTRA_ALLOW_ORACLE:-0}" = 1 ]; then
        RUNNER=$ROOT/aarch64/android/nan_cli
        MODE=oracle
    else
        echo "nfs2_extra: SKIP (no x86_64 S1 runner; set NFS2_EXTRA_RUNNER or NFS2_EXTRA_ALLOW_ORACLE=1)"
        exit 77
    fi
fi
[ -x "$RUNNER" ] || { echo "nfs2_extra: FAIL runner not executable: $RUNNER"; exit 1; }

gawk -f tools/nmk.awk -v CMD=emit src/tests/nfs2_extra_test.nas > "$T/nfs2.nan" 2> "$T/emit.err" || {
    echo "nfs2_extra: FAIL assemble"; cat "$T/emit.err"; exit 1; }
gawk -f tools/nmk.awk -v CMD=check "$T/nfs2.nan" >/dev/null 2> "$T/check.err" || {
    echo "nfs2_extra: FAIL check"; cat "$T/check.err"; exit 1; }
"$RUNNER" --img "$T/nfs2.nan" --mem 64 --steps 500000 --serial > "$T/out" 2> "$T/run.err" || true
tr -d '\r' < "$T/out" > "$T/out.norm"
if ! grep -qx 'NFS2 EXTRA PASS' "$T/out.norm"; then
    echo "nfs2_extra: FAIL output"; cat "$T/out.norm"; tail -3 "$T/run.err"; exit 1
fi
if [ "$MODE" = oracle ]; then
    echo "nfs2_extra: ORACLE MATCH (x86_64 S1 acceptance pending)"
else
    echo "nfs2_extra: PASS"
fi
