#!/bin/sh
# tools/nan_vec.sh - 512-bit abstract vector family (packed i8/i32 lanes).
# The C core is the semantic reference; the native x86 backend is the next
# stage and will be required to match these exact lanes.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nanvec.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/vec512_test.nas > "$T/t.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/t.nan" --mem 16 --steps 100000 --serial > "$T/o" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/o" > "$T/got"
cmp -s "$T/got" src/tests/vec512.expected || { echo "nan_vec: FAIL (C reference)"; diff -u src/tests/vec512.expected "$T/got" | head -20; exit 1; }
echo "nan_vec: PASS (VBCAST/VADD8/VADD32/VDP4B/VGET/VSET/VLOAD/VSTORE)"
