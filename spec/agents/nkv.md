# nkv — F6 zero-copy 64-bit tensor views, per-agent KV slabs, packed Q4/Q8

Status: implemented and gated (2026-11-26).  Agent slot B4.

## Scope

F6: tensor/KV memory for TB-scale agents.  The new pure-NaN libraries add:

- a metadata-only 64-bit tensor view over a storage capability, with
  `(offset_lo,offset_hi)`, byte size, shape, 64-bit element strides, element
  count and an owner/generation pair; a view can straddle 4 GiB and a 2 TiB
  capability is an ordinary input;
- a per-agent KV slab capability with agent id, generation, node, dtype,
  layers/heads/dim, bytes/token, capacity, used count, a 64-bit block table
  and a class-20 storage capability allocated from `nheap` (1 GiB and 2 MiB
  page classes are exercised);
- append-token, append-N, read-token and token-view paths, all returning or
  consuming 64-bit byte offsets; two agents get isolated slabs and isolated
  generation counters;
- packed Q4_0 and Q8_0 blocks (32 weights/block) with exact f32 dequant,
  single-block dot and 2-row GEMV.

No pre-existing product file was modified.  `nantensor.nas` and `nten.nas`
were not rewritten; `nkv` is a separate layer whose storage caps use the same
class-20 8-word payload as `nmem`.

## Files

- `src/lib/nkv.nas` — views, class-20 storage helpers, KV slab descriptor,
  block table, token paths, generation checks.
- `src/lib/nq4.nas` — Q4_0/Q8_0 block layout, dequant, dot32, GEMV.
- `src/tests/nkv_test.nas` — 2 TiB view + two-agent KV proof.
- `src/tests/nq4_test.nas` — exact Q4/Q8 dequant/dot/GEMV proof.
- `tools/nkv_gate.sh`, `tools/nq4_gate.sh` — emit + run + exact `O` marker.

`nkv.nas` includes `nanobj.nas` and `nheap.nas` (which includes `n64.nas`).
It embeds small class-20 create/info helpers instead of including `nmem.nas`:
both `nmem.nas` and `nheap.nas` inline `n64.nas`, and `nmk.awk` has no include
guard, so including both would duplicate every `n64_*` label.  The embedded
helpers use the exact `nmem` payload contract (`base_lo,base_hi,size_lo,
size_hi,rights,node,flags,class=20`), so either kind of cap is accepted by
`nkv_storage_info`.

## Layouts (guest words)

### Tensor view (24 words, caller-supplied)

```
+0  magic 0x4E4B5657 ("NKVW")     +1 version 1
+2  dtype (0 u8, 1 f16, 2 f32)   +3 rank 1..3   +4 flags
+5  storage capability
+6  off_lo   +7 off_hi            byte offset inside storage
+8  size_lo  +9 size_hi           view byte length
+10 count_lo +11 count_hi         product of shape[]
+12 shape[0] +13 shape[1] +14 shape[2] +15 shape[3]
+16 stride0_lo +17 stride0_hi
+18 stride1_lo +19 stride1_hi
+20 stride2_lo +21 stride2_hi
+22 generation  +23 owner cap
```

Creation validates the storage cap (read right, class 20), checks
`off + size <= storage.size` as a 64-bit pair, requires `1 <= rank <= 3`,
computes strides backwards from the last axis and `count = prod(shape)`, and
requires `count * elem_bytes <= size`.  It writes metadata only; the storage
bytes are never copied or renumbered.

### KV slab (class 21, 24-word capability payload)

```
+0  magic 0x4E4B5653 ("NKVS")     +1 version 1
+2  agent id                      +3 KV generation
+4  node                          +5 dtype
+6  layers +7 heads +8 dim
+9  bytes/token lo +10 hi
+11 capacity tokens               +12 used tokens
+13 block_tokens                  +14 block_count +15 block_cap
+16 block table word address
+17 base storage capability
+18 base_off_lo +19 base_off_hi
+20 allocation bytes lo +21 hi
+22 page class (0 4K, 1 2M, 2 1G)
+23 flags
```

Block table entry (8 words):

```
+0 token_start +1 token_count +2 byte_off_lo +3 byte_off_hi
+4 flags +5..7 reserved
```

Token address:

```
base_cap.base + base_off + block.byte_off
  + (token - block.token_start) * bytes_per_token
```

