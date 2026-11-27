# NaN/0S Master Tasklist

This is the authoritative work queue. Every item has an acceptance gate. Nothing
is "out of scope"; items are ordered, not dropped.

Status: `[ ]` open, `[~]` in progress, `[x]` done and gated.

## F. Frontier AI-native product queue (dispatch source)

Raw-NaN product only. C is allowed only under `src/tests` as an oracle. At most
two agents run at once. Pick the first open item whose dependencies are gated;
each item needs a real gate, a short proof, and a frontier note.

- [x] F0 Zero C in product source outside `src/tests`; `no_c_outside_tests` PASS.
- [x] F0.1 Native maximum map (4 PiB physical / 128 PiB virtual); `mem64_gate` PASS.
- [x] F0.2 Per-NUMA 4K/2M/1G page allocator; `nheap_gate` PASS.
- [x] F0.3 Translator SVC/SVCRET frame + control ports; `qgate64abi` PASS.
- [x] F0.4 Shared immutable block + per-core CR3 state; `qgate64core2` PASS.
- [x] F1 Real AP block runtime: 2 CPUs execute one immutable block with
      per-core CR3 and shared guest memory; `qgate64smpblock` PASS in raw
      assembly/NaN only.
- [x] F2 NaN per-CPU scheduler: queues, work stealing, affinity, migration,
      budgets/deadlines, preemption hooks; `nansched_mp_gate` PASS (2/4 CPU,
      exact stats; existing nansched/stress/jobs/GUI gates retained).
- [x] F3 E820/SRAT/NUMA topology: usable RAM and holes, node ids, CPU/APIC
      mapping, `nheap` integration; `nnuma_gate` PASS (sparse nodes, 5 GiB
      bases, holes/reserved/ACPI/MMIO skipped, per-node 4K/2M/1G heaps).
- [x] F4 4096-core scale: dynamic CPU count, x2APIC, per-core stacks/online
      bitmap, no global lock on dispatch; `ncscale_gate` PASS (4096 cores,
      x2APIC 0x10000000+2i, 16 KiB stacks, online/ready bitmaps, 2/4-CPU regress).
- [x] F5 AI ABI: capability generations/revocation, checkpoint/restore/fork,
      migration, shared weights, KV roots, trace continuity; `nagent_gate`
      PASS (exact `O`, no C product code).
- [x] F6 Tensor/KV memory: zero-copy 64-bit views, per-agent KV slabs,
      packed Q4/Q8 layouts, huge pages; `nkv_gate` + `nq4_gate` PASS
      (2 TiB views across 4 GiB, isolated slabs, exact Q4/Q8 dots).
- [x] F7 Model runtime: GGUF/safetensors import, tokenizer, Q4/Q8 GEMV/
      attention/RMSNorm, deterministic sampling; tiny-model token gate.
      GGUF v3 import/views, byte BPE tokenizer, RMSNorm, Q4/Q8 GEMV,
      deterministic sampler and a tiny embedding->norm->projection token gate
      are gated (`ngguf_gate`, `ntok_gate`, `nmodel_gate`).  F7b adds
      one-head causal attention over nkv token views with exact RoPE/softmax,
      fused Q4xQ8 QK^T bit-equal to the nq4_dot32 oracle, a 1-layer attention
      token gate (`nattn_gate`), GGUF f16-scale Q4/Q8 repack plus GEMV
      (`ngguf_scale_gate`) and a safetensors JSON header/importer
      (`nsafetensors_gate`).  Multi-head, paged decode and speculative
      decoding remain as (nattn) frontier directives.
- [x] F8 Trace/replay: hash chain, deterministic RNG, budgets/deadlines,
      divergence detection; `nreplay_gate` PASS (checkpoint replay, exact
      divergence index, fail-closed budgets, byte-identical runs).
- [x] F9 Isolation/security: per-agent address spaces, W^X/NX, capability
      revocation, sandbox/fuzz; `nsecure_gate` PASS (two agents, guard/range/
      cap errors, 1024 malformed denials, 160 admitted, byte-identical runs).
- [x] F10 Accelerator boundary: PCIe/IOMMU/DMA, VRAM/model placement,
      software fallback; `naccel_gate` PASS (emulated IOMMU domains, DMA
      ring/fence, software GEMV placeholder, 64-bit VRAM/BAR placement,
      exhaustion/unmapped fallback; no native GPU claim).
- [x] F11 Fabric/storage: NVMe/model streaming, RDMA/remote KV, checkpoint
      transport; `nnvme_gate` + `nfabric_gate` PASS (64-bit LBA 2^32, queue
      wrap/doorbells, trim/flush, two-node RDMA send/recv/write/read, stale
      rkey, remote KV, NAGC checkpoint epochs).
- [ ] F12 Observability/ops: per-core stats, OOM/eviction, quotas, scheduler
      traces; gate.
- [~] F13 Frontier capabilities: speculative decoding, MoE routing,
      long-context KV paging, live generations, symbiotic multi-agent
      scheduling; design + prototype gate.  Paged KV + incremental decode
      gated (`npaged_gate`: 2 MiB blocks, stable logical map, prefill+decode
      bit-equal to full recompute, remap/generation, pressure/eviction).
      Speculative decode, MoE, live generations and symbiotic scheduling
      remain.
