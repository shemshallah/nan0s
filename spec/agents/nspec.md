# nspec — F13b deterministic speculative decode with paged-KV rollback

Status: implemented and gated (2026-11-27). Agent slot B8.
Files (all raw NaN product code, zero C):

- `src/lib/nspec.nas` — draft-table stream, exact verifier stream over one
  immutable `nattn` weight root, deterministic accept/reject, `npaged_trim`
  rollback, counters and a hash-chained trace.
- `src/tests/nspec_test.nas` — speculative-vs-plain token/logit equality,
  forced rejection with generation-bump proof, deterministic rerun, and
  direct `npaged_trim` block/boundary/zero coverage.
- `tools/nspec_gate.sh`.
- `src/lib/npaged.nas` gained `npaged_trim` (the only change to an existing
  library; `tools/npaged_gate.sh` was rerun and passes).

No git commit was made. The other agent's `nfabric`/`nnvme` files were not
touched. `nattn.nas`, `nkv.nas`, `nq4.nas`, and `nmodel.nas` were not
modified; their gates were rerun unchanged.

## Layout

One `nattn` cfg (magic/version/dim/Wq/Wk/Wv/Wo/RoPE/scale/RMSNorm) is the
immutable weight root shared by the plain and speculative paths. The draft
stream is a first-order `vocab x vocab` f32 score table (no KV, no attention);
the verifier stream is a real `npaged` context whose records are consumed by
`npaged_attention` (nattn Q4xQ8 attention + RoPE + exact f32 softmax +
RMSNorm + Wo projection).

`nspec` context: 160 caller-supplied words.

```
+0  magic 0x4350534E "NSPC"   +1 version 1
+2  npaged ctx               +3  nattn cfg (weight root)
+4  draft score table        +5  token embedding table (vocab*dim)
+6  vocab 1..64              +7  dim 32..64
+8  draft K 1..8             +9  temperature bits (0 = greedy)
+10 flags (bit0 = force reject the next first draft)
+11 verifier xorshift state  +12 draft xorshift state
+13 prompt length            +14 generated tokens
+15 accepted drafts          +16 rejected drafts
+17 rollbacks                +18 verifier passes
+19 drafts made              +20 speculative steps
+21 trace buffer             +22 trace capacity
+23 trace events             +24 trace head
+25 forced rejections        +26 last token id
+27 reserved
+28 initial verifier seed    +29 initial draft seed
+30..31 reserved
+32..95 current logits       +96..159 scratch logits
```

Init config: 13 words (`magic "NSFC"`, version, vocab, K, temp bits, flags,
verifier seed, draft seed, draft table, token table, trace buffer, trace
capacity, nattn cfg). `nspec_init` rejects a zero table, a bad weight-root
magic/version/dim, or zero Q4/Q8 scales.

Trace events are four words `{kind, a, b, head}` and the head is a 32-bit
xorshift-style hash chain. Kinds: 1 prefill, 2 plain, 3 draft, 4 accept,
5 reject, 6 rollback, 7 verifier emit. When the buffer is full the head still
advances, so a capacity mistake cannot make two different runs compare equal.

`npaged_trim(ctx, count)` is the rollback primitive:

- count <= used; count == used is a no-op; count > used fails closed.
- every live block strictly above the target block releases its storage cap
  and returns its 2 MiB page to `nheap`; `live`/`evicts` are updated.
- if count ends inside the target block, the context generation is bumped,
  the block entry generation is repointed, and every retained record header in
  that block is rewritten to the new generation. Record payloads (`x`, `v`,
  Q4, Q8) are untouched, so attention bits do not change.
- a boundary trim (count on a block edge) frees the higher blocks without
  bumping the now-full target block, keeping its views valid.
- count == 0 frees every live block and restores full capacity; the free loop
  stops at block 0 (the first version underflowed to 0xFFFFFFFF and looped;
  the gate now covers trim-to-zero).

## Algorithm

`nspec_prefill(ctx, xs, count, last_id)` requires a fresh paged context
(`npaged->used == 0`), appends the prompt, computes the last prompt logits,
and resets counters, seeds and the trace head.

`nspec_generate(ctx, tokens_out, logits_out, count)`:

