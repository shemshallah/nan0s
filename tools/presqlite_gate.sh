#!/bin/sh
# tools/presqlite_gate.sh - aggregate pre-SQLite gate.
#
#   sh tools/presqlite_gate.sh                 # complete battery
#   sh tools/presqlite_gate.sh --only qgate64* # selected gates
#   sh tools/presqlite_gate.sh --list          # list gate names
#
# Progress is written to stdout and appended to build/gate-progress.log so a
# long gate can be watched from another terminal:
#   tail -f build/gate-progress.log
set -u
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/presqlite_gate.$$"; mkdir -p "$T" build
PROGRESS="${PRESQLITE_PROGRESS:-build/gate-progress.log}"
HB=0
cleanup() { [ "$HB" -ne 0 ] && kill "$HB" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM

ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) shift; ONLY="$*"; break ;;
    --list)
      for m in $(seq 1 62); do [ -f "tools/ncc_m$m.sh" ] && echo "ncc_m$m"; done
      for g in ncc_abi_sizes ncc_abi_ll ncc_alloc ncc_heap ncc_aligned narena narena64 nten \
               nan_simd nan_vec nan_vec_native nan_vec_avx2 nan_q4 nan_q4lm nan_bench \
               xlate_x86 ncc_dp4b nmatmul nmat64 nmat64x64 ncc_headers ncc_ppexpr \
               ncc_torture ncc_donut_exact ncc_macro_text ncc_include ncc_libm_exact \
               ncc_iso_c ncc_ctests tcc_nan16_enc tcc_nan16_smoke mkproof ndbg ndbg_diff ndbg_mon ndbg_img ndbg_term mkall qgate qgate_gui xmemgate qgate64 \
               qgate64core qgate64block qgate64alu qgate64branch qgate64mem qgate64byte \
               qgate64prog qgate64mul qgate64div qgate64fp qgate64fpe qgate64mem2 \
               qgate64blockops qgate64trap qgate64vec qgate64vldst qgate64vdp4b \
               qgate64vdp4b4 qgate64call qgate64callf qgate64putc; do
        [ -f "tools/$g.sh" ] && echo "$g"
      done
      exit 0 ;;
    *) echo "usage: $0 [--only PATTERN...] [--list]" >&2; exit 2 ;;
  esac
done

want() {
  [ -z "$ONLY" ] && return 0
  for p in $ONLY; do case "$1" in $p) return 0 ;; esac; done
  return 1
}
now() { date +%H:%M:%S; }
say() { printf '[%s] %s\n' "$(now)" "$*" | tee -a "$PROGRESS"; }
RUNNING="$T/running"; : > "$RUNNING"
mark_run()  { printf '%s\n' "$1" >> "$RUNNING"; }
mark_done() { grep -v -x "$1" "$RUNNING" > "$RUNNING.t" 2>/dev/null; mv "$RUNNING.t" "$RUNNING"; }

n=0; fail=0
printf '0 0\n' > "$T/counters"
setcounts() { printf '%s %s\n' "$n" "$fail" > "$T/counters"; }
heartbeat() {
  while :; do
    sleep 20
    read -r n2 f2 < "$T/counters" 2>/dev/null || { n2=0; f2=0; }
    say "... done=$n2 fail=$f2 running: $(tr '\n' ' ' < "$RUNNING")"
  done
}
heartbeat & HB=$!

run() {
  name="$1"; shift
  want "$name" || return 0
  n=$((n+1)); mark_run "$name"
  t0=$(date +%s); setcounts
  say "RUN  $name"
  if timeout "${PRESQLITE_TIMEOUT:-900}" "$@" >"$T/$name.log" 2>&1; then
    say "PASS $name ($(( $(date +%s) - t0 ))s)"
  else
    rc=$?
    say "FAIL $name ($(( $(date +%s) - t0 ))s, rc=$rc)"
    tail -12 "$T/$name.log" | sed 's/^/  /' | tee -a "$PROGRESS"
    fail=$((fail+1))
  fi
  setcounts
  mark_done "$name"
}