- [ ] F14 Verification: Coq/UTM trace, translation validation, reproducible
      build; gate.
- [ ] F15 Product raw substrate: replace C harnesses with raw assembly/NaN
      boot/AP/page-table paths; product image boots with no C.

Agent rule:

1. Pick one F item; work only in `.nas`/`.nan`/`.md`/`.sh`.
2. Add `src/lib/<name>.nas`, `src/tests/<name>_test.nas`,
   `tools/<name>_gate.sh`; run the gate.
3. Append `spec/agents/<name>.md` with the proof, exact output, and 2-4
   frontier ideas.
4. Add 3-5 directives with `sh tools/tasklist_append.sh <agent> "<text>"`.
5. End with `NEXT: F# ...` so the main loop can dispatch the next pair.

- [ ] (nnuma) Import real E820/ACPI SRAT+MADT (and QEMU/SeaBIOS dumps) into the nnuma word table; add a differential gate against the synthetic map.
- [ ] (nnuma) Add SRAT distance and HMAT latency/bandwidth entries plus a node-distance API; feed nansched affinity hints and nheap remote fallback.
- [ ] (nnuma) Add per-node 64-bit free/high-water counters and 4K->2M->1G compaction/coalescing over nheap, gated by fragmentation and no-cross-node allocation checks.
- [ ] (nnuma) Add CXL/PMEM and ACPI-reclaim tiers with explicit migration/eviction policy and a tiering gate; keep ACPI reclaim opt-in.
- [ ] (smpblock) Extend the real-AP block runtime to a per-core immutable block cache and shared (guest pc -> code) table; gate CPU1 dispatching a second block without copying code.
- [ ] (smpblock) Enable AP-local LAPIC timer and reschedule IPI after the F1 block, require timer/IPI counters on both CPUs, and fold the block path into the nansmp scheduler.
- [ ] (smpblock) Add a cross-core block handoff: CPU0 publishes a work item and wakes CPU1 with nsp_ipi; CPU1 runs the handed block under its own CR3 root.
- [ ] (smpblock) Add per-AP TSS/IST trap entry, a per-core SVC state frame, and CR3/TLB generation + shootdown for block reload and migration gates.
- [ ] (nansched) Wire nsched_* per-CPU current/trap-frame switching into the F1 AP runtime; keep nsch_* process policy above the substrate queue layer.
- [ ] (nansched) Add per-task KV slab id, byte count and NUMA node fields and make nsched_steal prefer same-node victims with deadline slack before queue length.
- [ ] (nansched) Widen task affinity to a 4096-bit bitmap, keep the 32-CPU fast path, and include nancore NC_NODE hints and steal/topology policy.
- [ ] (nansched) Add speculative tool-call admission with reserved budget classes and deadline-miss parking; gate an admitted and a rejected speculative call.
- [ ] (nansched) Add live-generation handoff: migrate with task epoch, KV epoch, trace head and a destination epoch fence; gate old-generation drain plus new-generation start.
- [ ] (ncscale) Parse x2APIC cluster/package fields from ACPI MADT type 9, carry cluster hints in the NanCore record, and gate a 4096-core cluster histogram.
- [ ] (ncscale) Add ncs_claim(index) as an atomic READY-claim and gate a 4096-core single-winner handoff race through the nansmp CAS seam.
- [ ] (ncscale) Fold nnuma SRAT/SLIT node and distance hints into ncs_init/ncs_index; gate sparse-node distance-aware dispatch preference with policy kept in NaN.
- [ ] (ncscale) Add a per-core cache-color stack/record placement pass and gate a 4096-core color histogram that excludes guard and shared text colors.
- [ ] (ncscale) Add ncs_next_online(start) word-skip scanning over the online bitmap so idle dispatch finds work without a 4096-entry linear scan; gate wrap and empty-bitmap cases.
- [ ] (nagent) Wire nagent records into nancore/nansched_mp: bind scheduler slot, cpu/node, 24-word trap frame and trace head; gate a 2-CPU checkpoint/migrate handoff.
- [ ] (nagent) Extend the checkpoint hash into an append-only chain with prev_hash; gate rollback detection across three checkpoint epochs.
- [ ] (nagent) Add weight-root refcounts and a COW KV object in nanobj; gate zero-copy weight fork with independent child KV generations.
- [ ] (nagent) Add live-generation publish/drain across CPUs and require checkpoint/restore to join the current agent/capability generation, never rewind it.
- [ ] (nagent) Add a per-agent deterministic RNG and replay from a checkpoint; gate trace-head equality and divergence.
- [ ] (nkv) Add per-block KV paging to nkv: allocate 2 MiB blocks on append, evict cold blocks to nheap, remap logical tokens to new 64-bit offsets, and gate allocation/eviction/remap with stable logical indices.
- [ ] (nkv) Add shared-prefix KV and fork copy-on-write: keep immutable prefix caps shared across agents, publish a new KV generation per branch, and gate parent/child prefix reads plus divergent suffix isolation.
- [ ] (nkv) Fuse Q4_0 dequant into QK^T/dot using integer nibble lanes and DP4B, apply the block scale once, and compare the fused result bit-for-bit against nq4_dot32 over a two-block vector.
- [ ] (nkv) Add zero-copy GGUF tensor import: read-only file-backed class-20 storage caps, nkv views from GGUF dtype/shape/strides, direct nq4 consumption, and a tensor range crossing 4 GiB.
- [ ] (nreplay) Bind nreplay to nagent turn records: one checkpoint carries the 24-word frame, scheduler slot, budget/deadline and nreplay RNG/head/index; gate a two-CPU restore that replays the same turn suffix and reproduces the identical trace head.
- [ ] (nreplay) Add deterministic tool-call replay: log SVC 42 args/results as nreplay events, derive request ids from nrng_next, and gate a reordered/missing tool call diverging at its exact event index before the result is admitted.
- [ ] (nreplay) Add checkpoint-ring divergence bisection (nr_replay_until plus periodic 13-word checkpoints) and gate first-divergence search in O(log n) replays with exact index equality.
- [ ] (nreplay) Add compacted-trace replay over chunked nantrace storage/zero-copy KV views and gate that replay from checkpoint roots plus suffix produces the same head as the full trace.
- [ ] (nmodel) Add a GGUF block import pass that converts Q4_0/Q8_0 f16 block scales to the nq4 f32-scale layout on first touch (or mmap a read-only file-backed storage cap), then gate direct nq4 GEMV over a GGUF view crossing 4 GiB.
- [ ] (nmodel) Add one-head attention over nkv token views: Q4/Q8 QK^T with DP4B/VDP4B4, exact f32 softmax, RoPE, and a differential gate against an nq4_dot32 oracle; then extend the tiny model from bag-of-tokens to a real 1-layer token gate.
- [ ] (nmodel) Wire nkv paged KV into nmodel decode: 2 MiB block append/eviction/remap, stable logical token indices, attention over paged views, and a checkpoint/fork safe KV generation.
- [ ] (nmodel) Add a safetensors importer with the same zero-copy nkv view contract (64-bit offsets, dtype/shape checks, rejection cases) and a differential GGUF-vs-safetensors tensor metadata gate.
- [ ] (nmodel) Implement deterministic speculative decoding: draft + verifier models, per-agent xorshift streams, accept/reject trace records and KV-generation rollback; gate identical output for a fixed seed/prompt and a forced-rejection path.
- [ ] (nsecure) Wire nsec records to per-agent CR3/PML4 roots with PCID/ASID: nsec_map/unmap/rebind allocate and clear leaf tables, bump the address-space epoch and issue TLB shootdowns; gate a two-agent stale-TLB isolation race.
- [ ] (nsecure) Add SMEP/SMAP/WP policy bits to the nsecure record and return the required CR4/PTE protection bits from nsec_check; gate kernel reads of agent pages faulting under SMAP and succeeding only through an explicit sandbox window.
- [ ] (nsecure) Add capability-revocation shootdown: publish a per-CPU cap/range epoch, fence after revoke, and gate a two-CPU stale-range failure followed by success after nsec_rebind plus a generation fence.
- [ ] (nsecure) Add an agent-scoped handle salt (or globally indexed cap id) so an identical index/generation/rights word from agent A is rejected on agent B; gate the cross-agent forgery case that the current index-local handle scheme cannot distinguish.
- [ ] (nsecure) Extend the deterministic malformed corpus with a branch-coverage counter over nsec_check/nsec_sandbox_check and add guard, overlap, window and op-bit mutation classes; gate deny-by-default with no admitted request outside an allowed window.
- [ ] (naccel) Wire niommu/naccel to nancore/nansched device discovery: parse PCIe ECAM/BARs, bind one device per agent domain, and gate a two-device/two-agent isolation handoff with hotplug revoke.
- [ ] (naccel) Add scatter-gather DMA descriptors and contiguous multi-entry IOVA translation, then gate a model load split across 4 KiB/2 MiB pages and a >4 GiB IOVA range with exact completion ordering.
- [ ] (naccel) Replace the VRAM bitmap with nheap-backed 4 KiB/2 MiB/1 GiB VRAM classes, add pin counts plus KV eviction to host, and gate pressure/eviction/remap accounting on a 2 TiB BAR.
- [ ] (naccel) Add IOMMU shootdown: per-domain in-flight counters, epoch fencing and drain on unmap/rebind/revoke; gate a stale-completion race on two DMA queues and a two-device generation fence.
- [ ] (nattn) Extend nattn from one head to two heads with per-head Q4/Q8 caches and gate that two independent one-head passes produce bit-identical per-head contexts.
- [ ] (nattn) Add an incremental decode path: append K/V to an nkv slab, apply RoPE at the new position, and gate prefill+decode logits against a full recompute for the same tokens.
- [ ] (nattn) Build an nmodel loader from ngguf_blocks_to_nq4 plus nsafetensors tensors (dtype/shape/offset checked) and gate one real token step over imported weights.
- [ ] (nattn) Replace truncating Q4/Q8 quantization with round-to-nearest and per-block scales; gate max error against f32 and keep fused QK bit-identical to nq4_dot32 on exact values.
- [ ] (npaged) Extend npaged past the 512-token decode window with chunked/online softmax over blocks: per-block max/denominator, rescale the running accumulator, and gate a 4k/32k-token synthetic context against a full recompute with exact in-block f32 order.
- [ ] (npaged) Add src/lib/nspec.nas: draft + verifier streams over one immutable weight root, deterministic accept/reject from the nreplay xorshift stream, KV rollback to the accepted prefix via npaged generation bump, a forced-rejection path, and exact token/logit equality with plain decode for a fixed seed/prompt.
- [ ] (npaged) Add shared immutable paged prefixes with refcounts and copy-on-write fork: page-table entries carry a shared owner/refcount, a child publishes its own KV generation on first append, and a gate proves parent/child prefix reads plus divergent suffix isolation.
- [ ] (npaged) Add a page eviction/tiering policy: recency + attention-mass + node-distance scoring, demotion of cold pages to a slower nheap class or swap capability with a small hot table, and a pressure-driven eviction/remap gate that re-checks exact post-remap logits and stable logical indices.
- [ ] (npaged) Lift the 4 GiB decode limit: carry base_hi through the paged K/V view path (chunked byte/word access or a 64-bit nattn view entry) and gate one block allocated above 4 GiB with prefill/decode parity and remap across the boundary.
- [ ] (nfabric) Add a GPUDirect/RDMA seam: register an naccel VRAM range as an nfabric MR through niommu, translate peer IOVAs in WRITE/READ, and gate a model load streamed directly into VRAM without a host bounce buffer.
- [ ] (nfabric) Add paged remote KV: per-2 MiB-block rkeys and generations, parallel queue-pair transfer, partial-failure rollback, and a COW prefix moved between nodes with stable logical tokens.
- [ ] (nfabric) Layer nnvme queue pairs on nfabric as NVMe-oF capsules plus data buffers; add controller-id/namespace generation checks and gate remote READ/WRITE/FLUSH/TRIM with exact bytes and stale-controller rejection.
- [ ] (nfabric) Extend NAGC checkpoint transport to a 4-node ring with per-link epoch fences and a quorum seal; gate torn-write, duplicate-epoch and rollback rejection, then restore an nagent record on another node without rewinding its capability generation.
<!-- AGENT-APPEND -->

