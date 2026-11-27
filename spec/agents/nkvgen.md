# nkvgen — generation-tagged KV pages/views and COW prefix fork (F13g)

Status: implemented and gated (2026-11-27). Agent slot A13.

Files (raw NaN product code, zero C):

- `src/lib/nkvgen.nas` — per-branch KV context, generation-tagged page
  headers and token records, nkv-backed views with a generation gate,
  refcounted shared immutable prefix pages, ngen-published fork, COW on the
  first append into a shared page, exact alloc/join/leave/free accounting.
- `src/tests/nkvgen_test.nas` — one scenario run twice from a cold init; a
  1184-word snapshot (three contexts, the 16-page registry, stats, all page
  payload buffers and ngen status) is compared word-for-word.
- `tools/nkvgen_gate.sh`.

`nkv.nas`, `npaged.nas`, `ngen.nas`, `nagent.nas`, `nsym.nas` and the other
agent's `noc`/F15 files were **not** modified.  No git commit was made.  The
gate links the real `nkvgen.nas`, `ngen.nas` and `nkv.nas`; there is no C
harness.

## Layout

Global page registry: 16 pages × 32 words at `0x358000`.
Global stats: 32 words at `0x358200`.
Low scratch: `0x30000..0x3005F` (ngen status/slot and shape).

Context (32 caller words):

```
+0  magic "NKGC" 0x43474B4E        +1 version 1
+2  ngen agent                     +3 ngen generation
+4  branch id                      +5 parent branch
+6  page table (4 words/block)     +7 table capacity in blocks
+8  tokens per block               +9 used tokens
+10 live blocks                    +11 COW page copies
+12 bytes/token (16)               +13 page slots (16)
+14 view opens                     +15 admitted
+16 last context error             +17 last ngen error
+18 fork joins                     +19 child forks
+20 ngen epoch                     +21 flags
+22 views minted                   +23 view reads
+24 view writes                    +25..31 reserved
```

Page table entry (4 words): `page pointer, map generation, flags(shared), 0`.

Page header (32 words):

```
+0  magic "NKGP" 0x50474B4E        +1 version 1
+2  allocation generation          +3 refcount
+4  state (1 live)                 +5 flags (1 shared immutable prefix)
+6  class-20 storage capability    +7 word base   +8 base_hi
+9  used tokens                    +10 slots (16)
+11 allocations                    +12 COW copies caused by this page
+13 tokens copied                  +14 joins +15 leaves +16 frees
+17 owner agent                    +18 owner generation
+19 page index                     +20..31 reserved
```

A page payload is 16 tokens × 4 words = 64 words (256 bytes), supplied by
the caller to `nkvgen_init`.  A token record is
`{logical token, value, tag 0xA5A5A5A5, generation}`.  Each token read is
resolved through a real nkv rank-1 f32 view (4 elements) minted over the
page's class-20 storage capability.

View (32 caller words):

```
+0  magic "NKGV" 0x56474B4E        +1 version 1
+2  reader generation              +3 branch
+4  logical token                  +5 page pointer
+6  page birth generation          +7 mode (1 read, 2 write)
+8..31 embedded nkv view
```

Stats: `{magic, version, live, allocs, frees, joins, leaves, copies,
tokens_copied, forks, view_opens, view_reads, view_writes, errors,
last_error, ops, cross-gen rejects, stale rejects, shared-write rejects,
page limit, buffer base, max pages, ...}`.

## Generation rules

`nkvgen_open(ctx, agent, gen, cpu, branch, table, cap, tokens_per_block)`
calls `ngen_enter(agent, gen, cpu)` and stores the admission.  A failed
enter is mapped to exact `NKG_ESTALE`, and the raw ngen error (for example
`NG_EDRAIN`) is retained in `ctx+17`.

