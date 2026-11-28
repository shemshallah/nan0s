# NANIX SMP on x86_64 S1

Status: **prototype, gated.**  A 2-CPU and 4-CPU QEMU boot brings every AP
online through a real APIC INIT-SIPI-SIPI path, gives each CPU its own LAPIC
timer and reschedule IPI, and runs the same NaN16 workload on every core
through `src/lib/nansmp.nas`.  The full S1 interpreter in
`src/tests/native64/s1_kabi.c` is still single-core; the prototype's per-CPU
execution slice is the scalar subset in `src/tests/native64/s1_smp.c`.  This
document is normative for the prototype and the migration target.

Related: `spec/KERNEL_ABI.md` (trap frame, ports, regions),
`spec/THREADS.md` (TCB, mutex/cond/TLS, single-core scheduler),
`spec/NANVM_SPEC.md` §9.2 (SMP contract), `spec/NAMING.md`.

## 1. Scope and honesty

Implemented and proven on QEMU `-smp 2` and `-smp 4`:

- ACPI MADT discovery of the enabled local APICs;
- BSP-only xAPIC setup, AP startup via INIT-SIPI-SIPI and a real-mode ->
  long-mode trampoline;
- one `Cpu` control block per core: registers, task slots, run queue state,
  timer/IPI counters;
- a per-CPU round-robin scheduler with a 1024-instruction quantum;
- one LAPIC one-shot timer per CPU (vector `0x40`) with EOI;
- cross-CPU reschedule IPIs (vector `0x41`) with a deterministic
  `resched` acknowledgement;
- NaN spinlock, atomic compare-and-swap, atomic fetch-add and fence in
  `src/lib/nansmp.nas`;
- a shared-word-memory NaN workload (`src/tests/nansmp_test.nas`) that runs
  on every CPU and produces an exact transcript.

Not implemented in this slice:

- the full S1 op/device/region/trap model per CPU (only a scalar subset);
- guest-mode region tables on APs (the prototype's guest tasks are trusted
  kernel work, not sandboxed processes);
- per-CPU TSS/IST stacks, x2APIC, IOAPIC, MSI, CPU hotplug;
- work stealing, priority queues, load balancing across cores;
- the ISA-level atomics 0x42/0x44 from `spec/NANVM_SPEC.md` §9.3; the
  prototype uses the experimental control-port atomics below;
- integration of the existing `nansched.nas` process scheduler with the
  per-CPU queues (the add-only `nansmp.nas` interface is the hook).

The portable C core (`aarch64/android/nan_cli`) remains an oracle and is
not an SMP target.  Product acceptance is the QEMU S1 transcript.

## 2. Topology and CPU discovery

The gate runs:

    qemu-system-x86_64 -m 256 -smp N -drive format=raw,if=floppy,file=IMG \
      -boot a -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -display none -serial file:COM1 -no-reboot

with `N` = 2 and 4.  QEMU's pc machine assigns local APIC IDs `0..N-1` with
`-smp N`; the gate's expected transcript prints those IDs.

Boot sequence:

1. The 512-byte fixture (`s1_bootsec.S`) loads the kernel, enters flat
   32-bit protected mode and jumps to `s1_boot.S`.
2. `s1_boot.S` builds identity page tables for the first 1 GiB at
   `0x30000..0x33fff`, enables PAE/LME/PG, loads the 64-bit GDT and calls
   `s1_main`.
3. `s1_main` masks the legacy 8259s, maps the LAPIC 2 MiB page, enables the
   BSP local APIC, installs the IDT, and scans ACPI for the MADT.
4. The MADT `Local APIC` entries (type 0, enabled flag bit 0) give the APIC
   ID list.  The BSP's ID (CPUID.1 EBX[31:24]) is moved to logical index 0.
5. Each AP is started one at a time: write the AP boot block, send INIT,
   wait, send SIPI twice with vector `0x08`, then wait for `online`.

