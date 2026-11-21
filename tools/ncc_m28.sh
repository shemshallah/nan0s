#!/bin/sh
# M28 gate: const is enforced for scalar locals, globals and params;
# pointers to const remain assignable. A rejected assignment must emit C000B.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm28.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m28_test.nas > "$T/g.nan"
./aarch64/android/nan_cli --img "$T/g.nan" --steps 400000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
diff -u src/tests/ncc_m28.expected "$T/got"
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_m28_bad.nas > "$T/b.nan"
./aarch64/android/nan_cli --img "$T/b.nan" --steps 400000000 --serial > "$T/bout" 2>"$T/berr" || true
grep -q 'C000B' "$T/bout" || { echo "ncc_m28: FAIL (const assignment not rejected)"; cat "$T/bout"; exit 1; }
echo "ncc_m28: PASS (const enforcement)"