## P0. ISO C parity (language + library + ABI)

### P0.1 Vendored c-testsuite
- [x] 00043 nested named struct definitions (separate nested member arena).
- [x] 00046 anonymous union/struct members (marker entries + recursive lookup;
      nested member and parent size/alignment state restored).
- [ ] 00078 block-scope function prototype.
- [ ] 00130 pointer-to-array declarator `(*p)[4]`.
- [x] Vendored c-testsuite has 0 skips: 56 passed, 0 failed.
- [ ] Add more c-testsuite cases beyond the vendored subset.

### P0.2 Fundamental types and ABI
- [ ] Audit and gate `sizeof(...)`. Measured baseline: char1 short2 int4 long4
      llong8 float4 double4 ldouble4 ptr4 size_t4 ptrdiff4. `double`,
      `long double` and pointers are the P0 ABI gaps.
- [ ] `long long` / `unsigned long long` are 64-bit in the C ABI, including
      arithmetic, shifts, division, varargs, struct layout and alignment.
- [ ] `double` and `long double` are >= 64-bit IEEE-754, including arithmetic,
      conversions, varargs, struct layout and `printf`.
- [ ] 64-bit pointers (`ADDRH`): pointer size, arithmetic, casts, arrays,
      struct layout, function ABI, varargs.
