#!/bin/sh
# bare_fs gate: NPAF-backed machine-interface filesystem slots
# (fs_open/read/write/seek/close/remove/rename), exercised without ncc_compile.
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/barefs.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/bare_fs_test.nas > "$T/a.nan"
./aarch64/android/nan_cli --img "$T/a.nan" --steps 30000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if diff -u src/tests/bare_fs.expected "$T/got"; then echo "bare_fs: PASS (NPAF-backed bare filesystem)"; else echo "bare_fs: FAIL"; tail -2 "$T/err"; exit 1; fi
