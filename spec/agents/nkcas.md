# nkcas — content-addressed store and cold hydration (F13k)

Status: gated by `tools/nkcas_gate.sh` (exact `O`, two cold runs).

## What is implemented

`src/lib/nkcas.nas` is a pure-NaN content-addressed store above `nkvmerkle`:

- 32-word superblock plus 48-word records keyed by `(hash_lo,hash_hi)`;
- each record carries used words, generation, ordered parent hashes, payload,
  a deterministic field/payload checksum, refcounts and dedup counters;
- `put`/`put_record`/`capture`/`get`/`delete`/`find`, persistent dedup and
  bytes-avoided counters, directory rebuild on mount;
- `hydrate` walks parents first into a 132-word page header plus token output;
- `proof` assembles inclusion proofs from the store alone and `verify`
  checks them with the `nkvmerkle` root-only verifier;
- `registry_hydrate` recreates public Merkle nodes and `agent_hydrate` opens,
  joins and binds an `nkvmerkle` agent view (fixed full nine-argument
  `nkm_open` handoff);
- exact errors for missing, corrupt, collision, proof and mount failures.

## Proof

The gate builds P (10 tokens/2 pages), Q (Q0/Q1), and multi-parent
`M{P1,Q1}`, persists four public nodes, clears the volatile directory and
Merkle registry, mounts from the store, replays four dedup puts (4 hits,
768 bytes avoided, writes unchanged), hydrates P and M without the original
registry, verifies 8 proofs plus 11 mutated rejects, recreates the public
nodes, joins P as a fresh agent, reads all 10 tokens, closes, then checks
collision/delete/missing/corruption/generic put paths and a 2,772-word
deterministic snapshot across two cold runs.

```
nkcas: PASS (persist, cold mount, dedup, hydrate/proofs,
             registry hydrate, collision/corruption fail-closed, deterministic)
```

## Honest limits

The store is a caller-supplied word region, not NVMe/RDMA transport. Checksums
are corruption detection, not a MAC. No GC/compaction; a deleted slot is reused
by sequence order. Proofs are CAS-only and root-bound, not a distributed
availability proof.
