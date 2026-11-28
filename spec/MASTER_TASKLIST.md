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
- [x] F12 Observability/ops: per-core stats, OOM/eviction, quotas, scheduler
      traces; `nobs_gate` PASS (4 CPUs, exact core/mem/quota/ring/health,
      pressure eviction + OOM, deterministic trace hashes).
- [x] F13 Frontier capabilities: speculative decoding, MoE routing,
      long-context KV paging, live generations, symbiotic multi-agent
      scheduling; design + prototype gate.  Paged KV + incremental decode
      gated (`npaged_gate`: 2 MiB blocks, stable logical map, prefill+decode
      bit-equal to full recompute, remap/generation, pressure/eviction).
      Speculative decode (`nspec_gate`: draft/verifier, forced rejection,
      exact ids/logits, paged-KV trim rollback, deterministic trace head) and
      tree speculation (`nspectree_gate`: 6-candidate depth-2 tree, batched
      verifier, longest-branch promote/trim, tree==plain) and MoE routing
      (`nmoe_gate`: top-2 Q4 router, 4 expert FFNs, capacity drops, load and
      NUMA/VRAM placement accounting, exact combine) are also gated.  Live
      generations (`ngen_gate`: publish/drain/start, stale/dup rejection,
      forced abort, two-agent isolation), symbiotic multi-agent scheduling
      (`nsym_gate`: 3-agent WFQ, bounded ratio, no starvation, shared-root
      refcounts), and COW prefix fork (`nkvgen_gate`: gen5 prefix, gen6 fork
      shares pages, cross-gen/old-gen rejection, boundary COW, exact
      refcounts) and a three-agent shared-prefix tree (`nkvtree_gate`: root
      gen5 10-token prefix, child1 gen2/child2 gen3, boundary COW, both close
      orders, 3344-word deterministic snapshot) and a content-hash prefix
      DAG (`nkvdag_gate`: 4 agents, P/Q prefixes, identical P0 page deduped
      to one header with refs 4, late fourth join, COW suffixes, both close
      orders, 5280-word snapshot) and a Merkle multi-parent DAG
      (`nkvmerkle_gate`: 4 agents, gen-tagged nodes, root-only page/token
      proofs, 11 mutation/order rejects, post-free proof, 6816-word snapshot)
      are gated.  F13 core complete; CAS hydration, sibling joins,
      generation deadlines and SMP publish are queued follow-ups.
- [x] F14 Verification: Coq/UTM trace, translation validation, reproducible
      build; `nverify_gate` PASS (reproducible nmk/translator output, byte
      goldens, native/n16i trace sha equality, non-ELF product images,
      C-free source, Python UTM anchors; Coq SKIP because no coqc on PATH).
- [x] F15 Product raw substrate: replace C harnesses with raw assembly/NaN
      boot/AP/page-table paths; `noc_product_gate` PASS (hermetic two-build
      image, full product boot to NANIX SHELL READY, raw64 2-AP block path,
      no C linked, C-free product source).
- [x] F16 Signed/authenticated product manifest: 4 KiB manifest at LBA 120
      and 512-byte anchor at LBA 128 over boot/kernel/guest; native SHA-256
      region/root plus Winternitz-4 OTS primary and HMAC defense-in-depth
      before guest fetch.  `ots_gate` PASS: two deterministic builds, exact
      boot/kernel/guest/manifest/root -> `!MAN`, key/pub/sig/anchor -> `!OTS`,
      HMAC -> `!SIG`, clean boot to NANIX SHELL READY, guest never entered on
      failure.  Development seed is public; production key custody and
      Ed25519/anti-rollback/measured boot remain queued.
- [x] F17 Raw 64-bit SMP substrate: per-AP GDT/TSS/IST, shared IDT, 4-core
      MADT/INIT-SIPI-SIPI, AP-local LAPIC timer, reschedule IPI, exact EOI,
      exception/IST1 self-test; `noc_raw64_smp_gate` PASS (4/2 CPUs, no C
      linked).