Fallback: if no MADT is found, the BSP alone is used and the gate fails the
CPU-count check explicitly.  There is no silent single-core success.

## 3. AP bootstrap

### 3.1 Trampoline and boot block

`src/native64/smp_tramp.S` is linked at physical `0x8000` and copied there
by the BSP before the first SIPI.  It is position-fixed, not relocatable.
The SIPI vector `0x08` starts the AP at `0x8000:0` in real mode.

The BSP fills a 32-byte boot block at `0x9000` before each SIPI:

| offset | field |
|---|---|
| +0 | CR3 (low 32 bits; page tables are below 4 GiB) |
| +8 | AP stack top (64-bit) |
| +16 | C entry `ap_main` (64-bit) |
| +24 | logical CPU index (64-bit) |

Because APs are started sequentially and `online` is waited for before the
next SIPI, the boot block has a single writer and needs no lock.

The trampoline:

1. `cli`, `cld`, load a private GDT (64-bit code/data at 0x08/0x10, 32-bit
   code/data at 0x18/0x20);
2. enter 32-bit protected mode through selector `0x18`;
3. load CR3 from the boot block, set CR4.PAE/OSFXSR/OSXMMEXCPT, set
   EFER.LME, enable CR0.PG;
4. far-jump to 64-bit code at selector `0x08`;
5. load RSP and RDI (CPU index) from the boot block and `call ap_main`.

The trampoline does not touch the BSP's GDT, IDT or stack.  IF stays clear
until `ap_main` installs the IDT and enables interrupts.

### 3.2 Shared page tables

All CPUs use the BSP's CR3 (`0x30000`).  The first 1 GiB is identity mapped
with 2 MiB pages.  The page containing `0xFEE00000` is mapped through
`PDPT[3] -> PD3 @0x33000`, entry `503`, so every CPU can reach its LAPIC.

AP kernel stacks are `0x300000 + cpu*0x10000 + 0xF000` (64 KiB per CPU,
growing down).  The BSP uses the boot stack at `0x1F0000`.  Guest word
memory begins at `0x200000` and does not overlap either.

### 3.3 AP entry

`ap_main(cpu)`:

1. `lidt` the shared IDT;
2. enable the local APIC (IA32_APIC_BASE bit 11, x2APIC bit 10 clear);
3. `sti`;
4. probe the per-CPU LAPIC timer;
5. publish `online = 1`;
6. enter the per-CPU scheduler loop.

An AP that does not publish `online` within the startup timeout is a hard
`SMP PANIC AP did not come online`, never a silent downgrade.

## 4. Per-CPU state and run queues

Each core owns one cache-line-aligned `Cpu`:

    Task task[2];
    online, timer_ok, timer_ticks;
    need_resched, pending_b;
    ipis, resched, finished;
    cur; atomic_result;
    index, apic_id, steps;

A `Task` owns a complete NaN context:

    r[16], pc, k;  state; id; stack; count; checksum; seen

States: `0` blocked/free, `1` ready, `2` running, `3` done.

The prototype's per-CPU queue is two slots (task A and task B) with strict
round robin.  `schedule()`:

1. a running task becomes ready;
2. scan from the current slot for the next ready task;
3. if none, keep the current task running, or set `cur = ~0` when nothing
   is runnable;
4. if the selected task is B and an IPI has been taken, set `resched`.

`run_cpu(cpu)` executes at most `QUANTUM = 1024` NaN instructions, then
round-robins if another task is ready.  When no task is ready and not both
are done, the CPU executes `sti; hlt; cli`; an IPI or timer wakes it.

The production migration replaces the two-slot array with the per-CPU
head/tail queues from `nansmp.nas` and moves TCBs/process state behind the
global scheduler lock described in §5.  The scheduling policy (round robin,
quantum, idle-halt) does not change.

## 5. Spinlocks, atomics, memory model

### 5.1 NaN API

