#!/bin/sh
# tools/ncc_ctests.sh - run the vendored c-testsuite subset on ncc/NaN16.
#
# For every "run" entry in src/tests/ctests/manifest.tsv this script:
#   1. builds a runner cartridge once (ncc.nas + serial status marker);
#   2. appends the C source at word address 110000 (outside compiler state);
#   3. runs the cartridge in the NaN16 core with nan_cli --serial;
#   4. strips the exact @@NCC_EXIT@@<status> marker and compares the remaining
#      bytes and the status with the checked-in .expected file and exit code.
#
# "skip" entries are reported but are neither passes nor failures.  Any run
# failure, missing file, or compile error makes the gate exit non-zero.
# Host clang is only used to regenerate .expected files; it is never in the
# guest execution path.
set -u; cd "$(dirname "$0")/.."; export LC_ALL=C
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli) || exit 1

T="${TMPDIR:-/tmp}/nccctests.$$"
B="$PWD/src/tests/.ctbuild.$$"
mkdir -p "$T" "$B" || exit 1
trap 'rm -rf "$T" "$B"' EXIT INT TERM

BASE_NAS="$B/base.nas"
BASE_NAN="$T/base.nan"
cat > "$BASE_NAS" <<'EOF'
.org 0
JMP @ct_entry
.include "../../lib/ncc.nas"
ct_entry:
MOVI r13,1
LA r1,110000
CALL @ncc_compile
CALL @ncc_run
MOVI r1,64
CALL @ncc_putc
MOVI r1,64
CALL @ncc_putc
MOVI r1,78
CALL @ncc_putc
MOVI r1,67
CALL @ncc_putc
MOVI r1,67
CALL @ncc_putc
MOVI r1,95
CALL @ncc_putc
MOVI r1,69
CALL @ncc_putc
MOVI r1,88
CALL @ncc_putc
MOVI r1,73
CALL @ncc_putc
MOVI r1,84
CALL @ncc_putc
MOVI r1,64
CALL @ncc_putc
MOVI r1,64
CALL @ncc_putc
LD r5,r0,#W_EXITCODE
CALL @putdec
MOVI r1,10
CALL @ncc_putc
HALT
.org 110000
EOF

if ! awk -f tools/nmk.awk -v CMD=emit "$BASE_NAS" > "$BASE_NAN" 2>"$T/base.err"; then
  echo "ncc_ctests: FAIL (runner assembly)"; cat "$T/base.err"; exit 1
fi

pass=0; skip=0; fail=0
failed=""

while IFS=' ' read -r name mode want steps note; do
  case "$name" in ''|'#'*) continue ;; esac
  src="src/tests/ctests/$name.c"
  exp="src/tests/ctests/$name.expected"
  if [ "$mode" = "skip" ]; then
    if [ ! -f "$src" ]; then
      echo "ncc_ctests: FAIL $name (missing skipped source)"
      fail=$((fail+1)); failed="$failed $name"
      continue
    fi
    echo "ncc_ctests: SKIP $name ($note)"
    skip=$((skip+1))
    continue
  fi
  if [ ! -f "$src" ] || [ ! -f "$exp" ]; then
    echo "ncc_ctests: FAIL $name (missing source or expected file)"
    fail=$((fail+1)); failed="$failed $name"
    continue
  fi
  # cache the runner prefix (base.nan has exactly 110000 words)
  {
    cat "$BASE_NAN"
    od -An -tx1 -v "$src" | awk '
      BEGIN { m=1; v=0; n=0 }
      { for (i=1; i<=NF; i++) {
          h=index("0123456789ABCDEF", toupper(substr($i,1,1)))-1
          l=index("0123456789ABCDEF", toupper(substr($i,2,1)))-1
          d=h*16+l
          v += d*m; m *= 256; n++
          if (n==4) { printf "7FF8_%08X_F87F   ; src\n", v; v=0; m=1; n=0 }
        } }
      END { if (n) printf "7FF8_%08X_F87F   ; src\n", v }
    '
  } > "$T/a.nan"
  "$CLI" --img "$T/a.nan" --steps "$steps" --serial > "$T/out" 2>"$T/err" || true
  if ! grep -q '@@NCC_EXIT@@' "$T/out"; then
    echo "ncc_ctests: FAIL $name (no completion marker)"
    head -c 120 "$T/out" | tr '\n' ' '; echo
    tail -1 "$T/err" 2>/dev/null
    fail=$((fail+1)); failed="$failed $name"
    continue
  fi
  off=$(grep -abo '@@NCC_EXIT@@' "$T/out" | tail -1 | cut -d: -f1)
  head -c "$off" "$T/out" > "$T/got"
  gotexit=$(tail -c +$((off+13)) "$T/out" | head -c 32 | sed -n 's/^\(-\{0,1\}[0-9]*\).*/\1/p')
  if cmp -s "$exp" "$T/got" && [ "$gotexit" = "$want" ]; then
    pass=$((pass+1))
    echo "ncc_ctests: PASS $name"
  else
    fail=$((fail+1)); failed="$failed $name"
    echo "ncc_ctests: FAIL $name (exit want=$want got=${gotexit:-?})"
    diff -u "$exp" "$T/got" | head -16
  fi
done < src/tests/ctests/manifest.tsv

echo "ncc_ctests: $pass passed, $skip skipped, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "ncc_ctests: failures:$failed"
  exit 1
fi
echo "ncc_ctests: PASS (vendored c-testsuite baseline)"