- [ ] `size_t`/`ptrdiff_t`/`uintptr_t`/`intmax_t` match the 64-bit ABI.
- [ ] Strict aliasing, effective types, alignment and object representation.
- [ ] Full C11/C17 lexical and preprocessor corner cases.

### P0.3 Library parity
- [ ] Header coverage audit against ISO C11/C17: assert, complex, ctype, errno,
      fenv, float, inttypes, iso646, limits, locale, math, setjmp, signal,
      stdalign, stdarg, stdatomic, stdbool, stddef, stdint, stdio, stdlib,
      stdnoreturn, string, tgmath, threads, time, uchar, wchar, wctype.
- [ ] Function coverage audit per header, including wide/unicode, file I/O,
      `fopen`/`fread`/`fwrite`/`fseek`/`ftell`/`fgetpos`/`fsetpos`, `remove`,
      `rename`, `tmpfile`, `setvbuf`, `vfprintf`, `snprintf`, `strto*`,
      `strftime`, `mbrtowc`, `wcs*`, `localeconv`, `signal`, `setjmp`.
- [ ] `errno` values and thread-local behavior.
- [ ] `math.h` classification, rounding modes, exceptions, `long double`.
- [ ] ISO C conformance programs beyond c-testsuite.

## P0.4 64-bit memory system (x86-64)

### P0.4.1 CPU and boot
- [x] Long-mode boot path: PAE, PML4/PDPT/PD identity map, EFER.LME,
      CR0.PG, 64-bit GDT/code/data, 64-bit stack. `src/native64/longmode.S`.
- [x] qemu-system-x86_64 gate (`tools/qgate64.sh`) prints a COM1 banner from
      64-bit code.
- [x] 4-level non-identity mapping: VA 0x40000000 -> physical 0x35000 through
      PML4/PDPT/PD/PT, proven by writing and printing through the high VA.
      64-bit IDT/per-CPU TSS follow with the kernel port.
