#!/bin/sh
# nfs2 gate: raw-NaN16 path-addressed RAM filesystem (format/write/find/read/list/delete).
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nfs2.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/nfs2_test.nas > "$T/fs.nan"
./aarch64/android/nan_cli --img "$T/fs.nan" --steps 1000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
printf 'hello\nOK\n' > "$T/exp"
if diff -u "$T/exp" "$T/got"; then echo "nfs2: PASS"; else echo "nfs2: FAIL"; exit 1; fi
