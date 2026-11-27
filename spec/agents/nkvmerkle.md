# nkvmerkle — Merkle multi-parent prefix DAG, root-only inclusion proofs (F13j)

## Delivered

- `src/lib/nkvmerkle.nas` — pure NaN Merkle multi-parent prefix DAG with
  generation-tagged node hashes, dedup, refcounts, private COW suffixes and
  self-contained inclusion proofs.
- `src/tests/nkvmerkle_test.nas` — four-agent, P/Q-prefix, multi-parent merge,
  mutation, COW and both-close-order gate image.
- `tools/nkvmerkle_gate.sh` — gate: `nmk` emit/check plus two cold
  `nan_cli` runs, exact one-byte `O`, structural and regression checks.

No C was added outside `src/tests`; no C at all is linked in this gate.
`src/lib/nkvdag.nas`, `src/lib/nkvgen.nas` and `src/lib/nkvtree.nas` are
untouched. `nkvdag` was sufficient as a predecessor; no extension was needed.

## Layout

Node registry: 64 nodes × 56 words at `0x360000`; stats 64 words at
`0x363000`; trace 128 × 8 words at `0x363200`; DFS scratch
`0x362000..0x36206F`; `ngen` scratch `0x30000..0x3005F`.

A public Merkle node:

```
 0 magic "NKMN"      1 version 1       2 kind (1 public, 2 private)
 3 refs              4 state (1 live)  5 flags (1 public)
 6 hash_lo           7 hash_hi         8 used words   9 slots (16)
10 payload base     11 dedup hits     12 allocations  13 joins
14 leaves           15 frees          16 headers      17 generation tag
18 owner agent      19 parent count
20..23 parent node indices (ordered)
24..27 parent hash lo (ordered)
28..31 parent hash hi (ordered)
32 node index       33 child refs held 34 proofs served
35 COW copies caused 36 tokens copied  37 lookups      38 hits
39..55 reserved
```

A branch context is 32 words: `ngen` agent/generation/epoch, `nagent` id,
an 8-word/entry page table, token counts, branch counters, root hash, root
index, sealed flag and view counters. A table entry is
`{node index, map generation, flags, content hash lo/hi, node index copy}`;
empty slots use `0xFFFFFFFF` because node index 0 is valid.

Private nodes are COW suffix pages. They are not in the content index and have
no node hash until seal. They are owned by exactly one branch generation and
cannot be read or written by another generation. Every public node owns one
reference to each parent; every page-table entry owns one reference to its
node. The last release frees the node and recursively releases its parents, so
closing the last branch of a merged DAG frees the whole graph exactly once. A
join acquires every node on a single-parent prefix chain. A multi-parent root
is deliberately rejected by `nkm_join` (`EBAD`); it is still a fully verifiable
proof root.

## Node hash

Two 32-bit lanes are seeded with `NKM_SEED_LO = 0x4E4B4D48` and
`NKM_SEED_HI = 0x4D45524B`. Each lane is mixed, in this exact order, with:

1. domain constant `NKM_DOMAIN = 0x4E4B4D44`;
2. used count;
3. generation tag;
4. parent count;
5. for each parent in order, parent hash lo into the lo lane and parent hash
   hi into the hi lane;
6. for each used content word, the word into both lanes;
7. final salt `NKM_SALT = 0x4B564D52` into both lanes.

The mix is XOR, add `0x9E3779B9`, xor-shift 16, multiply `0x85EBCA6B`,
xor-shift 15, multiply `0xC2B2AE35`, xor-shift 16, modulo 2^32. Only used
content words are committed; unused payload slots are not part of identity.
`nkm_hash(values, used, gen, parent_indices, count)` recomputes the same hash
from branch-visible fields; the gate checks P0 (no parent) and Q1 (parent P0)
reproduce their stored hashes.

Because the generation tag is committed, identical content at different
generations is deliberately a different identity and does not dedup. Q0 dedups
P0 in the gate because both branches are at generation 5.

## Inclusion proofs

`nkm_proof(root, target, token_offset_or_NONE, out)` walks the DAG from a
public root to a public target and emits one entry per node on the path,
target first and root last. Each entry carries used, generation tag, ordered
parent hashes, the used content words, and the recomputed node hash. The proof
header carries the root hash, target hash/used/gen, mode and token
offset/value. A proof is `16 + depth*32` words; depth is bounded by
`NKM_PROOF_MAX = 16`.

`nkm_proof_verify(root_lo, root_hi, proof)` uses only the supplied root hash
and the proof buffer. It does not read the node registry, a node index, a
branch context or a content index; the gate extracts the verifier section and
fails if it references `NKM_NODES`, `nkm_nodeptr`, `nkm_find` or `nkm_lookup`.
Verification:

1. validates magic/version, depth 1..16, mode 1..2, parent count ≤4 and used
   ≤16;
