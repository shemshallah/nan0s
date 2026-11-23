#!/bin/sh
# tools/gate_targeted.sh - run only the gates affected by the current changes.
#
#   sh tools/gate_targeted.sh                 # map git changes -> gates
#   sh tools/gate_targeted.sh FILE...         # map explicit files
#   sh tools/gate_targeted.sh --full          # complete battery
#
# Targeted runs are parallel, time-boxed, and cache successful gates in
# .gate-cache/ keyed by their input families.  Use --full (or NO_CACHE=1) for
# ABI/ISA/cross-cutting changes and before a release commit.
set -u
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
JOBS=${JOBS:-4}
TIMEOUT=${TIMEOUT:-300}
LONG_TIMEOUT=${LONG_TIMEOUT:-600}
CACHE=.gate-cache

if [ "${1:-}" = "--full" ]; then
  exec env PRESQLITE_JOBS="$JOBS" sh tools/presqlite_gate.sh
fi

if [ "$#" -gt 0 ]; then
  FILES="$*"
else
  FILES=$( { git diff --name-only HEAD; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u )
fi
if [ -z "$FILES" ]; then
  echo "targeted: no source changes (use --full for the complete battery)"
  exit 0
fi

COMPILER="ncc_abi_sizes ncc_abi_ll ncc_alloc ncc_heap ncc_aligned ncc_headers ncc_ppexpr ncc_torture ncc_donut_exact ncc_macro_text ncc_include ncc_libm_exact ncc_iso_c ncc_ctests ncc_dp4b"
m=1
while [ "$m" -le 62 ]; do
  [ -f "tools/ncc_m$m.sh" ] && COMPILER="$COMPILER ncc_m$m"
  m=$((m+1))
done
VEC="nan_simd nan_vec nan_vec_native nan_vec_avx2 nan_q4 nan_q4lm nan_bench xlate_x86"
IMAGES="mkall qgate64 qgate64core qgate64block qgate64alu qgate64branch qgate64mem qgate64byte qgate64prog qgate64call qgate64mul qgate64div qgate64fp qgate64fpe qgate64mem2 qgate64blockops qgate64trap qgate64vec qgate64vldst qgate64vdp4b qgate64vdp4b4 qgate64callf qgate64putc qgate qgate_gui xmemgate mkproof"
NATIVE="$VEC narena narena64 nten nmatmul nmat64 nmat64x64"

GATES=""
add() { for g in $1; do GATES="$GATES $g"; done; }
full=0
for f in $FILES; do
  case "$f" in
    third_party/tinycc/nan16-gen.c|third_party/tinycc/nan16-link.c|third_party/tinycc/tcc.h|third_party/tinycc/libtcc.c|third_party/tinycc/libtcc.h|third_party/tinycc/tccelf.c|tools/tcc_nan16_smoke.sh)
      add "tcc_nan16_smoke tcc_nan16_enc" ;;
    third_party/tinycc/nan16-*|tools/tcc_nan16_enc.sh)
      add "tcc_nan16_enc" ;;
    spec/*|third_party/*|*.md|build/*|aarch64/android/app/src/main/assets/*)
      ;;
    src/lib/ncc.nas|src/lib/ppexpr.nas|src/lib/mpp.nas|src/lib/wide*.nas|src/lib/vscanf.nas|src/lib/iso*.nas|src/lib/mathx.nas|src/prog/nasm0_tables.nas|src/tools/disasm.nas|src/tests/ctests/*|src/tests/ncc_*)
      add "$COMPILER" ;;
    aarch64/android/core/*|aarch64/android/tests/*|aarch64/android/tools/nan_cli.c|aarch64/android/Makefile)
      add "c_core_test ncc_m1 ncc_ctests ncc_iso_c nan_vec nan_q4 nan_q4lm nan_bench" ;;
    src/native/kan16.xa|src/native/nan16_x86.nan|x86/native/*|x86/boot/*)
      add "$NATIVE $IMAGES" ;;
    src/native64/*|tools/qgate64.sh)
      add "mkall qgate64 qgate64core qgate64block qgate64alu qgate64branch qgate64mem qgate64byte qgate64prog qgate64call qgate64mul qgate64div qgate64fp qgate64fpe qgate64mem2 qgate64blockops qgate64trap qgate64vec qgate64vldst qgate64vdp4b qgate64vdp4b4 qgate64callf qgate64putc" ;;
    src/translate/x86_64.nas|src/translate/x64_block.nas)
      add "mkall qgate64core qgate64block qgate64alu qgate64branch qgate64mem qgate64byte qgate64prog qgate64call qgate64mul qgate64div qgate64fp qgate64fpe qgate64mem2 qgate64blockops qgate64trap qgate64vec qgate64vldst qgate64vdp4b qgate64vdp4b4 qgate64callf qgate64putc" ;;
    src/tests/xlate64_test.nas|tools/qgate64core.sh)
      add "mkall qgate64core" ;;
    src/tests/xlate64_block.nas|tools/qgate64block.sh)
      add "mkall qgate64block" ;;
    src/tests/xlate64_alu.nas|tools/qgate64alu.sh)
      add "mkall qgate64alu" ;;
    src/tests/xlate64_branch.nas|tools/qgate64branch.sh)
      add "mkall qgate64branch" ;;
    src/tests/xlate64_mem.nas|tools/qgate64mem.sh)
      add "mkall qgate64mem" ;;
    src/tests/xlate64_byte.nas|tools/qgate64byte.sh)
      add "mkall qgate64byte" ;;
    src/tests/xlate64_prog.nas|tools/qgate64prog.sh)
      add "mkall qgate64prog" ;;
    src/tests/xlate64_call.nas|tools/qgate64call.sh)
      add "mkall qgate64call" ;;
    src/tests/xlate64_mul.nas|tools/qgate64mul.sh)
      add "mkall qgate64mul" ;;
    src/tests/xlate64_div.nas|tools/qgate64div.sh)
      add "mkall qgate64div" ;;
    src/tests/xlate64_fp.nas|tools/qgate64fp.sh)
      add "mkall qgate64fp" ;;
    src/tests/xlate64_fp_edge.nas|tools/qgate64fpe.sh)
      add "mkall qgate64fpe" ;;
    src/tests/xlate64_mem2.nas|tools/qgate64mem2.sh)
      add "mkall qgate64mem2" ;;
    src/tests/xlate64_blockops.nas|tools/qgate64blockops.sh)
      add "mkall qgate64blockops" ;;
    src/tests/xlate64_trap.nas|tools/qgate64trap.sh)
      add "mkall qgate64trap" ;;
    src/tests/xlate64_vec.nas|tools/qgate64vec.sh)
      add "mkall qgate64vec" ;;
    src/tests/xlate64_vldst.nas|tools/qgate64vldst.sh)
      add "mkall qgate64vldst" ;;
    src/tests/xlate64_vdp4b.nas|tools/qgate64vdp4b.sh)
      add "mkall qgate64vdp4b" ;;
    src/tests/xlate64_vdp4b4.nas|tools/qgate64vdp4b4.sh)
      add "mkall qgate64vdp4b4" ;;
    src/tests/xlate64_callf.nas|tools/qgate64callf.sh)
      add "mkall qgate64callf" ;;
    src/tests/xlate64_putc.nas|tools/qgate64putc.sh)
      add "mkall qgate64putc" ;;
    src/translate/*|src/tests/xlate*|tools/xlate_x86.sh)
      add "xlate_x86" ;;
    src/lib/narena*.nas|src/lib/nten.nas|src/lib/nmat.nas|src/lib/n64.nas)
      add "narena narena64 nten nmatmul nmat64 nmat64x64" ;;
    src/lib/*vec*|src/tests/vec*|src/tests/q4*|src/tests/bench*|tools/nan_vec*.sh|tools/nan_q4*.sh|tools/nan_bench.sh)
      add "$VEC" ;;
    tools/nmk.awk|tools/mkimg.awk|tools/xgold.sh|tools/mkall.sh)
      full=1 ;;
    tools/ncc_m*.sh|tools/ncc_*.sh)
      g=${f#tools/}; g=${g%.sh}; [ -f "tools/$g.sh" ] && add "$g" ;;
    tools/nan_*.sh|tools/xlate_x86.sh)
      g=${f#tools/}; g=${g%.sh}; [ -f "tools/$g.sh" ] && add "$g" ;;
    tools/qgate*.sh)
      add "qgate qgate_gui" ;;
    tools/presqlite_gate.sh|tools/gate_targeted.sh)
      ;;
    *)
      echo "targeted: unmapped $f -> full battery"
      full=1 ;;
  esac
done
if [ "$full" -eq 1 ]; then
  exec env PRESQLITE_JOBS="$JOBS" sh tools/presqlite_gate.sh
fi
if [ -z "$GATES" ]; then
  echo "targeted: documentation-only change; no gates"
  exit 0
fi
GATES=$(printf '%s\n' $GATES | sort -u | tr '\n' ' ')

mkdir -p "$CACHE"
T="${TMPDIR:-/tmp}/gate_targeted.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

# Cache key families.  Broad on purpose: a compiler input change reruns every
# compiler gate; a native input change reruns the native/vector/image gates.
gate_files() {
  case "$1" in
    c_core_test|ncc_*)
      echo "src/lib/*.nas src/prog/nasm0_tables.nas src/tools/disasm.nas src/tests/ncc_*.nas src/tests/ctests/* aarch64/android/core/*.c aarch64/android/core/*.h aarch64/android/tests/*.c aarch64/android/tools/nan_cli.c aarch64/android/Makefile tools/nmk.awk tools/ncc_*.sh"
      ;;
    tcc_nan16_*)
      echo "third_party/tinycc/nan16-* third_party/tinycc/tcc.h third_party/tinycc/libtcc.c third_party/tinycc/libtcc.h third_party/tinycc/tccelf.c tools/tcc_nan16_*.sh"
      ;;
    *)
      echo "src/native/*.xa src/native/*.nan src/native64/* x86/native/* x86/boot/* src/translate/*.nas src/tests/*.nas tools/mkimg.awk tools/nmk.awk tools/mkall.sh tools/xgold.sh tools/nan_*.sh tools/xlate_x86.sh tools/qgate*.sh tools/mkproof.sh"
      ;;
  esac
}
gate_key() {
  for f in $(gate_files "$1"); do [ -f "$f" ] && cat "$f"; done |
    sha256sum | cut -d' ' -f1
}
COMPILER_KEY=$(gate_key ncc_m1)
NATIVE_KEY=$(gate_key xlate_x86)
TCC_KEY=$(gate_key tcc_nan16_smoke)
key_for() { case "$1" in c_core_test|ncc_*) echo "$COMPILER_KEY" ;; tcc_nan16_*) echo "$TCC_KEY" ;; *) echo "$NATIVE_KEY" ;; esac; }
is_cached() {
  [ "${NO_CACHE:-0}" = 1 ] && return 1
  [ -f "$CACHE/$1.sha" ] || return 1
  [ "$(cat "$CACHE/$1.sha")" = "$(key_for "$1")" ]
}
cache_ok() { [ "${NO_CACHE:-0}" = 1 ] || key_for "$1" > "$CACHE/$1.sha"; }
cache_bad() { rm -f "$CACHE/$1.sha"; }

run_gate() {
  g="$1"
  case "$g" in
    c_core_test) ( cd aarch64/android && timeout "$LONG_TIMEOUT" make -s test ) ;;
    mkproof) timeout "$LONG_TIMEOUT" sh tools/mkproof.sh src/tests/key_test.nas ;;
    mkall|qgate|qgate_gui|xmemgate) timeout "$LONG_TIMEOUT" sh "tools/$g.sh" ;;
    *) timeout "$TIMEOUT" sh "tools/$g.sh" ;;
  esac
}

echo "targeted: affected gates:$GATES"
RUN=""
for g in $GATES; do
  if is_cached "$g"; then
    echo "CACHED $g"
  else
    RUN="$RUN $g"
  fi
done
if [ -z "$RUN" ]; then
  echo "targeted: all affected gates cached"
  exit 0
fi

fail=0

# The core C test builds the native CLI and is a dependency of the compiler
# gates, so run it first and alone when present.
case " $RUN " in
  *" c_core_test "*)
    echo "RUN c_core_test"
    if run_gate c_core_test >"$T/c_core_test.log" 2>&1; then
      echo "PASS c_core_test"; cache_ok c_core_test
    else
      echo "FAIL c_core_test"; tail -8 "$T/c_core_test.log" | sed 's/^/  /'
      cache_bad c_core_test; fail=1
    fi
    RUN=$(printf ' %s ' "$RUN" | sed 's/ c_core_test / /')
    ;;
esac

# Image gates are sequential and ordered: build once, then boot the image.
SEQ=""
for g in mkall qgate64 qgate64core qgate64block qgate64alu qgate64branch qgate64mem qgate64byte qgate64prog qgate64call qgate64mul qgate64div qgate64fp qgate64fpe qgate64mem2 qgate64blockops qgate64trap qgate64vec qgate64vldst qgate64vdp4b qgate64vdp4b4 qgate64callf qgate64putc mkproof qgate qgate_gui xmemgate; do
  case " $RUN " in *" $g "*) SEQ="$SEQ $g" ;; esac
done
PAR=""
for g in $RUN; do
  case " $SEQ " in *" $g "*) ;; *) PAR="$PAR $g" ;; esac
done

active=0
for g in $PAR; do
  ( run_gate "$g" >"$T/$g.log" 2>&1; echo $? >"$T/$g.rc" ) &
  active=$((active+1))
  if [ "$active" -ge "$JOBS" ]; then wait; active=0; fi
done
wait
for g in $PAR; do
  rc=$(cat "$T/$g.rc" 2>/dev/null || echo 1)
  if [ "$rc" -eq 0 ]; then
    echo "PASS $g"; cache_ok "$g"
  else
    echo "FAIL $g"; tail -8 "$T/$g.log" | sed 's/^/  /'
    cache_bad "$g"; fail=1
  fi
done

for g in $SEQ; do
  echo "RUN $g"
  if run_gate "$g" >"$T/$g.log" 2>&1; then
    echo "PASS $g"; cache_ok "$g"
  else
    echo "FAIL $g"; tail -8 "$T/$g.log" | sed 's/^/  /'
    cache_bad "$g"; fail=1
  fi
done

echo "targeted: $(printf '%s\n' $GATES | wc -w) affected gate(s), $fail failure(s)"
[ "$fail" -eq 0 ]
