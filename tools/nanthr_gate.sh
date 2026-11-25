#!/bin/sh
# tools/nanthr_gate.sh - NaN kernel thread subsystem gate.
#
# The test is one raw NaN16 image (src/tests/nanthr_test.nas).  It is first
# checked and run on the portable C core, which is the development oracle
# only.  The same image is then handed to an x86_64 S1 runner when one is
# available; that run is the product acceptance path.
#
# Runner contract:
#   NANTHR_X64_RUNNER=/path/to/runner sh tools/nanthr_gate.sh
#   $NANTHR_X64_RUNNER <image.nan>   -> exact transcript on stdout
# A default runner at build/nanthr_x64_runner is used when executable.
# With --require-x64 a missing or failing x86_64 runner fails the gate.
#
# No host path is hardcoded: temporary files live in ${TMPDIR:-/tmp}.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
REQ64=0
[ "${1:-}" = "--require-x64" ] && REQ64=1
T="${TMPDIR:-/tmp}/nanthr_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

CLI="${NANTHR_ORACLE_CLI:-aarch64/android/nan_cli}"
if [ ! -x "$CLI" ]; then
  (cd aarch64/android && make -s nan_cli)
fi

# 1. assemble the exact image
awk -f tools/nmk.awk -v CMD=emit src/tests/nanthr_test.nas > "$T/t.nan" 2>"$T/emit.err"
WORDS=$(sed -n 's/^words //p' "$T/emit.err" | tail -1)
[ -n "$WORDS" ] || { echo "nanthr_gate: FAIL (no word count)"; cat "$T/emit.err"; exit 1; }
# TCB arena starts at word 0x4000; code/data must not overlap it.
[ "$WORDS" -le 16383 ] || { echo "nanthr_gate: FAIL (image $WORDS words overlaps TCB arena)"; exit 1; }

# 2. the seed assembler must round-trip every instruction, including SVC imm
awk -f tools/nmk.awk -v CMD=check "$T/t.nan" 2>"$T/check.err"
grep -q '^check: 0 mismatches$' "$T/check.err" || {
  echo "nanthr_gate: FAIL (nmk check)"; cat "$T/check.err"; exit 1; }

# 3. all seven production SVC entry points must be present as opcode 0x4E
for imm in 000000 00000D 00000E 00000F 000010 000011 000012 000013; do
  n=$(grep -c "4E${imm}" "$T/t.nan" || true)
  [ "$n" -ge 1 ] || { echo "nanthr_gate: FAIL (missing SVC imm 0x$imm)"; exit 1; }
done

# 4. oracle run: exact transcript, no trap
"$CLI" --img "$T/t.nan" --mem 64 --steps 1000000000 --serial \
  > "$T/oracle.out" 2> "$T/oracle.err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/oracle.out" > "$T/oracle.got"
if ! cmp -s "$T/oracle.got" src/tests/nanthr.expected; then
  echo "nanthr_gate: ORACLE FAIL"
  diff -u src/tests/nanthr.expected "$T/oracle.got" | head -40
  tail -3 "$T/oracle.err"
  exit 1
fi
grep -q "trap=''" "$T/oracle.err" || {
  echo "nanthr_gate: ORACLE FAIL (trap)"; tail -3 "$T/oracle.err"; exit 1; }
echo "nanthr_gate: ORACLE PASS ($(wc -l < "$T/oracle.got") lines exact, $WORDS words)"

# 5. product path: same image on the x86_64 S1 runner
RUNNER="${NANTHR_X64_RUNNER:-}"
if [ -z "$RUNNER" ] && [ -x build/nanthr_x64_runner ]; then
  RUNNER=build/nanthr_x64_runner
fi
if [ -n "$RUNNER" ]; then
  set +e
  "$RUNNER" "$T/t.nan" > "$T/x64.out" 2> "$T/x64.err"
  xrc=$?
  set -e
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/x64.out" > "$T/x64.got"
  if [ "$xrc" -ne 0 ] || ! cmp -s "$T/x64.got" src/tests/nanthr.expected; then
    echo "nanthr_gate: X86_64 FAIL (runner=$RUNNER rc=$xrc)"
    diff -u src/tests/nanthr.expected "$T/x64.got" | head -40
    tail -3 "$T/x64.err"
    exit 1
  fi
  echo "nanthr_gate: X86_64 PASS ($RUNNER, same image, exact)"
  echo "nanthr_gate: RESULT PASS (x86_64 S1 acceptance)"
  exit 0
fi

echo "nanthr_gate: X86_64 PENDING (no S1 runner; set NANTHR_X64_RUNNER or build/nanthr_x64_runner)"
if [ "$REQ64" = 1 ]; then
  echo "nanthr_gate: FAIL (--require-x64 and no x86_64 S1 runner)"
  exit 1
fi
echo "nanthr_gate: RESULT ORACLE PASS, x86_64 ACCEPTANCE PENDING"