```
out = 0
while out < count:
    i = 0; prev = last_id
    while i < K and out < count:
        pos = prompt + generated_before_call + out
        expected = sample(cur_logits, vocab, temp, verifier_seed)
        draft    = draft_sample(score_row[prev], draft_seed)
        if flags.bit0 and i == 0:
            draft = (expected + 1) % vocab       # forced-rejection diagnostic
            clear flag; forced++
        append draft at pos; attention at pos -> tmp
        if draft == expected:
            record(cur_logits); token_out = draft; cur = tmp
            accepted++; prev = draft; out++; i++
        else:
            reject++; rollback++
            npaged_trim(npaged, pos)             # drop the rejected draft
            record(cur_logits); token_out = expected
            append expected at pos; attention -> cur
            prev = expected; out++
            break                                # the step ends at the mismatch
```

Both paths sample exactly once per output token, from the same logits vector,
with the same temperature and the same verifier xorshift stream. Draft draws
use a separate stream. Positions are `prompt + generated_before_call + out`,
so a generation call may be split into chunks (the test uses 1 + 15 to inspect
the forced step) without reprocessing a position.

`nspec_generate_plain` is the reference path: one `npaged_decode` per token,
the same sampler, the same seed and the same weight root.

The forced-rejection hook is deliberately explicit: it still performs a real
draft-stream draw, appends the wrong token, computes the real verifier logits,
compares, trims the paged KV, and appends the verifier token. It is a
diagnostic to guarantee rollback coverage, not a statistical acceptance
model.

## Exactness argument

1. At the start of every token, the speculative and plain contexts hold the
   same accepted token prefix and the same position.
2. Causal attention at position `p` depends only on records `0..p`; the
   rollback changes only the generation word of records below the accepted
   prefix and drops records at/above it. `npaged_attention` never reads the
   generation word as data.
3. Both paths call the same `ns_sample` on the same logits bits with the same
   seed state, so the verifier token is the same.
4. A draft is accepted only when it equals that verifier token. Accepted
   drafts are therefore plain-decode tokens at the same position; a rejected
   draft is replaced by the same verifier token plain decode would have
   appended.
5. By induction every emitted token id, every recorded pre-sample logits
   vector and the final next-token logits are bit-equal.

The test checks this with `cmpw` over 16 token ids, 16x32 logits and the final
32 logits, not just argmax equality.

## Proof map

| Claim | Test assertion |
|---|---|
| one immutable weight root | one `cfg` pointer in every `nspec` context; `nspec_init` checks its magic/version/dim/scales |
| draft stream is deterministic | seed-1 `ns_xorshift` is pinned to `0x00042021` (same recurrence as `nrng_next`) |
| forced rejection | first speculative step is forced at position 4; stats `rejected=1`, `rollbacks=1`, `verifier_passes=2`, `forced=1` |
| real paged-KV rollback | accepted token 3's generation changes across the forced step; old generation fails `npaged_check`, new generation passes |
| exact token ids | all 16 ids equal plain `npaged_decode` |
| exact logits | all `16*32` pre-sample logits bit-equal; final 32 next-token logits bit-equal |
| non-vacuous oracle | at least one of the 512 speculative logit words is nonzero; every id < vocab |
| accept path | stats `accepted=1` (one natural draft accepted) |
| reject/rollback path | stats `rejected=15`, `rollbacks=15` including the forced step |
| counter identities | `accepted+rejected == generated == 16`; `rollbacks == rejected`; `verifier_passes == generated+rejected == 31`; `drafts == generated`; `steps == 15` |
| trace/head | 63 events; first is prefill; a rollback event (kind 6) is present; head `0xCE24DDA9` |
| deterministic rerun | a fresh context with the same prompt/seed/forced flag reproduces ids, logits, final logits, counters, trace count and head |
| trim multi-block | 10-token context (`blocktok=4`) -> 6: used 6, live 2, evicts 1, token 8 gone, token 5 has a new generation |
| trim boundary | 6 -> 4 frees block 1 (evicts 2) without changing block 0's generation |
| trim fail-closed | trim 7 on a 6-token context returns -1; trim to used is a no-op |
| trim to zero | re-append at 4/5 then trim 0: used 0, live 0, remaining 16, evicts 4 |
| fresh prefill only | `nspec_prefill` rejects a non-empty paged context |

