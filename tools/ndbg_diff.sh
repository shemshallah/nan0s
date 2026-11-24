#!/bin/sh
# tools/ndbg_diff.sh - native-vs-stepped differential gate for the NANDBG core.
#
# 1. src/tests/ndbg_core_test.nas exercises reset/run/step on a real target.
# 2. src/tests/ndbg_diff_native.nas runs a deterministic target on the native
#    core; src/tests/ndbg_diff_debug.nas runs the SAME target under core.nas.
#    The serial transcripts (including per-section checksums) must be identical
#    and must equal the golden transcript.
# 3. src/tests/ndbg_guard_test.nas proves the write window and before-write
#    watchpoint.
# 4. The gate mutates one byte and proves it can fail.
#
# The target covers integer arithmetic/flags, memory/class ops, byte ops,
# BCOPY/BFILL, CALL/RET/CALLR/JMPR/JMPF/CALLF, floats, DP4B and the vector
# family (VBCAST/VADD8/VADD32/VSUB32/VMUL32/VDP4B/VGET/VSET/VLOAD/VSTORE).
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-$PWD/build}/ndbgdiff.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)

asm() { awk -f tools/nmk.awk -v CMD=emit "$1" > "$2" 2>"$2.err" || { cat "$2.err"; exit 1; }; }

# --- 1. reusable core on a small target -------------------------------------
asm src/tests/ndbg_core_test.nas "$T/core.nan"
"$CLI" --img "$T/core.nan" --steps 2000000 --serial > "$T/core.out" 2>"$T/core.err" || true
grep -qx 'CORE PASS' "$T/core.out" || { echo "ndbg_diff: CORE FAIL"; cat "$T/core.out" "$T/core.err"; exit 1; }

# --- 1b. a real museum cartridge under the core ------------------------------
asm src/tests/ndbg_cart_test.nas "$T/cart.nan"
"$CLI" --img "$T/cart.nan" --steps 50000000 --serial > "$T/cart.out" 2>"$T/cart.err" || true
grep -qx 'CART PASS' "$T/cart.out" || { echo "ndbg_diff: CART FAIL"; cat "$T/cart.out" "$T/cart.err"; exit 1; }

# --- 1c. containment and watchpoint ------------------------------------------
asm src/tests/ndbg_guard_test.nas "$T/guard.nan"
"$CLI" --img "$T/guard.nan" --steps 5000000 --serial > "$T/guard.out" 2>"$T/guard.err" || true
grep -qx 'SAFE PASS' "$T/guard.out" || { echo "ndbg_diff: GUARD FAIL"; cat "$T/guard.out" "$T/guard.err"; exit 1; }
grep -q '^!DFM@40002003 W=0000000000000100$' "$T/guard.out" || { echo "ndbg_diff: GUARD RECORD FAIL"; cat "$T/guard.out"; exit 1; }
grep -q '^!DIM@03002007 W=000056780000AAAA$' "$T/guard.out" || { echo "ndbg_diff: WATCH RECORD FAIL"; cat "$T/guard.out"; exit 1; }

# --- 2. native vs stepped ----------------------------------------------------
asm src/tests/ndbg_diff_native.nas "$T/native.nan"
asm src/tests/ndbg_diff_debug.nas  "$T/debug.nan"
"$CLI" --img "$T/native.nan" --steps 2000000  --serial > "$T/native.out" 2>"$T/native.err" || true
"$CLI" --img "$T/debug.nan"  --steps 50000000 --serial > "$T/debug.out"  2>"$T/debug.err"  || true

if grep -q '!D' "$T/debug.out"; then
  echo "ndbg_diff: stepped run faulted"
  cat "$T/debug.out" "$T/debug.err"
  exit 1
fi
if ! cmp -s "$T/native.out" "$T/debug.out"; then
  echo "ndbg_diff: native != stepped"
  diff -u "$T/native.out" "$T/debug.out" | head -40
  exit 1
fi

cat > "$T/expected" <<'EOF'
A00000063
B123457DB
C123457DE
D123457F8
E12345814
G1636601F
H16366025
I1636602B
J1636602C
F16366034
16366034
EOF
if ! cmp -s "$T/expected" "$T/debug.out"; then
  echo "ndbg_diff: transcript differs from golden"
  diff -u "$T/expected" "$T/debug.out" | head -40
  exit 1
fi

# --- 3. the gate must be able to fail ---------------------------------------
sed 's/16366034/16366035/' "$T/debug.out" > "$T/negative"
if cmp -s "$T/debug.out" "$T/negative"; then
  echo "ndbg_diff: NEGATIVE FAIL (mutated transcript accepted)"
  exit 1
fi

echo "ndbg_diff: PASS (core reset/run, real cart to KEY, guard/watch, native == stepped, golden transcript, vectors)"
echo "ndbg_diff: NEGATIVE PASS (mutated transcript rejected)"