A page is private to the generation that allocated it.  A fork marks every
parent page `SHARED`, increments its refcount and joins it into the child
table; the page payload is not copied.  A descendant context may read a
shared ancestor page, but writes are rejected with exact `NKG_ESHARED`.
The first append into a shared partial page allocates one fresh page, copies
only that page's used records (the divergence boundary), rewrites their
record generations to the child generation, and releases the child's
reference to the shared page.  Full prefix pages stay shared and untouched.

A view stores the reader generation, branch, token and page birth
generation.  `nkvgen_view_read`/`nkvgen_view_write` require
`view.reader_gen == ctx.gen` and `view.branch == ctx.branch`; a mismatch is
`NKG_EGEN`.  The context's ngen generation must still be CURRENT or an
admitted old generation still DRAINING; otherwise the view is `NKG_ESTALE`.
A page that has been freed, or whose generation no longer matches the view's
recorded page generation, is `NKG_EBLK`.  This rejects both "a child view used
by the parent" and "a parent view used by the child" at the view layer before
any payload word is exposed.

### Why the parent still reads after the fork

The parent's `nkvgen_open` entered gen 5 as an in-flight ngen request.
`ngen_publish` moves gen 5 to DRAINING and starts gen 6.  The parent's
already-admitted context remains a legal old-generation in-flight snapshot,
so it keeps reading its own gen-5 views.  A **new** open at gen 5 calls
`ngen_enter` again and fails with `EDRAIN`, which nkvgen reports as
`NKG_ESTALE`.  When the parent closes, `ngen_exit` completes the in-flight
request and the gen-5 slot becomes DRAINED.  This is the exact ngen tie.

## Proof (gate scenario)

1. ngen agent 1 is taken through start/drain generations 1..4 and started at
   generation 5.
2. Parent branch enters gen 5 and appends 10 tokens (values `0x5000+i`):
   page 0 is full (8 tokens), page 1 is partial (2 tokens).
3. Parent reads all 10 tokens through gen-5 views; page headers are
   `{gen 5, refs 1, used 8/2}`.
4. Fork publishes gen 6 and shares both pages: both headers become
   `{gen 5, refs 2, flags shared}`; stats joins = 2.
5. Parent and child both read all 10 prefix tokens.  A parent view presented
   to the child and a child view presented to the parent both fail with
   `NKG_EGEN`.
6. A new open at gen 5 fails with `NKG_ESTALE`; the context records
   `NG_EDRAIN`; ngen slot 5 is `NG_S_DRAINING`.
7. Child appends token 10.  Only the 2-token partial page 1 is copied:
   global copies = 1, tokens copied = 2, the 8-token page 0 is not copied.
   Page 1 refs drops to 1; page 2 is a private gen-6 copy with used = 3.
   Child appends tokens 11..16: page 2 fills (used 8), page 3 (gen 6) is
   allocated for token 16.  Copies stay 1.
8. Parent still has used = 10, live = 2, copies = 0 and reads all 10
   prefix values with gen-5 records, including the 2-token partial suffix.
9. Child reads page 0 tokens 0..7 at gen 5, the copied boundary tokens 8..9
   at gen 6, and its own suffix tokens 10..16 at gen 6.
10. Writes to shared page 0 from both branches fail with `NKG_ESHARED`.
11. Child close frees exactly page 2 and page 3; pages 0/1 remain at refs 1.
    Stats: live 2, allocs 4, frees 2, joins 2, leaves 4, copies 1,
    tokens copied 2, forks 1.  Parent still reads all prefix tokens.
12. Parent close frees pages 0/1.  Final stats: live 0, allocs 4, frees 4,
    joins 2, leaves 6, copies 1, tokens copied 2, forks 1.  The old parent
    view now fails with `NKG_ESTALE`; ngen slot 5 is `NG_S_DRAINED` and the
    current generation is 6.
13. The full scenario runs twice from a cold init.  All 1184 snapshot words
    (contexts, page registry, stats, page payloads, ngen status) compare
    equal.

Exact gate output:

