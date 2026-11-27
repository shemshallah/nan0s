# nattn — F7b attention, GGUF f16 scales, safetensors

Status: implemented and gated (2026-11-26).  Agent slot B6.
Files (all raw NaN product code, zero C):

- `src/lib/nattn.nas` — one-head causal attention over nkv token views,
  RoPE, exact f32 softmax, fused Q4_0 x Q8_0 QK^T, Q4/Q8 quantize and
  matvec, residual RMSNorm + output projection.
- `src/tests/nattn_test.nas` — differential and exact attention gate.
- `tools/nattn_gate.sh`.
- `src/lib/nsafetensors.nas` — safetensors u64 + JSON header parser,
  zero-copy nkv views.
- `src/tests/nsafetensors_test.nas`, `tools/nsafetensors_gate.sh`.
- `src/tests/ngguf_scale_test.nas`,
  `tools/ngguf_scale_gate.sh` — GGUF Q4_0/Q8_0 f16-scale consumption.
- Modified: `src/lib/nq4.nas` (f16 API wrapper), `src/lib/ngguf.nas`
  (block repack), `src/lib/n64.nas` (shared `n64_f16_to_f32`).

No git commit was made.  The other agent's `nsecure`/`naccel`/`niommu`
files were not touched.

## Attention layout

`nattn` consumes one rank-1 f32 nkv view per token.  Each token view holds
`3*dim` f32 words:

```
+0..dim-1       x    input latent
+dim..2dim-1    v    V projection
+2dim..3dim-1   ctx  attention context
```

Q and K are not kept as f32.  They are RoPE-rotated, quantized, and stored in
caller buffers:

```
Q cache: n_tokens * nblocks * 5 words   (Q4_0, q4scale)
K cache: n_tokens * nblocks * 9 words   (Q8_0, q8scale)
nblocks = dim/32
```

The test creates a real `nkv` slab (`nkv_slab_create`, f32, 384 bytes/token,
4 tokens, 2-token blocks) and obtains the views with
`nkv_slab_token_view`, so views carry slab owner and generation words.
`nattn_view_ptr` re-checks the view magic/version/dtype/rank, requires the
first element below 4 GiB and a 4-byte-aligned byte offset, then returns a
guest word address.

Config (32 words):

```
+0 0x5454414E "NATT"  +1 version 1
+2 n_tokens (1..8)    +3 dim (32 or 64)
+4 flags (bit0 RoPE)  +5 Wq Q4_0 blocks
+6 Wk Q8_0 blocks     +7 Wv Q4_0 blocks
+8 Wo Q4_0 blocks     +9 RoPE cos/sin table
+10 attention scale   +11 RMSNorm weight
+12 eps bits          +13 Q4 cache
+14 Q8 cache          +15 Q4 quant scale
+16 Q8 quant scale
```

API:

```
nattn_view_ptr    r1=view -> word address / 0
nattn_rope        r1=vec r2=table r3=pos r4=pairs -> 0/-1
nattn_softmax     r1=scores r2=n r3=out -> 0/-1
nattn_qk_fused    r1=q4blocks r2=q8blocks r3=nblocks -> f32 bits
nattn_quant_q4/8  r1=src r2=dst r3=cols r4=scale -> 0/-1
nattn_matvec_q4/8 r1=w r2=rows r3=cols r4=x r5=out -> 0/-1
nattn_forward     r1=cfg r2=views -> 0/-1
nattn_last_logits r1=cfg r2=views r3=logits -> 0/-1
```

