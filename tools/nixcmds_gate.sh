#!/bin/sh
# nixcmds_gate.sh - standalone S1 gate for src/lib/nixcmds.nas.
#
# Assembles src/tests/nixcmds_test.nas with tools/nmk.awk, runs the exact
# assembler round-trip check, then executes the image on the x86_64 S1 runner.
# The test image links the real nixcmds library against an in-memory fd shim
# and byte-compares head/tail/grep/sort/uniq output, including the 32 KiB
# too-large failure path.  Guest PASS lines use PUTC, so --serial is required.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
TMPDIR="${TMPDIR:-$ROOT/tmp}"
mkdir -p "$TMPDIR"
T=$(mktemp -d "$TMPDIR/nixcmds_gate.XXXXXX") || {
    echo "nixcmds_gate: FAIL (mktemp)"; exit 1; }
trap 'rm -rf "$T"' EXIT INT TERM

echo "nixcmds_gate: assemble"
if ! awk -f tools/nmk.awk -v CMD=emit src/tests/nixcmds_test.nas \
        > "$T/nixcmds.nan" 2> "$T/emit.err"; then
    echo "nixcmds_gate: FAIL (assemble)"
    cat "$T/emit.err"
    exit 1
fi
if ! awk -f tools/nmk.awk -v CMD=check "$T/nixcmds.nan" \
        > /dev/null 2> "$T/check.err"; then
    echo "nixcmds_gate: FAIL (assembler round-trip)"
    cat "$T/check.err"
    exit 1
fi
grep -q 'check: 0 mismatches' "$T/check.err" || {
    echo "nixcmds_gate: FAIL (assembler round-trip)"
    cat "$T/check.err"
    exit 1
}
WORDS=$(awk '/^words /{print $2; exit}' "$T/emit.err")
[ -n "$WORDS" ] || { echo "nixcmds_gate: FAIL (no word count)"; exit 1; }
# NXC_G lives at word 0x1000; this gate image is loaded at word 0, so it must
# end at or below 0x1000 to keep the library's low global block free.
[ "$WORDS" -le 4096 ] || {
    echo "nixcmds_gate: FAIL (test image $WORDS words overlaps NXC_G at 0x1000)"
    exit 1
}

echo "nixcmds_gate: run on x86_64 S1"
# Keep the runner's private temp under this gate's unique directory so
# concurrent gates cannot share/overwrite the image or transcript.
TMPDIR="$T" sh tools/s1_runner.sh --img "$T/nixcmds.nan" --mem 64 \
    --steps "${NIXCMDS_GATE_STEPS:-50000000}" --serial \
    > "$T/out" 2> "$T/run.err" || {
        echo "nixcmds_gate: FAIL (runner)"
        tail -20 "$T/run.err"
        exit 1; }

tr -d '\r' < "$T/out" > "$T/out.norm"
cat > "$T/expected" <<'EOF'
PASS head default
PASS head -n 2 file
PASS head -n 0
PASS tail default
PASS tail -n 3
PASS tail empty
PASS grep fixed
PASS grep -v -n
PASS grep empty
PASS sort
PASS uniq
PASS uniq -c
PASS sort too-large
PASS nixcmds
EOF

if ! diff -u "$T/expected" "$T/out.norm"; then
    echo "nixcmds_gate: FAIL (transcript mismatch)"
    exit 1
fi

cat "$T/out.norm"
echo "nixcmds_gate: PASS (nmk check 0 mismatches; head/tail/grep/sort/uniq + 32 KiB bound)"
