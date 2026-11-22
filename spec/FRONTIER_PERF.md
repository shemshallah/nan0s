# Frontier-scale performance model

This is the sizing contract behind `spec/CPU_SERIOUS.md`. It exists so the
next primitive is chosen by arithmetic, not vibes.

## 1. What must fit

Weights, KV cache, activations and the model file are all 64-bit byte counts.
A 32-bit-only design dies at 4 GiB, before a 7B Q4 model finishes loading.

| model | Q4 weights | Q8 weights | KV at 8k ctx (GQA, rough) | KV at 128k ctx |
| --- | --- | --- | --- | --- |
| 1B | ~0.6 GB | ~1.1 GB | <1 GB | a few GB |
| 7B | ~3.5 GB | ~7 GB | ~1-2 GB | ~16-32 GB |
| 70B | ~35 GB | ~70 GB | ~10-20 GB | ~160-320 GB |
| 405B | ~200 GB | ~400 GB | ~50-100 GB | ~0.8-1.6 TB |

The exact KV number depends on layers, KV heads, head dim, dtype and context;
the point is that **it exceeds 32 bits**. Every new descriptor uses `(lo,hi)`
pairs and 64-byte-aligned tiles. `narena64`, `nten`, `nmat_dot64` and
`nmat_i8_64` are the first implementations of that rule.

## 2. Compute arithmetic

One NaN payload is 32 bits. `DP4B` consumes four signed i8 lanes from each
operand and returns one int32 dot: **4 MACs per guest instruction**.

A guest instruction is not free. The native core currently retires roughly
tens of millions of guest instructions per second per core in the bare-metal
harness. Take a deliberately conservative 50M guest ops/s/core:

```text
50M ops/s * 4 MAC/op = 200M MAC/s/core
7B model, one token = 7e9 MAC
7e9 / 2e8 = 35 s/token/core
```

That is not a product. With 8 cores and perfect scaling it is still ~4.4 s.
The gap is not the allocator; it is the execution model.

## 3. The block-packed primitive and the 512-bit vector family

### 3.0 First measured packed-i8 number

`tools/nan_bench.sh` runs identical 1M-iteration loops: `VDP4B` (64 MACs
per instruction, 16 lanes x 4-byte dot) against scalar `DP4B` (4 MACs).
Checksums are exact on the C reference and bare x86. On the qemu guest
clock the native x86 ratio is **7x MAC throughput** (about 13.7M vs
1.7M MAC/s in TCG). This is a relative gate, not a hardware claim: qemu
emulates SSE2 and every guest instruction first goes through the NaN
dispatcher. It does establish the key point numerically: the packed
primitive buys roughly an order of magnitude in MACs per dispatched
instruction before any AVX2/AVX-512 widening. Real-hardware and
AVX2 numbers remain to be measured.

`DP4B` is the scalar seed. `spec/NANVM_SPEC.md` now defines a 512-bit
abstract vector family (0x50-0x5F) with 16 vector registers. `VDP4B` is the
block-packed primitive: each of 16 32-bit lanes holds four i8 values, so one
guest instruction performs **16 dot products = 64 MACs** with no guest
control flow inside the tile. That is exactly the tile width this section
called for; the C core is the reference implementation, and the native x86
backend is the next required match (SSE2/AVX2/AVX-512/NEON/RVV by feature
detect).

The older scalar `DP4B` remains the exact scalar seed and the fallback for
hosts without a vector backend. If a backend cannot lower a vector op, it
must trap, not silently scalarize a different lane order.

The equivalent memory-tile form is:

```text
VDP4B d,a,b
  Vd[i] += dot4(Va[i], Vb[i]) for i in 0..15
```

That is 16 dot products = **64 MACs per guest instruction**, with no NaN
control flow inside the tile. A memory-tile form (`VLOAD` four rows, `VDP4B`,
`VSTORE`) is built from the same primitive. The native core implements `VDP4B` with SSE2:
`pcmpgtb` for the sign mask, `punpcklbw/hbw` to sign-extend bytes to words,
`pmaddwd` for pair sums, and `pshufd`/`paddd` to form the 16 int32 lane
results. The packed `VADD8/VSUB8` (`paddb/psubb`), `VADD32/VSUB32`
(`paddd/psubd`) and `VMUL32` (SSE2 `pmuludq` + shuffle) paths are also
SSE2, four 128-bit chunks per 512-bit register. `VLOAD/VSTORE` gather and
scatter four payload dwords per SSE2 step when the guest address is
aligned and outside the RAW window, with the exact byte loop as fallback. AVX2/AVX-512 can widen the
same lowerings; NEON/RVV use their own dot instructions. The C core remains
the exact reference.

On a host with AVX2 a second form, `DP8X4`, can use 256-bit registers for
128 MACs per instruction. On AArch64 the same IR lowers to `smull`/`sadalp`
or NEON dot-product instructions. On RISC-V it lowers to `vdot` or scalar
fallback. The semantic definition stays int32-exact per DP4B; accumulation
and ordering are defined by the NaN kernel, not by the host.

With 64 MAC/op and the same 50M ops/s, a 7B token is
~2.2 s/core; 8 cores puts it near 0.3 s before memory effects. With `DP8X4`
and AVX2 it enters the sub-second single-core range on a desktop. That is the
first honest "respectable" target: **7B Q4 at <=1 s/token on 8 cores**, then
70B at <=10 s/token with streaming weights.

## 4. Memory path

- Model file: `mmap`/stream, no `fread` copy. Weights are read-only and
  64-byte aligned.
- KV cache: `narena64` slabs, 64-byte aligned, one slab per layer/head group,
  64-bit sizes. Never realloc per token; reset/mark at request boundaries.
- Activations: per-request arena; one reset per token.
- Quantization: store Q4 weights as two 4-bit values per byte, Q8
  activations. `VDP4B` consumes i8 pairs exactly; `VDP4B4` (4-bit weights,
  8-bit activations, 128 MACs/op) is reserved under the `VOP` space and
  lands only after its nibble order and accumulation rules are specified.
  fp8 e4m3/e5m2, f16 and bf16 lane formats are reserved the same way.
- Tensor descriptors: `nten` 64-bit base/strides, 64-byte-aligned tiles.

## 5. Threading

One core is the correctness target. Multi-core is a native shim responsibility
(APIC startup, per-core stacks, atomic ops). The NaN scheduler owns work
placement and tile assignment; the host owns only the reset/IPI mechanics.
Until that shim exists, no claim about multi-core tokens/s is allowed.

## 6. Gates

A performance claim is accepted only when:

1. The same vectors pass on the C core and the native core.
2. The 8x8x8, 64-bit-descriptor and 64-bit-accumulator tests are exact.
3. `ncc_libm_exact`, `ncc_donut_exact`, M1-M62, `ncc_ctests` and `qgate`
   remain green.
4. Wall time is reported with the VM/host/CPU and the exact command.

The next code milestone is `DP4X4` + a 64x64x64 packed-i8 benchmark. Only
then does a 7B token-time projection get printed as a measurement rather than
an estimate.