- [ ] 64-bit E820 discovery: the boot sector backs the map up to
      0x8FFE/0x9000 and the long-mode stub scans it, but x86-64 SeaBIOS is
      not delivering a usable table to the floppy boot path yet. The gate
      does not require it; `src/native64/e820probe.S` is the diagnostic.
- [x] NaN-coded x86-64 encoder (`src/translate/x86_64.nas`): MOVI/ADD/set-XPC/
      RET, SIB absolute addressing into the 64-bit register file.
- [x] Native 64-bit substrate executes the NaN-emitted block and reads back
      r1 (`qgate64core`, r1=84). The substrate does not decode instructions.
- [x] NaN-coded 64-bit ALU/flags: MOVHI, ADDI, SHL/SHR/SAR, CMP/CMPS,
      FLAGM; `qgate64alu` (r1=0x2000).
- [x] Conditional branches: FLAGM-tested JMP[cond] selects target or
      fallthrough in XPC; `qgate64branch` (XPC=0x200).
- [x] 64-bit guest word memory: LD/ST with the mask at 0x50404 and
      G=0x200000; `qgate64mem` (r1=0x12345678 exact).
- [x] 64-bit byte memory: LDB/STB byte addressing over the guest word
      model; `qgate64byte` (r1=0xAB, XPC=0x200).
- [x] HALT and the mechanical multi-block `(pc, code)` dispatcher;
      `qgate64prog` runs a three-block loop (r1=3, XPC=5).
- [x] Guest control flow: CALL, CALLR, RET, JMPR and NOP; `qgate64call`
      calls across blocks and returns to an earlier PC (r1=16, XPC=2).
      The native dispatcher now rescans its table after each block.
- [x] MUL/MULH/MULHU, BOOL, DIV/MOD/DIVU/MODU with exact zero/-1 and
      zero-divisor semantics; `qgate64mul` (0x2D), `qgate64div` (0x37).
- [x] Scalar FP: FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/CVTIF/CVTFI with exact
      NaN, zero-divisor, clamp and unordered-compare semantics;
      `qgate64fp`, `qgate64fpe`.  SSE enabled in the substrate.
- [x] LDN/STW/BSWAPM (header classes and byte-swap) and BCOPY/BFILL
      (memmove-safe copy, class-10 fill); `qgate64mem2`,
      `qgate64blockops`.
- [x] Trap path: unsupported opcodes emit a halt + trap code (0x4F);
      `qgate64trap`.
- [x] Full vector family: VZERO/VBCAST/VLOAD/VSTORE, byte/dword
      add/sub, VMUL32, VDP4B, VDP4B4, VGET/VSET; five vector gates.
- [x] JMPF/CALLF 24-bit targets and PUTC; `qgate64callf`,
      `qgate64putc`.
- [ ] Full NaN-coded 64-bit core: guest loader that preserves header
      predicates, and self-hosting.  Remaining opcodes: FEXP/FTANH/FLOG
      and the wider platform I/O surface (ports/fb/keyboard/timer).
- [ ] Port the native NaN16 execution core to 64-bit (`kan64`) only where the
      bootstrap/EXECN substrate requires it; core policy stays NaN.
- [ ] 64-bit native shims for ports, CPUID, RDTSC, MSRs, page tables.

### P0.4.2 Virtual memory
- [x] 4-level page tables and a non-identity 1 GiB mapping (`qgate64`).
- [ ] NX/WP/user bits, page-table walker/allocator API.
- [ ] Physical page allocator (4 KiB, 2 MiB, 1 GiB pages), E820 above 4 GiB.
- [ ] `mmap`/`munmap`/`mprotect`/`mremap` with 64-bit addresses and lengths.
- [ ] Demand paging, copy-on-write, file-backed mappings.
- [ ] 64-bit file offsets, `pread64`/`pwrite64`, sparse files.
- [ ] Zero-copy model mapping: map GGUF tensor ranges directly into guest
      address space without copying through NaN words.
- [ ] Guard pages, stack growth, address-space randomization policy.

### P0.4.3 Packed tensor memory / GGUF
- [ ] Raw packed byte arena addressed by 64-bit offsets, separate from the
      8-byte NaN word space.
- [ ] GGUF parser (header, metadata, tensor info, alignment, mmap ranges).
- [ ] Q4_0/Q4_1/Q5/Q8_0/Q8_K and F16/BF16 tensor layouts.
- [ ] Vector/tensor ops that consume packed weights directly (no 8-byte
      expansion per 4-byte payload).
- [ ] Zero-copy tokenizer/model file access.

### P0.4.4 GPU VRAM
- [ ] VRAM region abstraction with 64-bit sizes.
- [ ] BAR/MMIO mapping, command submission, fences.
- [ ] Model/KV placement policy (RAM vs VRAM), unified addressing.
- [ ] Backend skeleton for a real GPU and a software fallback.

## P0.5 SMP and concurrency
- [~] NaN thread subsystem: TCB/trap frame, ready queue, round-robin quantum,
      preemption hook, join/detach, mutex, cond, TLS and atomics boundary in
      `src/lib/nanthr.nas`; contract in `spec/THREADS.md`, exact gate in
      `tools/nanthr_gate.sh`.  The C core is the oracle; the same image has an
      S1 frame entry (`nthr_syscall_dispatch`) and timer hook
      (`nthr_preempt`).  Remaining: x86_64 S1 SVC/timer vector wiring and
      per-core queues/work stealing.
