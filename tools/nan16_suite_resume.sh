#!/bin/sh
# tools/nan16_suite_resume.sh BASE_IMAGE CHECKPOINT TEST_PATH [OUTDIR]
#
# Run one official SQLite aggregate in a single guest testfixture process with
# no step budget, checkpointing the whole VM periodically.  If the host kills
# the runner, run the same command again: it resumes from CHECKPOINT instead
# of restarting the suite.  The guest testfixture (tester.tcl/permutations)
# runs every file in the aggregate in that one process, as the official
# harness does.
#
# Environment:
#   NAN16_CLI                       runner (default aarch64/android/nan_cli)
#   NAN16_SUITE_MEM                 guest MiB (default 256)
#   NAN16_SUITE_CHECKPOINT_SECONDS  checkpoint interval (default 60)
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
[ "$#" -ge 3 ] || {
    echo "usage: $0 BASE_IMAGE CHECKPOINT TEST_PATH [OUTDIR]" >&2
    exit 2
}
BASE=$1
CKPT=$2
TEST=$3
OUT=${4:-$(dirname "$CKPT")}
CLI=${NAN16_CLI:-$ROOT/aarch64/android/nan_cli}
MEM=${NAN16_SUITE_MEM:-256}
EVERY=${NAN16_SUITE_CHECKPOINT_SECONDS:-60}
[ -x "$CLI" ] || { echo "suite: no runner $CLI" >&2; exit 1; }
[ -f "$BASE" ] || { echo "suite: no base image $BASE" >&2; exit 1; }
mkdir -p "$OUT"
attempt=0
while :; do
    attempt=$((attempt + 1))
    if [ -s "$CKPT" ]; then SRC=$CKPT; else SRC=$BASE; fi
    echo "suite: attempt $attempt img=$SRC test=$TEST $(date)" >> "$OUT/suite.log"
    set +e
    "$CLI" --img "$SRC" --mem "$MEM" --steps unlimited \
        --checkpoint "$CKPT" --checkpoint-every "$EVERY" \
        --guest-script "$TEST" --guest-stdout "$OUT/stdout" \
        --guest-stderr "$OUT/stderr" --peek '0x100:1' \
        > "$OUT/peek" 2>> "$OUT/run.err"
    rc=$?
    set -e
    steps=$(sed -n 's/.*: \([0-9][0-9]*\) steps,.*/\1/p' "$OUT/run.err" | tail -1)
    echo "suite: attempt $attempt rc=$rc steps=${steps:-?}" >> "$OUT/suite.log"
    [ "$rc" -eq 0 ] && break
    if [ ! -s "$CKPT" ]; then
        echo "suite: attempt failed and no checkpoint exists; abort" >> "$OUT/suite.log"
        exit "$rc"
    fi
    sleep 2
done
MAIN=$(tail -n 1 "$OUT/peek" 2>/dev/null || true)
echo "suite: finished main=$MAIN $(date)" >> "$OUT/suite.log"
echo "suite: finished test=$TEST main=$MAIN steps=${steps:-?}"
grep -E '[0-9]+ errors out of [0-9]+ tests' "$OUT/stdout" | tail -1 || true
