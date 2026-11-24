#!/bin/sh
# nanproc gate - exact-output conformance for the NaN process subsystem.
#
# Acceptance path (product): NANPROC_RUNNER must name an x86_64 S1 NaN image
# runner with the nan_cli-compatible CLI
#     RUNNER --img FILE --steps N --serial
# On success this script prints "nanproc gate: PASS" and exits 0.
#
# Without NANPROC_RUNNER the gate is a SKIP (exit 77): the process subsystem is
# NaN code and must be accepted on x86_64 bare metal/S1, never on the portable
# C core. Setting NANPROC_ALLOW_ORACLE=1 runs the same images on the C-core
# oracle and requires byte-exact output, but still exits 77 after printing
# "ORACLE MATCH"; that run is conformance evidence, not product acceptance.
#
# Scratch is worktree-relative under build/; no phone paths, no /tmp.
set -u
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T="$ROOT/build/nanproc-gate.$$"
mkdir -p "$T"
export TMPDIR="$T"
trap 'rm -rf "$T"' EXIT INT TERM

STEPS=5000000
MODE=""
RUNNER="${NANPROC_RUNNER:-}"
if [ -n "$RUNNER" ]; then
  MODE=x86_64
elif [ "${NANPROC_ALLOW_ORACLE:-0}" = "1" ]; then
  MODE=oracle
  RUNNER="$ROOT/aarch64/android/nan_cli"
else
  echo "nanproc gate: SKIP (no x86_64 S1 runner)"
  echo "  set NANPROC_RUNNER=/path/to/x86_64-nan-runner for acceptance,"
  echo "  or NANPROC_ALLOW_ORACLE=1 for C-core conformance evidence only."
  exit 77
fi

fail() { echo "nanproc gate: FAIL ($*)"; exit 1; }

# Product-rule guard: no phone paths or host-C includes in guest sources,
# and no raw SVC opcode words (kernel agent supplies SVC/SVCRET/INL mnemonics).
for f in src/lib/nanproc.nas src/prog/nanproc_test.nas src/prog/ps.nas; do
  [ -f "$f" ] || fail "missing $f"
  grep -n '/data/data/' "$f" && fail "phone path in $f"
  grep -n '#include' "$f" && fail "host include in $f"
  grep -n '0x4E' "$f" && fail "raw SVC word in $f"
done

if [ "$MODE" = oracle ]; then
  [ -x "$RUNNER" ] || ( cd aarch64/android && make -s nan_cli ) || fail "oracle build"
  [ -x "$RUNNER" ] || fail "oracle runner"
else
  case "$RUNNER" in
    */aarch64/android/nan_cli|aarch64/android/nan_cli)
      fail "the C-core oracle cannot be NANPROC_RUNNER; use an x86_64 S1 runner" ;;
  esac
fi
[ -x "$RUNNER" ] || fail "runner not executable: $RUNNER"

emit() { awk -f tools/nmk.awk -v CMD=emit "$1" > "$2" 2>"$2.emit" || fail "emit $1"; }
check_asm() { awk -f tools/nmk.awk -v CMD=check "$1" >/dev/null 2>"$T/check.err" || fail "check $1"; }

emit src/prog/nanproc_test.nas "$T/nanproc_test.nan"
emit src/prog/ps.nas "$T/ps.nan"
check_asm "$T/nanproc_test.nan"
check_asm "$T/ps.nan"

# Test-image memory map guard (test convenience, not a kernel ABI):
# code below vars 0x1F00; table 0x10000..0x11800 (64*96) below heaps at
# 0x30000; vars/scratch below the stack at 0x7000. The museum/shell link
# must choose NP_BASE from its own free-memory map, not these constants.
for spec in "$T/nanproc_test.nan" "$T/ps.nan"; do
  w=$(awk '/^words / { print $2 }' "$spec.emit")
  [ -n "$w" ] || fail "word count missing for $spec"
  [ "$w" -lt 7936 ] || fail "image $spec crosses vars at 0x1F00 ($w words)"
done
[ $((65536 + 64 * 96)) -lt 196608 ] || fail "process table overlaps test heaps"