- [ ] AP bring-up (INIT/SIPI), per-core GDT/TSS/IDT/stacks.
- [ ] Per-core run queues and scheduler; preemption.
- [ ] Atomic load/store/RMW, fences, CAS, fetch-add; exact memory model.
- [ ] Mutex, rwlock, condvar, semaphore, barrier, once.
- [ ] Real `thrd_*`, `mtx_*`, `cnd_*`, `tss_*` (no serialization).
- [ ] Fixed worker pool, parallel-for, work stealing.
- [ ] Parallel matrix tiles for Q4/Q8 GEMV/GEMM, attention, RMSNorm.
- [ ] Per-core NaN16 execution contexts and vector/FP state.
- [ ] Scalability gate: N worker threads on N cores with measured speedup.

## P0.6 Isolation and security
- [ ] Kernel/user address-space split; per-process page tables.
- [ ] Capability-based handles for memory, files, network, devices.
- [ ] Untrusted network input sandbox (parser process/domain).
- [ ] Model file domain: read-only, no kernel pointers.
- [ ] W^X, NX stack, guard pages, SMEP/SMAP if available.
- [ ] Syscall validation, pointer range checks, TOCTOU discipline.
- [ ] Fuzzing gates for parsers and syscalls.

## P0.7 TCC self-hosting and the verified compiler chain
- [x] Vendor TCC at `third_party/tinycc` (upstream `5cef7f3`, imported tree
      `dcb896d1c7ae2e64114c55c93f5223f92280bbdf`, LGPL-2.1); machine-readable
      provenance in `third_party/tinycc/VENDOR`.
- [x] NaN16 ABI contract (`nan16-abi.h`), host word encoder
      (`nan16-enc.c/.h`) and a runnable `MOVI/ST/HALT` smoke test
      (`tcc_nan16_enc`, raw words and `.nan` text).
- [x] tcc0: `TCC_TARGET_NAN16` builds (`nan16-gen.c`, `nan16-link.c`, `tcc.h`,
      `libtcc.c`, `tccelf.c` hooks) and compiles/runs 40 C programs
      (`tcc_nan16_smoke`), including 64-bit pairs, structs, varargs,
      8-byte binary64 `double`/`long double`, comparison-valued `?:`,
      constant-address lvalues and unaligned bit-field containers.
- [x] tcc1: `tools/tcc_nan16_selfhost.sh --run` builds self1 (~2.53 MB),
      self1 compiles `test.c`, emits a 144-byte inner cartridge, and the
      inner `main` returns 42.  Wired into `presqlite_gate`.
- [x] Guest compiler direct calls: whole-`SymAttr` bitfield copies were
      replaced with 2-byte `memcpy`s (a 4-byte bitfield-unit copy zeroed
      `Sym.r` and sent calls to `FP*4+2`).  The guest compiler now passes
      `add(20,22)`, recursive `fib(10)` (55) and a loops/arrays/structs/
      switch test (19).
- [x] NaN16 output: flat cartridge/executable writer, sections, 24-bit
      absolute far branches (`0x38`), 32-bit direct `MOVI/MOVHI`+`CALLR`
      calls, address/data relocations and the entry prelude.  Text-only audit
      of self1: 9,000 far jumps, 5,781 with targets >64k words, zero 16-bit
      branch instructions.
- [x] Guest libc `strtod`: keep 19 significant digits, round to nearest even,
      and apply one correctly rounded `10^k` from the generated
      `nan16_pow10.h` table; `__nan16_ull2d` was also corrected.  The old
      parser wrapped 2^64/2^96 to zero and lost the low bits of DBL_MAX; this
      was the last self1/self2 difference.
- [x] tcc2: self1 compiles the preprocessed TCC sources plus
      `NAN16_RUNTIME_SRC` to self2; `self1 == self2` byte-for-byte
      (2,529,728 bytes) within the 5.0B-step cumulative gate budget.  self2 compiles
      `test.c` to a 144-byte inner cartridge whose `main` returns 42.
      SHA-256 `32c3b8e82b62549ce23cbc372504412d076de2165988710889eabd23541b38f7`.
- [x] SQLite-driven compiler corrections (no SQLite field/allocator hacks):
      natural-alignment fallback for unaligned bit-field containers;
      per-`VT_CMP` operands in `SValue.cmp_r` so `?:` can save/restore
      comparisons; dereference in the non-symbol constant-lvalue load;
      `VT_LLOCAL`/member-offset materialisation; 16-byte allocator header for
      eight-byte payload alignment; `INT*_C`/`UINT*_C` and `NDEBUG` headers.
- [ ] Broaden the guest-compiler/program corpus beyond add/fib/loops/arrays/
      structs/switch and the double-constant test: printf, libm, varargs and
      libtcc subsets.
- [ ] ABI parity with ncc: args/returns, stack frames, varargs, structs,
      64-bit pairs, f32/f64; bidirectional call tests.  This is a separate
      gate: do not link ncc- and tcc-compiled objects until ncc's `double`
      is 8 bytes and the mixed `printf` test passes.