2. checks the proof header root equals the supplied root;
3. recomputes entry 0 and checks it equals the header target hash and that
   target used/gen agree;
4. for each next entry, recomputes its hash and requires the previous child
   hash to occur in its ordered parent list;
5. requires the last (root) entry hash to equal the supplied root;
6. for token mode, requires `offset < used` and
   `entry0.content[offset] == token_value`.

A mutated content word, ordered parent hash, generation tag or used count
changes an entry hash and breaks the chain. A mutated token value/content,
target hash, root field, depth, parent order or supplied root is also rejected
with `EPROOF` (11 mutation cases in the gate).

## Proof

Four cold scenarios run: close order A (`4,3,2,1,5`) twice and close order B
(`5,1,2,3,4`) twice. Each creates four `nagent` records and four `ngen` agents:
agent 1 and agent 2 at gen 5, agent 3 at gen 3, agent 4 at gen 4.

1. Branch 1 builds a 10-token prefix P over two pages and seals it. P0 is an
   8-token page with no parent; P1 is a 2-token page that commits P0 and is
   P's root. P0 refs 2 (table + P1's parent reference), P1 refs 1.
2. Branch 3 joins P by root hash, then branch 4 late-joins after Q exists.
   P0 refs 6 (b1, b2, b3, b4 tables plus P1 and Q1 parent references), P1
   refs 3 before the merge.
3. Branch 2 at gen 5 builds a 16-token Q. Its first page is identical to P0
   and seals to the same node hash and identical committed fields: one dedup
   hit, refs increment, no second header. Q1 commits P0. Q1 refs 1.
4. Branch 1 publishes gen 6. The old gen-5 slot is `DRAINING`; an open at gen 5
   fails `ESTALE` with `NG_EDRAIN`; the old admitted branch still reads its
   snapshot; a fresh gen-6 view is rejected with `EGEN`; a shared write is
   `ESHARED`.
5. A fresh gen-6 merge context builds M with two ordered parents `{P1,Q1}` and
   content `{0xA000,0xA001}`. M is a genuine multi-parent root; P0 now has the
   two root paths `M->P1->P0` and `M->Q1->P0`. P1 refs 4, Q1 refs 2, M refs 1.
   The root commitment reports M's hash, index, used 2, live 1, gen 6 and
   sealed 1. Agent 1's `nagent` KV root becomes M with KV generation 2.
6. Page proofs for P0 (depth 3) and Q1 (depth 2), plus token proofs for
   P1[1] = `0x5009` and P0[3] = `0x5003`, all verify from the M root hash
   alone. 11 mutations (content, parent hash, generation, used, token value,
   token content, target hash, root field, depth, parent order, supplied root)
   each fail `EPROOF`.
7. Branches 1/3/4 append divergent suffixes; each COWs exactly the shared
   2-token P1 boundary page. P1 refs go 4 → 3 → 2 → 1. Branch 2 starts a
   private third page at token 16. P0 stays at six refs.
8. Pre-close exact totals: `live=8`, `public_live=4`, `headers=4`,
   `public_allocs=4`, `private_allocs=8`, `private_frees=4`, `refs=21`,
   `releases=7`, `dedup=1`, `joins=2`, `join_refs=4`, `COWs=3`,
   `tokens_copied=6`, `seals=2`, `merges=1`, `proofs=4`, `verifies=4`,
   `proof_rejects=11`. P0/P1/Q1/M refs are 6/1/2/1; four private COW pages
   hold one ref each.
9. Close order A checks P0 refs after each close: `5,4,3,2,0`; order B gives
   `5,4,2,1,0`. Both orders free M, then the parent-reference cascade frees
   P1 and Q1 and finally P0. After close: `live=0`, `public_live=0`,
   `public_frees=4`, `private_frees=8`, `refs=releases=leaves=21`,
   `opens=closes=5`, trace events 44.
10. An orphan gen-6 context joins the old P and Q roots and gets `ENOENT`.
    Final counters: `opens=6`, `closes=6`, `errors=19`, `xdup=1`, `xref=1`,
    `xshared=1`, `xstale=1`, `xgen=1`, `xproof=11`, trace events 46, no wrap.
    The saved P0 page proof still verifies from the saved M root hash after
    every node has been freed, which is the root-only checkpoint property.
11. The 6816-word snapshot (7 contexts, 64-node registry, 64-word stats,
    512-word payload buffer, 4 `nagent` records, 4 `ngen` statuses, 1024-word
    trace ring) is identical across the two cold runs for each close order.

## Exact gate output

