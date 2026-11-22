#!/bin/sh
# tools/presqlite_gate.sh - aggregate pre-SQLite gate.
# Runs every gate that exists in tools/ and reports a single summary. New
# workstream gates (macro text, include, exact libm, ISO C, c-testsuite) are
# picked up automatically when present.
set -u
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/presqlite_gate.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
fail=0; n=0

run() {
  name="$1"; shift
  n=$((n+1))
  printf 'RUN %s\n' "$name"
  if timeout 600 "$@" >"$T/$name.log" 2>&1; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    tail -8 "$T/$name.log" | sed 's/^/  /'
    fail=$((fail+1))
  fi
}

# Parallel batch for the independent ncc_m* gates. The image/vector gates
# stay sequential because they share qemu/image resources.
run_parallel() {
  jobs="${PRESQLITE_JOBS:-4}"
  active=0
  names=""
  for spec in "$@"; do
    name=${spec%%=*}; cmd=${spec#*=}
    names="$names $name"
    ( timeout 300 sh "$cmd" >"$T/$name.log" 2>&1; echo $? >"$T/$name.rc" ) &
    active=$((active+1))
    if [ "$active" -ge "$jobs" ]; then wait; active=0; fi
  done
  wait
  for name in $names; do
    n=$((n+1))
    rc=$(cat "$T/$name.rc" 2>/dev/null || echo 1)
    if [ "$rc" -eq 0 ]; then
      printf 'PASS %s\n' "$name"
    else
      printf 'FAIL %s\n' "$name"
      tail -8 "$T/$name.log" | sed 's/^/  /'
      fail=$((fail+1))
    fi
  done
}

[ -x aarch64/android/nan_cli ] || (cd aarch64/android && make -s nan_cli)
mspecs=""
for m in $(seq 1 62); do
  [ -f "tools/ncc_m$m.sh" ] && mspecs="$mspecs ncc_m$m=tools/ncc_m$m.sh"
done
printf 'RUN ncc_m1..ncc_m62 (parallel=%s)\n' "${PRESQLITE_JOBS:-4}"
run_parallel $mspecs
for g in ncc_alloc ncc_heap ncc_aligned narena narena64 nten nan_simd nan_vec nan_vec_native nan_vec_avx2 nan_q4 nan_q4lm nan_bench xlate_x86 ncc_dp4b nmatmul nmat64 nmat64x64 ncc_headers ncc_ppexpr ncc_torture ncc_donut_exact; do
  [ -f "tools/$g.sh" ] && run "$g" sh "tools/$g.sh"
done
for g in ncc_macro_text ncc_include ncc_libm_exact ncc_iso_c ncc_ctests; do
  [ -f "tools/$g.sh" ] && run "$g" sh "tools/$g.sh"
done
[ -f tools/py_m1.sh ] && run py_m1 sh tools/py_m1.sh
[ -f tools/mkproof.sh ] && run mkproof sh tools/mkproof.sh src/tests/key_test.nas

if [ -f tools/mkall.sh ]; then
  run mkall sh tools/mkall.sh
  [ -f tools/qgate.sh ] && run qgate sh tools/qgate.sh
  [ -f tools/qgate_gui.sh ] && run qgate_gui sh tools/qgate_gui.sh
  [ -f tools/xmemgate.sh ] && run xmemgate sh tools/xmemgate.sh
  [ -f tools/qgate64.sh ] && run qgate64 sh tools/qgate64.sh
  [ -f tools/qgate64core.sh ] && run qgate64core sh tools/qgate64core.sh
  [ -f tools/qgate64block.sh ] && run qgate64block sh tools/qgate64block.sh
  [ -f tools/qgate64alu.sh ] && run qgate64alu sh tools/qgate64alu.sh
fi

printf '\npresqlite_gate: %d gate(s), %d failure(s)\n' "$n" "$fail"
[ "$fail" -eq 0 ]
