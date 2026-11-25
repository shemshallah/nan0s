#!/bin/sh
# tools/kabi_asm_gate.sh - named kernel-ABI ops through nmk + the NaN disassembler.
# Covers INL (0x4D), SVC (0x4E), SVCRET (0x4F): exact words, CMD=check
# round-trip, and the guest disassembler's t_ops table.  The nmk checks are
# mandatory; the guest-disassembler runtime check uses the C-core oracle
# only when it is available, never as the encoding authority.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/kabi_asm.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT

awk -f tools/nmk.awk -v CMD=emit src/tests/kabi_asm_test.nas > "$T/k.nan"
for row in \
  FFF8_4D120000_F8FF \
  FFF1_4D340000_F17F \
  FFF8_4E000000_F8FF \
  FFF8_4E000007_F8FF \
  FFF1_4E000016_F17F \
  FFF8_4F000000_F8FF \
  7FF1_4F000000_F8FF \
  FFF8_43120000_F8FF \
  FFF8_FF000000_F8FF
do
  grep -q "^$row" "$T/k.nan" || { echo "kabi_asm: FAIL missing $row"; cat "$T/k.nan"; exit 1; }
done
awk -f tools/nmk.awk -v CMD=check "$T/k.nan" > "$T/check.out" 2>&1
grep -q 'check: 0 mismatches' "$T/check.out" || { echo "kabi_asm: FAIL round-trip"; cat "$T/check.out"; exit 1; }

# The NaN disassembler source table must contain the same three ops.
grep -q '^\.word 77,33$' src/tools/disasm.nas || { echo "kabi_asm: FAIL disasm INL"; exit 1; }
grep -q '^\.word 78,4$'  src/tools/disasm.nas || { echo "kabi_asm: FAIL disasm SVC"; exit 1; }
grep -q '^\.word 79,0$'  src/tools/disasm.nas || { echo "kabi_asm: FAIL disasm SVCRET"; exit 1; }

# Optional differential run of the guest disassembler on the C-core oracle.
if [ -x aarch64/android/nan_cli ] || make -s -C aarch64/android nan_cli 2>/dev/null; then
  awk -f tools/nmk.awk -v CMD=emit src/tests/disasm_test.nas > "$T/d.nan"
  ./aarch64/android/nan_cli --img "$T/d.nan" --steps 30000000 --serial > "$T/d.out" 2>/dev/null || true
  for s in 'INL r1,r2' 'SVC 7' 'SVCRET' 'DISASM DONE'; do
    grep -q "$s" "$T/d.out" || { echo "kabi_asm: FAIL disassembler missing '$s'"; tail -20 "$T/d.out"; exit 1; }
  done
  echo "kabi_asm: PASS (INL/SVC/SVCRET emit + round-trip + disasm table + oracle run)"
else
  echo "kabi_asm: PASS (INL/SVC/SVCRET emit + round-trip + disasm table; oracle run SKIP)"
fi
