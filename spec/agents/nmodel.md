# nmodel — F7 model-runtime slice (GGUF, tokenizer, Q4/Q8, sampler)

Status: first real model-runtime slice implemented and gated (2026-11-26).
Agent slot B5.  F7 remains partially open: full attention, safetensors and
direct GGUF-quantized consumption are not in this slice.

## Scope and files

Pure NaN product code, zero C outside `src/tests`:

- `src/lib/ngguf.nas` — GGUF v2/v3 header, metadata kv skipping, tensor
  infos, alignment, 64-bit tensor offsets, zero-copy nkv views.
- `src/lib/ntok.nas` — deterministic byte-level tokenizer with a fixed
  24-merge BPE table, BOS/EOS/UNK ids.
- `src/lib/nmodel.nas` — f32 RMSNorm, Q4_0/Q8_0 GEMV entry points, a local
  xorshift32 sampler, and a tiny embedding -> RMSNorm -> Q4 projection model.
- `src/tests/ngguf_test.nas`, `src/tests/ntok_test.nas`,
  `src/tests/nmodel_test.nas`.
- `tools/ngguf_gate.sh`, `tools/ntok_gate.sh`, `tools/nmodel_gate.sh`.

One pre-existing file changed: `src/lib/nkv.nas` had an off-by-one in the
row-major stride loop (`shape[i+1]` instead of `shape[i]`).  Rank-2 F32/F16
GGUF views need correct strides, so the loop now multiplies by `shape[i]`.
`nkv_gate` and `nq4_gate` were rerun and still pass.  `nq4`, `nagent` and the
other agent's `nreplay` were not touched.

## GGUF import

`ngguf_parse r1=storage cap r2=header r3=tensor table r4=capacity -> 0/-1`.

The image is read through a class-20 byte-addressable storage capability, the
same 8-word contract as `nmem`/`nkv`.  Header/metadata/tensor-infos must live
below 4 GiB (guest `LDB` is 32-bit); tensor absolute offsets, sizes and the
2 TiB storage size are full 64-bit.

Header (24 words):

```
+0 magic 0x47475546 ("GGUF")  +1 version 2/3
+2 tensor_count lo +3 hi      +4 kv_count lo +5 hi
+6 alignment (general.alignment, default 32)
+7 data_off lo +8 hi          +9 tensor table ptr
+10 tensor capacity           +11 parsed tensors
+12 metadata_end lo +13 hi   +14 tensor_info_end lo +15 hi
+16 storage cap +17 base_lo +18 base_hi +19 flags
```

Tensor record (64 words, 5 records used by the test):

```
+0 magic 0x4554474E ("NGTE")  +1 gguf dtype +2 n_dims
+3..18 dims[8] as (lo,hi)
+19 name_len +20 name_off lo +21 hi
+22 rel_off lo +23 hi         +24 abs_off lo +25 hi
+26 size lo +27 hi            +28 element count lo +29 hi
+30 blocks lo +31 hi          +32..55 nkv view (24 words)
```

Supported tensor types: F32 (0), F16 (1), Q4_0 (2), Q8_0 (8).
F32/F16 get typed nkv views (dtype 2/1) with the GGUF shape and corrected
row-major byte strides.  Q4_0/Q8_0 get zero-copy raw `u8` views over their
packed bytes; the record keeps GGUF dtype, element count and 32-weight block
count.  This is deliberately honest: GGUF Q4_0/Q8_0 blocks carry an f16
scale (18/34 bytes), while `nq4.nas` consumes the F6 layout with an f32
scale (20/36 bytes).  Direct GGUF-block consumption therefore needs a
one-time scale conversion pass, which is the next GGUF item.  The model gate
below uses native `nq4` blocks, as specified for the tiny-model path.

Validation: magic, version 2/3, counts, key/value bounds, all GGUF scalar
value types, strings, arrays (including string arrays), alignment power of
two, tensor name length, 1..4 dims, positive dims, supported dtype, 64-bit
offsets, 64-bit alignment, 64-bit overflow/wrap rejection, data-section
bounds and tensor-table capacity.