- [~] VFS and headers completeness for `#include`, source and model/SQLite
      files: the guest libc VFS handles includes/sources; a named in-memory
      SQLite base VFS is in `third_party/sqlite/nan16_vfs.c`; host-file
      persistence remains separate.
- [~] NaN16 `libtcc1` runtime: 64-bit arithmetic, shifts and binary64 helpers
      are in place; `alloca`, `setjmp` and full mem/str coverage remain open.
- [x] SQLite 3.54.1: vendored unmodified in `third_party/sqlite` with
      `VENDOR` hashes; tcc0 cross-compiles it with `SQLITE_OS_OTHER=1`,
      `SQLITE_THREADSAFE=0`, `SQLITE_TEMP_STORE=3`, no WAL, and the in-memory
      VFS.  `tools/tcc_sqlite.sh` requires bit-identical guest/native results
      for a 96-result suite and a 256-result 500-row stress database
      (multi-page btrees, overflow blobs, joins, indexes, transactions,
      `VACUUM`, close/reopen), plus a `SQLITE_DEBUG` assertion build.
      Guest `tcc2` compiling the 9.2 MB amalgamation remains a larger
      budget gate.
- [ ] Verified chain: finite per-opcode/block lowering lemmas plus small UTM
      trace checks; scope the compiler-correctness/translation-validation
      claim honestly (a trace does not by itself prove the binary implements
      the C source).
- [x] Gates: `tcc_nan16_smoke`, `tcc_nan16_selfhost`, `tcc_nan16_enc` are in
      `presqlite_gate`; `tcc_nan16_tcc2` is a standalone resumable gate.
      `tcc_sqlite` is now a passing standalone differential gate.
      `tcc_verified` remains the future verified-chain gate.

The TCC port contract, ABI, bootstrap stages and proof chain are detailed in
`spec/TCC_NAN16.md`. TCC and SQLite are C; the C++17 track is only a dependency
for llama.cpp, not for tcc2.

## P1. C++17
- [ ] C++17 frontend: namespaces, classes, access control, references,
      overloading, constructors/destructors, operator overloading.
- [ ] Templates (function/class, partial/full specialization, variadic).
- [ ] STL subset: vector, string, string_view, unordered_map, map, memory,
      algorithm, functional, utility, chrono, thread, mutex, atomic.
- [ ] RTTI, exceptions or a documented no-exception build, `new`/`delete`.
- [ ] Name mangling and C++ ABI; `extern "C"`.
- [ ] C++ runtime: initializers, static destructors, `std::terminate`.
- [ ] C++17 conformance gate suite.

## P1. llama port ("llamanan")
- [ ] Port llama2.c/llama.cpp GGUF loader to NaN C/C++.
- [ ] Tokenizer (BPE/SentencePiece), vocab, special tokens.
- [ ] Transformer: RMSNorm, RoPE, GQA/MQA attention, SwiGLU MLP, KV cache.
- [ ] Quantized matmul/GEMM with packed weights and SIMD tiers.
- [ ] Sampling: greedy, temperature, top-k, top-p, repetition penalties.
- [ ] CLI generation and server path with isolation.
- [ ] Token/s benchmarks at 7B/13B/70B-equivalent shapes.

## P1. Performance
- [ ] AVX2/AVX-512/NEON/RVV tiers, CPUID steer, exact lanes.
- [ ] VNNI / dot-product instructions where available.
- [ ] Decoded-block cache and native block JIT.
- [ ] Prefetching, cache blocking, NUMA awareness.
- [ ] Tokens/s and MAC/s benchmark gates on real hardware.

## P2. Testing and performance workflow
- [x] Full aggregate is time-boxed per gate and parallelizes the 62 compiler
      gates.
- [x] `tools/gate_targeted.sh`: changed-file -> affected-gate mapping,
      parallel execution, content-hash cache, `--full` battery.
- [x] Compiler family measured at 239 s cold / 9 s cached (75 gates).
- [ ] Combined multi-test VM harness to remove per-gate compiler startup.
- [ ] CI matrix and coverage-guided gate selection.

## P2. System
- [ ] Filesystem, network stack, GUI, apps, package/tooling.
- [ ] APK/assets and bare-metal image pipeline.

## P2. NANDBG — NaN-native debug system
Design: `spec/NANDBG.md`. Gates: `tools/ndbg.sh`, `tools/ndbg_diff.sh`,
`tools/ndbg_mon.sh`, `tools/ndbg_img.sh`, `tools/ndbg_gui.sh`.
- [x] Typed diagnostic word: 4×4 severity/domain matrix from the two NaN heads;
      STW/LDN round-trip, BSWAPM mirror law, quiet/raise.
- [x] First proof: single-step core (MOVI/MOVHI/ADD/SUB/CMP/JMP/CALL/RET/JMPR/
      LD/ST/STW/LDN/PUTC/NOP/HALT, all 16 BOOLs, predication/flags), breakpoint
      without patching, gate/bad-op records, exact transcript gate.
- [x] Full `0x00–0x5F` step core in `src/dbg/core.nas`: all defined ops,
      vectors via host-vector delegation, DP4B/VDP4B4, shadow call stack,
      non-blocking KEY; `0x60/0x61` classified as host extensions.
