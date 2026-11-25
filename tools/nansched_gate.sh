#!/bin/sh
# tools/nansched_gate.sh - kernel process scheduler acceptance.
#
# src/lib/nansched.nas is the nan0s kernel scheduler.  The test image installs
# it through nk_install_proc in src/lib/nankernel.nas, so SVC 4..8 stay on the
# NPAF file service while SVC 0/1/9/10/20/21/22/23/24 go to the scheduler.
# The image is run on the C-core oracle and on the x86_64 S1; the complete
# transcript must be byte-identical and end in SCHED PASS.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nansched.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

MEM=${NANSCHED_MEM:-16}
STEPS=${NANSCHED_STEPS:-20000000}

# Static integration checks: the scheduler is installed by the existing
# kernel, and the test uses the named SVC mnemonics (no raw SVC opcode word).
grep -q 'nk_install_proc' src/tests/nansched_test.nas || {
  echo "nansched: FAIL (test does not install the process hook)"; exit 1; }
grep -q '^nsch_svc:' src/lib/nansched.nas || {
  echo "nansched: FAIL (missing nsch_svc entry)"; exit 1; }
grep -q '^ns_svc:' src/lib/nansched.nas || {
  echo "nansched: FAIL (missing public ns_svc alias)"; exit 1; }
if grep -nE '_[0-9A-F]{4}4E[0-9A-F]{6}_' src/lib/nansched.nas src/tests/nansched_test.nas >/dev/null; then
  echo "nansched: FAIL (raw SVC opcode word in guest source)"; exit 1
fi

if ! make -s -C aarch64/android nan_cli 2> "$T/make.err"; then
  if [ -x ./aarch64/android/nan_cli ]; then
    echo "nansched: note: oracle build unavailable; using existing nan_cli" >&2
  else
    echo "nansched: FAIL (cannot build nan_cli)"; cat "$T/make.err"; exit 1
  fi
fi

awk -f tools/nmk.awk -v CMD=emit src/tests/nansched_test.nas \
  > "$T/sched.nan" 2> "$T/emit.err"
WORDS=$(sed -n 's/^words //p' "$T/emit.err")
[ -n "$WORDS" ] || { echo "nansched: FAIL (no word count)"; exit 1; }
[ "$WORDS" -lt 262144 ] || {
  echo "nansched: FAIL (image $WORDS words reaches NP_BASE)"; exit 1; }
[ "$WORDS" -lt 131072 ] || {
  echo "nansched: FAIL (image $WORDS words exceeds the process code region)"; exit 1; }

awk -f tools/nmk.awk -v CMD=check "$T/sched.nan" 2> "$T/check.err" || {
  echo "nansched: FAIL (nmk check)"; cat "$T/check.err"; exit 1; }
grep -q 'check: 0 mismatches' "$T/check.err" || {
  echo "nansched: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

cat > "$T/expected" <<'EOF'
SCHED BEGIN
FS OK
SPAWN 8
RUN HLSXAhBKYAsBAB
W 10
W 20
W 30
W 40
W 50
W 60
W 70
KILL 0
W 143
SCHED PASS
EOF

./aarch64/android/nan_cli --img "$T/sched.nan" --mem "$MEM" --steps "$STEPS" \
  --serial > "$T/c.out" 2> "$T/c.err"
if ! cmp -s "$T/expected" "$T/c.out"; then
  echo "nansched: FAIL (C oracle transcript)"
  echo "--- expected ---"; cat -v "$T/expected"
  echo "--- actual ---"; cat -v "$T/c.out"
  exit 1
fi

sh tools/s1_runner.sh --img "$T/sched.nan" --mem "$MEM" --steps "$STEPS" \
  --serial > "$T/s1.out" 2> "$T/s1.err"
if ! cmp -s "$T/c.out" "$T/s1.out"; then
  echo "nansched: FAIL (x86_64 S1 differs from C oracle)"
  echo "--- C ---"; cat -v "$T/c.out"
  echo "--- S1 ---"; cat -v "$T/s1.out"
  tail -20 "$T/s1.err" 2>/dev/null || true
  exit 1
fi
[ "$(tail -n 1 "$T/s1.out")" = "SCHED PASS" ] || {
  echo "nansched: FAIL (S1 transcript does not end in SCHED PASS)"
  cat -v "$T/s1.out"; exit 1; }

# Slice-preemption evidence: NS_PREEMPT (NS_BASE+327) counts timer-IRQ
# preemptions.  It must be nonzero on both engines, proving the quantum path
# ran, not only cooperative yields.
./aarch64/android/nan_cli --img "$T/sched.nan" --mem "$MEM" --steps "$STEPS" \
  --peek '0x48147:1' > "$T/cpre.out" 2> "$T/cpre.err"
[ "$(tail -n 1 "$T/cpre.out")" != "00000000" ] || {
  echo "nansched: FAIL (C oracle never timer-preempted)"; exit 1; }
sh tools/s1_runner.sh --img "$T/sched.nan" --mem "$MEM" --steps "$STEPS" \
  --peek '0x48147:1' > "$T/s1pre.out" 2> "$T/s1pre.err"
[ "$(tail -n 1 "$T/s1pre.out")" != "00000000" ] || {
  echo "nansched: FAIL (S1 never timer-preempted)"; exit 1; }

echo "nansched: PASS (64-slot nanproc, 32 priority queues, timer preemption,"
echo "  yield/exit/spawn/wait/kill/sleep; SVC 4..8 NPAF + process SVCs on"
echo "  C oracle == x86_64 S1)"
cat "$T/s1.out"