- [x] F18 Source-derived GOLD: raw n16i nasm1 boot slice (512/512 bytes),
      native xgold.sh full GOLD (512+12,368 bytes, 32+773 rows), nan_cli only
      an optional comparator; `source_gold_gate` PASS in 76.6 s.  The n16i
      slice now passes the 8M-word host mask; the old 256 KiB mask wrapped
      nasm1's output at word 0x100000 and stack at 0x1F0000.  Full-kernel raw
      n16i remains the slow reference path.
- [x] (nasm) Collision-proof NaN label table: three-word entries (two
      independent 32-bit hashes + value), newest-first `llook` for nmk's
      last-definition-wins semantics, and the `LD/ST -> LDS/STS` plus
      `JMP/CALL -> JMPF/CALLF` promotions.  `nhost` now reproduces the full
      51-file guest exactly: 530,842/530,842 words, SHA-256 match, 0 errors;
      `tools/nhost_gate.sh` covers it.  The duplicate `tn_d` name in libcx
      was renamed `cx_tn_d`, fixing the in-shell `asm` operand hang;
      `tools/nixsh_asm_gate.sh` PASSes.
- [x] (nasm) Self-hosted guest emission: `nhost` assembles itself to a
      4,532-word fixed point; `tools/nhost_emit_guest.sh` emits the 530,842-word
      guest, and `tools/nhost_product_gate.sh` proves it packs to the shipped
      `build/nan0s.img` byte-for-byte.  `NHOST_BUILD=1` selects it in
      `tools/build.sh` and `tools/mkn16iimg.sh`.
- [x] (nasm) Native-core nhost: `native_nhost_gate.sh` boots the product boot
      sector + GOLD kernel with nhost as the guest and the source bundle at
      LBA 2048.  Self-host is 4,532 words in 17 s with no `nan_cli`/S1 KABI;
      the full 530,842-word native run is opt-in (`NHOST_NATIVE_FULL=1`).
      `nhost_emit_guest.sh NHOST_NATIVE=1` exposes the same native chain.
- [ ] (nasm) Make the native-core nhost the default producer: the full guest
      is ~30 min on the 32-bit interpreter, so first add a faster native path
      (cache/native in-product build); then remove `nmk.awk` from `build.sh`.
- [x] F18c Unified nasm: `src/prog/nasm.nas` is the single assembler with a
      NaN-word mode (z0, `run`/`V_*`) and an x86-byte mode (x1, `_start`);
      `nasm0.nas`/`nasm1.nas` are aliases.  x86 boot output is byte-identical
      to nasm1, `xgold.sh` matches GOLD, `blockcache_gate` PASS (3,913-word
      cache), and `source_gold_gate` PASS in 73.7 s.  In-shell `asm`
      operands/labels now assemble and run (`nixsh_asm_gate` PASS) after the
      duplicate `tn_d` label fix.