`src/lib/nansmp.nas` is the NaN-side interface.  It is additive: it does not
modify `nansched.nas` or `nanthr.nas`.

ABI: `r0=0`, `r13=1`, `r14=SP` (grows up), `r15=link`; arguments `r1..r3`,
result `r1`; `r6..r12` and `r13/r14` are preserved, `r1..r5` and flags are
scratch.

| routine | arguments | result |
|---|---|---|
| `nsp_cpu` | - | logical CPU index |
| `nsp_steps` | - | NaN instructions on this CPU (low 32) |
| `nsp_ipi` | target CPU | 0 |
| `nsp_fence` | - | 0 (mfence) |
| `nsp_cas` | addr, expected, new | old payload |
| `nsp_fetch_add` | addr, delta | old payload |
| `nsp_trylock` | lock word | 0 acquired / 1 busy |
| `nsp_lock` | lock word | 0 |
| `nsp_unlock` | lock word | 0 |
| `nsp_q_push` | queue struct, tid | 0 |
| `nsp_q_pop` | queue struct | tid or `0xFFFF` |
| `nsp_q_len` | queue struct | count |

Queue structure (4 words): `head` (encoded tid+1), `tail`, `count`,
`link_base`.  `link_base[tid]` holds the encoded next tid, 0 = end.

**Frame contract:** non-leaf routines use the `nansched.nas` 9-word frame
(`ST r15,r14,0; ADDI r14,r14,#9; ...; ADDI r14,r14,#-9; LD r15,r14,0; RET`).
The first SMP workload used one-word frames and a callee's saved link
overwrote the caller's lock word; the lock address became a `CALL` return
address and the CAS never acquired.  New `nansmp` routines must keep the
9-word contract.

### 5.2 Experimental control ports

Outside the frozen `KERNEL_ABI.md` 0x4E00-0x4E07 map:

| port | direction | value |
|---|---|---|
| 0x4E08 | IN | current logical CPU index |
| 0x4E09 | IN | NaN instructions executed on this CPU (low 32) |
| 0x4E0A | OUT | send reschedule IPI (vector 0x41) to CPU value |
| 0x4E0B | OUT/IN | CAS descriptor word address / old payload |
| 0x4E0C | OUT/IN | fetch-add descriptor word address / old payload |
| 0x4E0D | OUT | acquire/release fence (`mfence`) |
| 0x4E0E | IN | packed APIC-id bitmap of started APs (bit n = APIC id n) |
| 0x4E0F | IN | logical CPU count reported by the host core |

Descriptors live on the calling task's stack, so no CPU shares a mailbox:

    CAS   { addr, expected, new }
    FADD  { addr, delta }

The S1 port body performs the whole RMW with one locked x86 operation
(`__atomic_compare_exchange_n` over the 64-bit NaN word, preserving the
NaN heads).  Fetch-add is a CAS loop that rebuilds the word with
`mkword(old+delta, 10)`, because adding two NaN words would corrupt the
head bytes.

The native 32-bit core starts APs before entering the guest.  The BSP copies
a 16-bit trampoline to physical 0x6000, sends INIT-SIPI-SIPI, and the APs
enter flat protected mode at 0x6200.  Each AP records its LAPIC id in a
per-id table and increments a shared counter with `LOCK INC`.  The BSP packs
the ids into the bitmap returned by 0x4E0E; 0x4E0F reports the CPU count.
APs park after the handshake, so the guest interpreter remains on the BSP
until the product binds `nansched_nansmp` to real AP contexts.  The x64 host
core is BSP-only in this revision.

The atomics are sequentially consistent.  This is stronger than the final
NaN memory model needs, and it is the only primitive the prototype lock
policy uses.  The frozen ISA atomics 0x42/0x44 should replace these ports
when the full S1 gains them; the `nansmp` bodies are the single replacement
point.

### 5.3 Locking rules

- The kernel's serial console, scheduler state and AP boot block use their
  own small spinlocks (`__atomic_exchange_n` / `__atomic_store_n`).
