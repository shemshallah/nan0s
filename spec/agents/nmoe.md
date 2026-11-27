# nmoe — F13d deterministic MoE routing, expert FFN and placement hints

Status: implemented and gated (2026-11-27). Agent slot A10.

Files (all raw NaN product code, zero C):

- `src/lib/nmoe.nas` — Q4_0 router, stable top-k, selected softmax,
  two-layer Q4_0 expert FFN with ReLU, capacity dispatch, load-balance and
  placement accounting.
- `src/tests/nmoe_test.nas` — hand-built 4-expert / 4-token top-2 MoE with
  exact expected router ids, weights, expert outputs, combined logits and an
  80-word stats block.
- `tools/nmoe_gate.sh`.

No shared library was modified.  `nmodel.nas`, `nq4.nas`, `nkv.nas`,
`nheap.nas`, `nnuma.nas`, `nagent.nas` and the other agent's `noc` files were
not touched.  No git commit was made.  The gate includes the real
`src/lib/nmoe.nas` + `nmodel.nas` + `nq4.nas`; there is no C harness.

## Layout

Model config (24 caller-supplied words):

```
+0  magic 0x454F4D4E ("NMOE" little-endian bytes)  +1 version 1
+2  n_experts 1..8        +3 dim 1..32
+4  topk 1..n_experts     +5 router Q4_0 blocks (n_experts rows)
+6  W1 Q4_0 blocks        +7 W2 Q4_0 blocks
+8  hidden 1..32          +9 current NUMA node
+10 placement table       +11 flags (bit0 = remote placement bias)
+12 remote bias f32 bits  +13 capacity numerator
+14 capacity denominator  +15..23 reserved
```

Every Q4 row is one `nq4` block (32 lanes); rows are zero-padded past
`dim`/`hidden`.  `W1` is `n_experts * hidden` consecutive blocks and `W2`
is `n_experts * dim` consecutive blocks.  A placement entry is two words:
NUMA node id and flags (bit 0 = VRAM-resident hint).

Stats block (80 caller-supplied words):

```
+0 tokens +1 topk +2 capacity +3 n_experts
+4 assign_total +5 accept_total +6 drop_total
+7 tokens_with_a_drop +8 tokens_with_no_expert
+9 local_selected +10 remote_selected
+11 vram_selected +12 dram_selected
+13 max_accept +14 min_accept +15 accept_span
+16 model flags +17 cap_num +18 cap_den +19 remote bias bits
+20..23 reserved
+24..31 expert assign[0..7]     +32..39 expert accept[0..7]
+40..47 expert drop[0..7]       +48..55 expert local[0..7]
+56..63 expert remote[0..7]     +64..71 expert vram[0..7]
+72..79 expert dram[0..7]
```

API:

```
nmoe_init        r1=cfg -> 0/-1
nmoe_router      r1=cfg r2=x r3=logits r4=scores -> 0/-1
nmoe_topk        r1=logits r2=n r3=k r4=ids r5=vals -> 0/-1
nmoe_softmax_sel r1=logits r2=ids r3=k r4=weights -> 0/-1
nmoe_route       r1=cfg r2=x r3=ids r4=weights -> 0/-1
nmoe_expert      r1=cfg r2=expert r3=x r4=out -> 0/-1
nmoe_forward     r1=cfg r2=x rows r3=count r4=out rows r5=stats -> 0/-1
```

Scratch is `0x5900..0x5AFF`, below `nq4` scratch `0x6000` and above
`nmodel` scratch `0x5400`.  `r0=0`, `r13=1`, `r14` grows up, `r15` is the
link register.

## Algorithm

`nmoe_router` copies up to `dim` activation words into a zero-padded 32-word
vector, runs `nmod_gemv_q4` against the router blocks, and emits both the raw
logits and the selection scores.  When config flags bit 0 is set, each remote
NUMA hop subtracts `remote_bias` from the selection score:

```
hops   = abs(placement[e].node - cfg.current_node)
score  = logit - hops * remote_bias
```

The bias is selection-only.  Combine weights are the max-shifted f32 softmax
of the selected **raw** router logits.  This keeps a hardware-placement hint
from silently changing the mixture weights of the experts that were chosen.

`nmoe_topk` is an O(k*n) repeated max scan.  It skips already selected ids and
uses a strict `>` comparison, so equal logits keep the lower expert id.  For
`k=2`, logits `[1,1,1,0]` select `[0,1]`; `[0,2,2,0]` select `[1,2]`.