```
$ sh tools/nkvmerkle_gate.sh
O
nkvmerkle: PASS (4 agents, gen-tagged Merkle nodes, P/Q prefixes, P0 dedup refs 6 / one header, multi-parent M{P1,Q1}, page+token inclusion proofs verified from the M root only, 11 field/root/order mutation rejects, private COW suffixes, parent-ref cascade in both close orders, orphan ENOENT, post-free root-only proof verify, exact counters + 6816-word deterministic snapshot)
```

Regressions run after the change:

```
$ sh tools/nkvdag_gate.sh
O
nkvdag: PASS (4 agents, P/Q prefixes, identical P0 page deduped to one header (refs 4, dedup 1, headers 1), branch3 join + late branch4 join, per-branch ngen tags, private COW suffix isolation, cross-gen/old-gen/shared-write/EDUP/ECOLL/EREF/ENOENT rejects, zero-ref frees in both close orders, exact counters + 5280-word deterministic snapshot)

$ sh tools/nkvtree_gate.sh
O
nkvtree: PASS (3 agents share 10-token prefix via nsym roots, child1 gen2/child2 gen3 divergent suffixes, parent gen5 suffix unchanged, boundary COW only, cross-gen/old-gen/shared-write reject, both close orders free at zero refs, exact counters + 3344-word deterministic snapshot)

$ sh tools/nkvgen_gate.sh
O
nkvgen: PASS (parent gen5 10-token prefix, fork gen6 shares pages, cross-gen/old-gen reject, COW 2-token boundary only, parent/child isolation, exact refcounts, deterministic rerun)

$ sh tools/nagent_gate.sh
O

$ sh tools/nsym_gate.sh
O
nsym: PASS (3-agent WFQ over 2 CPUs, bounded ratio, no starvation, reservation by deadline, budget park + budget reject, deadline miss, shared-root refcount/join/leave/free, generation publish/drain/start isolation, deterministic rerun)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Honest limits

- The hash is a deterministic two-lane 32-bit corruption/identity mix, not a
  cryptographic hash. It catches accidental mutation and ordering errors; it
  does not resist a deliberate collision search and is not a signature. The
  equal-hash/different-fields `ECOLL` path is implemented but not exercised by
  the gate, because synthesizing a 64-bit collision is not a product test.
- Single-threaded. Refcounts are plain word increments; there is no CAS,
  fence, per-CPU shard or epoch-deferred reclamation, so this is not yet an
  SMP-safe join/leave protocol.
- Node lookup is a linear 64-slot scan. It is deterministic and small enough
  for the gate, not an indexed content store.
- A multi-parent root cannot be materialized into one linear token table by
  `nkm_join`; joining rejects it with `EBAD`. Multi-parent roots are proof and
  commitment objects. Page-addressable materialization would need a
  path/order selector or a richer branch view.
- The generation tag is part of node identity, so equal content at different
  generations does not dedup. This is deliberate but reduces cross-generation
  sharing compared with `nkvdag`.
- Root metadata (`live` pages, context epoch, KV root generation) is returned
  by `nkm_root_info` but is not itself inside the node hash. A checkpoint must
  save the root hash plus that metadata; the root hash commits the DAG path and
  the root page's content/parents/used/generation.
- Limits: 64 nodes, 16 values/page, 4 ordered parents, proof depth 16,
  32 page-table blocks, 128 trace entries. `nkm_init` must be called cold for
  each independent DAG.
- Private COW pages have no hash and cannot be proof targets until sealed.
  Only used content words are committed; unused slots are not.
- `nkm_node_free` is a rejection API for referenced nodes. Its zero-ref direct
  path does not cascade parent releases; normal release/COW/close does.
- No persistent store, cross-node hydration, encryption, access control or
  attestation is implemented here.

## Frontier ideas

1. **Persistent content-addressed store.** Put the 56-word node records and
   payloads in an NVMe/RDMA CAS keyed by `(hash_lo, hash_hi)`, hydrate a cold
   agent by root hash, and gate exact dedup hits and bytes avoided across a
   restart. Multi-parent nodes make the missing-ancestor set a small DAG
   closure rather than a linear chain.
2. **Root-only checkpoints.** Save `{DAG root hash, ngen generation, nagent KV
   root, trace head}` and verify page/token proofs offline from that record
   without the registry. This gate already proves the post-free case; the next
   step is a durable checkpoint format plus replay of a suffix through the view
   gate with old-view divergence at the exact event index.
3. **Cross-node hydration and shard assembly.** Publish a multi-parent root
   whose parents live on different nodes, fetch each shard's proof chain,
   verify every entry against the root hash during assembly, and fail closed on
   a missing or mutated shard. This turns the parent-reference cascade into a
   distributed reachability/refcount protocol.
4. **Proof-carrying KV.** Attach an inclusion proof to every page or token
   view and verify it on read or at a transport boundary, so a remote cache or
   untrusted adapter can serve KV without being trusted. Combine with a
   proof-carrying checkpoint so restore rejects any page whose proof does not
   chain to the saved root.