- [x] Native-vs-stepped differential gate (`tools/ndbg_diff.sh`): integer,
      memory, calls, floats, DP4B and vectors; byte-identical transcript,
      golden checksum, negative mutation check.
- [x] Real cartridge under the core: Baby runs to `KEY` (`CART PASS`); Trust
      also passes manually.
- [~] Containment/watch: write window `[nd_wlo, nd_whi)` guards ST/STB/STW/
      BCOPY/BFILL; before-write watchpoints with old/new records; guard and
      watch gate. Watchpoint table + `wpts`/`watch` CLI and ABI2 register/memory
      setters exist; full permission map, typed write commands, and I/O
      mediation remain.
- [x] Serial monitor (`src/dbg/n16dbg.nas`): step, run, breakpoint, goto,
      watch, history, stack, live type matrix, regs, disassembly, dump; exact
      session gate.
- [x] Bare-metal floppy image: `tools/ndbg_img.sh` boots `n16dbg.nas` on
      qemu with no host OS and checks the monitor banner/prompt on COM1.
- [x] Desktop terminal `debug` command opens a second CLI (kind 8) with the
      resident core at 6200 and demo target at 8100.
- [x] Desktop `carts` / `load <id>` picker: sealed cart copied to the debug
      arena at 0x80000, mapped at guest 8192; Baby runs to `KEY`.
- [x] TOC/title snapshots at 0x70000/0x72000, taken before the GUI boots.
- [x] `next` / `finish` commands over the shadow call stack in the desktop
      debug CLI.
- [x] `log` (last four typed records) and `mem [addr]` (eight words at PC
      or a chosen address, with class) in the desktop debug CLI; break events
      are logged.
- [x] Breakpoint/watchpoint tables in the core, ABI2 list/toggle entries,
      `bp <hex>`/`wp <hex>`/`bpts`/`wpts`/`watch` GUI commands; fast single
      break remains.
- [x] Typed `setr <n> <hex>`, `setm <addr> <hex>`, `setw <addr> <word>
      <class>`, `setc <addr> <class>` and `goto <hex>` commands on ABI2
      register/memory/class/PC setters.
- [x] Debug-pane vector I/O capture into a private 25x80 text buffer;
      `screen` CLI command.
- [x] Serial capture from target `PUTC` into 0x61000; `serial` CLI command.
- [x] System utilities `[3] DEBUG` entry opens the desktop debug CLI.
- [ ] 80×25 pane console (the serial/GUI CLIs already have the type matrix).
- [x] Bounded scalar undo: 32-record ring at 0x30000, restore of registers,
      PC, condition, call depth, and two guest words per step; `undo [n]` CLI.
- [x] Redo ring at 0x62000 with post-step registers/writes; `redo [n]` CLI.
- [x] Cart `checkpoint`/`restore`: registers, PC, condition, call depth, 64K arena.
- [x] Desktop `dis [addr]`: shared disassembler, guest-to-host mapping.
- [ ] 8-word records, mirror-pair log, flight recorder.
- [ ] NDP (NaN Debug Protocol) over serial/mailbox; symbol blob; poison fill.
- [ ] Standalone `n16mon` boot monitor; self-debug (`n16dbg` under itself).
- [ ] Optional native trap trampoline/trace port behind the same control API.


## P0.8 Tcl + SQLite official suite (x86_64 product target)
Plan and component census: `spec/TCL_SQLITE_OFFICIAL_SUITE.md`.
- [x] tcc1 raw-source guest VFS gate: `tools/tcc_nan16_rawcc.sh` compiles
      raw `libc.c` + program with `/usr/include` headers from the guest VFS,
      links a runnable cartridge, and checks inner `main` = 42.  This removes
      host-preprocessed `.i` input for the program.
- [x] resumable tcc2 fixpoint: self1 == self2 byte-for-byte at
      2,529,728 bytes after the VFS/runtime changes; SHA-256
      `32c3b8e82b62549ce23cbc372504412d076de2165988710889eabd23541b38f7`;
      fixed-size checkpoints and `TCC2_DIR` resume.
- [ ] x86_64 S1 parity for the acceptance path: trap/SVC frames, timer IRQ,
      region checks, device windows; QEMU x86_64 gates.  `nan_cli` remains a
      compiler conformance oracle only.
- [ ] NaN kernel: process/thread tables, scheduler, mutex/cond, signals,
      NaNFS write/dirs, tty, pipes, loopback sockets, NaN16 dynamic loader.
- [ ] Tcl 9.0.3 port (`tclNan16Port`, channels, notifier, threads, load).
- [x] Pin Tcl 9.0.3 + SQLite 3.54.1 test-suite provenance; x86_64-gated
      native baseline script (`tools/tcl_sqlite_native_baseline.sh`).
- [ ] SQLite testfixture on NaNFS; official 1,199 `.test` files; exact
      pass/skip/error archive.
- [ ] tcc1 builds Tcl/testfixture from guest sources; tcc2 fixpoint; suite
      passes under the tcc1-built image.
- [ ] Guest process viewer/manager (processes, threads, memory, steps,
      spawn/kill/priority hooks).
- [ ] No host/phone path in product or acceptance gates; neutral build dirs
      only.