RoPE: `y0 = x0*c - x1*s`, `y1 = x0*s + x1*c` for pair `i` at `vec[2i]`;
the table is `table[(pos*pairs+i)*2] = cos, +1 = sin`.  NaNVM1 has no
FSIN/FCOS, so the table is precomputed by the caller (the same contract as
llama.cpp's precomputed RoPE tables).  The rotation itself is exact f32.

Softmax: max-shifted `exp((s-max)/1)`, sum, divide, all f32 with FEXP.
Equal scores give exact `1/n`; a >=104 gap makes the loser `exp()` underflow
to zero, so the winner is exactly 1.

QK^T fusion: for each 32-weight block the kernel walks Q4 nibbles and Q8
signed bytes, accumulates the integer dot, converts it once, and multiplies
by `scale4*scale8` once.  With power-of-two block scales and small payloads
every intermediate is exact in binary32, so the result is bit-identical to
the `nq4_dot32` oracle (which dequantizes Q8 into f32 acts and calls
`nq4_dot32`).  The gate asserts equality for one and two blocks.

Quantization is truncating (`CVTFI(src/scale)`, clamped to `[-8,7]` or
`[-128,127]`).  The gate values are integers, so quantization is exact and
the attention scores are exactly 508/0/-508 in the token gate.

## Exact attention gate

Uniform attention (`Wq = 0`) on token embeddings `[e0,e1,e2,e2]`, dim 32,
Wv = I, scale 0.25, RoPE enabled:

```
t0 ctx = [1, 0, ...]
t1 ctx = [1/2, 1/2, 0, ...]
t2 ctx = [1/3, 1/3, 1/3, 0, ...]        (1/3 = 0x3EAAAAAB)
t3 ctx = [1/4, 1/4, 1/2, 0, ...]
```

The contexts are compared bit-for-bit.  `nattn_last_logits` then computes
`Wo * RMSNorm(x[t3]+ctx[t3])` and the argmax is id 2.

The 1-layer token gate uses `Wq = I`, `Wk = 127I`, `Wv = I`, scale 4.0,
dim 32, RoPE.  For token `t` the self score is `4*127 = 508`; any
off-diagonal score is 0 or -508.  `exp(-508)` is 0 in binary32, so the
softmax is exactly one-hot on the token itself.  The output projection rows
map the last position to:

```
prompt [0]    -> id 1
prompt [0,1]  -> id 3
prompt [0,2]  -> id 2
```

All three ids are checked, and a rerun of the same prompt produces four
identical logits.

RoPE is also checked directly: pos 0 table `[1,0, 0.5,0.25]` maps
`[1,2,3,4]` to `[1,2,0.5,2.75]`; pos 1 table `[0,1, -1,0]` maps it to
`[-2,1,-3,-4]`, all exact.

Softmax is checked for four equal scores (exact 1/4), two equal (1/2),
three equal (1/3), a one-hot gap (exact 1/0/0), and a generic 3-way case
(strict order plus sum within 1e-6).  Generic exponentials are not
bit-gated because `expf` is not a binary fraction.

## GGUF f16 block scales

GGUF Q4_0/Q8_0 blocks carry an f16 scale and a packed payload (18/34 bytes).
`nq4` blocks use an f32 scale and word-aligned payload (20/36 bytes).
`ngguf_blocks_to_nq4` is the documented one-time conversion:

1. check tensor magic, dtype Q4_0/Q8_0, 32-bit block count, destination
   capacity, default view magic;
2. resolve the tensor's nkv view with `nkv_view_addr`; a base >=4 GiB or an
   end that leaves 32-bit addressability returns -2 (distinct from -1);
3. for each block read the little-endian f16 scale through LDB, convert it
   exactly with `n64_f16_to_f32` (normals, subnormals, +-0, Inf, NaN);
4. copy the 16/32 payload bytes unchanged into the nq4 word layout;
5. return the block count.

The scale is not consumed in place because the block stride changes
18->20 / 34->36 bytes.  The conversion is once per first touch; after that
`nq8_gemv`/`nq4_gemv` run over the converted blocks.

The gate builds a real minimal GGUF v3 image (two tensors, alignment 32,
data at 96) and proves exact values:

```
q8 block: f16 scale 0.5, q[0]=2, q[31]=-3, acts[0]=1, acts[31]=2
          -> dot = 1 - 3 = -2.0 (0xC0000000)
q4 block: f16 scale 0.5, q[0]=+1, q[16]=+1, acts[0]=1, acts[16]=3
          -> dot = 0.5 + 1.5 = 2.0 (0x40000000)
```

The exact conversion cases:

```
0x3C00 -> 0x3F800000   1.0
0x3800 -> 0x3F000000   0.5
0xBC00 -> 0xBF800000  -1.0
0x0001 -> 0x33800000   2^-24
0x03FF -> 0x387FC000   1023*2^-24
0x0000 -> 0x00000000   +0
0x8000 -> 0x80000000   -0
0x7C00 -> 0x7F800000   +Inf
0xFC00 -> 0xFF800000   -Inf
0x7E00 -> 0x7FC00000   NaN
```

Range proof: an nkv view over a 2 TiB cap with base `0xFFFF_FF00` and offset
`0xF0` has its first byte at `0xFFFF_FFF0`; a 34-byte Q8 block would end at
`0x1_0000_0012`, so the converter returns -2 before any load.  A view whose
base is exactly 4 GiB also returns -2.  Bad magic/dtype/blocks/capacity
return -1.

## safetensors

`nsafetensors_parse r1=storage cap r2=header(16) r3=table r4=max` returns
0/-1.  The header is a u64 little-endian length followed by JSON; data
starts at `8+len`.  The parser is a real minimal JSON parser:

- strings (with backslash escapes), nested objects/arrays, unsigned
  numbers, and true/false/null literals;
- unknown keys are skipped; `__metadata__` is skipped as a value;
- `dtype`, `shape`, `data_offsets` are required and validated;
- rank 1..4, dims > 0, `begin <= end`, `count*elem == size`;
- absolute range `8+len+begin .. +size` is 64-bit checked against storage;
- each tensor gets a zero-copy nkv view (F32->2, F16->1, U8/I8->0).

Tensor record (48 words):

```
+0 magic 0x5454534E  +1 dtype  +2 rank  +3..6 shape
+7 begin lo/hi +9 end lo/hi +11 abs lo/hi +13 size lo/hi
+15 count lo/hi +17 name_len +18 name_off(absolute) lo/hi
+20..43 nkv view +44 flags
```

The test header is 200 bytes:

```
{"__metadata__":{"format":"pt"},
 "a":{"dtype":"F32","shape":[2,2],"data_offsets":[0,16]},
 "b":{"dtype":"F16","shape":[4],"data_offsets":[16,24]},
 "c":{"dtype":"U8","shape":[3],"data_offsets":[24,27]}}
```

Data at 208: `a` = f32 1,2,3,4; `b` = f16 0.5,-1,2,0
(bytes `00 38 00 BC 00 40 00 00`); `c` = `AA BB CC`.  The gate checks all
record fields, names `a`/`b`/`c`, the view dtype/count/offset, element 0 and
3 of `a` through `nkv_view_addr`, the first f16 byte, and all three U8
bytes.

Rejection cases all return -1: bad JSON start, unsupported dtype, zero dim,
non-numeric dim, missing shape key, `begin > end`, size mismatch, data past
storage, more tensors than table capacity, zero header length, header length
over 1 MiB, and truncated storage.

## Exact gate output

```
$ sh tools/nattn_gate.sh
O
nattn: PASS (exact RoPE/softmax, fused Q4xQ8 QK^T == nq4_dot32 oracle, nkv KV token views, 1-layer token gate ids 1/3/2)

$ sh tools/ngguf_scale_gate.sh
O
ngguf_scale: PASS (exact f16->f32, Q4/Q8 GGUF block repack to nq4, GEMV -2.0/2.0, 4 GiB view rejected -2)

$ sh tools/nsafetensors_gate.sh
O
nsafetensors: PASS (u64+JSON header, __metadata__, F32/F16/U8 nkv views, 12 reject cases)

$ sh tools/nq4_gate.sh
nq4: PASS (Q4_0/Q8_0 32-weight blocks, 0.5/-0.5/28.0/-1.25/-128.0 exact dots, 2-row GEMV)

$ sh tools/ngguf_gate.sh
O
ngguf: PASS (GGUF v3 header/metadata/tensor infos, F32/F16/Q4_0/Q8_0 views, 4 GiB-crossing range, reject cases)

$ sh tools/nkv_gate.sh
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)

$ sh tools/ntok_gate.sh
O
ntok: PASS (24-merge deterministic BPE, exact ids, all-256-byte round-trip, BOS/EOS/UNK)

$ sh tools/nmodel_gate.sh
O
nmodel: PASS (exact RMSNorm/Q4/Q8 GEMV, tiny-model prompts -> ids 0 and 2, xorshift/top-k sampler)

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Proof map

| Claim | Test assertion |
|---|---|
| RoPE exact | `[1,2,3,4]` -> `[1,2,0.5,2.75]` and `[-2,1,-3,-4]` bits |
| softmax exact uniform | 4 equal -> 0x3E800000; 3 -> 0x3EAAAAAB; 2 -> 0x3F000000 |
| softmax one-hot | gap -1000 -> 1,0,0 |
| fused QK == oracle | two 32-weight blocks, bit equality |
| quant round-trip | Q4/Q8 dequant of 1,-1,2 exact |
| matvec | Q4 identity over 32 cols; Q8 127I; 64-col two-block dot = 64.0 |
| nkv token views | slab create/append/token_view, 4 views, count 96 |
| uniform attention | exact contexts 1, 1/2, 1/3, 1/4 |
| token gate | ids 1, 3, 2 for prompts [0], [0,1], [0,2] |
| determinism | rerun logits bit-equal |
| f16 exact | 10 values incl. subnormal/Inf/NaN |
| GGUF block repack | scale 0x3F000000, payload words unchanged |
| GGUF GEMV | -2.0 and 2.0 exact |
| 4 GiB block | -2 return, no wrapped load |
| safetensors records | 3 tensors, exact fields/names/views |
| safetensors rejects | 12 mutation/limit cases |

## Honest gaps

- One head, one layer; `dim` is 32 or 64 and `n_tokens` <= 8.  There is no
  batched/padded attention, no multi-head split, and no KV-cache decode loop
  (the slab is sized for it, but `nattn_forward` re-projects every token each
  call).
- Q/K quantization truncates rather than round-to-nearest and uses one
  caller-supplied scale per vector buffer (not per block).  The gate uses
  integer values so this is exact; real weights will see quantisation error.
- Softmax is exact only for the uniform/one-hot cases.  Generic `FEXP`
  results are checked for order and normalization to 1e-6, not bit-for-bit.
- RoPE needs a precomputed table; there is no FSIN/FCOS in NaNVM1.
- GGUF Q4/Q8 consumption requires a repack pass; there is no in-place
  f16-scale access and no mmap/fault path.  Tensor data at or above 4 GiB is
  rejected with -2 because guest `LDB` is 32-bit.
- safetensors supports only F32/F16/U8/I8; BF16/F64/int types and the
  F8 formats are rejected.  Duplicate names, overlapping data ranges and the
  `__metadata__` schema are not validated.  The JSON header must be below
  4 GiB; tensor data may cross 4 GiB.
- `nattn` includes `nkv` and therefore reserves `nkv` scratch (`0x5000`) and
  its own scratch (`0x5600`); images that include it must place code above
  the scratch (the gate uses `0x10000`).

## Frontier ideas

1. **Fused multi-head Q4 attention with VDP4B4/DP4B**: keep Q/K in packed
   Q4/Q8 blocks, compute two heads per vector pass with the 512-bit vector
   registers, and fold the `scale4*scale8*softmax_scale` into one multiply.
   Gate against the `nq4_dot32` oracle on a four-block vector and measure
   tokens/s versus the scalar fused kernel.
2. **Paged KV decode**: use `nkv` 2 MiB slabs and the 64-bit block table for
   logical token pages, remap prefix pages on fork, and add a decode step
   that only appends K/V for the new token.  Tie the slab generation to
   `nagent` checkpoint/fork so a branch cannot read a stale page.
3. **Speculative decoding**: a draft model and verifier share an immutable
   weight root; the verifier accepts a prefix and rolls back KV to the
   accepted token.  Use per-agent xorshift streams and trace hashes so
   accepted/rejected proposals are reproducible for a fixed seed.
4. **On-the-fly RoPE**: replace the table with a CORDIC/series sine-cosine
   kernel evaluated in f32 at each position, and gate the table and computed
   paths to a documented ulp bound.  This removes the per-position table
   memory at the cost of a few dozen FP ops per pair.