```
O
nkvgen: PASS (parent gen5 10-token prefix, fork gen6 shares pages, cross-gen/old-gen reject, COW 2-token boundary only, parent/child isolation, exact refcounts, deterministic rerun)
```

Regression gates run after F13g:

```
ngen:   PASS (gen1 in flight, publish gen2, drain coexist, gen2 admit, old complete, post-drain stale reject, auto-drain, forced abort, dup/stale publish reject, 2-agent isolation, deterministic rerun)
nkv:    PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)
nagent: PASS (gate prints O)
nattn:  PASS (exact RoPE/softmax, fused Q4xQ8 QK^T == nq4_dot32 oracle, nkv KV token views, 1-layer token gate ids 1/3/2)
npaged: PASS (2 MiB blocks, stable logical map, prefill+decode == full recompute, remap/generation, pressure/capacity/eviction)
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

## Honest limits

- Page registry is a fixed 16-page table; a context table is caller supplied
  with at most 16 blocks per context in the gate.  There is no dynamic
  registry growth or page-table walk.
- Pages are 16 tokens (256 bytes), not real 2 MiB attention pages.  This gate
  isolates the generation/refcount/COW semantics; npaged owns 2 MiB blocks.
- `nkv_view_addr` is used only for addresses below 4 GiB (`base_hi == 0`);
  record pointers are shifted from the low word.  The nkv 64-bit view path
  itself is unchanged, but this layer does not yet carry high word addresses.
- A view does not hold a page reference.  A view can be invalidated by a
  free (reported as `NKG_EBLK`) and must be re-opened; only page headers hold
  refcounts.
- COW copies the whole used boundary page, not individual tokens.  With a
  16-token page the worst copy is 16 tokens; this is the intended paged-KV
  granularity, not a per-token COW.
- The fork path requires the parent generation to be the current ngen
  generation and publishes exactly `parent_gen + 1`.  Multiple fan-out
  children of the same generation, grandchild trees beyond that, and sibling
  joins are not exercised.
- No locks, CAS, SMP publish, checkpoint/restore, eviction/tiering, or
  attention recomputation is implemented here.  This is single-threaded
  metadata/COW semantics with deterministic counters.

## Optional integration (documented, not gated)

- **nagent_fork:** the nagent child id can be used as a separate ngen agent
  for a child branch, but the ngen generation must be started through its own
  ngen record; the simpler same-agent "parent is an in-flight old-generation
  snapshot" model is the one gated here.  `nkvgen_open` already takes an ngen
  agent id, so a caller can bind a branch to a forked agent's ngen record
  without changing nkvgen.
- **nsym shared roots:** nkvgen page refcounts are the same join/leave/free
  shape as `nsym` root refcounts.  A caller can couple a shared weight root
  and a shared KV prefix as two independent reference-counted objects; no
  nsym symbol is called here, so neither gate depends on the other.

## Frontier ideas

1. **Prefix sharing across agents and hierarchical roots.** Replace the flat
   per-branch page table with a refcounted prefix-page DAG keyed by content
   hash, so several agents (and nested adapters) share one immutable prefix
   without duplicating page headers.  Gate a three-branch tree with exact
   refcounts and per-branch generation tags.
2. **COW eviction and tiering.** Evict cold shared pages to an nheap slow
   class while preserving refcounts, then rehydrate on the first read; combine
   recency, attention mass and node distance with the existing exact
   alloc/join/leave/free counters and a pressure-driven remap parity check.
3. **Generation-tagged KV replay.** Checkpoint a branch's page table and
   generation, then replay a suffix from the checkpoint with the view gate
   live; prove that a stale/forked view diverges at its exact event and that
   replay reproduces the original logits/token suffix.
4. **Fork trees with garbage collection.** Support many children of one
   generation, sibling joins, orphan reclamation and merge of identical COW
   pages, with a deterministic tree-generation trace and exact page
   refcounts across a multi-level fork/close tree.