The block table is built at create time by splitting capacity into
`block_tokens` ranges and accumulating the 64-bit byte offset with
`n64_mul32`/`n64_add`.  The backing is one `nheap_alloc` of
`pages * page_class_size`; the slab stores a class-20 capability over the
whole allocation.  `nkv_slab_append_n` reserves token slots and advances
`used`; data movement is the caller's job through the returned
`(base_cap, 64-bit offset)`, so the library itself is zero-copy.

The caller fills a 16-word config:

```
+0 agent +1 generation +2 node +3 dtype +4 layers +5 heads +6 dim
+7 bytes/token lo +8 hi +9 capacity tokens +10 block_tokens
+11 page class +12 pages lo +13 pages hi +14 flags +15 reserved
```

API: `nkv_storage_create/info`, `nkv_view_create`, `nkv_view_addr`,
`nkv_slab_create`, `nkv_slab_info`, `nkv_slab_append`, `nkv_slab_append_n`,
`nkv_slab_used`, `nkv_slab_capacity`, `nkv_slab_regen`,
`nkv_slab_token_off`, `nkv_slab_token_addr`, `nkv_slab_read_token`,
`nkv_slab_token_view`, `nkv_view_check`.

`nkv_slab_token_view` creates a 1-D view over one token (offset = block byte
offset + token-in-block * bytes/token), stamps the slab generation and owner
cap, and `nkv_view_check` returns 1 only while both still match.

## Q4_0 / Q8_0 layout

The gate uses a word-aligned variant with an f32 scale.  llama.cpp's on-disk
Q4_0/Q8_0 use a 2-byte f16 scale; the NaN path has native f32 but no f16
conversion opcode.  Converting one f16 scale per block at import rounds once,
before any dot, and leaves the payload and reduction exact.  The gate is
deliberately built so the dequant/dot values are hand-computable:

```
Q4_0 block: 5 words
  word 0      f32 scale
  words 1..4  16 packed bytes (4 bytes/word, LE)
              byte j low nibble  = q[j]     (value - 8)
              byte j high nibble = q[16+j]  (value - 8)
  dequant = scale * (nibble - 8)

Q8_0 block: 9 words
  word 0      f32 scale
  words 1..8  32 signed bytes (4 bytes/word, LE)
  dequant = scale * int8
```

Blocks advance by 5 or 9 words.  Activations are f32 bits, one word each.
The dots reduce in element order with `FADD`, so the bit patterns are fixed.

## Proof map

### 2 TiB views across 4 GiB

A class-20 storage cap is created with base 0 and size 2 TiB
(`size_hi = 512`).  Four views are created:

- `view0`: whole 2 TiB, u8, shape 1; fields `off=0`, `size=(0,512)`,
  `count=1`, `stride0=1`; element 0 maps to address 0.
- `view1`: offset `4 GiB - 32 = (0xFFFFFFE0,0)`, size 64, f32, shape 16.
  Element 8 maps to exactly `0x1_00000000` (`addr_lo=0`, `addr_hi=1`);
  element 7 maps to `0xFFFFFFFC` (`hi=0`); element 16 is rejected (`r3=-1`).
- `view2`: offset 1 TiB `(0,256)`, size 64; element 15 maps to
  `1 TiB + 60` with `hi=256`.
- `view3`: offset `(0xFFFFFFE0,511)`, size 64 — end is 32 bytes past 2 TiB,
  so creation returns `-1`.

Storage metadata is re-read after view creation and is unchanged: base 0,
size 2 TiB.  No storage word is touched.

### Per-agent KV isolation

Slab A: agent 7, generation 1, node 0, f16, 2 layers x 4 heads x 8 dim,
256 bytes/token, capacity 8, 2-token blocks, one **1 GiB page** from
`nheap`.

- backing base is exactly 4 GiB (`0x1_00000000`), allocation 1 GiB;
- block table offsets are 0, 512, 1024, 1536;
- append 1 + append 7 -> used 8; the 9th append and any append-N past
  capacity return `-1`;
- token 2 reads `addr = 0x1_00000200`, len 256, gen 1, agent 7;
- token 7 reads `addr = 0x1_00000700`, len 256;
- token 8 (not appended) is rejected;
- token view of token 2 has offset 512, size 256, count 128 f16 elements,
  stride 2, gen 1, owner = slab A; element 64 maps to `0x1_00000280`;
- regen bumps A to generation 2: the old view check returns 0, a new token
  view has gen 2 and checks 1.

Slab B: agent 9, generation 5, node 1, 64 bytes/token, capacity 4,
1-token blocks, one **2 MiB page** from `nheap`.

