#!/bin/sh
# tools/ncc_iso_c.sh - ISO C11 language and library additions gate.
# Covers _Static_assert/_Alignof/_Alignas/_Generic/_Noreturn/_Atomic/
# _Thread_local, compound literals, wide string/char literals, flexible array
# members, <uchar.h>, the f/s/v wide stdio family, <stdatomic.h>,
# <fenv.h> and <threads.h> (single-threaded semantics).
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/ncciso.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
fail=0
for n in lang uchar wstdio c11lib; do
  awk -f tools/nmk.awk -v CMD=emit "src/tests/ncc_iso_${n}_test.nas" > "$T/$n.nan" 2>"$T/e" || {
    echo "ncc_iso_c: FAIL $n (assemble)"; cat "$T/e"; exit 1; }
  "$CLI" --img "$T/$n.nan" --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
  if cmp -s "$T/got" "src/tests/ncc_iso_$n.expected"; then
    echo "ncc_iso_c: PASS $n ($(wc -l < "$T/got") lines, exact)"
  else
    echo "ncc_iso_c: FAIL $n"; diff -u "src/tests/ncc_iso_$n.expected" "$T/got" | head -20
    fail=1
  fi
done
[ $fail = 0 ] || exit 1
echo "ncc_iso_c: PASS (C11 language, uchar, wide stdio, atomic/fenv/threads)"
