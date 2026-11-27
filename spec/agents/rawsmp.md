# rawsmp - F17 raw 64-bit AP timer/IPI/TSS/IST and 4-core extension

Status: **implemented and gated**. `tools/noc_raw64_smp_gate.sh` prints exactly
`O` as its final marker. The gate boots the raw 64-bit product path with
`-smp 4` and `-smp 2`, and also runs a deliberate page-fault self-test through
the per-AP IST1 path. No C object is linked into the raw image.

This work extends `src/native64/raw64_smp_body.S`; the only C still involved in
the `nansmp` regression is the test-only comparator under `src/tests`, which is
not part of the raw product link.

## What F17 proves

1. **Four real APs through the existing MADT/INIT-SIPI-SIPI path.** The BSP
   parses the ACPI MADT, moves itself to logical slot 0, and starts slots
   1..N-1 through `smp_tramp.S`. Every core gets its own 4-level CR3 root and
   its own 4 KiB state page mapped at VA `0x50000`, while block text
   (`0x51000`) and guest word memory (`0x200000`) stay shared identity maps.
2. **Per-AP GDT/TSS with IST stacks and a shared 256-entry IDT.** Each core
   loads a GDT whose `0x18` selector is a 64-bit TSS descriptor with
   `rsp0`, `IST1` (exception stack) and `IST2` (double-fault stack). The shared
   IDT routes vectors `0x40`/`0x41`/`0xFF` to timer/IPI/spurious handlers and
   all 32 architectural exceptions to reporting stubs; `#DF` uses IST2, the
   other exceptions use IST1.
3. **AP-local one-shot LAPIC timer and reschedule IPI, exact EOI.** Each core
   programs its own LAPIC timer (vector `0x40`, divide by 1, count `0x10000`),
   takes exactly one timer interrupt, receives exactly one IPI (vector
   `0x41`) and writes exactly one EOI per interrupt. The counters must be
   `timer=1 ipi=1 resched=1 eoi=2` on every core; a lost or duplicated
   interrupt fails the gate.
4. **Exception frame reporting.** A gate-only `RAW64_FAULT_TEST` build reads
   the unmapped VA 1 GiB; the BSP reports vector 14, RIP, error code and
   `CR2=0x40000000`, then halts with interrupts disabled.
5. **No C in the raw product link.** Link inputs are `s1_boot.S`,
   `raw64_smp_body.S`, `smp_tramp.S` and the NaN-emitted block. The gate
   audits every input, requires `llvm-nm -u` to be empty, and runs
   `tools/no_c_outside_tests.sh`. The NaN block bytes are produced at build
   time by the existing `nan_cli` translator oracle; only the emitted 159
   bytes are linked, never the C executable.

## Layout

All addresses are physical and identity mapped unless noted.

| range | use |
|---|---|
| `0x8000..` | raw AP trampoline copied from `smp_tramp.S` |
| `0x9000..` | AP boot block (CR3, stack, entry, cpu index) |
| `0x100000 + i*0x10000` | per-core stack arena; top `+0xF000`, IST1 `+0xE000`, IST2 `+0xD000` |
| `0x38000 + i*0x4000` | per-core 4-level page root (PML4/PDPT/PD/PT) |
| `0x50000` (VA) | private state window; maps to `0x70000 + i*0x1000` |
| `0x51000` | immutable 159-byte NaN-emitted block (shared) |
| `0x54000` | shared IDT, 256 x 16 bytes |
| `0x58000 + i*0x2000` | per-core GDT page; TSS at `+0x1000` |
| `0x68000 + i*0x40` | per-core counter/state table (see below) |
| `0x200000` | shared guest word memory `G` |
| `0xFEE00000` | LAPIC MMIO; mapped through `PDPT[3]` / `PD3[503]` |
| `0xFEC00000` | IOAPIC MMIO; mapped through `PDPT[3]` / `PD3[502]` |

Per-core counter table (`0x68000 + i*0x40`):

| offset | word |
|---|---|
| `+0` | timer ticks |
| `+4` | IPI count |
| `+8` | reschedule count |
| `+12` | EOI count |
| `+16` | spurious count |
| `+20` | TSS-installed flag |
| `+24` | IST-verified flag |
| `+28` | block-complete flag |
| `+32` | online flag |
| `+36` | APIC id |
| `+40` | logical index |

The per-core table is addressed by `IA32_GS_BASE` in the interrupt handlers,
so a handler never needs a CPU-id lookup or a global lock.

