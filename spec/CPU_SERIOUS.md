# CPU-serious plan: native x86 shim, NaN-native everything else

Status: active. This document is the contract for speed work. It does not
replace `spec/NANVM_SPEC.md`; it fixes *where* each layer lives and which
gates must stay exact. The sizing/throughput arithmetic is in
`spec/FRONTIER_PERF.md`.

## 1. The split

The product target is bare x86 (BIOS -> protected mode -> NaN16), not v86.
v86/qemu are test harnesses only.

### Must be native x86 (the S1 shim)

These are dictated by the CPU, firmware or the act of fetching a NaN word:

1. Vendor ROM and reset vector.
2. Stage 1 boot sector (raw x86).
3. Real-mode BIOS calls: E820, VBE, INT 13h disk reads.
4. GDT/CR0 setup, protected-mode far jump, A20.
5. IDT entry stubs. A stub may do nothing but forward to a NaN handler.
6. Raw port I/O (`in`/`out`), CPUID, RDTSC, MSR access, MMIO.
7. The NaN16 execution core (fetch/decode/predicate/dispatch). Something
   native must turn NaN words into host actions until NaN16 silicon exists.
8. The boot-time guest loader (ATA read into guest RAM).

Everything in this list is kept small, audited and replaceable per host
(x86, AArch64, RISC-V). No filesystem, allocator, GUI, network protocol or
application logic may land here.

### Must be NaN-native

These have no hardware excuse to be x86:

- PIT/tick accounting and the scheduler policy.
- Keyboard scancode decode, keymap, modifiers, repeat.
- ATA command sequences and IDENTIFY parsing (`src/lib/ata.nas`).
- PCI enumeration and device policy.
- Allocator (`src/prog/nalloc.nas`), arenas, alignment.
- NaNFS / NFS2 filesystem and block allocation.
- Cartridge loader/ABI, TOC, seals.
- NIC logic and the whole NaNNet stack.
- Graphics: framebuffer drawing, NaNGlyph, windows, scaling.
- Apps: Terminal, Monitor, Hex, Settings, NaNNet, utilities.
- All cartridges/exhibits and the micro-transformer.
- Tooling: `nasm0` and the NaN-native translator back ends.

The native core exposes only primitives. A NaN driver reaches hardware with
`INB/INW/OUTB/OUTW/OUTL/OUTSW`, `CPUID`, `RDTSC`, `KEY/KEYQ`, `TICK`,
`VPOKE/VPEEK`, `DISPSET/FBINFO/VSYNC/FBCOPY/FBFILL`. A driver never needs a
new x86 line unless a new *primitive* is missing.

## 2. Performance law

1. **No host C/Python/JS in the execution path.** A native-core JIT or
   translator may emit machine code, but the decision logic and program
   transformation must be NaN where it is not hardware-bound.
2. **Semantics first.** A new op lands in `spec/NANVM_SPEC.md` and
   `aarch64/android/core/OPS.md` before it lands in a core. The C core remains
   a conformance harness, not the definition.
3. **Bit-exactness gates are non-negotiable.** `ncc_libm_exact`,
   `ncc_donut_exact`, M1-M62, `ncc_ctests`, `ncc_torture` and `qgate` define
   "still correct".
4. **Guest code is demand-mapped in the C harness and flat in bare metal.**
   A 100 MB+ C heap and a 1 GiB payload ceiling are already supported.
5. **Decode once.** The native core may cache decoded blocks keyed by PC and
   invalidate only when a guest writes a translated code page.
6. **NaN-native libraries beat generic interpreted C.** Matrix, attention,
   tokenizer and sampling loops get NaN-native kernels; the C compiler calls
   them through documented builtins or the ABI.

## 3. Work items

### 3.1 Native core (allowed to be x86)

- [x] Runtime word count and mask (`mem_size`, CPUID `0x4E4D00FF`).
- [x] Dynamic C address space and 100 MB heap.
- [ ] Decoded block cache: decode once, validate once, execute tokens.
- [ ] Superinstruction fusion in the decoded stream: common
      `LD/ST/LDB/STB` + `ADD/SUB/CMP/JMP` pairs, FMA-shaped float pairs.
