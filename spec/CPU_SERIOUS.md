# CPU-serious plan: native x86 shim, NaN-native everything else

Status: active. This document is the contract for speed work. It does not
replace `spec/NANVM_SPEC.md`; it fixes *where* each layer lives and which
gates must stay exact.

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
- [ ] Native block chaining for loop back-edges; step budget exact.
- [ ] Baseline NaN->x86 translator for hot blocks, driven by the NaN-native
      translator (`src/translate/x86.nas`) through a single `EXECN` shim.
- [ ] AArch64 backend for the same translator IR.
- [ ] RISC-V backend for the same translator IR.
- [ ] CPU/feature steer: CPUID-driven choice of scalar, SSE2, AVX2, NEON,
      RVV; one semantic path.

The translator itself is NaN. The native core only provides the final
"execute these bytes" primitive and the port shim. This is the line that keeps
the JIT from becoming a second hidden operating system.

### 3.2 New SIMD/AI primitives (native core, specified first)

- [ ] `DP4B d,a,b`: four signed i8 lanes in each payload, dot product to
      int32, exact integer, Z/L flags.
- [ ] `FMA d,a,b`: fused f32 `d = a*b + d`, one rounding, explicitly gated
      against the libm/donut vectors.
- [ ] `DP2H d,a,b`: two f16 lanes, dot to f32 (after DP4B is proven).
- [ ] `CVTPK`: f32 <-> packed f16 lanes.

These are ISA primitives, not a matrix library. A matrix library built on
them stays NaN.

### 3.3 NaN-native runtime

- [ ] `src/lib/narena.nas`: aligned bump arena, mark/release/reset, no
      freelist, for inference activations and KV blocks.
- [ ] `src/lib/nmat.nas`: packed-i8 matmul built on `DP4B`, with tiling and
      a scalar reference in the same file.
- [ ] Aligned C allocation (`aligned_alloc`/`posix_memalign`) in ncc, backed
      by the arena or the S0 allocator.
- [ ] NaN task scheduler: contexts, run queue, yield via a primitive. One
      core first; SMP only when the native APIC/startup shim is real.
- [ ] Huge-page hint and zero-copy model load (`mmap` equivalent) once a
      storage-backed model loader exists.

### 3.4 Proof/bench gates

- `tools/nan_simd.sh`: DP4B vectors, scalar reference, exact output.
- `tools/narena.sh`: alignment, overlap, mark/release, reset, exhaustion.
- `tools/cpu_bench.sh`: one NaN program, measured on the C core and the
  native x86 core; prints guest steps and wall time. Thresholds are recorded,
  not guessed.
- Existing bit-exact gates must stay green after every step.

## 4. Why this order

The native core is the only layer that can make *all* guest code faster, so
decode caching and SIMD primitives come first. The NaN libraries then make the
AI-shaped work fast without moving policy into x86. The translator is last in
this phase because a bad translator is worse than a good interpreter; it is
built behind the same exact gates.

## 5. Non-goals for this phase

- No Python/JS in the runtime.
- No second VM document.
- No GPU claim; the first target is useful CPU tokens/s on one core, then
  multi-core, then optional GPU.
- No "trust the optimizer" shortcut around the exact-math gates.