The exact current run reports:

```
prompt=4 generated=16 accepted=1 rejected=15 rollbacks=15 passes=31
drafts=16 steps=15 trace_events=63 head=0xCE24DDA9
vocab=8 K=4 seed_low=0xFF draft_seed_low=0x69 flags=0 forced=1
```

## Exact gate output

```
$ sh tools/nspec_gate.sh
O
nspec: PASS (spec ids/logits == plain, forced reject + paged KV trim rollback, deterministic trace head, npaged_trim block/boundary/zero)
```

`nan_cli` report for the same image:

```
[nan_cli] nan-text: 33397866 steps, rc=3, pc=72235, trap=''
```

## Regressions run

```
$ sh tools/npaged_gate.sh
O
npaged: PASS (2 MiB blocks, stable logical map, prefill+decode == full recompute, remap/generation, pressure/capacity/eviction)

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

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Honest limits

- **No speedup claim.** The draft model is a first-order score table with no
  KV and no attention. In the gate it accepts 1 of 16 drafts (15 rejects,
  including the forced one), so verifier passes exceed generated tokens. The
  prototype proves the correctness and rollback mechanics, not a throughput
  gain.
- Verification is **sequential**, one append + attention per draft. There is
  no batched or tree verifier, no parallel draft streams, and no top-k/top-p
  or nucleus sampling. Sampling is temperature softmax over the first `vocab`
  logits; the gate uses vocab 8 out of a 32-dim head.
- The verifier is one head, one layer, f32 `npaged` records; the existing
  limitations apply: 512-token attention window, page base `hi == 0`, tail
  eviction only, synchronous remap/trim.
- Rollback bumps the tail block's generation and invalidates every view into
  that block, including the accepted prefix in it. It is correct but coarse;
  there is no page sharing, COW branch or refcount, and no background
  migration.
- `nreplay` is not linked: `nreplay.nas` includes `nantrace`/`nanobj`, which
  would duplicate `nanobj` definitions already pulled in by
  `npaged -> nattn -> nkv`. `ns_xorshift` is step-for-step identical to
  `nrng_next`, and the trace head is a local hash chain, not `nr_head`. There
  is no `nagent` checkpoint/fork binding and no budget/deadline accounting.
- Exactness is within this f32 NaN execution path for a fixed prompt/seed and
  the same implementation. It is not a cross-platform FP or a
  statistical-sampling equivalence claim.
- `nspec_prefill` requires a fresh paged context; there is no reset/rewind API
  for reusing a context with a different prompt (the new trim-to-zero
  primitive can free the pages, but the nspec counters are not rewound).
- Only one forced-rejection diagnostic is consumed per flag write; there is
  no adversarial draft corpus or accept-rate distribution test.
- The test image is a synthetic tiny model; no real GGUF/safetensors weights
  are involved in the speculative gate.

## Frontier ideas

1. **Multi-token / tree speculation.** Replace the first-order table with a
   small transformer draft stream sharing the `nattn` weight root, propose a
   tree of K drafts with ancestry, verify the tree in one paged attention pass
   using a per-branch causal mask, and accept the longest root-to-leaf prefix.
   Gate accepted length per verifier pass against the sequential baseline plus
   exact token/logit equality.
2. **Batched verifier pages.** Append all draft candidates to scratch page
   slots, run one `npaged_attention_range`-style pass with branch masks, then
   promote the accepted branch and trim the rest with `npaged_trim`. This
   needs a scratch generation/owner field per token record and an exact
   in-block f32 order proof against the sequential verifier.
3. **KV page sharing and COW branches.** Refcount immutable prefix pages,
   give each draft branch private suffix pages, and publish only the accepted
   branch's pages. Gate parent/child prefix reads plus divergent suffix
   isolation, then tie it to `nagent_fork` and live generations. This turns
   the current coarse generation bump into per-page generation/owner checks.
4. **nagent/nreplay integration and measurement.** Bind the verifier seed,
   trace head and accepted/rejected counters to an agent turn checkpoint,
   replay a speculative step through the nreplay engine (requires an include
   guard or a split `nrng` core), and gate identical heads after restore.
   Add tokens-per-verifier-pass and accepted-length histograms on real weights
   before making any speedup claim.