- [x] Native vector handlers for the full 0x50-0x5F family. VDP4B and the
      packed VADD8/VSUB8/VADD32/VSUB32/VMUL32 paths use SSE2 (four 128-bit
      chunks); the scalar handlers remain as the fallback tier.
- [ ] AVX2/AVX-512/NEON/RVV lowerings and CPUID feature steer.
- [ ] Native block chaining for loop back-edges; step budget exact.
- [x] Baseline NaN->x86 translator for basic blocks: NaN-native encoders
      in `src/translate/x86.nas`, driver in `src/translate/block.nas`,
      native `CODELEN`/`EXECN` shim. Covers MOVI/MOVHI/ADD/SUB/ADDI/SHL/
      SHR/SAR/CMP/CMPS/LD/ST/LDB/STB and JMP/JMPR/RET block terminators.
      Guest flags live in `FLAGM`; JMP[cond] tests the predicate mask and
      selects target/fallthrough with cmov. Gate `tools/xlate_x86.sh`
      runs ALU, memory, unsigned and signed branch blocks exactly.
- [ ] AArch64 backend for the same translator IR.
- [ ] RISC-V backend for the same translator IR.
- [ ] CPU/feature steer: CPUID-driven choice of scalar, SSE2, AVX2, NEON,
      RVV; one semantic path.

The translator itself is NaN. The native core only provides the final
"execute these bytes" primitive and the port shim. This is the line that keeps
the JIT from becoming a second hidden operating system.

### 3.2 New SIMD/AI primitives (native core, specified first)

- [x] `DP4B d,a,b`: four signed i8 lanes in each payload, dot product to
      int32, exact integer, Z/L flags.
- [x] 512-bit abstract vector family (0x50-0x5F): 16 vector registers,
      VZERO/VBCAST/VLOAD/VSTORE, packed-i8/i32 add/sub/mul, VDP4B (16 lanes,
      64 MACs), VGET/VSET. C reference exact; the full family is exact on
      bare x86, with VDP4B lowered to SSE2. Wider SIMD is the next step.
- [ ] `FMA d,a,b`: fused f32 `d = a*b + d`, one rounding, explicitly gated
      against the libm/donut vectors.
- [ ] `DP2H d,a,b`: two f16 lanes, dot to f32 (after DP4B is proven).
- [ ] `CVTPK`: f32 <-> packed f16 lanes.

These are ISA primitives, not a matrix library. A matrix library built on
them stays NaN.

### 3.3 NaN-native runtime

- [x] `src/lib/narena.nas`: aligned bump arena, mark/release/reset, no
      freelist, for inference activations and KV blocks.
- [x] `src/lib/nmat.nas`: packed-i8 matmul built on `DP4B`, with tiling and
      a scalar reference in the same file.
- [x] Aligned C allocation (`aligned_alloc`) in ncc, backed
      by the S0 allocator.
- [x] `src/lib/narena64.nas`: 64-bit `(lo,hi)` arena, 64-bit mark/release,
      4 GiB-crossing pointer test.
- [x] `src/lib/nten.nas`: 64-bit tensor descriptors and path arithmetic with
      64-bit strides and a 4 GiB crossing.
- [x] `src/lib/nmat.nas` `nmat_dot64`: DP4B into a signed 64-bit accumulator,
      proven past 2^32 and on negative vectors.
- [x] `nmat_i8_64`: 64-bit tensor descriptors, strides and result words for
      the packed-i8 matmul.
- [ ] NaN task scheduler: contexts, run queue, yield via a primitive. One
      core first; SMP only when the native APIC/startup shim is real.
- [ ] Huge-page hint and zero-copy model load (`mmap` equivalent) once a
      storage-backed model loader exists.

### 3.4 Proof/bench gates

