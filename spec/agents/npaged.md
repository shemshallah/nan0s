# npaged — F13a paged KV and incremental prefill/decode

Status: implemented and gated (2026-11-27).  Agent slot B7.
Files (all raw NaN product code, zero C):

- `src/lib/npaged.nas` — per-agent 2 MiB KV blocks over `nheap` + `nkv`,
  stable logical token map, generation-checked records, incremental
  prefill/decode with RoPE, remap, tail eviction, pressure/capacity.
- `src/tests/npaged_test.nas` — paged-vs-full parity, remap/generation,
  pressure/capacity/eviction and fail-closed cases.
- `tools/npaged_gate.sh`.

No git commit was made.  The other agent's `nfabric`/`nnvme` files were not
touched.  `nattn.nas` and `nkv.nas` were **not modified**; both gates were
rerun unchanged.

## Block and record layout

A context owns a caller-supplied block table.  Each live block is one
`nheap` 2 MiB page, wrapped in an `nkv` class-20 storage capability, plus a
generation and a used-token count.

```
npaged context (24 words)
 +0 magic 0x4741504E "NPAG"   +1 version 1
 +2 agent id                  +3 KV generation seed
 +4 nheap ctx                 +5 block table
 +6 table capacity (blocks)   +7 tokens/block
 +8 dim (32..64, /32)         +9 nb = dim/32
 +10 record stride words      +11 used tokens
 +12 token capacity           +13 live blocks
 +14 allocations              +15 generation counter
 +16 pressure threshold %     +17 nheap node
 +18 evictions                +19 remaps
 +20 pressure flag            +21 current pressure %
```

Block table entry (16 words): state, logical block, `(base_lo,base_hi)`,
storage capability, generation, used tokens in block, block bytes.

Token record inside a block, `stride = align8(4 + 2*dim + 14*nb)` words:

```
+0 "NREC"  +1 generation  +2 logical token  +3 flags
+4..                 x   f32 input latent
+4+dim..             v   f32 V projection
+4+2*dim..           q4  dim/32 Q4_0 blocks (5 words each)
...                  q8  dim/32 Q8_0 blocks (9 words each)
```

For `dim=32`, `stride=88` words.  A token's address is
`block.base/4 + slot*stride`; only `tokens_per_block*stride*4` bytes of the
2 MiB page are used, and `npaged_init` rejects a config that exceeds the
page.  Logical `token -> (token/block_tokens, token%block_tokens)` never
changes while the context lives, even across a remap.

`npaged_append` computes `q=Wq*x`, `k=Wk*x`, `v=Wv*x` with the nattn/nq4
kernels, applies RoPE at the caller's position, quantizes Q to Q4_0 and K to
Q8_0, and writes the record.  `npaged_attention` resolves every K/V record
through a fresh `nkv_view_create` rank-1 f32 view plus `nattn_view_ptr`, so
the paged path really consumes paged views, not a shadow contiguous cache.
The record header is checked against the block generation and logical token
on every resolve.

Softmax is a local copy of `nattn_softmax` with a 512-entry window:
`nattn` caps one pass at 8 tokens.  The max/exp/sum/divide order is identical
to `nattn_softmax`, which is why the paged output is bit-equal to a full
`nattn_forward` recompute for the 7- and 4-token gates.

## API

```
npaged_init        r1=ctx r2=nheap ctx r3=table r4=table cap r5=cfg -> 0/-1
npaged_append      r1=ctx r2=x r3=position r4=nattn cfg -> token/-1
npaged_prefill     r1=ctx r2=xs r3=count r4=position0 r5=cfg r6=logits
                   -> last token/-1
npaged_decode      r1=ctx r2=x r3=position r4=cfg r5=logits -> token/-1
npaged_attention   r1=ctx r2=token r3=cfg r4=logits -> 0/-1
npaged_remap       r1=ctx r2=logical block -> new generation / 0
npaged_evict_last  r1=ctx -> 0/-1
npaged_token_word  r1=ctx r2=token -> record word address / 0
npaged_token_gen   r1=ctx r2=token -> generation / 0
npaged_check       r1=ctx r2=token r3=generation -> 1/0
npaged_pressure    r1=ctx -> used*100/capacity, updates the flag
npaged_remaining   r1=ctx -> free token slots / -1
npaged_stats       r1=ctx r2=out(16) -> 0/-1
```

`npaged_remap` allocates a fresh 2 MiB page, copies only the used records,
bumps the context generation, rewrites each copied record generation,
releases the old storage capability, returns the old page to `nheap`, and
repoints the table entry.  `npaged_check` on the old generation then fails
and the new one succeeds.  `npaged_evict_last` truncates the tail block,
releases its page to `nheap`, decrements used/live and bumps the eviction
count; earlier logical tokens are untouched.

## Exact gate output

```
$ sh tools/npaged_gate.sh
O
npaged: PASS (2 MiB blocks, stable logical map, prefill+decode == full recompute, remap/generation, pressure/capacity/eviction)
```

`nan_cli` report for the same image:

```
[nan_cli] nan-text: 11648682 steps, rc=3, pc=70791, trap=''
```

## Proof map

