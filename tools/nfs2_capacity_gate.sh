#!/bin/sh
# nfs2_capacity_gate.sh - the NaN file store scales by compile-time config.
#
# NFS_MAX and NFS_CAP are .equ defaults that tools/nmk.awk lets the
# environment override.  This gate assembles the same NPAF code with
# 512 files and an 8 MiB arena, writes 512 x 7936 bytes, and verifies the
# first/middle/last files plus the header counters.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nfs2cap.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CLI=${NFS2_CAPACITY_RUNNER:-aarch64/android/nan_cli}
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
STEPS=${NFS2_CAPACITY_STEPS:-1000000000}

export NFS_MAX=512
export NFS_CAP=8388608
awk -f tools/nmk.awk -v CMD=emit src/tests/nfs2_capacity_test.nas > "$T/cap.nan"

"$CLI" --img "$T/cap.nan" --mem 128 --steps "$STEPS" --serial \
    --peek '0x225510:5' > "$T/out" 2> "$T/err" || true
if ! grep -qx 'PASS' "$T/out"; then
    echo "nfs2_capacity: FAIL (guest did not report PASS)"
    tail -5 "$T/out"; tail -2 "$T/err"; exit 1
fi
# magic, count=512, used words, cap, max
W=$(sed -n '/^4E504146$/,$p' "$T/out" | sed -n '2p')
[ "$W" = "00000200" ] || { echo "nfs2_capacity: FAIL (count=$W)"; exit 1; }
W=$(sed -n '/^4E504146$/,$p' "$T/out" | sed -n '5p')
[ "$W" = "00000200" ] || { echo "nfs2_capacity: FAIL (max=$W)"; exit 1; }
echo "nfs2_capacity: PASS (512 files, 8 MiB arena via NFS_MAX/NFS_CAP)"