## GDT/TSS/IDT details

- GDT: null, `0x08` 64-bit code (`0x00AF9A000000FFFF`), `0x10` 64-bit data
  (`0x00AF92000000FFFF`), `0x18` 64-bit TSS descriptor (limit `0x67`,
  type `0x89`, DPL0, present).
- TSS: `rsp0` at `+4`, `IST1` at `+0x24`, `IST2` at `+0x2C`, I/O-map base
  `0x68` (no bitmap).
- IDT entry: offset low/mid/high, selector `0x08`, type `0x8E`, IST index.
  Exceptions 0..31 use IST1 except `#DF` (8) on IST2; timer/IPI/spurious use
  IST0.
- Exception stubs with a CPU-pushed error code (8, 10, 11, 12, 13, 14, 17,
  21, 29, 30) push only the vector; the rest synthesize a zero error code.
  Every stub reaches one reporter that prints vector, RIP, error code and CR2
  and halts.

## Interrupt flow

- The BSP masks the legacy 8259 PIC and all IOAPIC redirection entries before
  enabling interrupts. This matters: QEMU's floppy IRQ6 can be routed to
  vector `0x0E`, which would collide with `#PF`. The raw path only needs the
  LAPIC timer and IPIs, so legacy routing is disabled.
- The BSP runs the block with IF=0, then `sti`; each AP runs the block with
  IF=0, sets `ap_finished`, then `sti` and halts.
- After all APs finish the block, the BSP sends one fixed-delivery IPI to
  every core (including itself) and waits for the exact counter tuple.
- Timer handler: `incl %gs:CT_TIMER`, `incl %gs:CT_EOI`, LAPIC EOI, `iretq`.
- IPI handler: `incl %gs:CT_IPI`, `incl %gs:CT_RESCHED`, `incl %gs:CT_EOI`,
  LAPIC EOI, `iretq`.
- Spurious handler: increments `CT_SPUR` and returns without EOI, as the
  xAPIC spurious vector requires.
- The BSP verifies each TSS descriptor is present/type `0x89` or `0x8B`
  (`ltr` marks it busy) and that `rsp0`, IST1 and IST2 are nonzero.

## Exact gate output

```
$ sh tools/noc_raw64_smp_gate.sh
raw64 block 159 bytes
raw64 link: s1_boot.S + raw64_smp_body.S + smp_tramp.S + NaN block; no C object, no undefined symbols
raw64 block sha256 d3a0d31e5a655439154792c21d29b65d100150fccc66c2987047204438908875; kernel sha256 269f2c98f128df4732cc573a9378cf6fcc108c991be7a25e252793522a78844f
noc_raw64_smp_gate: -smp 4 transcript:
NAN64 RAW SMP x86_64
RAW64 cpus=4
RAW64 core0 r1=00000011 slot=00000011 done=00000011 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 core1 r1=00000021 slot=00000021 done=00000021 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 core2 r1=00000031 slot=00000031 done=00000031 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 core3 r1=00000041 slot=00000041 done=00000041 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 PASS
noc_raw64_smp_gate: -smp 2 transcript:
NAN64 RAW SMP x86_64
RAW64 cpus=2
RAW64 core0 r1=00000011 slot=00000011 done=00000011 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 core1 r1=00000021 slot=00000021 done=00000021 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 PASS
noc_raw64_smp_gate: exception/IST1 self-test:
NAN64 RAW SMP x86_64
RAW64 cpus=2
RAW64 EXC vec=0000000e rip=0000000000010185 err=00000000 cr2=0000000040000000
no_c_outside_tests: PASS (src outside src/tests is C-free)
noc_raw64_smp_gate: PASS (4/2 real CPUs, per-AP GDT/TSS/IST, shared IDT, one-shot LAPIC timer, reschedule IPI, exact EOI, immutable NaN block, no C linked)
O
```

The `-smp 4` transcript is the exact output; the gate uses `diff -u` against a
generated expected file, not a grep. The same is true for `-smp 2`. The
exception self-test is checked for vector 14, error code 0, CR2
`0x40000000`, and the absence of `RAW64 PASS` (it must halt).

## Regressions

