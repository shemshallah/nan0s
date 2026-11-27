# nspectree — F13c tree speculation + batched paged verifier

Status: implemented and gated (2026-11-27). Agent slot A9.
Files (all raw NaN product code, zero C):

- `src/lib/nspectree.nas` — depth-2 / two-root / two-child draft tree over
  one shared `nattn` weight root, per-candidate ordered causal masks,
  branch/owner tags in the paged record headers, one batched verifier call
  over all six candidates, longest root-to-leaf accept, accepted-branch
  promotion/relocation, `npaged_trim` release of every other candidate,
  free-token fallback, counters and a hash-chained trace.
- `src/tests/nspectree_test.nas` — tree-vs-plain bit equality, generation
  bump/boundary stability, alternate-root relocation, partial accept,
  full no-root fallback, deterministic rerun, fail-closed API checks.
- `tools/nspectree_gate.sh`.

No shared library was modified. In particular `nspec.nas`, `npaged.nas`,
`nattn.nas`, `nkv.nas` and `nq4.nas` are unchanged; their gates were rerun.
No git commit was made. The other agent's `nverify` files were not touched.

## Layout

`nspectree` includes `nspec.nas` (the sampler and xorshift are reused
step-for-step) and therefore `npaged -> nattn -> nkv -> nanobj/nheap`.
The caller supplies a 768-word context:

```
+0  magic 0x5254534E "NSTR"  +1 version 1
+2  npaged ctx               +3  nattn cfg (immutable weight root)
+4  token table              +5  draft score table
+6  vocab 1..64              +7  dim 32..64
+8  verifier seed            +9  initial verifier seed
+10 draft seed               +11 initial draft seed
+12 temperature bits         +13 flags
+14 prompt length            +15 generated tokens
+16 accepted nodes           +17 rejected nodes
+18 trimmed nodes            +19 verifier passes
+20 tree steps               +21 drafts made
+22 trace buffer             +23 trace capacity
+24 trace events             +25 trace head
+26 last token               +27 depth (2)
+28 branch factor (2)        +29 promotions
+30 accepted-path generation +31 forced corrections
+32 last accepted length     +33 tree prefix
+40..103  current logits (64)       +104..167 scratch logits (64)
+168..551 candidate logits (6x64)
+552..623 candidate metadata (6x12)
+624..719 per-candidate causal masks (6x16)
```

Candidate metadata: `token, parent, depth, record logical token,
generation-before-trim, record tag, accepted, RoPE position, reserved`.
A mask entry is `{length, ancestor logical tokens in increasing order}`.
The six candidates are ordered DFS:

```
c0 root A at prefix     c1 child A0 at prefix+1   c2 child A1 at prefix+1
c3 root B at prefix     c4 child B0 at prefix+1   c5 child B1 at prefix+1
```

Masks are exactly the prefix `0..prefix-1` followed by the branch's parent
record and then the candidate record, so a depth-1 mask is
`[0..prefix-1, root]` and a depth-2 mask is
`[0..prefix-1, root, child]`. The record flags word of every candidate is
overwritten with `0x4E540000 | (candidate+1)`; the accepted slots keep their
tag after promotion, and rejected records disappear with the trim.

## Algorithm

```
nspectree_generate(ctx, tok, log, count):
  count must be positive and even; one tree step emits exactly two
  plain-decode tokens.
  repeat count/2 times:
    nt_build:
      e1 = sample(cur)
      root A / root B from the draft table (or diagnostic anchors)
      append c0; optionally probe c0 and sample e2; append c1,c2
      append c3; optionally probe c3 and sample e2; append c4,c5
      fill each candidate mask and tag
    nt_verify: one call over i=0..5 -> nt_attn_mask(ctx, i, cand_logits[i])
    nt_accept:
      find a root equal to e1; else trim all six and fall back
      e2 = probe sample or sample(root logits)
      find a child of that root equal to e2 -> accept length 2 else 1
      relocate the accepted path to the front if it is not already c0/c1
      npaged_trim(prefix + accept_len)
      emit two tokens; if accept_len==1 append e2 as the free verifier
      token; if accept_len==0 append e1 then sample/append e2
```

`nt_attn_mask` is the verifier: it resolves the candidate query record and
each ancestor record directly through `np_record`, computes
`nattn_qk_fused(q4_t, q8_s) * scale` in mask order, runs the same
`np_softmax` order as `npaged_attention`, accumulates `v[s] * w[s]` in the
same s-then-d order, then applies the same `nat_rmsnorm` + `nattn_matvec_q4`
(Wo) tail. The only difference from `npaged_attention` is the ordered
ancestor set instead of `0..token`.

Diagnostic flags (explicit correctness harness, not an acceptance model):

- bit0: root A and child A0 are anchored to the verifier's own samples, so
  the primary branch is a guaranteed depth-2 accept.