- A task must not hold a spinlock across a blocking operation.
- Preemption while holding a spinlock is allowed but expensive; the
  prototype's 1024-instruction quantum bounds the waiter's wasted work.
  Production policy should either disable preemption in the critical
  section or use a fair ticket lock.
- Lock words are ordinary guest words and are visible through the region
  model once per-process regions are enabled; a lock in a shared region is
  the only supported cross-process synchronization.

## 6. IPIs and reschedule

Vector `0x41` is the reschedule IPI.  `smp_ipi_isr`:

1. read the local APIC ID and map it to the logical CPU;
2. increment `ipis`;
3. set `need_resched` and `pending_b`;
4. EOI.

`pending_b` releases task B exactly once.  The scheduler runs at the next
quantum boundary (or immediately from the idle `hlt` wake) and sets
`resched = 1` when task B is actually dispatched after an IPI.  The gate
requires `ipi=1 resched=1` on every CPU.  This is deliberately a flag, not
a switch count: round-robin switch counts are timing-dependent, while
"the IPI caused task B to run" is deterministic.

The BSP sends one IPI to each AP after that AP has executed at least one
NaN instruction, then sends itself one before running its own slice.  This
proves both cross-CPU (`0 -> 1`) and self-IPI delivery.

`nsp_ipi` exposes the same path to NaN code.  The production scheduler will
use it for work stealing and remote wakeups; the IPI handler will set a
per-CPU pending word and the scheduler will merge the stolen task at a
safe point.

## 7. Per-CPU timer

Each CPU programs its own LAPIC timer:

- divide configuration `0x3E0 = 3` (divide by 16);
- LVT timer `0x320 = 0x40` (one-shot, vector 0x40, unmasked);
- initial count `0x380 = 1_000_000`.

`smp_timer_isr` increments `timer_ticks`, masks the LVT timer
(`0x320 = 0x10000`) and EOIs.  The probe waits with a bounded spin and
publishes `timer_ok` (0 or 1).  The gate requires `ticks=1` on every CPU.

The production timer is periodic at the kernel tick rate (100 Hz in
`spec/NANVM_SPEC.md` §9.2), calibrated once by the BSP against the PIT or
TSC and programmed identically on every AP.  The per-CPU pending bit is
what the interpreter tests between instructions; the LAPIC vector is only
the hardware transport.  A timer must never vector while the CPU is inside
the kernel (the prototype masks it during bring-up; production uses the
in-kernel flag).

## 8. Memory and region model

Physical layout for the prototype:

| range | use |
|---|---|
| `0x00000..0x7BFF` | real-mode/BIOS |
| `0x7C00..0x7DFF` | boot fixture |
| `0x8000..0x8FFF` | AP trampoline |
| `0x9000..0x90FF` | AP boot block |
| `0x10000..0x2FFFF` | S1 SMP kernel image + BSS |
| `0x30000..0x33FFF` | PML4/PDPT/PD0/PD3 |
| `0x1F0000` | BSP boot stack (grows down) |
| `0x200000..0x27FFFF` | shared guest word memory, 64K words |
| `0x300000..0x37FFFF` | AP kernel stacks |
| `0xFEE00000..0xFF000000` | LAPIC MMIO (2 MiB page) |

Guest word memory is **one shared array**; every CPU's `LD`/`ST` uses the
same `0x200000` base.  The guest data map is:

| words | use |
|---|---|
| `0x8000 + cpu*16 + task*8` | result slot: count, cpu, queue checksum |
| `0x9000` | shared atomic counter |
| `0x9001` | global spinlock |
| `0x9002` | global locked counter |
| `0x9010 + cpu` | per-CPU spinlock |
| `0x9020 + cpu` | per-CPU locked counter |
| `0xA000 + cpu*32 + task*16` | per-task queue structure |
| `0xB000 + (cpu*2+task)*64` | per-task FIFO link table |
| `0xE000 + cpu*0x100` | task A stack (task B at +0x80) |

