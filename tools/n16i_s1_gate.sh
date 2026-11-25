#!/bin/sh
# n16i_s1_gate.sh - n16i (NaN16 interpreter written in NaN16) runs on S1.
#
# The same guest image runs natively and under n16i on the bare x86_64 S1
# machine.  Serial output must be byte-identical.  This is the machine-level
# proof that the NaN-coded interpreter executes on the NaN core, not only
# under the portable C oracle.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/n16i_s1.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
RUNNER=${N16I_S1_RUNNER:-tools/s1_runner.sh}
STEPS=${N16I_S1_STEPS:-100000000}
MEM=${N16I_S1_MEM:-1}

awk -f tools/nmk.awk -v CMD=emit -v LABELS="$T/l.txt" \
    src/tests/n16i_test.nas > "$T/t.nan" 2>/dev/null
M=$(awk '$1=="mode"{print $2}' "$T/l.txt")
G=$(awk '$1=="gsel"{print $2}' "$T/l.txt")
for m in 0 1; do
    cp "$T/t.nan" "$T/m$m.nan"
    printf '.org %d\n7FF8_%08X_F87F\n' "$M" "$m" >> "$T/m$m.nan"
    printf '.org %d\n7FF8_%08X_F87F\n' "$G" 0 >> "$T/m$m.nan"
done

echo "n16i_s1: native guest"
"$RUNNER" --img "$T/m0.nan" --mem "$MEM" --steps "$STEPS" --serial \
    > "$T/native.out" 2> "$T/native.err" || true
echo "n16i_s1: guest under n16i"
"$RUNNER" --img "$T/m1.nan" --mem "$MEM" --steps "$STEPS" --serial \
    > "$T/n16i.out" 2> "$T/n16i.err" || true

if ! cmp -s "$T/native.out" "$T/n16i.out"; then
    echo "n16i_s1: FAIL (native and interpreted output differ)"
    diff -u "$T/native.out" "$T/n16i.out" | head -20 || true
    exit 1
fi
if ! grep -q 'N16I GUEST DONE' "$T/n16i.out"; then
    echo "n16i_s1: FAIL (guest did not finish under n16i)"
    tail -5 "$T/n16i.out"; exit 1
fi
echo "n16i_s1: PASS (n16i ran the guest on S1; output byte-identical, $(wc -c < "$T/n16i.out") bytes)"
