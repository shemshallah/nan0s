#!/bin/sh
# tools/nixjobs_gate.sh - S1 acceptance for concurrent jobs and pipelines.
#
# Runs src/tests/nixjobs_test.nas on the C-core oracle and the x86_64 S1.
# The test starts a producer alone, proves it blocks after filling the 8 KiB
# shared ring, then starts a consumer that records the producer's partial
# progress before reading.  The 16 KiB stream must match byte-for-byte and
# hash to F8DFF505; a background job must start, be waited for (status 42,
# job state 2) and reaped (state 0).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C

TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nixjobs_gate.$$"
mkdir -p "$T"
trap 'if [ "${NIXJOBS_KEEP:-0}" = 1 ]; then echo "nixjobs_gate: kept $T" >&2; else rm -rf "$T"; fi' EXIT INT TERM

STEPS=${NIXJOBS_STEPS:-40000000}
MEM=${NIXJOBS_MEM:-16}

fail() {
  echo "nixjobs_gate: FAIL ($*)" >&2
  exit 1
}

for f in spec/NIX_JOBS.md src/lib/nixjobs.nas src/tests/nixjobs_test.nas; do
  [ -f "$f" ] || fail "missing $f"
done

# The primitive must be process-based and expose the real lifecycle.
grep -q '^nj_worker_entry:' src/lib/nixjobs.nas || fail "no worker entry"
grep -q '^nj_ring_write:' src/lib/nixjobs.nas || fail "no blocking ring writer"
grep -q '^nj_ring_read:' src/lib/nixjobs.nas || fail "no blocking ring reader"
grep -q '^nj_job_start:' src/lib/nixjobs.nas || fail "no job start"
grep -q '^nj_job_wait:' src/lib/nixjobs.nas || fail "no job wait"
grep -q '^nj_job_reap:' src/lib/nixjobs.nas || fail "no job reap"
grep -q 'SVC 9' src/lib/nixjobs.nas || fail "no SVC 9 spawn"
grep -q 'SVC 10' src/lib/nixjobs.nas || fail "no SVC 10 wait"
grep -q 'SVC 24' src/lib/nixjobs.nas || fail "no SVC 24 blocking sleep"

# The concurrent path must not fall back to the process-global fd/pipe state.
if grep -nE '(CALL|JMP)[[:space:]]+@(nfd_|np_|nx_)' \
    src/lib/nixjobs.nas src/tests/nixjobs_test.nas >/dev/null; then
  fail "worker path calls process-global nfd/nanpipe/shell code"
fi
if grep -q 'nfd_init' src/tests/nixjobs_test.nas; then
  fail "test installs NFD"
fi

# NaN16 LD/ST immediates are 16-bit.  High word globals must use a base
# register materialized with LA; reject the truncating r0+imm form and any
# symbolic/numeric offset whose value exceeds 0xFFFF.
if grep -nE '(^|[^A-Za-z0-9_])(LD|ST)[[:space:]]+r[0-9]+,[[:space:]]*r0[[:space:]]*,[[:space:]]*#' \
    src/lib/nixjobs.nas src/tests/nixjobs_test.nas > "$T/highaddr"; then
  cat "$T/highaddr" >&2
  fail "LD/ST rX,r0,#high address is truncated; use LA base register"
fi
python3 - "$T/highaddr2" src/lib/nixjobs.nas src/tests/nixjobs_test.nas <<'PY'
import re, sys
out = sys.argv[1]
files = sys.argv[2:]
eq = {}
for f in files:
    for line in open(f):
        m = re.match(r"\s*\.equ\s+([A-Za-z_]\w*)\s+([^;]+)", line)
        if not m:
            continue
        v = m.group(2).strip()
        if re.fullmatch(r"0x[0-9A-Fa-f]+|[0-9]+", v):
            eq[m.group(1)] = int(v, 0)
