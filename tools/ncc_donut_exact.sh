#!/bin/sh
# ncc_donut_exact: the a1k0n donut source ported to ncc. The program is an
# infinite animation; run one frame and compare it byte-for-byte with the
# saved frame. The first frame is also 1757/1761 chars identical to clang's
# float-trig build (4 luminance-boundary chars differ).
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccdonx.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
awk -f tools/nmk.awk -v CMD=emit src/tests/donut_exact_test.nas > "$T/d.nan"
./aarch64/android/nan_cli --img "$T/d.nan" --steps 1000000000 --serial > "$T/out" 2>"$T/err" || true
gawk 'BEGIN{RS="\033\\[2J"} NR==2{printf "%s",$0}' "$T/out" > "$T/got"
if diff -u src/tests/ncc_donut_exact.expected "$T/got"; then echo "ncc_donut_exact: PASS (a1k0n donut, first frame)"; else echo "ncc_donut_exact: FAIL"; tail -2 "$T/err"; exit 1; fi
