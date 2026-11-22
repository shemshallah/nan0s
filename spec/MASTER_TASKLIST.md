# NaN/0S Master Tasklist

This is the authoritative work queue. Every item has an acceptance gate. Nothing
is "out of scope"; items are ordered, not dropped.

Status: `[ ]` open, `[~]` in progress, `[x]` done and gated.

## P0. ISO C parity (language + library + ABI)

### P0.1 Vendored c-testsuite
- [x] 00043 nested named struct definitions (separate nested member arena).
- [ ] 00046 anonymous union/struct members (recursive member lookup).
- [ ] 00078 block-scope function prototype.
- [ ] 00130 pointer-to-array declarator `(*p)[4]`.
- [ ] Add more c-testsuite cases until the vendored set has 0 skips.

### P0.2 Fundamental types and ABI
- [ ] Audit and gate `sizeof(char, short, int, long, long long, float, double,
      long double, void*, size_t, ptrdiff_t, off_t, time_t)`.
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
- [ ] Long-mode boot path: PAE, PML4/PDPT/PD/PT, EFER.LME, CR0.PG, GDT,
      64-bit code/data segments, 64-bit IDT, per-CPU GDT/TSS.
- [ ] qemu-system-x86_64 gate that prints a banner from 64-bit code.
- [ ] Port the NaN16 execution core to 64-bit (`kan64.xa`), preserving exact
      NaN/DP4B/vector semantics.
- [ ] 64-bit native shims for ports, CPUID, RDTSC, MSRs, page tables.

### P0.4.2 Virtual memory
- [ ] 4-level page tables with NX/WP/user bits.
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

## P2. System
- [ ] Filesystem, network stack, GUI, apps, package/tooling.
- [ ] APK/assets and bare-metal image pipeline.
