# NaN/0S memory at scale: Doom/Quake now, 16 GB RAM + 32 GB VRAM for LLM training later (round 33 plan)
## Facts and arithmetic
- 1 NaN word = 8 bytes = 32-bit payload + class nibble in the heads. 16 GB RAM = 2^31 words = 8 GB of payload. 32 GB VRAM = 2^32 words if coded as NaN words (16 GB of payload) or 32 GB if raw.
- A 32-bit register word index reaches 2^32 words (32 GB of word space). RAM fits in it; VRAM does NOT fit beside RAM, so VRAM is reached through windows and bulk DMA, not through ordinary LD/ST.
- fp32 tensors as NaN words waste half the RAM. Pack two bf16/fp16 per payload (SWAR on BOOL/ADD lanes) or keep tensors in raw VRAM windows. Rule of thumb for later: mixed-precision Adam needs about 16-18 bytes per parameter, so 32 GB of VRAM trains on the order of 1-2 billion parameters before activations (estimate, not measured).
## Tension with an earlier decision (owner to confirm)
spec/MEMORY_PLAN.md (round 08) says all memory is NaN words, no raw side-regions. VRAM tensors are raw. Proposal: raw windows are explicit and named (RAWMAP), never reachable by LD/ST/fetch, and every block that crosses between NaN space and a raw window carries the dual-face seal (see INTEGRITY_PLAN.md L4): sealed before DMA out, verified after read back. That turns the double-endian seal into silent-corruption detection for long training runs.
## Milestones
M0 DONE (v32, tested in model + v86): 4M words (32 MB), JMPF/CALLF 24-bit far code, 64 MB v86 RAM. tools/test_far.py, src/tests/far_test.nas -> FKMN.

M1a DONE: high-data `LDS`/`STS` forms address the 0xF0000 compiler scratch window without a 16-bit base register. `nmk.awk` lowers direct `LD/ST rX,r0,#high_symbol` to these forms, so the GUI can use the full 64K code slot while compiler scratch stays outside it.

M1c DONE: control port 0x4E07 relocates the `LDS`/`STS` window; the default remains 0xF0000. The C core, native x86 core, host core and x86_64 S1 all honor it, so compiler scratch can become a per-process mapping without changing `nmk` output.

M1b DONE: the frozen kernel ABI v0.1 is in the product tree. The C core and x86_64 S1 both enforce regions, traps, timers and kernel-only control ports. `kabi_proc_demo.nas` proves a region-isolated process, a `region_map` heap grant backed by nalloc, and fault recovery; `tools/kabi_proc_gate.sh` compares the C and x86_64 transcripts exactly.
M1 (implemented in the current kernel-boot slice): the guest asks MEMQ
(CPUID leaf `0x4E4D00FF`, subleaf 1) for the actual word count, refuses
less than 16M words, widens the boot region table and both process region
tables, and reports the count through the NANIX `mem` command.  The
scheduler block, nanproc table and nanproc variables are placed at the top
of real RAM with guard pages; `NS_BASE`, `NP_BASE` and `NP_VARS` are
runtime configuration words, not link-time constants.  The heap ends just
below them, so RAM size, kernel placement and heap size are decoupled.
`tools/mem_scale_gate.sh` proves 64 MiB and 128 MiB machines return
different counts from the same raw image; the scheduler gate reads the
runtime pointers and verifies PID 1/PID 2 above 268 MB on the 128 MiB
image.  `SVC 2` carves RW regions from the bump heap;
`tools/alloc_scale_gate.sh` allocates 4K and 64 MiB regions.  `execbig 70000` allocates an RWX region,
fills it with valid NOP words, copies a tail that addresses through `r12`,
calls it, and verifies its result, so code larger than the 64K cart slot
runs at a runtime base (`tools/execbig_scale_gate.sh`).  Still open for M1:
a general executable format with code/data relocation tables, a
filesystem-backed loader, and VRAM/DEV windows sized from the real device
BAR rather than a fixed S1 test aperture.

## PAE large-RAM path (separate kernel)

`src/native/kan16_pae.xa` is a separate 32-bit PAE kernel with 2 MiB pages
and a 1 GiB bank window at linear `0x40200000`.  It keeps the MEMMAP direct
map `(physical - G)/8`, so the PCI hole stays a hole.  `pae16_gate.sh`
proves MEMQ/PMEM, every address bank, the bank-0 last word and cross-bank
BCOPY.  Local QEMU results: 7 GiB = 8 banks / 7,165 MiB usable; 16 GiB
demand-paged = 17 banks / 16,381 MiB usable.  The 7 GiB job uses a standard
`ubuntu-latest` runner; the full-resident 16 GiB job is a separate guarded
workflow for a 32 GiB+ host.  The legacy non-PAE kernel remains the v86
path.
M2: x86-64 long-mode kernel (nasm1 gains REX/64-bit encodings), identity-mapped large pages, guest word array above 4 GB, 16 GB = 2^31 words. Register word index stays 32-bit; word index 2^31 and up is reserved.
M3: PCIe enumeration (config space), find the GPU, map its BARs (resizable BAR for a full VRAM aperture), RAWMAP window ops, DMA block copy RAM <-> window with seal-on-transfer.
M4: GPU compute: command submission and kernels emitted from NaN source (a GPU emitter like nasm1 is for x86). Honest risk: this needs a documented GPU ISA and a bring-up path without a vendor driver. AMD publishes ISA documents and has open drivers to read; NVIDIA keeps SASS and firmware closed. Choice of GPU decides feasibility.
## Rules for code written now (so nothing has to be redone)
1. Never hard-code a memory size in guest code: ask the kernel (planned MEMQ op: words of RAM, raw windows present).
2. Addresses are 32-bit word indices; code beyond word 65535 is reached with CALLF/JMPF (24-bit) or CALLR/JMPR (32-bit register).
3. Big cartridges run in place at their load address; store a 32-bit load address and entry in the TOC (reserved words 10-15), never assume the slot at 4096.
4. Every bulk block that leaves or enters NaN space is sealed (dual-face seal) and verified.
5. Allocators (nalloc) take a region base+length from MEMQ, not constants.