- backing base is 6 GiB (`0x1_80000000`), allocation 2 MiB;
- block offsets are 0, 64, 128, 192;
- append 2 -> used 2; token 1 reads `addr = 0x1_80000040`, len 64,
  gen 5, agent 9; token 2 is rejected before it is appended;
- regen bumps B to 6; B's view checks 1 against B, 0 against A; A's view
  checks 1 against A, 0 against B;
- B is filled to capacity 4; the 5th append fails; A remains at used 8,
  generation 2.  The two slabs have different caps, agents, nodes, bases
  and generations.

`nheap_stats` after both creates shows node 0 with 7 free 1 GiB pages and
node 1 with 511 free 2 MiB pages, proving one huge page per slab was taken
from the allocator, not a fake contiguous range.

### Exact Q4/Q8 values

Q4 block A: scale 0.5, only `q[0]=1`, `q[16]=-1`.

- `nq4_dequant(0) = 0.5 = 0x3F000000`
- `nq4_dequant(16) = -0.5 = 0xBF000000`
- `nq4_dequant(15) = nq4_dequant(31) = 0x00000000`
- activations `a[0]=1`, `a[16]=2`: dot `= 0.5 + (-1.0) = -0.5 = 0xBF000000`

Q4 block B: scale 1.0, only `q[31]=7`; `a[31]=4`:
dot `= 28.0 = 0x41E00000`.

Q8 block A: scale 0.25, `q[0]=3`, `q[31]=-2`.

- `nq8_dequant(0) = 0.75 = 0x3F400000`
- `nq8_dequant(31) = -0.5 = 0xBF000000`
- dot with `a[0]=1`, `a[31]=4`: `0.75 - 2.0 = -1.25 = 0xBFA00000`

Q8 block B: scale 1.0, `q[0]=-128`:
`nq8_dequant(0) = -128.0 = 0xC3000000`; dot `= 0xC3000000`.

Both 2-row GEMVs emit the same two values per format:
Q4 `[-0.5, 28.0]`; Q8 `[-1.25, -128.0]`.

All weights are small integers, scales are exact powers of two, and
activations are 1/2/4, so every product and partial sum is exactly
representable in f32; the expected bit patterns are deterministic.

## Gate transcript

```
$ sh tools/nkv_gate.sh
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)
$ sh tools/nq4_gate.sh
nq4: PASS (Q4_0/Q8_0 32-weight blocks, 0.5/-0.5/28.0/-1.25/-128.0 exact dots, 2-row GEMV)
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)
$ sh tools/nmem_scale_gate.sh
nmem_scale: PASS (2 TiB object, 1 TiB 64-bit view, bounds/rights/node)
```

Each guest image emits exactly `O` on serial.  The KV gate runs 38,060 guest
steps; the Q4 gate runs 17,262; reruns produce the same marker, step count
and PC.  No shared library, `nantensor.nas`, `nten.nas` or the other agent's
`nagent` files were modified.

## Frontier ideas

1. **Paged KV.**  The block table is already a page directory keyed by token
   range with 64-bit byte offsets.  Extend it with per-block availability and
   allocate 2 MiB pages on append, evict cold blocks back to `nheap`, and gate
   an allocation/eviction/remap sequence where a token keeps its logical
   index but changes physical block.  A hierarchical table (root, mid, leaf)
   avoids growing a flat table for 1M-token contexts.
2. **Shared-prefix KV.**  A forked agent should map the shared prompt blocks
   read-only and copy-on-write only the divergent suffix.  The existing
   `(base_cap, generation, owner)` triple can represent a prefix chain:
   token views carry the slab generation, and a fork publishes a new
   generation while keeping immutable prefix caps shared.  Gate a fork where
   two agents read the same prefix address and the child's new token does
   not appear in the parent.
3. **Fused Q4 attention.**  Consume the packed block directly in QK^T:
   accumulate `nibble * activation` in integer lanes (nibbles are -8..7),
   apply the block scale once, and use `DP4B`/`VDP4B4` for four bytes at a
   time.  This removes the per-element dequant array and keeps the exact
   integer reduction; compare against the current dequant-then-dot path for
   every block in the gate.
4. **Zero-copy GGUF mmap.**  Make a model file range a read-only class-20
   storage cap backed by the native mmap path, then build `nkv` views with
   dtype/shape/strides from GGUF tensor info.  Q4/Q8 tensor data can be
   passed directly to `nq4_*`, so loading a model is metadata + page-table
   work, not a copy; gate a tensor whose byte range crosses 4 GiB.
