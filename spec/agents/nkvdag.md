# nkvdag — content-hash prefix-page DAG, dedup and late joins (F13i)

## Delivered

- `src/lib/nkvdag.nas` — pure NaN content-addressed KV prefix DAG.
- `src/tests/nkvdag_test.nas` — four-agent, two-prefix, late-join gate image.
- `tools/nkvdag_gate.sh` — gate: `nmk` emit/check plus two cold `nan_cli`
  runs, exact one-byte `O`, structural and regression checks.

No C was added outside `src/tests`; no C at all is linked in this gate.
`src/lib/nkvgen.nas` and `src/lib/nkvtree.nas` are untouched.

## Layout

Node registry: 64 nodes × 32 words at `0x35C000`; stats 64 words at
`0x35D000`; trace 128 × 8 words at `0x35D200`; scratch `0x30000..0x3005F`
for `ngen_status`/`ngen_slot`.

A node is one immutable prefix page or one private COW page:

```
 0 magic "NKDN"      1 version 1       2 kind (1 DAG, 2 private)
 3 refs              4 state (1 live)  5 flags (1 immutable)
 6 hash_lo           7 hash_hi         8 used tokens   9 slots (16)
10 payload word base 11 dedup hits    12 allocations   13 joins
14 leaves           15 frees           16 headers       17 birth generation
18 owner agent      19 prev node index 20 node index    21 COW copies caused
22 tokens copied    23 lookups         24 hits          25..31 reserved
```

A branch context holds `ngen` agent/generation/epoch, `nagent` id, an
8-word/entry page table, token counts and branch counters. A table entry is
`{node index, map generation, flags, content hash lo/hi, node index copy}`;
empty slots use `0xFFFFFFFF` because node index 0 is valid.

The content key is a pair of deterministic 32-bit mix lanes over the used
token values and the used count. Logical token index and birth generation are
not hashed, so equal content dedups across agents and generations. Each
immutable node stores `prev` (the previous immutable node in the sealing
chain); the last node is the prefix root. `nkd_join` accepts the root key,
walks `prev`, and installs the chain oldest-to-newest, acquiring every node.

Views are 16 words: reader generation, branch, token, node index, node birth
generation, mode, entry flags and page offset. Reads require the exact reader
generation and branch; writes reject shared/refcounted pages and private pages
from another generation.

## Proof

The gate runs four cold scenarios: close order A (`4,3,2,1,1b`) twice and close
order B (`1,2,3,4,1b`) twice. Each scenario creates four `nagent` records and
four `ngen` agents (agent 1 at gen 5, agents 2/3/4 at gen 2/3/4).

1. Branch 1 builds a 10-token prefix P over two pages, seals it, and gets two
   DAG headers. P0 is 8 tokens, P1 is the 2-token boundary/root. Both have
   `refs=1`, `headers=1`, `joins=0`, `dedup=0`, birth gen 5.
2. Branch 3 joins P by root hash: P0/P1 refs 2, joins 1 each, join operations 1,
   join refs 2. Branch 4 late-joins the same existing DAG: refs 3, joins 2,
   join operations 2, join refs 4.
3. Branch 2 builds a second 16-token prefix Q whose first page is
   byte-identical to P0 (values `0x5000..0x5007`). Seal finds P0 by content
   hash, takes a dedup reference and creates **no** second header. Exact P0
   state: `refs=4`, `dedup=1`, `headers=1`, `joins=2`. Q1 is a new header
   behind P0, `refs=1`. Total DAG headers = 3.
4. `nkd_hash` recomputed from P0's payload and `used` equals P0's stored
   `hash_lo/hash_hi`. A duplicate raw insert of the same key+content is
   `EDUP`; the same content with a mutated key is `ECOLL`; freeing P0 while
   referenced is `EREF`; both reject without changing headers/refs.
5. Branch 1 publishes gen 6. The gen-5 ngen slot is `DRAINING`; an open at gen
   5 fails `ESTALE` with `NG_EDRAIN`; the old admitted branch still reads the
   shared view; a fresh gen-6 ctx fails the same view with `EGEN`; a shared
   write is `ESHARED`; an unknown root join is `ENOENT`.
6. Branch 1/3/4 each append a divergent suffix and COW exactly the 2-token
   boundary P1. Its refs go 3 → 2 → 1 → 0, and the third COW frees P1 at zero
   refs. P0 stays at four refs. Branch 2's suffix page is private (Q was
   full-page aligned), and a private write succeeds only on its own gen-5
   branch.
