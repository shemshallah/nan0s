# smpblock — F1 real-AP immutable block runtime

Status: implemented and gated (2026-11-26).  Agent slot B2.

## Scope

F1: two real CPUs execute one immutable NaN-emitted block with per-core CR3
roots and genuinely shared guest word memory.  The block is straight-line:

```
ADDI r1,r1,1
ST   r1,r2,0
ST   r1,r3,0
HALT
```

The per-core state window `0x50000..0x50FFF` contains `r1/r2/r3`, FLAGM and
the guest mask.  The block bytes live once at `0x51000`; guest words live at
`0x200000`.  Both are identity mapped under both roots.  Only the state
window differs.

## Files

- `src/tests/xlate64_smpblock.nas` — translator driver for the four-word
  block, output byte base `0x20000`.
- `src/tests/native64/s1_smp.c` — `#ifdef BLOCK_SMP` real-AP path; the
  existing `nansmp` path is unchanged when the define is absent.
- `tools/qgate64smpblock.sh` — translate, extract, embed, boot `-smp 2`,
  exact COM1 diff.
- `spec/agents/smpblock.md` — this note.

No C was added outside `src/tests`, and no product source was touched.

## Translation and extraction

The gate runs the NaN translator driver with `nmk.awk` and `nan_cli`, dumps
4096 bytes at `0x20000`, finds the final `C3` (the block's `RET`), and checks
the emitted byte prefixes before embedding it.  This run produced a
**159-byte** block with exactly one `C3`.  The first bytes are:

```
8b 04 25 04 00 05 00   mov eax,[0x50004]      ; r1
05 01 00 00 00         add eax,1
89 04 25 04 00 05 00   mov [0x50004],eax
...
c7 04 25 00 0c 05 00   mov dword [0x50C00],1  ; HALT
01 00 00 00
c3                     ret
```

The gate asserts the ADDI prefix, the `r2`/`r3` base loads, the `r1` store
value load, the HALT tail, one `C3`, and a size of at most 4 KiB.

## Page tables and state

Each CPU gets a 16 KiB 4-level root:

| CPU | CR3 root | private 0x50000 page |
|---|---|---|
| 0 | `0x38000` | `0x70000` |
| 1 | `0x3C000` | `0x71000` |

Root layout: PML4 -> PDPT -> PD.  PD[0] points at a PT that maps the first
2 MiB with 4 KiB pages and overrides PT[0x50] to the core's state page.
PD[1..511] are 2 MiB identity pages, so `0x51000` (block), `0x200000`
(guest words), AP stacks at `0x300000+`, and the kernel remain shared
identity mappings.  PD[1] covers guest memory and AP stacks; the block page
is inside the PT-covered first 2 MiB and its PT entry is identity.

State initialization:

```
+0x004 r1 = 0x10 | (cpu << 4)   -> 0x10 / 0x20
+0x008 r2 = 0x100 + cpu         -> 0x100 / 0x101
+0x00C r3 = 0x200 + cpu         -> 0x200 / 0x201
+0x400 FLAGM = 0
+0x404 guest-word mask = 0x1FFFFF
```

The assignment prose said `r1=0x10+cpu`; that would produce `0x11` and
`0x12`, contradicting the required transcript.  The state therefore uses a
nibble per core (`0x10 + (cpu << 4)`) so the single `ADDI` produces the
required `0x11` / `0x21`.  This matches the earlier `qgate64core2` proof,
which used `0x10` / `0x20`.

## Execution path

1. BSP initializes the console, LAPIC, IDT, MADT discovery; prints
   `BLOCK SMP cpus=2`; requires exactly two CPUs.
2. `init_guest` copies the 159-byte block to `0x51000`, the AP trampoline to
   `0x8000`, and clears guest word memory.
3. The BSP builds both roots and initializes both private state pages.
4. `start_ap(1)` uses the existing INIT-SIPI-SIPI path, but under
   `BLOCK_SMP` writes root `0x3C000` into the trampoline boot block instead
   of the BSP CR3.  The AP therefore enters long mode directly on its own
   root.
5. AP entry (IF=0): loads the shared IDT, publishes `online=1`, calls
   `0x51000`, publishes `finished=1`, halts.
6. BSP switches CR3 to `0x38000`, calls the same `0x51000`, and waits for
   the AP's `finished` flag.
7. For each CPU the BSP switches to that CPU's root, reads `r1` at
   `0x50004`, then reads `slot` and `done` from the shared guest words at
   `0x100+cpu` and `0x200+cpu`.

A boot-CR3 AP would leave its private state page at its initialized value
and write `slot=1`; the observed `r1=0x21 slot=0x21 done=0x21` on CPU1 can
only come from the AP executing the shared block under root `0x3C000`.

## Gate transcript

```
$ sh tools/qgate64smpblock.sh
block 159 bytes
NAN0S BLOCK SMP x86_64
BLOCK SMP cpus=2
BLOCK SMP core0 r1=0x11 slot=0x11 done=0x11
BLOCK SMP core1 r1=0x21 slot=0x21 done=0x21
BLOCK SMP PASS
qgate64smpblock: PASS (2 real CPUs, one immutable 159-byte NaN-emitted block, per-core CR3 state, shared guest memory)
```

The COM1 file is compared byte-for-byte with the five required lines; the
gate also checks `nmk CMD=check` (0 mismatches), the 64 KiB image limit,
`__bss_end <= 0x30000`, the 512-byte boot fixture, and the 4 KiB trampoline
limit.  `BLOCK_SMP` compiles warning-free with `-Wall -Wextra`.

## Regression

```
$ sh tools/nansmp_gate.sh
nansmp: PASS (-smp 2: 2 CPUs, NaN A/B, IPI reschedule, LAPIC timer, atoms, 189-word image)
nansmp: PASS (-smp 4: 4 CPUs, NaN A/B, IPI reschedule, LAPIC timer, atoms, 189-word image)
nansmp: RESULT PASS (x86_64 S1 2-CPU and 4-CPU prototype, exact transcripts)
$ sh tools/qgate64core2.sh
CORE2 PASS
qgate64core2: PASS (one immutable block, two CR3 roots, per-core r1/slot, shared code/guest memory)
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

`git status` also shows the other agent's `src/lib/nansched_*` and
`nansched_mp_test.nas` work; those files were not read or modified here.

## Frontier ideas

1. **Per-core block cache.**  Replace the fixed 159-byte page with a per-core
   `(guest pc -> code)` table whose entries point at shared immutable block
   pages.  The state window and CR3 machinery stay the same; only the lookup
   and cache generation become local.  A multi-block program then proves
   dispatch on APs without copying code.
2. **AP-local interrupts.**  Enable the AP LAPIC timer and reschedule IPI
   after `finished`, so each CPU can take a timer/IPI while executing shared
   blocks.  The next gate can require `timer=1 ipi=1` on both CPUs and a
   preemption point between blocks, folding the F1 runtime into `nansmp`.
3. **Scheduler handoff.**  Put a small `(pc, state page, guest base)` work
   item in shared memory and have CPU0 hand a second block to CPU1 with
   `nsp_ipi`; CPU1 executes it under its existing root.  This proves block
   dispatch, not just one fixed entry, and gives F2 its real cross-core
   wakeup.
4. **Per-core trap/SVC and CR3 generations.**  Add a TSS/IST per AP and a
   trap vector that saves the per-core state page, plus a CR3 generation
   word for block reload/TLB shootdown.  A migration gate can then move a
   guest context between the two roots and require the same result.
