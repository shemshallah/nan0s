#!/bin/sh
# cpu_serious_gate.sh - exercise the CPU_SERIOUS layers already in the tree.
#
# 32/64 host parity   core32_64_parity_gate (same guest, both native cores)
# 64-bit arena        narena64 (4 GiB crossing)
# 64-bit tensors      nten (64-bit strides/paths)
# 64-bit matmul       nmat64 / nmat64x64
# 4096-core topology  nancore_scale / ncscale
# multicore scheduler nansmp 2/4-CPU S1 + nansched_mp/nancore/ncscale
# cooperative threads nanthr (C oracle; S1 acceptance is optional)
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"

run() {
  echo "== cpu_serious: $1"
  sh "$1" || { echo "cpu_serious: FAIL ($1)"; exit 1; }
}

run tools/core32_64_parity_gate.sh
run tools/narena64.sh
run tools/nten.sh
run tools/nmat64.sh
run tools/nmat64x64.sh
run tools/nancore_scale_gate.sh
run tools/ncscale_gate.sh
run tools/nansmp_gate.sh
run tools/nansmp_native_gate.sh
run tools/nansched_native_gate.sh
run tools/native_ap_gate.sh
run tools/native_ap_guest_gate.sh
run tools/native_product_smp_gate.sh
run tools/native_product_n64_gate.sh
run tools/nanthr_gate.sh

echo "cpu_serious: PASS (host parity, 64-bit arena/tensor/matmul, 4096-core topology, 2/4-CPU nansmp, native AP startup, AP guest handoff, product SMP binding, product 64-bit ABI, nanthr oracle)"
