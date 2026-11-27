# nnuma — F3 E820/SRAT/NUMA topology + nheap integration

Status: implemented and gated (2026-11-26).  Agent slot B.

## Scope

F3: parse a synthetic E820/ACPI-SRAT-style guest-word table, classify
RAM/reserved/ACPI/MMIO/hole ranges, map physical addresses and APIC ids to
sparse NUMA node ids, expose node counts/ranges/totals, and feed only usable
RAM into `nheap` per-node 4K/2M/1G classes.

## Files

- `src/lib/nnuma.nas` — new pure-NaN topology library.  It includes
  `nheap.nas` (which includes `n64.nas`), so one include provides topology +
  allocator.
- `src/tests/nnuma_test.nas` — synthetic-map proof.
- `tools/nnuma_gate.sh` — gate: `tools/nmk.awk` emit + `aarch64/android/nan_cli`.
- `src/lib/nheap.nas` — two related fixes:
  - scratch moved from `0x3B0` to `0x7800`; larger linked images were about to
    overlap allocator bookkeeping with code (this test's code is ~1.1K words);
  - the fit test now compares `n64_cmp` against `-1` explicitly.  The previous
    `CMP r1,r0; JMP[LT]` treated `-1` (0xFFFFFFFF) as unsigned-greater, so an
    allocation larger than the extent could underflow the extent count.  The
    nnuma gate asks for 9 x 1 GiB from an 8-page extent and 257 x 4 KiB from a
    256-page extent; both must fail.

No C was added outside `src/tests`, and no C was added anywhere for this item.
`src/lib/nheap.nas` is the only pre-existing product file touched.

## Table contract (all words)

Header: magic `0x4E554D41`, version 1, range_count, cpu_count, node_count,
three reserved zero words.  Entries are contiguous and sorted:

```
range: base_lo, base_hi, size_lo, size_hi, kind, node, flags=0, reserved=0
cpu:   apic_id, cpu_id, node, flags        (cpu_id == index, apic ascending)
node:  node_id, mem_lo, mem_hi, cpu_count  (node ids ascending, sparse)
```

Kinds: 0 RAM, 1 reserved, 2 ACPI reclaim, 3 ACPI NVS, 4 MMIO, 5 hole.
Only kind 0 is usable; ACPI reclaim is deliberately conservative until a
separate reclaim policy exists.  All bases/sizes totals are `(lo,hi)`; the
parser rejects addresses/ends at or above 4 PiB (`hi >= 0x00100000`), zero-size
ranges, overlapping/unsorted ranges, duplicate/unsorted nodes, missing node
references, non-contiguous CPU ids, and unsorted APIC ids.

API: `nnuma_init`, `nnuma_range_count`, `nnuma_node_count`,
`nnuma_node_range`, `nnuma_kind_class`, `nnuma_kind_usable`,
`nnuma_range_get`, `nnuma_phys_node`, `nnuma_apic_node`, `nnuma_cpu_info`,
`nnuma_node_total` (8-word result: derived RAM bytes/ranges/CPUs plus declared
bytes/CPUs/id), `nnuma_verify`, and `nnuma_heap_add`.

## Proof map

The synthetic map is low RAM at 0 (512 MiB), reserved 512–768 MiB, hole
768 MiB–1 GiB, RAM 1–2 GiB, MMIO at 3.75 GiB, ACPI reclaim/NVS above it, and
RAM from 5 GiB with size 8 GiB + 3 MiB.  Nodes are 0 and 2 (sparse).

The gate proves:

- `nnuma_verify` accepts the map only when every declared node total and CPU
  count equals the derived sum over kind-0 ranges / CPU entries.
- Node count = 2, node id range = 0..2, range count = 8.
- `nnuma_range_get` returns the 5 GiB base as `(0x40000000, 1)` and its
  8 GiB + 3 MiB size as `(0x00300000, 2)`; the end is 13 GiB + 3 MiB.
- `nnuma_phys_node` maps 0, 511 MiB, 1 GiB, and the last byte of 2 GiB to
  node 0; 5 GiB and 13 GiB + 3 MiB − 1 to node 2.  Reserved, hole, MMIO,
  both ACPI kinds, the 4 GiB gap, and the exclusive end all fail.
- `nnuma_apic_node` maps APIC 0/2 to node 0, APIC 16/18/256 to node 2, and
  rejects 1 and 257.  APIC 256 proves ids are not 8-bit-truncated.  APIC 18
  is flagged offline in the CPU entry but still maps, as SRAT topology
  requires.
- `nnuma_heap_add` yields exactly:
  - node 0: 1 x 1 GiB, 256 x 2 MiB, 0 x 4 KiB;
  - node 2: 8 x 1 GiB, 1 x 2 MiB, 256 x 4 KiB;
  - node 1 (absent): zero everywhere.
  A heap with only two node slots is rejected before any descriptor is used
  (pre-scan), proving no partial map.
- A per-node allocation from node 2 returns a 64-bit base `0x00000001_40000000`
  (5 GiB); a 4 KiB allocation returns `0x00000003_40200000`
  (13 GiB + 2 MiB); node 0's 2 MiB allocation starts at 0.
- The 2 MiB class is exhausted with exactly 256 successes (last base
  510 MiB) and the 257th fails.  The 1 GiB class is exhausted with exactly 8
  successes (last base 12 GiB) and the 9th fails.  The 4 KiB class is
  exhausted with exactly 256 successes (last base `0x00000003_402FF000`) and
  the 257th fails.  Therefore the reserved+hole span (768 MiB) and the
  MMIO+ACPI spans were never added to any class and can never be allocated.
- The untouched classes remain: node 0 still has its 1 GiB page, node 2 its
  2 MiB page, which proves classes and nodes are not cross-contaminated.

## Gate transcript

```
$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)
$ sh tools/nnuma_gate.sh
nnuma: PASS (sparse nodes 0/2, 5 GiB bases, holes/reserved/ACPI/MMIO skipped, APIC->node, per-node 4K/2M/1G heap stats + exhaustive allocation)
```

The guest serial output is exactly `O`; the lines above are the shell gate
status.  The test runs in 113,497 guest steps, deterministic across reruns.

## Regression

`tools/nheap_gate.sh` passes after the scratch relocation and the extent-fit
comparison fix.  No other gate was touched.  `git status` additionally shows
untracked F2 (`nansched_*`) files from the other agent; they were not read or
modified.

## Frontier ideas

1. **NUMA-aware model/KV placement.**  Weights are shared read-only objects and
   replicated per node on demand; KV slabs are bound to the owning agent's
   home node.  `nnuma_node_total` and `nnuma_phys_node` give the placement
   layer exact free/total and address ownership without host pointers.  The
   next step is a per-node KV-slab cap with migration accounting.
2. **Hugepage compaction.**  The allocator never coalesces.  A compactor can
   scan 4 KiB extents per node, verify free ranges with `nnuma_phys_node`,
   and rebuild 2 MiB/1 GiB extents; the per-class stats already expose the
   fragmentation signal.  This matters for 70B-class weight arenas where 1 GiB
   leaves avoid 32 MiB of page tables per 4 PiB map.
3. **CXL / memory tiering.**  Extend the kind enum with CXL volatile and
   persistent memory and add a per-node latency/bandwidth tier.  `nheap` then
   prefers local DRAM for KV and falls back to CXL with an explicit migration
   policy, while `nnuma_verify` keeps the tier map honest.
4. **Remote-memory hints.**  Parse SRAT distance and HMAT latency/bandwidth
   entries into an `(node,node)` matrix; the scheduler can then choose
   `home_node`, steal targets and remote-allocation hints.  A simple first
   policy is "local first, nearest node on OOM, never remote for 1 GiB
   weights unless the node pair is directly connected".