bad = []
for f in files:
    for n, line in enumerate(open(f), 1):
        code = line.split(";", 1)[0]
        m = re.search(r"\b(?:LD|ST)\s+r\d+\s*,\s*r\d+\s*,\s*#(\S+)", code)
        if not m:
            continue
        tok = m.group(1)
        val = eq.get(tok)
        if val is None and re.fullmatch(r"0x[0-9A-Fa-f]+|[0-9]+", tok):
            val = int(tok, 0)
        if val is not None and val > 0xFFFF:
            bad.append("%s:%d: LD/ST offset #%s = 0x%X" % (f, n, tok, val))
open(out, "w").write("\n".join(bad) + ("\n" if bad else ""))
PY
if [ -s "$T/highaddr2" ]; then
  cat "$T/highaddr2" >&2
  fail "LD/ST immediate offset exceeds 16 bits"
fi

# No raw SVC opcode words in guest source.
if grep -nE '_[0-9A-Fa-f]{4}4E[0-9A-Fa-f]{6}_' \
    src/lib/nixjobs.nas src/tests/nixjobs_test.nas >/dev/null; then
  fail "raw SVC opcode word in guest source"
fi

awk -f tools/nmk.awk -v CMD=emit src/tests/nixjobs_test.nas \
  > "$T/test.nan" 2> "$T/emit.err" || {
    cat "$T/emit.err" >&2; fail "assembler emit"; }
WORDS=$(sed -n 's/^words //p' "$T/emit.err")
[ -n "$WORDS" ] || fail "no word count"
[ "$WORDS" -lt 131072 ] || fail "image $WORDS words exceeds the 0x20000-word code region"
[ "$WORDS" -lt 262144 ] || fail "image $WORDS words reaches NP_BASE"

awk -f tools/nmk.awk -v CMD=check "$T/test.nan" 2> "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }
grep -q 'check: 0 mismatches' "$T/check.err" || {
  cat "$T/check.err" >&2; fail "assembler round-trip"; }

cat > "$T/expected" <<'EOF'
NJ BEGIN
RING 00002000
FDS OK
BG START 00000001
PREBLOCK 1
PIPE 00004000 F8DFF505
OVERLAP 1
WBLK 1
BG WAIT 0000002A 00000002
BG REAP 0000002A 00000000
NJ PASS
EOF

[ -x ./aarch64/android/nan_cli ] || fail "missing aarch64/android/nan_cli oracle"
command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "no qemu-system-x86_64"

C_RC=0
./aarch64/android/nan_cli --img "$T/test.nan" --mem "$MEM" --steps "$STEPS" \
  --serial > "$T/c.full" 2> "$T/c.err" || C_RC=$?
if ! cmp -s "$T/expected" "$T/c.full"; then
  echo "--- expected ---"; cat -v "$T/expected"
  echo "--- C oracle (rc=$C_RC) ---"; cat -v "$T/c.full"
  cat "$T/c.err" >&2
  fail "C oracle transcript"
fi

S_RC=0
sh tools/s1_runner.sh --img "$T/test.nan" --mem "$MEM" --steps "$STEPS" \
  --serial > "$T/s1.full" 2> "$T/s1.err" || S_RC=$?
if ! cmp -s "$T/expected" "$T/s1.full"; then
  echo "--- expected ---"; cat -v "$T/expected"
  echo "--- S1 (rc=$S_RC) ---"; cat -v "$T/s1.full"
  tail -20 "$T/s1.err" 2>/dev/null || true
  fail "x86_64 S1 transcript"
fi
if ! cmp -s "$T/c.full" "$T/s1.full"; then
  fail "C oracle and x86_64 S1 differ"
fi

echo "nixjobs_gate: PASS (image $WORDS words, steps $STEPS)"
echo "nixjobs_gate: producer blocked before consumer, 16 KiB stream + hash,"
echo "  per-worker fd tables, background job wait/reap; C oracle == x86_64 S1"
cat "$T/s1.full"