The test image uses a 2 TiB storage cap at byte base 0x18000.  The last Q8
tensor has rel offset 0xFFFFFD80 and abs offset 0xFFFFFFE0; its 68-byte range
ends at 0x100000024, i.e. it crosses 4 GiB.  Another Q8 view is placed so its
element 32 is exactly 4 GiB (`lo=0, hi=1`).  Rejection cases: bad magic, bad
version, tensor count over capacity, kv count over 4096, non-power-of-two
alignment, unsupported dtype, misaligned tensor offset, truncated 300-byte
storage and a too-small tensor table.

## Tokenizer

Ids: `0..255` byte, `256` BOS, `257` EOS, `258..281` 24 merges, `282` UNK,
`283` vocabulary size.  Encoding starts from one token per byte and merges
the adjacent pair with the lowest table rank (leftmost on ties), so it is
order-deterministic.  Merge-table rows are `left, right, new_id`; rank is the
row index.  Decoding recursively expands merged tokens; BOS/EOS emit no
bytes, UNK emits `?`, invalid ids return `-1`.

Exact test encodings:

```
"hello"      -> [266]
"the theory" -> [262, 261, 111, 114, 121]
"banana"     -> [98, 267, 267, 97]
"is an and"  -> [279, 280, 276]
```

Round-trips cover ASCII, NUL plus `\xFF\x80`, and all 256 byte values.
Every byte is in-vocabulary; UNK is only reachable as an explicit id.

## Model, RMSNorm, GEMV, sampler

Model descriptor (16 words):

```
+0 0x4E4D4F44 ("NMOD") +1 version 1 +2 vocab +3 dim
+4 embedding ptr (f32 words) +5 norm weight ptr +6 Q4 output blocks
+7 rows +8 eps bits +9 flags +10..15 reserved
```

`nmod_forward` averages prompt-token embeddings (deterministic bag of
tokens; **no attention in this slice**), RMSNorm with `sqrt(mean(x*x)+eps)`,
then one Q4_0 GEMV over 32-element blocks.  The test uses dim 4, vocab 4,
eps 0 and exact binary fractions.  Embeddings, norm weights and packed Q4
nibbles are hand-built; `0x88` bytes are zero weights (nibble 8), not zero
bytes.

Exact path:

```
prompt [1,2] -> ctx [2,2,2,2] -> norm [0.5,0.25,0.125,0.0625]
             -> logits [1.625, 1.0, -0.5, 0.0625] -> next id 0
prompt [0]   -> ctx [-2,-2,-2,-2] -> norm [-0.5,-0.25,-0.125,-0.0625]
             -> logits [-1.625, -1.0, 0.5, -0.0625] -> next id 2
```

Logits are compared bit-for-bit (`0x3FD00000`, `0x3F800000`, `0xBF000000`,
`0x3D800000`; negatives analogous).  The sampler:

- `nmod_argmax` uses `FCMP` and keeps the first index on ties.
- `nmod_sample` selects top-k by repeated max with an O(k*n) scan, then
  computes `exp((logit-max)/temp)` with `FEXP`.  Temperature 0 is greedy and
  leaves the seed unchanged.
- xorshift32 uses `BOOL.6` (XOR truth table) for `x ^= x<<13; x ^= x>>17;
  x ^= x<<5`.  Seed 0 maps to 0x12345678.
- The threshold uses the top 24 bits of the next state divided by 2^24, so
  no 32-bit float conversion saturation is involved.

Exact sampler checks: seed 1 -> next 0x00042021 (picks the first of two
equal candidates); seed 0x12345678 -> next 0x87985AA5 (picks the second);
same seed twice gives identical pick and next seed; top-k=1 always returns
the argmax; a dominant logit always wins.

## Proof map