- `tools/nan_simd.sh`: DP4B vectors, exact output on C and native x86. Done.
- `tools/nan_vec.sh`: full 512-bit vector family, C reference + native x86. Done.
- `tools/nan_vec_native.sh`: native VZERO/VBCAST/VDP4B/VGET/VSET. Done.
- `tools/ncc_dp4b.sh`: C `dp4b(a,b)` builtin emits 0x4A. Done.
- `tools/nmatmul.sh`: 8x8x8 packed-i8 matmul on DP4B, both cores. Done.
- `tools/narena.sh`: alignment, overlap, mark/release, reset, exhaustion. Done.
- `tools/narena64.sh`: 64-bit arena, high-half base, 4 GiB crossing. Done.
- `tools/nmat64.sh`: DP4B into a 64-bit accumulator past 2^32. Done.
- `tools/nmat64x64.sh`: 64-bit-descriptor matmul, both cores. Done.
- `tools/nten.sh`: 64-bit tensor paths, 64-bit strides, 4 GiB crossing. Done.
- `tools/nten.sh`: 64-bit tensor paths, 64-bit strides, 4 GiB crossing. Done.
- `tools/ncc_aligned.sh`: `aligned_alloc` 16/32/64, writes, free, realloc. Done.
- `tools/cpu_bench.sh`: one NaN program, measured on the C core and the
  native x86 core; prints guest steps and wall time. Thresholds are recorded,
  not guessed. Next.
- Existing bit-exact gates must stay green after every step.

## 4. Why this order

The native core is the only layer that can make *all* guest code faster, so
decode caching and SIMD primitives come first. The NaN libraries then make the
AI-shaped work fast without moving policy into x86. The translator is last in
this phase because a bad translator is worse than a good interpreter; it is
built behind the same exact gates.

## 5. 64-bit sizing law

Frontier inference makes 32-bit sizes a dead end: 7B Q4 weights are about
3.5 GB, 70B Q4 about 35 GB, and KV caches are larger than the weights at long
context. The VM word count may be 2^31+ and a tensor offset can cross 4 GiB.

Rules for every new library/API:

1. A pointer or size is a `(lo,hi)` pair of 32-bit words, low first. Never add
   a new API that takes a bare 32-bit pointer/size as its only form.
2. Dimensions that are structurally small (heads, tiles, kernel K) may be
   32-bit, but **strides, offsets, byte counts and accumulator totals are
   64-bit**.
3. Alignment is in words; 16 words = 64 bytes is the SIMD tile alignment.
4. DP4B returns int32, but reductions accumulate in signed 64-bit. `nmat_dot64`
   is the reference; a 32-bit fast path is allowed only when K is bounded and
   the bound is checked.
5. The C ABI is still 32-bit pointers. That is a declared transition limit,
   not a design choice: `ADDRH`/64-bit indices (NaNVM1 §4.1) must land before
   a C object can exceed the 1 GiB payload window. No new NaN library may
   assume it will stay 32-bit.
6. Weight/KV/activation buffers are 64-byte aligned and tiled. The tile
   descriptors use 64-bit strides.

Sizing sanity (single token, Q4, 4-bit weights, 8-bit activations):

| model | weights | MACs/token | 32-bit-only? |
| --- | --- | --- | --- |
| 1B | ~0.6 GB | ~1e9 | no |
| 7B | ~3.5 GB | ~7e9 | no |
| 70B | ~35 GB | ~7e10 | no |
| 405B | ~200 GB | ~4e11 | no |

DP4B is one four-lane primitive. It is not sufficient by itself for frontier
throughput; the next ISA step is a packed-dot form that consumes more than one
32-bit payload per operand (or a vector register file), and the native core
must execute it as one host SIMD sequence. The 64-bit descriptors and 64-bit
accumulators above are sized for that step now.

## 6. Non-goals for this phase

- No Python/JS in the runtime.
- No second VM document.
- No GPU claim; the first target is useful CPU tokens/s on one core, then
  multi-core, then optional GPU.
- No "trust the optimizer" shortcut around the exact-math gates.