Region tables are still a single S1-wide table, not per CPU.  Production
SMP changes that to one region table/view per process, published on each
CPU that runs one of its threads.  A thread migration must reload the
region base (`0x4E04`) and the `LDS`/`STS` window (`0x4E07`) as part of the
context switch.  Until then, the prototype's tasks are kernel-owned and
omit region checks; this is not a security boundary.

## 9. The nansmp interface for nansched

The existing `nansched.nas` remains the single-core process scheduler.  The
additive integration path is:

1. allocate one `nansmp` queue structure per CPU and one link table large
   enough for the process slots;
2. on `create`/`wake`, call `nsp_q_push(queue[cpu], slot)` for the target
   CPU; the initial target is the creating CPU;
3. on `nsch_pick`, call `nsp_q_pop(queue[cpu])` and recheck the nanproc
   state (the queue is a hint, exactly as in the single-core code);
4. replace the scheduler's lock/atomic helpers with `nsp_lock`,
   `nsp_unlock`, `nsp_cas`, `nsp_fetch_add`, `nsp_fence`;
5. on a cross-CPU wake, call `nsp_ipi(target)` after the queue push;
6. keep TCB frames in the existing per-slot array; the per-CPU `current`
   pointer is `NS_CUR` widened to `NS_CUR[cpu]`.

The prototype does not yet move `nansched`'s 64-slot arrays, so this is a
documented interface, not a claimed integration.  The queue functions are
executed by the gate's NaN workload, including push/pop ordering.

## 10. Gate and exact transcript

`tools/nansmp_gate.sh` builds the trampoline at `0x8000`, assembles
`src/tests/nansmp_test.nas` with `tools/nmk.awk` (including
`src/lib/nansmp.nas`), embeds both blobs in `s1_smp.c`, boots QEMU with
`-smp 2` and `-smp 4`, and compares the COM1 transcript byte-for-byte.

For `-smp 2` the exact transcript is:

    NAN0S SMP x86_64
    SMP BSP apic=0 cpus=2
    SMP AP cpu=1 apic=1 online timer=1
    SMP IPI cpu=0 -> cpu=1 vec=0x41
    SMP TIMER cpu=0 ticks=1
    SMP TIMER cpu=1 ticks=1
    SMP IPI cpu=0 -> cpu=0 vec=0x41
    SMP WORK cpu=0 task=A count=5000
    SMP WORK cpu=0 task=B count=1000
    SMP RESCHED cpu=0 ipi=1 resched=1
    SMP ATOM cpu=0 total=6000 q=12/12
    SMP WORK cpu=1 task=A count=5000
    SMP WORK cpu=1 task=B count=1000
    SMP RESCHED cpu=1 ipi=1 resched=1
    SMP ATOM cpu=1 total=6000 q=12/12
    SMP SHARED atomic=12000 locked=200
    SMP PASS cpus=2 atomic=12000 locked=200

For `-smp 4`, the same lines repeat for `cpu=0..3`, `atomic=24000`,
`locked=400`.  `total=6000` is task A (5000) plus task B (1000) in the
per-CPU locked counter; `locked=400` is 4 CPUs × 2 tasks × 50 global-lock
iterations; `q=12/12` is the FIFO self-test (`push 1, push 2, pop 1,
pop 2`).

The gate also checks:

- `nmk CMD=check` reports 0 mismatches;
- the image stays below the guest data at word `0x8000`;
- all `nsp_*` symbols required by §5.1 are present;
- the trampoline is at most 4 KiB and the kernel image at most 64 KiB;
- `__bss_end <= 0x30000` so the image cannot overlap the live page tables.

A failed boot prints `SMP EXC vec=... rip=... err=... cr2=...` (page fault
or double fault) or `SMP PANIC ...` on COM1 and exits with the gate's
nonzero status.