| Claim | Test assertion |
|---|---|
| GGUF v3 header/counts | header magic/version=3/tensors=5/kv=9 |
| metadata skip | meta_end=357, align=32, info_end=data_off=608 |
| tensor names | byte comparison at name offsets 365/422/475/517/566 |
| F32 rank-2 view | dtype 2, shape [4,4], count 16, strides 16/4 bytes |
| Q4_0 view | raw u8, 72 bytes, 4 blocks, abs 672 |
| F16 view | dtype 1, count 8, size 16, abs 736 |
| Q8 range crosses 4 GiB | abs 0xFFFFFFE0 + 68 = 0x100000024 |
| view element at 4 GiB | `nkv_view_addr(...,32)` -> lo=0, hi=1 |
| rejection | nine mutation/limits cases all return -1 |
| BPE determinism | exact id arrays above |
| byte coverage | all 256 bytes encode/decode identically |
| specials | BOS/EOS skipped, UNK -> `?`, id 999 -> -1 |
| RMSNorm | four exact output words |
| Q4/Q8 GEMV | [1.625,1,-0.5,0.0625] and 1.0 exact |
| tiny model | prompts -> ids 0 and 2, exact logits, rerun identical |
| sampler | seed/next-seed/top-k exactness and reproducibility |

## Exact gate output

```
$ sh tools/ngguf_gate.sh
O
ngguf: PASS (GGUF v3 header/metadata/tensor infos, F32/F16/Q4_0/Q8_0 views, 4 GiB-crossing range, reject cases)

$ sh tools/ntok_gate.sh
O
ntok: PASS (24-merge deterministic BPE, exact ids, all-256-byte round-trip, BOS/EOS/UNK)

$ sh tools/nmodel_gate.sh
O
nmodel: PASS (exact RMSNorm/Q4/Q8 GEMV, tiny-model prompts -> ids 0 and 2, xorshift/top-k sampler)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nkv_gate.sh
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)

$ sh tools/nq4_gate.sh
nq4: PASS (Q4_0/Q8_0 32-weight blocks, 0.5/-0.5/28.0/-1.25/-128.0 exact dots, 2-row GEMV)

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)
```

## Honest gaps

- No attention in the tiny model.  The token gate proves the
  embedding/RMSNorm/GEMV/sampler path, not a transformer.
- GGUF Q4_0/Q8_0 are zero-copy raw byte views; nq4 needs the f32-scale F6
  block layout, so a GGUF block scale conversion is not yet implemented.
- The GGUF header must be addressable below 4 GiB.  Tensor offsets/sizes are
  64-bit and the data range can cross 4 GiB.
- No safetensors importer yet.
- Sampler supports temperature, top-k and greedy; top-p/repetition penalty
  are not in this slice.

## Frontier ideas

1. **GGUF mmap/streaming**: back storage caps with read-only file/ATA/stream
   objects, fault in 2 MiB pages, convert f16 block scales to f32 on first
   touch, and let `nq4` consume mapped blocks without a full copy.  Keep the
   64-bit tensor range rule and measure tokens/s against resident weights.
2. **Q4-fused attention**: compute QK^T directly from packed Q4 nibbles with
   `VDP4B4`/`DP4B`, apply the block scale once, and compare bit-for-bit with
   an `nq4_dot32` oracle over a two-block vector.  Feed KV through `nkv`
   token views so the attention kernel never expands weights.
3. **Paged KV decode**: use `nkv` 2 MiB slabs and the 64-bit block table,
   evict cold blocks to `nheap`, remap logical token ranges, and gate a
   decode that walks pages with stable logical indices.  Tie the KV
   generation to `nagent` checkpoint/fork for branch-safe prefixes.
4. **Speculative decoding**: a small draft model and a verifier share an
   immutable weight root; per-agent xorshift streams and trace hashes make
   accepted/rejected proposals reproducible.  Gate acceptance, rollback of
   the KV generation, and identical output for the same seed and prompt.
