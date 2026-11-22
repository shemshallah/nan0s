# NaN/0S Master Tasklist

This is the authoritative work queue. Every item has an acceptance gate. Nothing
is "out of scope"; items are ordered, not dropped.

Status: `[ ]` open, `[~]` in progress, `[x]` done and gated.

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
- [ ] Full NaN-coded 64-bit core: LDN/STW/BSWAPM, BCOPY/BFILL, traps,
      vector families, guest loader and self-hosting.
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
- [x] Vendor TCC at `third_party/tinycc` (commit 5cef7f3, LGPL-2.1).
- [ ] `TCC_TARGET_NAN16`: `nan16-gen.c`, `nan16-link.c`, `nan16-asm.c`,
      `nan16-tok.h`, `nan16-abi.h`.
- [ ] NaN16 output: flat cartridge/executable writer, relocations, sections,
      entry point, symbol table.
- [ ] ABI parity with ncc: args/returns, stack frames, varargs, structs,
      64-bit pairs, f32/f64; bidirectional call tests.
- [ ] VFS and headers for `#include`, source and model/SQLite files.
- [ ] NaN16 `libtcc1` runtime: 64-bit arithmetic, float helpers, alloca,
      setjmp, mem/str primitives.
- [ ] tcc0: host cross-build emits NaN16.
- [ ] tcc1: tcc0 compiles TCC on the VM.
- [ ] tcc2: tcc1 compiles TCC again; tcc1 == tcc2 byte-for-byte fixpoint.
- [ ] SQLite: tcc2 compiles the amalgamation, links the shell, runs a query
      suite (schema, insert, select, join, index, transaction, file reopen).
- [ ] Verified chain: NaN16 binary -> Binary TM -> Minsky UTM -> Coq trace.
- [ ] Compiler-correctness bridge: checked relation from TCC output to the
      executed Binary TM, so "the C you compiled is the code that ran" is an
      artifact.
- [ ] Gates: `tools/tcc_build.sh`, `tools/tcc_selfhost.sh`,
      `tools/tcc_sqlite.sh`, `tools/tcc_verified.sh`, all in presqlite.

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