## 11. What remains for full SMP

Ordered by dependency:

1. **Per-CPU S1 state.**  Factor `S1 s` in `s1_kabi.c` into a per-CPU
   instance: `r[16]`, pc, k, timer counters, trap frame/entry/stack/region
   ports, and `atomic_result`.  `s1_run` becomes `s1_run_cpu(cpu, budget)`.
2. **Per-CPU trap and vector path.**  Each CPU needs its own kernel stack,
   TSS/IST for faults, IDT (shared is fine if the selector is valid on all
   CPUs), and a timer vector that calls the per-CPU scheduler.  The
   prototype's software `sti; hlt` idle is not a substitute for a real
   interrupt-driven kernel.
3. **Full trap-frame scheduler.**  Port `nansched.nas` to per-CPU current
   pointers and queues, with a global scheduler lock for cross-CPU
   create/wake/kill.  Work stealing: a CPU with an empty queue sends a
   `nsp_ipi` and the victim pushes half its queue under `nsp_lock`.
4. **Regions per CPU.**  A process's region table must be installed on
   every CPU that runs one of its threads; a cross-CPU `region_map` needs a
   TLB-shootdown IPI (vector `0x42`) before the old mapping is reused.
5. **ISA atomics.**  Implement 0x42/0x44 (and the fence spelling chosen by
   `NANVM_SPEC.md` §9.3) in the full S1, then switch `nansmp` bodies from
   the experimental ports to the ISA ops.  Define the memory model
   formally: NaN words are 32-bit payloads; atomics are sequentially
   consistent; ordinary loads/stores are coherent but not ordered without
   a fence.
6. **Timer calibration and periodic mode.**  Calibrate the LAPIC timer once
   against the PIT/TSC, program a periodic per-CPU tick, and wire the
   pending bit into `nthr_tick`/`nthr_preempt` semantics.  The current
   prototype proves only one one-shot delivery per CPU.
7. **Topology and ACPI robustness.**  x2APIC support, IOAPIC masking,
   MADT type 9 entries, CPU hotplug, and a fallback MP-table parser.
8. **Security.**  AP kernel stacks must not share a page with guest data;
   SMEP/SMAP/NX; per-process page tables; the current prototype shares one
   address space and trusts guest code.
9. **Scalability gate.**  N worker threads on N cores with a measured
   speedup and a shared-counter stress test (compare `n*iterations`), plus
   a lock-holder preemption test that bounds worst-case latency.

Until items 1-4 land, "SMP" means: all CPUs execute NaN code and the
atomic/IPI/timer mechanics are real, but the product kernel is still a
single-core scheduler with a multi-core execution substrate.

## 12. Files

| file | role |
|---|---|
| `src/tests/native64/s1_smp.c` | SMP prototype kernel, AP bring-up, per-CPU scheduler, scalar NaN slice |
| `src/native64/smp_tramp.S` | real-mode -> long-mode AP trampoline at `0x8000` |
| `src/native64/s1_smp_isr.S` | timer/IPI/spurious/exception IDT stubs |
| `src/lib/nansmp.nas` | NaN per-CPU queue, spinlock, atomics, fence, IPI |
| `src/tests/nansmp_test.nas` | shared-memory NaN workload executed on every CPU |
| `tools/nansmp_gate.sh` | build, boot `-smp 2/4`, exact transcript |
| `spec/SMP.md` | this document |

No commit is created by the gate; all artifacts live under the temporary
directory selected by `NANSMP_TMP`/`TMPDIR`.


## Scale note

The QEMU prototype now compiles with `NCPU_MAX=256`; the verified gates remain
2 and 4 CPUs.  The product target is 4096 logical cores with x2APIC, ACPI
SRAT/MADT topology, per-core `NanCore` records (see
`spec/MULTICORE_NAN.md`) and 16 KiB per-core stacks.  APIC IDs are mapped to
logical indices in NaN topology code; the substrate only reports the topology.
