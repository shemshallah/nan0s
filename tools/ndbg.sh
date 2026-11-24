#!/bin/sh
# tools/ndbg.sh - the first native-NaN debug gate.
#
# src/dbg/ndbg.nas is written entirely in NaN16. It proves:
#   - all 16 diagnostic types survive STW/LDN and the BSWAPM mirror law
#   - quiet/raise act on the two head bits
#   - a target at the museum slot runs under the step core
#   - a breakpoint stops before fetch without modifying the target
#   - a gate trap and a bad-op trap become typed records, not a dead machine
#
# The gate is deliberately exact. It compares the whole serial transcript, so a
# change in a record field, a register, or a status word is a failure.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-$PWD/build}/ndbg.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/dbg/ndbg.nas > "$T/ndbg.nan" 2>"$T/asm.err" || {
  cat "$T/asm.err"; echo "ndbg: ASSEMBLY FAIL"; exit 1;
}
"$CLI" --img "$T/ndbg.nan" --steps 2000000 --serial > "$T/out" 2>"$T/err" || true

cat > "$T/expected" <<'EOF'
NDBG: NAN16 NATIVE DEBUG CORE
TYPES PASS
TYPES FC FM FD FS
TYPES PC PM PD PS
TYPES WC WM WD WS
TYPES IC IM ID IS
BREAK PASS
PC=2007 K=2 R0=00000000 R1=00000005 R2=0000000F R3=00000005 R4=00000000 R5=00000000 R6=00000000 R7=00000000 
STEP PASS
ARUN PASS
!DFC@10002329 W=FFFFFFFFDEADBEEF
GATE RECORD PASS
!DFC@2000232A W=0000000F7F000000
BADOP RECORD PASS
QUIET PASS
NDBG PASS
EOF

if cmp -s "$T/out" "$T/expected"; then
  echo "ndbg: PASS (types, mirror, quiet, step, breakpoint, gate record, bad-op record, exact)"
else
  echo "ndbg: FAIL"
  diff -u "$T/expected" "$T/out" | head -40
  echo "--- stderr ---"
  cat "$T/err"
  exit 1
fi

# A gate that cannot fail is not a gate. Mutate the expected transcript and
# prove the comparator rejects it.
sed 's/NDBG PASS/NDBG PAST/' "$T/expected" > "$T/negative"
if cmp -s "$T/out" "$T/negative"; then
  echo "ndbg: NEGATIVE FAIL (mutated transcript accepted)"
  exit 1
fi
echo "ndbg: NEGATIVE PASS (mutated transcript rejected)"