7. P0 is still `refs=4` before close. The gate checks P0 refs 3 → 2 → 1 → 0
   after each close in both orders, so P0 is freed only when its last sharer
   closes; Q1 frees when branch 2 closes and private COW pages at their single
   owner close. After both orders:
   `live=0`, `dag_live=0`, `dag_headers=3`, `dag_allocs=3`, `dag_frees=3`,
   `private_allocs=9`, `private_frees=9`, `refs=17`, `releases=17`,
   `leaves=17`, `joins=2`, `join_refs=4`, `dedup=1`, `COWs=3`,
   `tokens_copied=6`, `seals=2`, `roots=4`.
8. A fresh gen-6 ctx then joins the old P and Q roots: both are gone, so both
   joins fail `ENOENT` (orphan-root rejection). Final errors: 2 `EDUP`,
   1 `ECOLL`, 1 `EREF`, 1 `ESHARED`, 1 `ESTALE`, 1 `EGEN`, 3 `ENOENT`.
9. The 5280-word snapshot (7 contexts, 64-node registry, 64-word stats, 512
   payload words, 4 nagent records, 4 ngen statuses, 1024-word trace ring) is
   identical across the two cold runs for each close order.

## Exact gate output

```
$ sh tools/nkvdag_gate.sh
O
nkvdag: PASS (4 agents, P/Q prefixes, identical P0 page deduped to one header (refs 4, dedup 1, headers 1), branch3 join + late branch4 join, per-branch ngen tags, private COW suffix isolation, cross-gen/old-gen/shared-write/EDUP/ECOLL/EREF/ENOENT rejects, zero-ref frees in both close orders, exact counters + 5280-word deterministic snapshot)
```

Regressions run after the change:

```
nkvtree_gate: PASS (3 agents share 10-token prefix via nsym roots, ... 3344-word deterministic snapshot)
nkvgen_gate: PASS (parent gen5 10-token prefix, fork gen6 shares pages, ... deterministic rerun)
nagent_gate: O  (exit 0)
nsym_gate: PASS (3-agent WFQ ... deterministic rerun)
ngen_gate: PASS (gen1 in flight ... deterministic rerun)
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Honest limits

- Single-threaded. Refcounts are plain word increments; there is no CAS or
  per-CPU shard, so this is not yet an SMP-safe join/leave protocol.
- Node lookup is a linear 64-slot scan. It is deterministic and small enough
  for the gate, not an indexed content store.
- The hash is a two-lane 32-bit non-cryptographic mix. It catches corruption
  and accidental mismatch, not an adversary. A 64-bit key pair is not a
  Merkle root over history.
- Chain identity is single-parent. Content that reappears at a different
  `prev` position is rejected as `ECOLL` instead of becoming a multi-parent
  node. The gate exercises the valid same-depth case.
- Max 64 nodes, ≤32 page-table blocks, 16 values/page, and a 128-entry trace
  ring. `nkd_init` must be called cold before each independent tree.
- There is no `nsym` mirror and no nheap tiering. Node headers and payloads
  are plain NaN words in caller-supplied memory.
- `nkd_node_free` is a rejection path for a referenced node; normal zero-ref
  reclamation happens inside release/COW/close. There is no background GC.
- `ngen` tags are per branch, and the per-node `birth generation` is the
  sealing generation. A view is a snapshot of one exact branch generation,
  not a general version vector.

## Frontier ideas

1. **Merkle prefix DAG.** Replace the two-lane key with a Merkle node hash
   `H(content, prev, used, generation_tag)`, allow multi-parent nodes, and
   gate inclusion proofs and root-only checkpoint verification. This turns
   the DAG into an authenticated KV history without changing branch views.
2. **Cross-agent dedup store and late hydration.** Make nodes persistent and
   content-addressed across cold runs, then have a new adapter join by root
   hash and hydrate only missing nodes from an NVMe/RDMA store. Gate exact
   dedup hits and bytes avoided across four agents and a restart.
3. **Epoch GC and SMP refcounts.** Add generation-stamped refcounts with
   CAS/fence join/leave, deferred zero-ref reclamation, cycle/orphan
   detection, and a pressure-driven GC that never frees a node visible to a
   live view.
4. **Checkpoint roots.** Save `{root hash, ngen generation, nagent KV root,
   trace head}` as a branch checkpoint, replay a suffix through the view
   gate, and assert exact token/value equality plus old-view divergence at
   the exact event index.
