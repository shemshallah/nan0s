# Multicore NaN product architecture

Status: normative direction after the n16i runtime experiment.

## Decision

The product runtime is:

```
native multicore substrate
  -> NaN-coded block translator / block cache
  -> NaN scheduler and custom NaN ABI
  -> agents, tools, tensors/KV, traces
```

`n16i` remains the **reference interpreter and differential oracle**, not the
product runtime.  The x86-64 interpreter (`kan16_x64`) is a bootstrap and
compatibility reference only.

There is no native guest-ISA decoder in the product substrate.

## Substrate: what is native

The substrate is the mechanical machine layer.  It may only do:

- boot, GDT/IDT, long mode, page tables, per-CPU TSS/IST;
- physical/linear memory, per-core stacks, guest-word memory;
- copy a NaN-emitted block into an executable page and call it;
- per-core register file, XPC, flags and trap frame storage;
- LAPIC/IOAPIC, timer, INIT-SIPI-SIPI, reschedule IPI;
- atomic CAS, fetch-add and fence over guest words;
- port I/O / MMIO, CPUID, RDTSC, MSR access;
- COM1, framebuffer, keyboard, block device primitives.

It must not decode guest instructions, select blocks, schedule agents, own
capabilities, interpret tensors/traces or decide ABI policy.

## Per-core NanCore record

Each CPU owns one page-aligned record; the index is the CPU id.

```
+0    cpu id
+1    core state (off/running/kernel/halted)
+2    guest register-file word base
+3    guest XPC
+4    guest flags
+5    trap-frame word base
+6    kernel entry
+7    kernel frame
+8    kernel-mode flag
+9    current agent cap
+10   current generation
+11   quantum / budget
+12   deadline tick
+13   trace head
+14   run-queue head
+15   run-queue tail
+16   block-cache base
+17   block-cache generation
+18   pending IPI mask
+19   timer left
+20..31 reserved
```

The shared guest memory is the same physical word memory for every core.
Register files, PCs, flags, frames and block caches are per core.  Code blocks
are immutable and shared; a cache is only a local mapping.

## Block image and dispatch

The NaN translator emits a sorted `(guest pc, code word address)` table and
immutable x86-64 blocks.  A core:

1. looks up XPC in the shared table/cache;
2. calls the block;
3. reads back XPC/flags/halt/trap;
4. repeats.

A block may set XPC backwards (RET) or switch to the kernel entry (SVC).  The
substrate rescans from the table base after every block; it never inspects the
guest word that produced the block.

## Trap and ABI boundary

The translator emits the custom NaN ABI frame save/restore and XPC switch.
Native helpers are limited to the device/atomic boundary:

- `nc_port_in` / `nc_port_out` for non-ABI devices;
- `nc_cas`, `nc_fetch_add`, `nc_fence`;
- `nc_ipi`, `nc_timer_arm`, `nc_halt`.

The ABI control fields (kernel entry, frame, timer, stack, regions, TCB) are
guest words or per-core NanCore fields.  No POSIX/KABI host call is inserted.

## Multicore scheduler

- One NaN ready queue per CPU plus a shared steal queue.
- Agents have `home_cpu`, `affinity`, `migration_epoch`, `budget`, `deadline`.
- `nansmp.nas` provides lock/CAS/fetch-add/fence and queue primitives.
- A reschedule IPI wakes a core; the scheduler runs in NaN.
- A checkpoint records the per-core NanCore record, the agent frame, caps,
  tensors/KV roots and trace head.  Restore can target another CPU.
- Read-only weights are shared caps; KV shards and traces are per agent/core
  and merge by generation/hash.

## AI ABI mapping

`spec/NAN_ABI.md` defines the capability/checkpoint/tensor/trace ABI.  For
multicore it adds:

- `cpu_id`, `cpu_count`, `affinity`, `migration_epoch`;
- per-core checkpoint records and per-core trace head;
- shared read-only weight caps and per-core KV shard caps;
- `migrate`, `barrier`, `shared_map` SVCs;
- atomic-domain descriptors for lock-free queues.

## Current blockers

1. `src/translate/x86_64.nas` has no `INL`/`OUTL`/`SVC`/`SVCRET` handlers or
   block loader.  This is the next code slice.
2. The SMP prototype (`s1_smp.c`, `nansmp.nas`) is a C/scalar mechanics proof;
   the full per-core NaN block runtime is not wired.
3. `n16i` is single-context and has no atomics/IPI; it stays the reference.
4. A full x86-64 -> NaN lifter is not present and is not the product path.
   Source recompilation (`ncc`) or NaN-native kernels are preferred.

## Milestones

- **M1 translator ABI**: `OUTL`, `INL`, `SVC`, `SVCRET` emitted by the NaN
  translator; `qgate64abi` proves a guest SVC round-trip on one core.
- **M2 per-core substrate**: NanCore records, 2-core AP bring-up, shared
  block table, per-core dispatch.
- **M3 NaN SMP scheduler**: per-CPU queues, work stealing, affinity/migration,
  atomics via `nansmp`.
- **M4 full image**: AOT block image for the scheduler/shell, block loader,
  custom ABI, serial shell gate.
- **M5 AI layer**: checkpoint/migrate, shared weights/KV, trace merge,
  generations on 2+ cores.

n16i gates remain the differential reference for M1/M3.


## Scale: modern core counts

The NaN layer is sized for 4096 logical cores:

- records at `0x400000`, 64 words each, 4096 entries, end `0x440000`;
- online bitmap at `0x440000` (4096 bits = 128 words);
- per-core APIC id, NUMA node, state, stack/top, quantum/budget, deadline,
  trace head, queue head/tail/count, steal queue, block-cache base/generation;
- block code is shared and immutable; only the per-core lookup/cache is local.

The x86-64 S1 prototype is raised to 256 APs for the current APIC path.  The
target substrate uses x2APIC and ACPI SRAT/MADT for >256 cores, with APIC-id
to logical-index mapping in NaN topology code.  Per-core stacks are sized in
the substrate; 16 KiB is the target for 4096-core builds, with 64 KiB only in
the small QEMU prototype.

No global lock is on the dispatch path.  Queue/steal/online/counter operations
use `nansmp` CAS/fetch-add/fence; a core that has no work can halt until a
timer or reschedule IPI.  NUMA placement is a hint carried in the NanCore
record; the NaN scheduler owns the policy.