- bit1: root A is deliberately one past the verifier sample and root B is
  the verifier sample; the accepted B branch is relocated to the prefix.
- bit2: with bit0, child A0 is deliberately wrong; the step accepts depth 1
  and appends the verifier's free token.
- bit3: both roots are deliberately wrong; the step accepts nothing and
  falls back to two sequential verifier appends.

The anchor child is obtained by a draft-time root probe (`nt_probe`). The
probe recomputes one candidate's masked logits to choose the draft; it is
not counted as a verifier pass. The real batched verifier then recomputes
every candidate, including that root.

## Exactness argument

1. For the accepted path, the mask is `0,1,...,p` and the record payloads
   are the same token embeddings at the same RoPE positions as plain decode.
   `nt_attn_mask` performs the same operations in the same order as
   `npaged_attention` at token `p`, so each accepted logits vector is
   bit-equal.
2. Both tree and plain paths call the same `ns_sample` on the same logits
   bits with the same verifier xorshift stream. A tree step draws e1 and e2
   exactly once, just as plain decode draws two tokens; the probe sample is
   reused, not redrawn. A depth-1 accept appends the already-sampled e2 as
   the free token; a depth-0 accept samples and appends e2 after e1.
3. Rejected candidates never appear on the accepted mask, and
   `npaged_trim` leaves the accepted payloads untouched (only the generation
   header of the target block changes). The next step therefore starts from
   exactly the plain prefix and the same logits.
4. By induction every emitted token id, every pre-sample logits vector and
   the final next-token logits are bit-equal to plain `npaged_decode`.

The test compares 4 token ids, 4x32 pre-sample logits and the final 32
next-token logits with `cmpw`, not just argmax. It also checks that the
accepted records' generations change across an in-block trim and stay stable
across a boundary trim.

## Proof map

| Claim | Test assertion |
|---|---|
| one immutable weight root | one `cfgNatt` pointer in every nspectree context; init checks magic/version/dim/scales |
| six-candidate tree | stats `drafts=6` per step; candidate table has two roots and four children |
| per-branch masks | `nspectree_mask_len` / `nspectree_mask`: c0 `[0,1,2,3,4]`, c1 `[0,1,2,3,4,5]`, c3 `[0,1,2,3,7]`, c2 `[...4,6]`, c4 `[...7,8]`, c5 `[...7,9]` |
| branch/owner tags | `nspectree_branch_gen` and candidate tags; promoted record flags equal the accepted candidate tags |
| one batched verifier | stats `passes=1` per tree step and `drafts=6`; `NT_E_VERIFY` records `(6,pass)` |
| longest root-to-leaf | primary step accepts c0->c1 (length 2); alt mode accepts c3->c4 (length 2); partial mode accepts c0 only (length 1) |
| promote accepted branch | c0/c1 stay at prefix; c3/c4 are relocated from logical 7/8 to 4/5 and keep their tags |
| trim the rest | `trimmed=8` after two primary steps; stale generations fail `npaged_check`; rejected logical slots return 0 |
| exact token ids | 4 ids equal plain `nspectree_generate_plain` |
| exact logits | 4x32 pre-sample logits equal; final 32 next-token logits equal |
| in-block generation bump | step-1 c0/c1 gen=2 before trim; promoted gen=4; old gen fails `npaged_check`, new passes |
| boundary generation stability | step-2 c0 gen-before=4 equals promoted token-6 gen=4 |
| partial accept | flags 5: `accepted=1, rejected=5, trimmed=5, promotions=1, last_len=1`; ids/logits/cur equal plain |
| no-root fallback | flags 8: `accepted=0, rejected=6, trimmed=6, promotions=0, last_len=0`; ids/logits/cur equal plain |
| deterministic rerun | fresh context reproduces ids, logits, cur, accepted/rejected/trimmed/passes/steps/drafts/promotions/last_len/trace count/head |
| non-vacuous | every id < vocab; logits words are nonzero |
| fail-closed | odd `count` rejected; prefill on a non-empty paged ctx rejected; mask index past length rejected |

Exact primary run:

```
prompt=4 generated=4 accepted=4 rejected=8 trimmed=8
passes=2 steps=2 drafts=12 trace_events=35 head=0x3445AF60
vocab=8 dim=32 seed=0x1255994F draft_seed=0xC5186E29 flags=1 forced=0
promotions=2 accepted_gen=4 last_len=2 np_used=8
tokens=0,6,0,6  (plain 0,6,0,6)
```

Exact zero-root run (final scratch context):

```
prompt=4 generated=2 accepted=0 rejected=6 trimmed=6
passes=1 steps=1 drafts=6 trace_events=17 head=0xD8E31579
vocab=8 dim=32 seed=0x04080601 draft_seed=0x81B3AC98 flags=8 forced=3
promotions=0 accepted_gen=0 last_len=0 np_used=6
tokens=0,6  (plain 0,6)
```