`nmoe_expert` is a real two-layer FFN, not a single projection:

```
acts[i] = x[i] for i < dim, else 0
h       = nmod_gemv_q4(W1_e, hidden, acts)
h[i]    = max(h[i], 0)                 # ReLU
y       = nmod_gemv_q4(W2_e, dim, h)
```

`nmoe_forward` computes

```
cap = ceil(count * topk * cap_num / (n_experts * cap_den))
```

(`cap_num == 0` means capacity 0).  Tokens are processed in ascending token
order; within a token, selected experts are processed in top-k rank order.
The first `cap` assignments to an expert are accepted.  Later assignments are
dropped, a dropped expert contributes nothing, and surviving weights are not
renormalized.  This is a deliberate first-come-first-served overflow policy:
it is deterministic and makes the drop accounting exact.  A token is counted
in `tokens_with_a_drop` if at least one selected assignment was dropped, and
in `tokens_with_no_expert` if all selected assignments were dropped.

Placement accounting is counted for every selected assignment before the
capacity check: local vs remote node, and VRAM hint vs DRAM.  It is a pure
hint/accounting model; nothing here allocates VRAM or calls `naccel`.

## Gate construction

The test uses four tokens, four experts, `dim=4`, `hidden=4`, one Q4 block per
row, and exact binary-fraction weights.  Router columns for the basis inputs:

```
x=e0 -> logits [2,2,0,0]     x=2e0 -> [4,4,0,0]
x=e1 -> [0,0,2,2]            x=e2  -> [1,1,1,0]
```

Experts:

```
e0: W1=2I, W2=0.5I -> y=x
e1: W1=I,  W2=I    -> y=x
e2: W1=I,  W2=2I   -> y=2x
e3: W1=2I, W2=2I   -> y=4x
```

All Q4 nibbles are hand-built (`0x8889888A` etc.; `0x88` bytes are zero
weights, not zero bytes).  Every product, sum and division in the expected
path is exact in binary32.

Capacity factor 2 gives `cap = ceil(4*2*2/4) = 4`, so all eight assignments
run:

```
token 0 (e0,e1) -> x       token 1 -> 2x
token 2 (e2,e3) -> 3x      token 3 (e0,e1) -> x
```

Capacity factor 1 gives `cap = ceil(8/4) = 2`.  Experts e0/e1 fill on tokens
0 and 1, token 2 still runs e2/e3, and token 3's two assignments are dropped;
token 3's combined output is all zero.  Stats: `assign=8`, `accept=6`,
`drop=2`, `tokens_with_a_drop=1`, `tokens_with_no_expert=1`.

Placement table: e0 node0 DRAM, e1 node1 VRAM, e2 node0 VRAM, e3 node1 DRAM;
current node 0; remote bias 1.0.  Token 3 raw logits `[1,1,1,0]` become
selection scores `[1,0,1,-1]` (e3 is remote too), so the top-2 flips from
`(e0,e1)` to `(e0,e2)`.  The selected raw logits are still both 1.0, so the
weights remain exactly `1/2,1/2`, and the combined output is
`0.5*x + 0.5*2x = 1.5x`.  Placement stats: accept `[3,2,2,1]`,
local/remote `5/3`, VRAM/DRAM `4/4`.

## Exactness argument

1. Q4 dequant is `scale * (nibble-8)`; all gate scales are powers of two and
   all payloads are small integers, so each dequantized weight and every
   `dot32` partial sum is exactly representable in f32.
2. The router and both expert layers call the same `nq4_gemv` path; the
   expected logits are the exact integer-scaled vectors above.
3. Top-k uses a strict `>` scan and skips prior ids, so ties are stable and
   the selected id order is deterministic.
4. The selected softmax is max-shifted; equal selected raw logits give
   `exp(0)=1` twice, sum 2, and exactly 0.5 each.
5. Capacity is computed with integer `DIVU` and a ceiling.  Token order and
   top-k rank order are fixed, so the accept/drop decision is deterministic.
6. The rerun executes `nmoe_forward` again into fresh buffers and compares
   all 16 output words and all 80 stats words bit-for-bit.

## Proof map

