#!/bin/sh
# tools/ncc_heap.sh - dynamic-VM heap gate.
# One C program, four VM sizes.  The guest asks the VM for its word count
# (CPUID 0x4E4D00FF), so the same image must give a 100 MB heap on a
# 128 MiB-payload VM, fail cleanly on smaller VMs, and scale further up.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccheap.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_heap_test.nas > "$T/a.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
run() {
  mb="$1"; want="$2"
  "$CLI" --img "$T/a.nan" --mem "$mb" --steps 1000000000 --serial > "$T/out" 2>"$T/err" || true
  sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
  if ! printf '%s\n' "$want" | cmp -s - "$T/got"; then
    echo "ncc_heap: FAIL at --mem $mb"
    printf '%s\n' "$want" > "$T/want"
    diff -u "$T/want" "$T/got" | head -20
    tail -2 "$T/err"
    exit 1
  fi
}
SMALL='BIG 0
MB 1
REUSE 1
HEAP PASS'
BIG='BIG 1
EDGE 11 22
MB 1
REUSE 1
HEAP PASS'
run 16 "$SMALL"
run 64 "$SMALL"
run 128 "$BIG"
run 512 "$BIG"
echo "ncc_heap: PASS (16/64 MiB clean failure, 128/512 MiB 100 MB heap + reuse)"