# Parallel batch for the independent ncc_m* gates.  PIDs are tracked so the
# heartbeat is never waited on.
run_parallel() {
  jobs="${PRESQLITE_JOBS:-4}"
  specs=""
  for spec in "$@"; do
    name=${spec%%=*}
    want "$name" && specs="$specs $spec"
  done
  [ -z "$specs" ] && return
  pids=""; active=0
  for spec in $specs; do
    name=${spec%%=*}; cmd=${spec#*=}
    n=$((n+1)); mark_run "$name"; setcounts
    say "RUN  $name"
    (
      t0=$(date +%s)
      timeout "${PRESQLITE_MTIMEOUT:-300}" sh "$cmd" >"$T/$name.log" 2>&1
      echo $? > "$T/$name.rc"
      echo $(( $(date +%s) - t0 )) > "$T/$name.dt"
    ) &
    pids="$pids $!"
    active=$((active+1))
    if [ "$active" -ge "$jobs" ]; then
      for p in $pids; do wait "$p"; done
      pids=""; active=0
    fi
  done
  for p in $pids; do wait "$p"; done
  for spec in $specs; do
    name=${spec%%=*}
    mark_done "$name"
    rc=$(cat "$T/$name.rc" 2>/dev/null || echo 1)
    dt=$(cat "$T/$name.dt" 2>/dev/null || echo '?')
    if [ "$rc" -eq 0 ]; then
      say "PASS $name (${dt}s)"
    else
      say "FAIL $name (${dt}s, rc=$rc)"
      tail -12 "$T/$name.log" | sed 's/^/  /' | tee -a "$PROGRESS"
      fail=$((fail+1))
    fi
    setcounts
  done
}

: > "$PROGRESS"
say "presqlite start (only='${ONLY}', jobs=${PRESQLITE_JOBS:-4})"
[ -x aarch64/android/nan_cli ] || (cd aarch64/android && make -s nan_cli)

mspecs=""
for m in $(seq 1 62); do
  [ -f "tools/ncc_m$m.sh" ] && mspecs="$mspecs ncc_m$m=tools/ncc_m$m.sh"
done
say "batch ncc_m1..ncc_m62"
run_parallel $mspecs

for g in ncc_abi_sizes ncc_abi_ll ncc_alloc ncc_heap ncc_aligned narena narena64 nten nan_simd \
         nan_vec nan_vec_native nan_vec_avx2 nan_q4 nan_q4lm nan_bench xlate_x86 \
         ncc_dp4b nmatmul nmat64 nmat64x64 ncc_headers ncc_ppexpr ncc_torture \
         ncc_donut_exact; do
  [ -f "tools/$g.sh" ] && run "$g" sh "tools/$g.sh"
done
for g in ncc_macro_text ncc_include ncc_libm_exact ncc_iso_c ncc_ctests tcc_nan16_enc tcc_nan16_smoke; do
  [ -f "tools/$g.sh" ] && run "$g" sh "tools/$g.sh"
done
[ -f tools/py_m1.sh ] && run py_m1 sh tools/py_m1.sh
[ -f tools/mkproof.sh ] && run mkproof sh tools/mkproof.sh src/tests/key_test.nas
[ -f tools/ndbg.sh ] && run ndbg sh tools/ndbg.sh
[ -f tools/ndbg_diff.sh ] && run ndbg_diff sh tools/ndbg_diff.sh
[ -f tools/ndbg_mon.sh ] && run ndbg_mon sh tools/ndbg_mon.sh
[ -f tools/ndbg_img.sh ] && run ndbg_img sh tools/ndbg_img.sh
[ -f tools/ndbg_term.sh ] && run ndbg_term sh tools/ndbg_term.sh
[ -f tools/lds_gate.sh ] && run lds_gate sh tools/lds_gate.sh
[ -f tools/kabi_gate.sh ] && run kabi sh tools/kabi_gate.sh
[ -f tools/kabi_proc_gate.sh ] && run kabi_proc sh tools/kabi_proc_gate.sh
[ -f tools/kabi_sched_gate.sh ] && run kabi_sched sh tools/kabi_sched_gate.sh
[ -f tools/kabi_spawn_gate.sh ] && run kabi_spawn sh tools/kabi_spawn_gate.sh
[ -f tools/kabi_load_gate.sh ] && run kabi_load sh tools/kabi_load_gate.sh
[ -f tools/s1_guest_gate.sh ] && run s1_guest sh tools/s1_guest_gate.sh

if [ -f tools/mkall.sh ] && want mkall; then
  run mkall sh tools/mkall.sh
fi
for g in qgate qgate_gui xmemgate; do
  [ -f "tools/$g.sh" ] && run "$g" sh "tools/$g.sh"
done
# The qgate64* gates are independent QEMU boots; run them in parallel.
q64specs=""
for g in qgate64 qgate64core qgate64block qgate64alu qgate64branch qgate64mem \
         qgate64byte qgate64prog qgate64mul qgate64div qgate64fp qgate64fpe \
         qgate64mem2 qgate64blockops qgate64trap qgate64vec qgate64vldst \
         qgate64vdp4b qgate64vdp4b4 qgate64call qgate64callf qgate64putc; do
  [ -f "tools/$g.sh" ] && q64specs="$q64specs $g=tools/$g.sh"
done
run_parallel $q64specs

say "presqlite done: $n gate(s), $fail failure(s)"
[ "$fail" -eq 0 ]