| Claim | Test assertion |
|---|---|
| descriptor validation | valid cfg returns 0; bad magic returns -1 |
| raw router logits | t0 `[2,2,0,0]`, t3 `[1,1,1,0]` exact |
| placement score | t3 raw `[1,1,1,0]` -> `[1,0,1,-1]` with bias 1.0 |
| top-2 ids | t0/t1/t3 `[0,1]`, t2 `[2,3]`, placement t3 `[0,2]` |
| exact weights | all selected pairs are `0x3F000000,0x3F000000` |
| stable ties | `[1,1,1,0]` -> `[0,1]`; `[0,2,2,0]` -> `[1,2]` |
| expert FFN | e0/e1 -> `x`, e2 -> `2x`, e3 -> `4x`; e0 on `e1` -> `e1` |
| full capacity | cap 4; 8/8 accepted; outputs `x,2x,3x,x` |
| capacity overflow | cap 2; 6/8 accepted, 2 drops, token 3 output zero |
| load balance | accept `[3,3,1,1]`, span 2 full; `[2,2,1,1]`, span 1 cap1 |
| placement accounting | local/remote 5/3, VRAM/DRAM 4/4 on the placement run |
| placement routing | token 3 flips to `(e0,e2)` and outputs exactly `1.5x` |
| deterministic rerun | 16 output words and 80 stats words bit-equal |
| narrow output | success serial output is exactly one byte `O` |

Exact current run:

```
$ sh tools/nmoe_gate.sh
O
nmoe: PASS (top-2 Q4 router, exact 1/2 weights, 4 expert FFNs, capacity drop/overflow, load+NUMA/VRAM accounting, placement flip, deterministic rerun)
```

Regressions rerun unchanged:

```
$ sh tools/nmodel_gate.sh
O
nmodel: PASS (exact RMSNorm/Q4/Q8 GEMV, tiny-model prompts -> ids 0 and 2, xorshift/top-k sampler)

$ sh tools/nattn_gate.sh
O
nattn: PASS (exact RoPE/softmax, fused Q4xQ8 QK^T == nq4_dot32 oracle, nkv KV token views, 1-layer token gate ids 1/3/2)

$ sh tools/nq4_gate.sh
nq4: PASS (Q4_0/Q8_0 32-weight blocks, 0.5/-0.5/28.0/-1.25/-128.0 exact dots, 2-row GEMV)

$ sh tools/nkv_gate.sh
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Honest limits

- This is a tiny deterministic MoE slice, not a transformer layer.  There is
  no attention, bias term, layer stack, tokenizer or sampling loop here.
- `dim <= 32` and `hidden <= 32`; every Q4 row is one padded 32-lane block.
  A real model needs multiple blocks per row and a Q4/Q8/f16 import path.
- The gate pins exact nonuniform weights only for equal selected logits
  (`1/2,1/2`).  Generic softmax uses `FEXP` and is deterministic, but no
  nonuniform f32 weight vector is pinned to hand constants yet.
- Capacity is first-come-first-served by token order.  There is no
  overflow rerouting to the next expert and no renormalization of the
  surviving weights; both are explicit policy choices, not omissions hidden
  in the accounting.
- Placement is a hint/bias/accounting model only.  No VRAM allocation, DMA,
  NUMA migration, expert residency or `naccel` runtime is involved.
- Experts run sequentially.  There is no expert-parallel scheduling,
  batching, overlap or measured throughput in this gate.
- `count <= 64`, `n_experts <= 8`, `topk <= 8`.  Per-token route traces are
  not stored in the stats block; callers use `nmoe_route` for that.

## Frontier ideas

1. **Expert-parallel dispatch on nansched.**  Give each expert a deterministic
   per-CPU/per-node queue, dispatch token batches with the same stable order,
   and gate CPU0/CPU1 expert work with per-expert accept/drop counters and
   same-node steal policy.  Keep the route result identical to the sequential
   path.
2. **Capacity-aware routing with overflow.**  When an expert is full, try the
   next-ranked expert (or a second-choice table) instead of dropping, then
   gate a no-drop fallback and an explicitly pinned renormalized weight
   vector.  This turns the current accounting policy into a serving policy.
3. **KV-aware expert residency.**  Attach `nkv` slab ids and generation
   checks to expert state, keep hot experts resident across a decode, and
   evict cold experts through `nheap`.  Gate token-by-token continuity after
   an expert eviction/reload.
4. **GGUF MoE import.**  Map GGUF router and expert tensors into the same
   config, convert f16 block scales to f32 once at import, and gate bit-equal
   logits against the hand-built Q4_0 table.  This is the missing bridge from
   the tiny slice to real MoE checkpoints.
