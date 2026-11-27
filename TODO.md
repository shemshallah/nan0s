# NaN/0S task list

## P0 — 64-bit long-mode core

- Port the native NaN16 core and boot from 32-bit protected mode to x86-64
  long mode (64-bit host registers/pointers, NaN16 guest ISA unchanged).
- Add `.code64`, 64-bit registers, REX prefixes, 64-bit push/pop and the
  long-mode system instructions to `nasm1`; regenerate the core with
  `nasm1`/`xgold`.
- Add a single-image boot path: BIOS -> 512-byte boot -> long mode -> core
  -> guest, with no floppy/IDE split.
- Bring up `nasm0`, `nasm1`, the NANIX shell and the scheduler on the
  64-bit core.

## P0 — scheduler/desktop bring-up

- The scheduler restores PID 1's frame (`cart_entry`) but the entry has not
  yet executed on the 32-bit reference; verify the initial fetch and timer
  handoff.
- Once PID 1 runs, verify the NANIX shell (`nx_main`) and Terminal dispatch.
- Keep the KABI gate/transcript on the 64-bit S1 oracle in sync.

## P1 — Trust conversion

- Convert `src/trust/trust_cart.nas` to the scheduler/flat-image ABI.
- Add a Trust gate that runs the converted cart on the product core.

## P1 — loader and build

- Replace the remaining host `sh`/`gawk`/`xxd` image packers with the
  minimal linker + `nasm0`/`nasm1` path.
- Update `tools/boot_chain_gate.sh`, `native_product_boot_gate.sh` and
  `guest_raw_only_gate.sh` for the 64-bit image format.
- Remove legacy 32-bit build paths after the long-mode core passes.

## Done

- Flat scheduler image is packed without a cart TOC and no longer truncated
  to a floppy.
- Native KABI v0.1 added to the 32-bit core (ports, SVC/SVCRET, trap frame,
  timer).

## Product direction (locked)

- Product runtime: native multicore substrate -> NaN-coded block translator
  -> NaN scheduler/ABI.  n16i is the reference oracle, not the runtime.
- Next: `spec/MULTICORE_NAN.md` M1 (translator `OUTL/INL/SVC/SVCRET` and
  `qgate64abi`), then M2 per-core NanCore dispatch on 2 CPUs.
- No x86-64 -> NaN lifter in the product path; source recompilation / ncc is
  the compatibility route.

## Scale
- 4096 logical NanCore records at 0x400000 (64 words each), online bitmap at
  0x440000; `tools/nancore_scale_gate.sh` PASS.
- x86-64 S1 prototype compiles with NCPU_MAX=256; 2/4-CPU nansmp gate PASS.
- Target >256 cores: x2APIC + ACPI SRAT/MADT, NaN topology mapping, 16 KiB
  per-core stacks; no global lock on the dispatch path.

## Frontier scope
- `spec/FRONTIER_AI_OS.md`: TBs RAM is necessary, not sufficient.
- Credible target: single-node memory-centric verifiable inference/agent
  appliance.  Frontier training needs accelerators, fabric and ecosystem.
- Next memory code: `nmem` 64-bit memory objects/caps, 1 TB page-table gate,
  NUMA/hugepage allocator; then model runtime and accelerator boundary.

## Memory64
- `src/native64/mem64_boot.S` + `mem64.c`: 5-level/4-level boot, 4 KiB table
  pool, 1 GiB/2 MiB/4 KiB leaves, 52-bit physical / 57-bit virtual.
- `tools/mem64_gate.sh` PASS: 4 PiB direct map, 8,214 tables, 1 TiB object,
  high-half read, MAXPHYADDR/non-canonical rejection on a 128 MiB guest.
- Next: E820/SRAT-driven ranges, per-NUMA page allocator, nmem map/unmap/
  protect calls, 16 KiB per-core stacks, sealed checkpoint roots, tiering.

## ABI / translator
- `qgate64abi` PASS: emitted SVC/SVCRET frame, control ports, kernel
  return word, resume PC 11, r1=0x9A.  INL=0x18000, OUTL=0x18100,
  ABI scratch 0x50E00, frame payload at word byte +2.
- Next: 2-core NanCore block dispatch with per-core register files, then
  NaN per-CPU queues/work stealing/affinity/migration.

## Multicore block runtime
- `qgate64core2` PASS: one immutable 111-byte block, two CR3 roots,
  per-core state window at 0x50000, shared guest memory; r1=0x11/0x21.
- Next: install those roots on real APs (MADT/INIT-SIPI-SIPI), per-CPU block
  cache, then NaN per-CPU queues/work stealing/affinity/migration.

## NaN allocator
- `src/lib/nheap.nas` + `tools/nheap_gate.sh` PASS: per-NUMA 4K/2M/1G free
  lists, 1 TiB/512 GiB nodes, split/free/reuse, 64-bit bases, stats.
- Next: coalescing and per-node locks; wire `nheap` to the native `mem64`
  map/unmap boundary; keep C only in `src/native64` gate harnesses, never in
  `build/nan0s.img`.