- [x] F18b Block-cache GOLD build: translate nasm1's 2,992 compiled words to
      native x86 slots plus a per-PC predicate-mask table, dispatch directly
      in a multiboot 64-bit stub, and consume it from `tools/xgold.sh`.
      `blockcache_gate` PASS: two deterministic cache builds, boot 512/512 and
      kernel 12,368/12,368 byte-identical to GOLD, kernel 10.9 s and xgold
      16.5 s (raw 621 s).  `USE_BLOCK_CACHE=0` keeps the raw native-kernel
      path.  Multi-instruction blocks and a product-resident cache are queued.

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
- [ ] (nobs) Wire nobs core samples, quotas and health into nagent: bind agent id to scheduler slot/cpu/node, include the trace head and remaining quota, and gate a two-agent dashboard where one denial leaves the other's counters exact.
- [ ] (nobs) Replace the fixed cold-FIFO eviction path with a scored OOM policy (recency, KV attention mass, node distance, quota overage), keep the deny/OOM event shape, and gate deterministic victim choice plus a no-cross-node eviction rule.
- [ ] (nobs) Feed nobs quota headroom into nansched_mp admission: park an agent before dispatch at its CPU-step, memory or KV limit, reserve a class for interactive agents, and gate admit/park/resume with exact per-core budget and deadline counters.
- [ ] (nobs) Export the nobs trace ring into nantrace/nreplay chunks with the same hash chain; gate that replaying an exported scheduler window reproduces the ring head and health totals, and that a mutated window diverges at its exact event index.
- [ ] (nspec) Add tree speculation over a small draft stream sharing the nattn weight root: per-branch causal masks, one batched paged verifier pass, longest root-to-leaf accept, and exact token/logit equality against sequential speculative decode.
- [ ] (nspec) Add per-record branch/owner tags and scratch page slots so a tree verifier can append all draft candidates, promote the accepted branch and trim the rest with npaged_trim; gate an exact sequential-vs-batched logits comparison.
- [ ] (nspec) Add KV page refcounts and copy-on-write draft branches: immutable prefix pages shared read-only, private suffix pages per branch, accepted-branch publication, and a parent/child plus divergent-suffix isolation gate tied to nagent_fork.
- [ ] (nspec) Bind nspec seeds, trace head and accepted/rejected counts to nagent/nreplay turn checkpoints; add an include guard or split nrng core, gate restore+replay head equality, and report tokens-per-verifier-pass before any speedup claim.
- [ ] (nverify) Make the F14 gate rebuild the full product image twice in a hermetic environment, compare sha256, and fail if build/nan0s.img is stale; keep the current nmk/translator checks as the fast path.
- [ ] (nverify) Add an independent translator oracle for the covered opcode subset (second encoder or SMT/bit-vector equivalence) plus randomized block fuzzing; promote the loop-block sha pin to checked bytes.
- [ ] (nverify) Add proof-carrying block certificates for MOVI/ADD/ADDI/JMP/RET and verify them at gate/load time; fail closed on uncertified opcodes and keep the Coq scope explicit.
- [ ] (nverify) When coqc is present, build and coqchk the formal/utm universality/literal-run/bridge cone in the F14 gate; keep the Python literal-image/table/step anchors as separate pre-checks.
- [ ] (nverify) Investigate the ngate_n16i trap-case mismatches (gate-trap and native bad-op), fix or scope them, then fold the trap cases into the F14 differential.
- [ ] (nspectree) Replace the serial per-candidate masked verifier with a fused tree-attention kernel: pack six candidate Q rows and branch masks, share each distinct ancestor K/V fetch, keep the exact f32 score/softmax order, and gate tokens-per-verifier-pass plus bit-equal logits against the current nspectree path.
- [ ] (nspectree) Add refcounted COW KV branch pages: shared read-only prefix pages, private suffix pages per draft branch, accepted-branch publication without payload relocation, and a parent/child plus divergent-suffix isolation gate tied to nagent_fork.
- [ ] (nspectree) Add variable-depth/top-k draft trees with per-node masks, a longest-path accept, an accepted-length histogram and a natural (no-anchor) accept-rate gate over fixed prompts/seeds.
- [ ] (nspectree) Bind nspectree seeds, trace head, accepted/rejected/trimmed counters and promoted generations to nagent/nreplay turn checkpoints; gate restore+replay head equality and report tokens per verifier pass before any speedup claim.
- [ ] (nspectree) Move branch/owner tags, record relocation and per-page refcounts into npaged as first-class fields so nspectree no longer copies record payloads; keep stable logical indices and generation-checked views, and rerun npaged/nspectree gates.
- [ ] (nmoe) Add capacity-aware overflow rerouting: when an expert is full, try the next ranked expert and gate a no-drop fallback with exact renormalized combine weights.
- [ ] (nmoe) Wire expert-parallel dispatch to nansched per-expert queues with deterministic token order, same-node affinity and per-expert accept/drop counters.
- [ ] (nmoe) Add per-expert KV slab residency hints and a decode gate that keeps selected experts resident across tokens, evicting cold experts through nkv/nheap.
- [ ] (nmoe) Import GGUF MoE router and expert tensors with one-time f16-to-f32 scale conversion and gate bit-equal logits against the hand-built Q4_0 table.
- [ ] (ngen) Wire ngen enter/publish/drain into nagent records and nansched_mp on two CPUs; gate a live handoff where the old generation's in-flight turn drains on CPU0 while CPU1 starts the new generation, with exact per-CPU and epoch counters.
- [ ] (ngen) Tag nkv/npaged KV block headers and views with the ngen generation, reject cross-generation reads at the view layer, and gate a COW fork that publishes a new KV generation without copying shared prefix pages.
- [ ] (ngen) Add per-draining-generation deadlines to ngen: account ticks, force abort at expiry with an exact reason, and gate early completion, deadline abort and stale post-abort rejection.
- [ ] (ngen) Add bounded generation rollback: keep the last four drained descriptors and permit rollback only when no newer checkpoint, capability epoch or KV generation exists; gate the accepted rollback and each rejection reason.
- [ ] (ngen) Make publish atomic under real SMP by driving a per-agent CAS/fence through the nansmp ops seam, with a two-CPU publish race gate that proves one winner, one EDUP loser and no partial drain/start state.
- [ ] (nsym) Bind nsym agent records to nansched_mp task slots through the nansmp CAS/fence ops seam; gate two CPUs dispatching concurrently with one winner per tick, exact per-CPU service, and root refcounts unchanged by scheduling.
- [ ] (nsym) Add hierarchical shared-prefix weight roots: per-prefix refcounts, immutable prefix pages, and copy-on-write only on the diverging suffix; gate a parent/child adapter branch that publishes its own generation without copying shared prefix pages.
- [ ] (nsym) Add team-level budgets and deadlines to nsym: a team share with producer/consumer handoff (drafter/verifier or tool agent), team admission, and a gate that team fairness holds while each member's reservation and root reference stay independent.
- [ ] (nsym) Integrate deadline-aware KV reservation: couple nsym admission to nobs quota headroom and npaged residency, reject/defer jobs whose deadline is infeasible after eviction, and gate eviction-vs-deadline decisions with exact park and miss accounting.
- [ ] (nsym) Add cooperative migration of an nsym agent (queue, vrt, reservation, budget, generation tag and root reference) between CPUs with a destination epoch fence and two-lock handoff; gate no double service and unchanged root refcount.
- [ ] (noc) Extend src/native64/raw64_smp_body.S with per-AP TSS/IST, AP-local LAPIC timers and reschedule IPIs, a per-core block cache and x2APIC 4096-core discovery; gate 2/4/4096 CPUs and retire the s1_smp.c comparator for the F1/F4 paths.
- [ ] (noc) Add a signed product-image manifest over boot+kernel+guest and verify it in the native boot path before the first guest fetch; gate a one-byte mutation in each region and fail closed.
- [ ] (noc) Run the NaN translator under raw n16i in the gate, compare emitted bytes against the nan_cli oracle, then regenerate src/native/nan16_x86.nan with xgold.sh and fix the stale xgold kernel-row count so the checked-in GOLD is source-derived.
- [ ] (noc) Add a headless COM1 NANIX shell transcript (mkdir/write/cat/ls/stat/rm) to the full product image so the service path is gated without a GUI; keep the GUI/VBE test separate.
- [ ] (nkvgen) Replace the flat per-branch page table with a refcounted prefix-page DAG keyed by content hash so three or more agents/adapters share one immutable prefix without duplicating page headers; gate a three-branch tree with exact per-page refcounts and per-branch ngen tags.
- [ ] (nkvgen) Add COW eviction/tiering: demote cold shared prefix pages to an nheap slow class while preserving refcounts, rehydrate on read, and gate a pressure-driven evict/remap that re-checks exact post-remap prefix values and alloc/join/leave/free counters.
- [ ] (nkvgen) Add generation-tagged KV checkpoint/replay: save a branch page table plus ngen generation, replay a suffix from the checkpoint through the view gate, and gate exact logits/token equality plus an old-view divergence at the exact event index.
- [ ] (nkvgen) Extend nkvgen fork from one child to a multi-level fork tree with sibling joins, identical-COW-page merging and orphan reclamation; gate a deterministic tree-generation trace and exact page refcounts across a fork/close tree.
- [ ] (rawsmp) Add an AP-local immutable block cache and a shared (guest pc -> code) table; gate CPU1 dispatching a second block without copying code and with shared text mapped read-only.
- [ ] (rawsmp) Add x2APIC 4096-core MADT type-9 discovery, full 32-bit APIC ids, 4096 per-core state pages and batched AP startup; gate a 4096-core histogram plus the current 4-core raw transcript.
- [ ] (rawsmp) Add a BSP/AP exception trap matrix (#PF/#GP/#DF) over the per-AP TSS/IST and a per-core SVC state frame; gate exact vector/RIP/CR2 and non-colliding IST1/IST2 stacks.
- [ ] (rawsmp) Add a CR3/TLB generation shootdown IPI (vector 0x42) with per-core ack counters; gate block reload or address-space migration so no core executes under a stale root.
- [ ] (rawsmp) Add a bounded periodic LAPIC tick with per-core quantum/tick accounting and a cross-core reschedule seam into nansched_mp/nansmp; gate preemption after N ticks on 4 cores.
- [x] (nkvtree) Gate a content-hash prefix-page DAG shared by three or more agents/adapters without duplicate page headers; assert exact per-page refs, dedup hits and per-branch ngen tags. Gated as `nkvdag` (`tools/nkvdag_gate.sh`, `spec/agents/nkvdag.md`): 4 agents, P/Q prefixes, identical P0 page deduped to one header (refs 4, dedup 1, headers 1), late fourth join, shared/private COW suffixes, EDUP/ECOLL/EREF/ENOENT rejects, both close orders, exact counters and 5280-word snapshot.
- [ ] (nkvtree) Add sibling joins, identical-COW-page merging and orphan reclamation to nkvtree; gate a multi-level fork/close tree with a deterministic tree-generation trace and exact page/root refcounts.
- [ ] (nkvtree) Add generation-tagged tree checkpoint/replay: save a branch page table plus ngen generation, replay its suffix through the view gate, and assert exact token/value equality and old-view divergence at the exact event index.
- [ ] (nkvtree) Bind nkvtree fork/close to nansched_mp task slots with CAS/fence refcounts; gate concurrent sibling fork/close on two CPUs with one winner per refcount op, exact per-CPU counters and unchanged shared-root refs when only scheduling changes.
- [ ] (nkvdag) Upgrade the content key to a Merkle node hash over content+prev+used+generation tag, allow multi-parent prefix nodes, and gate inclusion proofs from a root-only checkpoint.
- [ ] (nkvdag) Persist DAG nodes in a content-addressed store and gate late hydration of a new agent by root hash over NVMe/RDMA, asserting exact dedup hits and bytes avoided across a cold restart.
- [ ] (nkvdag) Add CAS/fence per-node refcounts plus epoch GC/orphan reclamation; gate two-CPU concurrent sibling join/close with one winner per refcount op, exact per-CPU counters and no free of a node visible to a live view.
- [ ] (nkvdag) Save checkpoint roots {DAG root, ngen generation, nagent KV root, trace head}, replay a branch suffix through the view gate, and assert exact token/value equality plus old-view divergence at the exact event index.
- [ ] (ngold) Add a proof-carrying GOLD certificate over boot/kernel/guest: hash-chain each region, verify it in the native boot path before the first guest fetch, and gate a one-byte mutation in each region so the image fails closed.
- [ ] (ngold) Run nasm1 over the full src/native/kan16.xa under raw n16i on the native core (oracle count 1,125,205,921 outer steps; measured 621 s end-to-end, 9913/9913 kernel bytes matched) and decide whether the ~10 min full path or the 36 s boot slice is the default n16i proof.
- [ ] (ngold) Make the GOLD producer parallel-safe and deterministic: unique src/prog staging files instead of fixed _xgold_h.nas/_xgold64_h.nas, a QEMU serial lock, and a gate that two concurrent reconstructions are byte-identical.
- [ ] (ngold) Cross-check the boot GOLD with an independent NaN encoder (nasm0 or a table-driven encoder) or a bit-vector equivalence checker so the bytes do not rely on nasm1 plus the optional C oracle.
- [ ] (ngold) Wire source_gold_gate.sh and the native xgold64 rebuild into the product/no-C aggregate so a stale GOLD fails the build, not just a standalone gate.
- [ ] (nmanifest) Replace the embedded-key HMAC tag with a real public-key verifier: implement Ed25519 verification in raw native assembly, root the public key outside the image (boot ROM/TPM/secure variable), and gate an attacker who knows the whole image but cannot re-sign it.
- [ ] (nmanifest) Add a Winternitz/Lamport one-time signature over SHA-256 with a 2-4 KiB manifest region, generate the key pair deterministically offline, keep the secret out of the image, and gate one-byte boot/kernel/guest/manifest/signature mutations plus a forged re-tag.
- [ ] (nmanifest) Add manifest key id, image generation and anti-rollback state: a small allowed-key set, signed key transitions, monotonic generation checks before guest fetch, and a gate that rejects replay of an older valid image and an unknown key id.
- [ ] (nmanifest) Extend the manifest into measured boot: PCR-like extend chain over boot, kernel, guest and service carts, a bounded COM1 event log, and a gate that replays the log to the same root and detects a rollback or out-of-order event.
- [ ] (nmanifest) Replace the flat guest digest with a per-2 MiB-page Merkle tree and verify root plus inclusion proofs lazily before entering each guest page; gate an exact failing-page report and a partial guest fetch that never enters an unverified page.
- [ ] (nkvmerkle) Persist nkvmerkle nodes in a content-addressed store keyed by (hash_lo,hash_hi), hydrate a cold agent by root hash over NVMe/RDMA, and gate exact dedup hits and bytes avoided across a restart.
- [ ] (nkvmerkle) Save root-only checkpoints {DAG root hash, ngen generation, nagent KV root, trace head}, verify page and token proofs without the node registry, replay a branch suffix through the view gate, and gate exact token equality plus old-view divergence at the exact event index.
- [ ] (nkvmerkle) Add cross-node proof assembly: publish a multi-parent root whose parents live on different shards, fetch and verify each shard's chain against the root hash, and gate missing/mutated-shard fail-closed plus a distributed parent-ref count.
- [ ] (nkvmerkle) Attach inclusion proofs to nkvmerkle page/token views and verify them at the view or transport boundary so an untrusted adapter/cache can serve KV; gate a forged page and a forged token rejected before the value is returned.
- [ ] (nkcas) Persist nkcas records on NVMe through nnvme and hydrate by root hash across a cold QEMU restart; gate exact dedup/bytes avoided.
- [ ] (nkcas) Add CAS epoch GC and orphan reclamation with a live-view fence; gate no free of a record visible to a proof or agent view.
- [ ] (nkcas) Add a 4 KiB page-store variant and a 64-bit record index so a TB-scale CAS does not depend on the 48-word fixed record count.
- [ ] (nkcas) Bind nkcas roots to nagent checkpoints and nreplay trace heads; gate restore+hydrate+replay with an exact divergence index.
- [ ] (nots) Replace the development OTS seed with an offline production master and add key-id allow-lists plus signed key rotation; gate unknown-key and rollback rejection.
- [ ] (nots) Add image generation and anti-rollback state before guest fetch; gate replay of an older valid OTS image and an unknown key id.
- [ ] (nots) Extend the manifest guest digest to a per-2 MiB Merkle tree with lazy page verification; gate a failing-page report and no entry into an unverified page.
- [ ] (nots) Add measured-boot PCR/event-log extension over boot, kernel, guest and service carts; gate replay to the same root plus out-of-order/rollback detection.
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
- [ ] Decoded-block cache and native block JIT (build-path threaded cache done, see F18b; product-resident/multi-instruction cache queued).
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