```
$ sh tools/qgate64smpblock.sh
block 159 bytes
NAN0S BLOCK SMP x86_64
BLOCK SMP cpus=2
BLOCK SMP core0 r1=0x11 slot=0x11 done=0x11
BLOCK SMP core1 r1=0x21 slot=0x21 done=0x21
BLOCK SMP PASS
qgate64smpblock: PASS (2 real CPUs, one immutable 159-byte NaN-emitted block, per-core CR3 state, shared guest memory)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nansmp_gate.sh
nansmp: PASS (-smp 2: 2 CPUs, NaN A/B, IPI reschedule, LAPIC timer, atoms, 189-word image)
nansmp: PASS (-smp 4: 4 CPUs, NaN A/B, IPI reschedule, LAPIC timer, atoms, 189-word image)
nansmp: RESULT PASS (x86_64 S1 2-CPU and 4-CPU prototype, exact transcripts)
```

`noc_product_gate.sh` was updated to the new two-core raw64 transcript and
still ends in `O`:

```
raw64 PASS: boot + page roots + MADT/INIT-SIPI-SIPI AP + per-AP TSS/IST + timer/IPI + one immutable block, no C
noc_product_gate: PASS (no-C product build audit, hermetic image, full product boot, raw 64-bit AP/block runtime)
O
```

## Honest gaps

- **Four cores, not 4096.** This is the 2/4-core runtime. x2APIC IDs, cluster
  discovery, 4096 per-core records and batched AP startup are separate
  frontier work; the current APIC ID shift is the legacy 8-bit xAPIC form.
- **One-shot timer, one tick.** The gate proves one timer interrupt and one
  EOI per core, not a periodic scheduler tick. There is no quantum,
  preemption or tick accounting yet.
- **One immutable block.** There is no per-core block cache, no shared
  `(guest pc -> code)` table, and no second block dispatch. The block page is
  shared read-only in all roots.
- **The C comparator still exists.** `src/tests/native64/s1_smp.c` remains a
  test-only oracle used by `nansmp_gate`; it is never in the raw64 link. The
  F1/F4 proof path is now the raw gate, but the comparator was not deleted.
- **Exception self-test is BSP-only.** It proves the shared IDT, TSS, TR and
  IST1 reporting path on the BSP. The APs have the same per-AP TSS/IST and
  IDT entries, but the gate does not inject a fault on an AP.
- **Static page roots.** There is no CR3/TLB generation, no shootdown IPI and
  no block reload/migration; roots are built once before AP startup.
- **GPR-only interrupt frames.** The timer/IPI handlers save the 15 GPRs but
  not XMM/YMM state. The current immutable block is integer-only; a vector
  block would need an extended save area.
- **Spurious counter is not in the transcript.** The spurious handler
  maintains `CT_SPUR` and deliberately does not EOI vector `0xFF`, but the
  exact per-core line asserts only the timer/IPI/resched/EOI tuple. A benign
  spurious interrupt would not by itself fail the gate.
- **Serial is not locked.** The success transcript is printed only by the BSP
  after APs stop printing, so it is deterministic. A real concurrent fault
  could interleave COM1 output; the exception path intentionally reports and
  halts without a serial lock.
- **Single IOAPIC assumption.** The raw path maps and masks one IOAPIC at
  `0xFEC00000`. It does not implement interrupt routing, MSI or multiple
  IOAPICs.
- **QEMU proof only.** No bare-metal hardware validation is claimed here.

## Frontier ideas

1. **AP-local block cache and shared code table.** Add a per-core cache of
   decoded/emitted blocks plus a shared `(guest pc -> code)` publication
   table. Gate CPU1 dispatching a second block without copying its code and
   with a read-only shared text mapping.
2. **x2APIC 4096-core discovery and batched startup.** Parse MADT type 9
   cluster/package fields, carry the full 32-bit x2APIC id, lay out 4096
   per-core state pages and start APs in batches. Gate a 4096-core topology
   histogram plus the existing 4-core runtime transcript.
3. **TSS/IST trap matrix and per-core SVC frame.** Inject #PF, #GP and #DF on
   both BSP and AP, verify the reported vector/RIP/CR2 and that IST1/IST2
   stacks do not collide, then fold a per-core SVC frame into the same TSS.
4. **CR3/TLB generation shootdown.** Add a shootdown IPI (vector `0x42`) with
   per-core ack counters, bump a generation on block reload or address-space
   migration, and gate that no core runs a block under a stale root.
5. **Periodic timer and scheduler seam.** Add a bounded periodic LAPIC tick,
   per-core tick/quantum accounting, and a cross-core reschedule handoff into
   `nansched_mp.nas`/`nansmp.nas`.