## Exact gate output

```
$ sh tools/nspectree_gate.sh
O
nspectree: PASS (6-candidate depth-2 tree, per-branch masks, one batched paged verifier, longest-branch promote + npaged_trim, tree ids/logits == plain, alt/partial/zero-root paths, deterministic rerun)
```

The same image runs about 23.4M NaN steps and exits cleanly with the exact
one-byte marker `O`.

## Regressions run

```
$ sh tools/nspec_gate.sh
O
nspec: PASS (spec ids/logits == plain, forced reject + paged KV trim rollback, deterministic trace head, npaged_trim block/boundary/zero)

$ sh tools/npaged_gate.sh
O
npaged: PASS (2 MiB blocks, stable logical map, prefill+decode == full recompute, remap/generation, pressure/capacity/eviction)

$ sh tools/nattn_gate.sh
O
nattn: PASS (exact RoPE/softmax, fused Q4xQ8 QK^T == nq4_dot32 oracle, nkv KV token views, 1-layer token gate ids 1/3/2)

$ sh tools/nkv_gate.sh
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)

$ sh tools/nreplay_gate.sh
O

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Honest limits

- **No speedup claim.** The best case is two accepted tokens per tree step,
  but each step appends six candidates, runs six masked attention passes and
  one draft probe. The gate is a correctness/rollback proof, not a throughput
  result. Tokens-per-verifier-pass is 2 per step in the anchored gate and 0
  in the forced-fallback step.
- **"Batched" means one verifier call over all six candidates, not one
  fused kernel.** `nt_verify` invokes `nt_attn_mask` per candidate serially;
  there is no packed Q-row batch, no shared K/V fetch across candidates and
  no SIMD/parallel verifier. The per-candidate K/V walk is the honest
  bottleneck.
- **The draft model is a first-order table.** It has no KV, no attention and
  no tree distribution. The anchor/probe modes are correctness diagnostics
  (like `nspec`'s forced rejection), not an accept-rate model. The natural
  no-anchor mode is not the gated path.
- **The probe is an extra attention computation** used only to choose the
  anchored child. It is not counted as a verifier pass and is not part of a
  real draft model.
- **Relocation is a payload copy inside paged pages**, not COW or page
  sharing. The alternate root is copied from its DFS slot to the prefix, then
  trimmed. There are no refcounted shared prefix pages, no per-page
  generation/owner object and no `nagent_fork` binding.
- **The generation bump is coarse.** An in-block trim bumps the whole target
  block and rewrites every retained header; every view into the block is
  invalidated, including the accepted prefix. A freed scratch block also
  advances the context generation, so the accepted records can jump from
  gen 2 to gen 4 rather than 2 to 3. Boundary trims do not bump.
- **Fixed tree shape.** Depth 2, two roots, two children per root, at most 16
  mask entries. There is no variable-depth/top-k/top-p tree and no
  accepted-length histogram on real weights.
- **One head, one layer, dim 32, vocab 8 in the gate**, with the inherited
  `npaged` 512-token attention window and below-4-GiB view base.
- **`nreplay` is not linked.** `nspec`/`nspectree` reproduce the `nrng_next`
  xorshift and a local hash chain, but there is no `nagent` checkpoint/fork
  binding, no budget/deadline accounting and no `nr_head` equality claim.
- **Exactness is within this f32 NaN execution path** for a fixed
  prompt/seed and the same implementation. It is not a cross-platform FP or a
  statistical-sampling equivalence claim.
- **Even-count API.** `nspectree_generate` emits two tokens per step and
  rejects an odd count. The fallback paths make every step exactly two plain
  tokens, but the caller cannot ask for a single token from this entry point.

## Frontier ideas

1. **True batched tree attention.** Pack the six candidate Q rows and their
   masks into one kernel: one K/V fetch per distinct ancestor, masked score
   blocks, one shared softmax schedule, then measure tokens per verifier pass
   and bytes fetched per accepted token against the sequential verifier.
2. **COW/refcounted branch pages.** Make prefix pages read-only shared
   objects with refcounts, give each branch private suffix pages, and publish
   only the accepted branch's page set. This removes the payload relocation,
   makes the generation bump per-page instead of per-block, and ties into
   `nagent_fork` / live generations.
3. **Variable-depth top-k draft tree.** Replace the fixed 2x2 tree with a
   top-k draft distribution, per-node masks of arbitrary width, a
   longest-path accept and an accepted-length histogram. Gate the same exact
   token/logit equality and report tokens per verifier pass on real weights.
4. **nagent/nreplay turn binding.** Bind the verifier seed, trace head,
   accepted/rejected/trimmed counters and promoted generations to an agent
   turn checkpoint, replay the speculative suffix through the nreplay engine,
   and gate identical heads after restore.