| Claim | Test assertion |
|---|---|
| 2 MiB paged blocks | nheap 2 MiB class, one page per live block; `NP_BLOCK_BYTES 0x200000` |
| stable logical map | tokens 0/1/2 differ by exactly `stride`; token 3 is in a different page; after remap tokens 3/4 still differ by `stride` |
| prefill + incremental decode | 4-token prefill then one-token decode at positions 4,5; 3-token prefill then decode at position 3 |
| exact parity | decoded logits bit-equal to full `nattn_forward` + `nattn_last_logits` for counts 4,5,6,7 and 3,4; argmax equal |
| non-vacuous oracle | at least one of the 32 decoded logits is nonzero |
| direct attention | `npaged_attention` rerun is bit-equal to the decode output |
| RoPE at the new position | decode uses `position=token index`; gate phase 0x63/0x64 |
| remap | block 1 copied to a new page; old generation fails `npaged_check`, new generation passes; next decoded token still matches full recompute |
| pressure | 4/12 = 33% below 40% threshold with flag clear; 7/12 = 58% above; ctx2 4/6 = 66% above |
| capacity | 13th append on a 12-token context returns -1 |
| eviction | tail block returns to nheap, used 12 -> 9, live 4 -> 3, re-append reuses token 9 with a new generation |
| fail-closed | null x, out-of-range token and cfg-dim mismatch return -1 |

## Regressions run

```
$ sh tools/nattn_gate.sh
O
nattn: PASS (exact RoPE/softmax, fused Q4xQ8 QK^T == nq4_dot32 oracle, nkv KV token views, 1-layer token gate ids 1/3/2)

$ sh tools/nkv_gate.sh
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)

$ sh tools/nq4_gate.sh
nq4: PASS (Q4_0/Q8_0 32-weight blocks, 0.5/-0.5/28.0/-1.25/-128.0 exact dots, 2-row GEMV)

$ sh tools/nmodel_gate.sh
O
nmodel: PASS (exact RMSNorm/Q4/Q8 GEMV, tiny-model prompts -> ids 0 and 2, xorshift/top-k sampler)

$ sh tools/nreplay_gate.sh
O

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Honest gaps

- **Speculative decoding was outside F13a.**  F13a was delivered as the
  paged/incremental parity gate; F13b now adds `src/lib/nspec.nas` and the
  `npaged_trim` rollback primitive described at the end of this file.  The
  F13a paged/incremental parity claim is unchanged.
- Decode requires the block base `hi` word to be zero (page below 4 GiB of
  byte address), because `nattn_view_ptr` rejects a high address word.  The
  table stores 64-bit bases and remap preserves them, but a >4 GiB page
  cannot be fed to the current attention view path.
- The attention window is 512 tokens; a longer prompt needs chunked/online
  softmax.  KV capacity can exceed the window, but one `npaged_attention`
  call cannot consume it.
- `npaged_remap` is a synchronous copy.  There is no background migration,
  no pinned/borrowed page, and no overlap with decode.
- Eviction is tail-only.  There is no cold-block scoring, no swap-out to a
  slower tier, and no way to evict a prefix while keeping descendants'
  logical indices readable.
- One head, one layer, f32 V.  Multi-head KV layouts, per-head page tables
  and KV quantization for V are not implemented.
- There is no `nagent` checkpoint/fork binding yet: the context carries an
  agent id and generations, but a fork does not share prefix pages COW.
- `npaged_init` zeroes the caller's table in O(table capacity); there is no
  lazy initialization.

## Frontier ideas

1. **Chunked long-context attention over pages.**  Replace the 512-entry
   score buffer with a two-pass or online-softmax scan over blocks: compute
   each block's max/denominator, rescale the running accumulator by
   `exp(old_max-new_max)`, and keep the exact f32 order within a block.
   Gate a 4k/32k-token synthetic context against a full recompute and add a
   `npaged_attention_range` that skips blocks marked cold.
2. **Speculative decode with paged KV rollback.**  Draft k tokens with a
   small model, verify them in one batched `npaged_attention` pass, accept
   the longest matching prefix, and roll the KV tail back by moving the
   logical `used` pointer and bumping a block generation; rejected draft
   pages stay allocated until the verifier confirms.  Use `nreplay` xorshift
   streams for a fixed seed/prompt and a forced-rejection path; require
   token/logit equality with plain decode.
3. **Prefix sharing and COW fork.**  Let multiple agents reference the same
   immutable page with a refcount and publish a child generation on first
   append; only the divergent suffix gets a new page.  Gate parent/child
   reads plus suffix isolation, then tie it to `nagent_fork`.
4. **Eviction and tiering policy.**  Score pages by recency, attention mass
   and node distance; demote cold pages to a slower nheap class or a
   file-backed swap capability, keep a small hot table, and gate a
   pressure-driven eviction/remap sequence with stable logical indices and
   exact post-remap parity.

## F13b extension: `npaged_trim`

`src/lib/npaged.nas` gained one API, used by `nspec` for speculative KV
rollback:

```
npaged_trim  r1=ctx r2=count -> 0/-1
```

It truncates to `count <= used`.  Every live block strictly above the target
block releases its storage capability and returns its 2 MiB page to `nheap`
(`live--`, `evicts++`).  If `count` ends inside the target block, the context
and block generations are bumped, the block entry is repointed, and the
retained record headers in that block are rewritten; the payload (`x`, `v`,
Q4, Q8) is untouched, so attention bits and logical indices below `count` are
stable.  A boundary trim frees the higher blocks without bumping the full
target block, and `count == 0` frees every live block.  `count > used` fails
closed.  The free loop stops at block 0; an early version underflowed the
block cursor and looped forever on trim-to-zero, which the nspec gate now
covers.

No other `npaged` code changed.  `tools/npaged_gate.sh` still prints:

```
O
npaged: PASS (2 MiB blocks, stable logical map, prefill+decode == full recompute, remap/generation, pressure/capacity/eviction)
```

The speculative and trim-specific proofs are in `spec/agents/nspec.md`.
