#!/bin/sh
# tools/nansched_stress_gate.sh - 512-process + thread scheduler stress.
#
# src/tests/nansched_stress_test.nas boots the real nan0s kernel with
# nankernel (SVC 4..8), nansched (1024-slot process scheduler + appended
# priority/count SVCs) and nanthr (cooperative threads for one owner process).
# It spawns 512 children, kills every seventh pid, waits all of them, then
# runs four mutex/cond/join threads.  The full transcript must match on the
# C oracle and x86_64 S1 and end in SCHED STRESS PASS.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nansched_stress.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

MEM=${NANSCHED_STRESS_MEM:-16}
STEPS=${NANSCHED_STRESS_STEPS:-10000000}

grep -q '^\.equ NP_MAX_PROCS 1024' src/tests/nansched_stress_test.nas || {
  echo "nansched_stress: FAIL (test does not request 1024 processes)"; exit 1; }
grep -q '^\.equ NS_MAX_PROCS  1024' src/lib/nansched.nas || {
  echo "nansched_stress: FAIL (scheduler is not 1024-slot)"; exit 1; }
grep -q 'nk_install_proc' src/tests/nansched_stress_test.nas || {
  echo "nansched_stress: FAIL (test does not install the kernel hook)"; exit 1; }
for n in 13 14 15 16 17 25 26 27 28; do
  grep -q "SVC $n" src/tests/nansched_stress_test.nas || {
    echo "nansched_stress: FAIL (missing SVC $n exercise)"; exit 1; }
done

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nansched_stress: note: oracle build unavailable; using existing nan_cli" >&2
  else
    echo "nansched_stress: FAIL (cannot build nan_cli)"; cat "$T/make.err"; exit 1
  fi
fi

awk -f tools/nmk.awk -v CMD=emit src/tests/nansched_stress_test.nas \
  > "$T/stress.nan" 2> "$T/emit.err"
WORDS=$(sed -n 's/^words //p' "$T/emit.err")
[ -n "$WORDS" ] || { echo "nansched_stress: FAIL (no word count)"; exit 1; }
[ "$WORDS" -lt 131072 ] || {
  echo "nansched_stress: FAIL (image $WORDS words exceeds code region)"; exit 1; }
awk -f tools/nmk.awk -v CMD=check "$T/stress.nan" 2> "$T/check.err" || {
  echo "nansched_stress: FAIL (nmk check)"; cat "$T/check.err"; exit 1; }
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nansched_stress: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

cat > "$T/expected" <<'EOF'
SCHED STRESS BEGIN
SPAWN 512
KILL 73
WAIT 512
SUM 31672
STATUS OK
COUNT 1 LIMIT 1024
PRIO 2
THREADS 4
MUTEX 200
COND 4
JOIN 2806
SCHED STRESS PASS
EOF

./aarch64/android/nan_cli --img "$T/stress.nan" --mem "$MEM" --steps "$STEPS" \
  --serial --peek '0x59047:1' > "$T/c.full" 2> "$T/c.err"
sed '$d' "$T/c.full" > "$T/c.out"
if ! cmp -s "$T/expected" "$T/c.out"; then
  echo "nansched_stress: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expected"
  echo "--- actual ---"; cat -v "$T/c.out"
  tail -3 "$T/c.err"; exit 1
fi
[ "$(tail -n 1 "$T/c.full")" != "00000000" ] || {
  echo "nansched_stress: FAIL (C oracle never timer-preempted)"; exit 1; }

sh tools/s1_runner.sh --img "$T/stress.nan" --mem "$MEM" --steps "$STEPS" \
  --serial --peek '0x59047:1' > "$T/s1.full" 2> "$T/s1.err"
sed '$d' "$T/s1.full" > "$T/s1.out"
if ! cmp -s "$T/c.out" "$T/s1.out"; then
  echo "nansched_stress: FAIL (x86_64 S1 differs from C oracle)"
  echo "--- C ---"; cat -v "$T/c.out"
  echo "--- S1 ---"; cat -v "$T/s1.out"
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi
[ "$(tail -n 1 "$T/s1.out")" = "SCHED STRESS PASS" ] || {
  echo "nansched_stress: FAIL (S1 transcript does not end in PASS)"
  cat -v "$T/s1.out"; exit 1; }

# Slice preemption evidence (NS_BASE 0x58000 + NS_PREEMPT 4167): the last
# line of each run is the peeked counter.
[ "$(tail -n 1 "$T/s1.full")" != "00000000" ] || {
  echo "nansched_stress: FAIL (S1 never timer-preempted)"; exit 1; }

echo "nansched_stress: PASS (1024-slot nanproc, 512 live processes,"
echo "  spawn/wait/kill/sleep, priority/count SVCs, 4 nanthr threads with"
echo "  mutex/cond/join; C oracle == x86_64 S1)"
cat "$T/s1.out"