run_img() {
  "$RUNNER" --img "$1" --steps "$STEPS" --serial > "$2" 2>"$2.err" || fail "run $1"
  tr -d '\r' < "$2" > "$2.norm"
}

cat > "$T/expected_test" <<'EOF'
nanproc test
init live=00000000 run=00000000 zomb=00000000 spawn=00000000 reap=00000000
create pid=00000001 ppid=00000000 state=00000001 live=00000001
run state=00000002 run=00000001
heap used=00000064 words=00000400 regions=00000001 mem=00000400 head=0000039C
create pid=00000002 ppid=00000001 state=00000001 live=00000002
child parent=00000001 count=00000001
spawn-stub pid=00000003 ppid=00000001 image=00050000 words=00000080 nreg=00000001
child parent=00000001 count=00000002
heap used=00000064 words=00000800 regions=00000003 mem=000008C0 head=0000079C
region pid=00000003 idx=00000001 base=00033000 n=00000800 kind=00000002 prot=00000003
region pid=00000003 idx=00000002 base=0003A000 n=00000040 kind=00000003 prot=00000003
region pid=00000003 idx=00000003 found=00000000
threads pid=00000003 count=00000002 dup=00000003
attrs pid=00000003 steps=00001388 prio=00000005 state=00000003
illegal pid=00000003 transition=00000002
create pid=00000004 ppid=00000001 state=00000001 live=00000004
child parent=00000001 count=00000003
exit pid=00000004 state=00000004 status=00000003 zombies=00000001 live=00000004
wait parent=00000001 pid=00000004 status=00000003
wait-none parent=00000001 pid=00000002 code=00000000 status=00000000
reap pid=00000004 status=00000003 live=00000003 zombies=00000000
cleanup pid=00000004 found=00000000 children=00000002
reap-again pid=00000004 code=00000001
kill pid=00000002 sig=0000000F status=0000008F state=00000004 zombies=00000001
wait-any parent=00000001 pid=00000002 status=0000008F
cleanup pid=00000002 found=00000000 children=00000001 live=00000002 zombies=00000000
stats live=00000002 run=00000001 zomb=00000000 spawn=00000004 reap=00000002
kill pid=00000003 sig=00000009 status=00000089 state=00000004
reap pid=00000003 status=00000089 live=00000001
clear pid=00000006 nreg=00000000 mem=00000000
orphan pid=00000005 state=00000005 status=0000000B kid=00000006 kidppid=00000001 initchildren=00000001
reap pid=00000005 status=0000000B live=00000002 zombies=00000000
kill pid=00000006 sig=00000002 status=00000082 state=00000004
wait-any parent=00000001 pid=00000006 status=00000082
capacity procs=00000040 overflow=00000000 regions=00000008 threads=00000010
reap pid=00000006 status=00000082 live=00000001
final live=00000001 run=00000001 zomb=00000000 spawn=00000045 reap=00000044
PASS checks=000001A4
EOF

cat > "$T/expected_ps" <<'EOF'
NaN/0S PROCESS VIEWER
 PID PPID STATE  THR    MEM    CPU PRIO
   1    0 RUN      1   1024      10    0
   2    1 READY    1    512      42    3
   3    1 BLOCK    2   2240    5000    5
   4    1 ZOMBIE   1    320       7    0
LIVE 4  RUN 1  ZOMBIE 1  SPAWN 4  REAP 0
HOOK priority pid=2 code=0 prio=3
HOOK kill pid=2 code=0 state=4 status=143
HOOK spawn-stub pid=5 ppid=1 image=00070000 words=16
HOOK reap pid=5 status=9
VIEWER OK
EOF

run_img "$T/nanproc_test.nan" "$T/test.out"
run_img "$T/ps.nan" "$T/ps.out"
diff -u "$T/expected_test" "$T/test.out.norm" || fail "nanproc_test output"
diff -u "$T/expected_ps" "$T/ps.out.norm" || fail "ps viewer output"

if [ "$MODE" = oracle ]; then
  echo "nanproc gate: ORACLE MATCH (byte-exact, flat np_spawn stub; x86_64 S1 acceptance pending, not a product PASS)"
  exit 77
fi
echo "nanproc gate: PASS (x86_64 runner=$RUNNER; exact process/viewer output, flat np_spawn stub)"
exit 0
