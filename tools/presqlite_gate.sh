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
  if "$@" >"$T/$name.log" 2>&1; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    tail -8 "$T/$name.log" | sed 's/^/  /'
    fail=$((fail+1))
  fi
}

for m in $(seq 1 62); do
  [ -f "tools/ncc_m$m.sh" ] && run "ncc_m$m" sh "tools/ncc_m$m.sh"
done
for g in ncc_alloc ncc_heap ncc_aligned narena narena64 nten nan_simd nan_vec nan_vec_native ncc_dp4b nmatmul nmat64 nmat64x64 ncc_headers ncc_ppexpr ncc_torture ncc_donut_exact; do
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
fi

printf '\npresqlite_gate: %d gate(s), %d failure(s)\n' "$n" "$fail"
[ "$fail" -eq 0 ]
