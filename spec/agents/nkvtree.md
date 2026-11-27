# nkvtree — three-agent shared-prefix branch tree (F13h)

Status: implemented and gated (2026-11-27). Agent slot A14.

Files (raw NaN product code, zero C):

- `src/lib/nkvtree.nas` — generation-tagged tree KV contexts over nkv views,
  ngen live generations, nagent fork records and nsym shared roots.  Immutable
  prefix pages are SHARED with a page refcount mirrored one-for-one by an nsym
  root, COW copies only the used boundary records, and an explicit
  alloc/join/leave/free/copy counter set plus a deterministic tree-generation
  trace.
- `src/tests/nkvtree_test.nas` — four cold runs: two close orders, each run
  twice and compared as a 3344-word full state snapshot.
- `tools/nkvtree_gate.sh`.

`nkvgen.nas`, `nagent.nas`, `nsym.nas`, `ngen.nas`, `nkv.nas` and all other
agents' files were **not modified**.  No git commit was made.  The gate links
the real `nkvtree.nas`, `nkv.nas`, `nagent.nas` and `nsym.nas` (which includes
`ngen.nas`); there is no C harness and no C outside `src/tests`.

## Layout

Global page registry: 16 pages × 32 words at `0x359000`.
Stats: 48 words at `0x359800`.
Trace: 64 entries × 8 words at `0x359A00`.
Scratch: `0x30000..0x3005F` (ngen status/slot and nkv shape).
Page payload: caller supplied, 16 token records × 4 words = 64 words per page
slot; the test uses 8-token pages and six allocated pages.

Context (32 caller words):

```
+0  magic "NKTC" 0x43544B4E        +1 version 1
+2  ngen agent                     +3 ngen generation
+4  branch id                      +5 parent branch
+6  nagent id                      +7 nagent KV generation
+8  page table (4 words/block)     +9 table capacity in blocks
+10 tokens per block               +11 used tokens
+12 live blocks                    +13 COW page copies
+14 bytes/token (16)               +15 page slots (max 16)
+16 admitted                       +17 last context error
+18 last ngen error                +19 fork joins
+20 child forks                    +21 ngen epoch
+22 view opens                     +23 views minted
+24 view reads                     +25 view writes
+26 nagent record generation       +27 tree depth
+28 nsym weight root               +29 nsym KV root (first prefix page root)
+30 prefix pages                   +31 flags
```

Page table entry (4 words): `page pointer, map generation, flags(shared),
nsym root index`.

Page header (32 words):

```
+0  magic "NKTP" 0x50544B4E        +1 version 1
+2  allocation generation          +3 refcount
+4  state (1 live)                 +5 flags (1 shared immutable prefix)
+6  class-20 storage capability    +7 word base   +8 base_hi
+9  used tokens                    +10 slots (<=16)
+11 allocations                    +12 COW copies caused by this page
+13 tokens copied                  +14 joins +15 leaves +16 frees
+17 owner ngen agent               +18 owner generation
+19 page index                     +20 nsym root index / 0xFFFFFFFF
+21..31 reserved
```

A token record is `{logical token, value, tag 0xA5A5A5A5, generation}`.  Each
read is resolved through a real nkv rank-1 f32 view (4 elements) over the
page's class-20 storage capability.

View (32 caller words):

```
+0  magic "NKTV" 0x56544B4E        +1 version 1
+2  reader generation              +3 branch
+4  logical token                  +5 page pointer
+6  page birth generation          +7 mode (1 read, 2 write)
+8..31 embedded nkv view
```

Stats: `{magic, version, live, allocs, frees, joins, leaves, copies,
tokens_copied, forks, opens, seals, view_opens, view_reads, view_writes,
errors, last_error, ops, cross-gen rejects, stale rejects, shared-write
rejects, page limit, buffer, max pages, trace head, trace events, trace wraps,
roots created, root acquires, root releases, roots freed, mirror checks,
mirror errors, closes, cows, prefix pages, nagent forks, binds, publishes}`.

Trace entry (8 words): `kind, seq, a, b, c, 0, hash, 0`.
Kinds: 1 open, 2 seal, 3 fork, 4 COW, 5 close, 6 page free, 7 publish,
8 weight bind.  The hash is the same deterministic xor/multiply chain shape as
nagent/ngen/nsym with an NKT seed.

## Generation and refcount rules

`nkvt_open(ctx, agent, gen, cpu, branch, nagent, table, cap, slots)` calls
`ngen_enter(agent, gen, cpu)` and stores the admission.  A failed enter maps
to exact `NKT_ESTALE` and retains the raw ngen error (for example
`NG_EDRAIN`).

`nkvt_bind(ctx, weight_root)` binds the immutable nagent weight root and
acquires one nsym reference.  A fork acquires that root once per child and a
close releases it, so the weight root has one reference per live tree agent.

`nkvt_seal_prefix(ctx)` marks every live page SHARED, creates one nsym root
per page whose payload is the page's eight token values plus count/generation/
index/owner, acquires the root for the parent's existing reference, and binds
the first page root as the nagent KV root.  Page-root slots are `page index +
1`; nsym slot 0 is unused and slot 15 is reserved for the caller's weight
root.  A page's refcount equals its nsym root's refcount at every join,
leave and free; a mismatch is charged to `mirror_errors`.

A fork:
1. verifies the parent is admitted and its ngen generation is CURRENT;
2. starts the child's own ngen agent at generation 1 and publishes up to the
   requested child generation (child1 gen 2, child2 gen 3);
3. creates an nagent_fork child record and verifies its KV generation is the
   parent's + 1;
4. copies the parent table's shared prefix entries, acquires each nsym page
   root once and increments the page refcount; no payload is copied.

The parent is not published on by a fork.  This is what allows two siblings
to fork the same parent.  The parent may later publish its own next generation
and keep appending as an admitted DRAINING snapshot.  A new open at the old
generation fails `ESTALE`/`NG_EDRAIN`.  Shared-prefix readability is
established by the SHARED join and refcount, not by comparing ngen generation
numbers across agents.

A view stores the reader generation, branch, token and page birth generation.
`nkvt_view_read`/`nkvt_view_write` require `view.ctxgen == ctx.gen` and
`view.branch == ctx.branch`; a mismatch is `NKT_EGEN`.  The context's ngen
generation must still be CURRENT or an admitted old DRAINING snapshot;
otherwise the view is `NKT_ESTALE`.  A freed page or a changed page birth
generation is `NKT_EBLK`.  Shared pages reject writes with exact
`NKT_ESHARED`.  The first append into a shared page (or a page with refs > 1)
COW-copies only that page's used records, rewrites their record generation to
the child generation, releases the shared reference, and then writes.  Full
prefix pages stay shared and untouched.

## Proof (gate scenario)

1. ngen agent 1 reaches generation 5.  The root tree agent opens at gen 5,
   branch 1, nagent id 1, and binds nsym weight root 15.
2. The root appends a 10-token immutable prefix (values `0x5000+i`): page 0
   is full (8 tokens), page 1 is partial (2 tokens).  Page headers are
   `{gen 5, refs 1, used 8/2}`.
3. The root reads all 10 tokens through gen-5 views, then seals both pages.
   Page roots are nsym slots 1 and 2 (ids `0x4E4B5401`/`0x4E4B5402`), each at
   refs 1; page 0's root is bound as the nagent KV root, KV generation 1.
   Stats: roots created 2, root acquires 3 (weight + two page roots).
4. child1 forks on ngen agent 2 at generation 2, branch 2.  nagent_fork
   returns id 2 with KV generation 2.  Both prefix pages become refs 2;
   weight root 15 becomes refs 2.
5. child2 forks on ngen agent 3 at generation 3, branch 3.  nagent_fork
   returns id 3 with KV generation 2.  Both prefix pages become refs 3;
   weight root 15 becomes refs 3.  Stats joins = 4, forks = 2.
6. All three agents read the 10-token prefix.  A parent view presented to a
   child, a child1 view presented to child2, and a child2 view presented to
   the parent all fail with `NKT_EGEN` (4 EGEN including the gen-6 document
   below).
7. A parent write view on shared page 0 and a child1 write view both fail with
   `NKT_ESHARED` (2).
8. The parent publishes gen 6 and stays an admitted gen-5 DRAINING snapshot.
   A new context opens at gen 6 on the same branch and reads no pages; it
   rejects the old gen-5 view with `NKT_EGEN`.  A fresh open at gen 5 fails
   `NKT_ESTALE` and records `NG_EDRAIN`.  Closing the gen-6 scratch context
   leaves gen 6 current and the parent still admitted.
9. The parent appends a 2-token suffix (`0x6000+token`).  Only page 1 (2 used
   records) is copied into page 2; page 0 is untouched.  Parent used = 12,
   live = 2 table blocks, copies = 1.
10. child1 appends 7 tokens (`0x7000+token`): page 1 is copied into page 3
    (2 tokens copied), tokens 8..15 fill page 3 to 8 used, token 16 allocates
    private page 4.  Child1 used = 17, live = 3, copies = 1.
11. child2 appends 6 tokens (`0x8000+token`): page 1 is copied into page 5 and
    filled to 8 used.  Child2 used = 16, live = 2, copies = 1.  The last
    shared reference to page 1 leaves here: page 1 refs 0 and its nsym root 2
    refs 0 are freed.
12. Parent suffix values, child1 values and child2 values at the same logical
    tokens are distinct; parent prefix/suffix reads are unchanged after both
    children write.  Page 0 stays shared at refs 3, each private page is at
    refs 1, and `mirror_errors` is 0.
13. Close order A is child1, child2, parent; order B is child2, child1,
    parent.  In both orders child closes free only their private pages and
    leave page 0/root 1 and weight root 15 at refs 1 after both children.
    Parent close frees page 0/root 1, page 2 and weight root 15; all counters
    land on the same final values in both orders.
14. Final exact counters: allocs 6, frees 6, joins 4, leaves 10, copies 3,
    tokens copied 6, forks 2, opens 2, seals 1, view opens 88, view reads 83,
    view writes 0, EGEN 4, ESTALE 2, ESHARED 2, total errors 8, page roots
    created 2, root acquires 9, root releases 9, roots freed 3, mirror
    errors 0, closes 4, COWs 3, prefix pages 2, nagent forks 2, binds 1,
    publishes 1.  nsym global: roots created 3, acquires 9, releases 9, roots
    freed 3, trace events 6.  ngen: agent 1 current 6 with gen 5 DRAINED;
    agent 2 current 2; agent 3 current 3.
15. The full 3344-word snapshot covers five contexts (parent, child1, child2,
    gen-6 scratch, failed old-gen context), the 16-page registry, 48 stats
    words, 512 payload words, 512 nsym root words, 32 nsym global words, three
    nagent records (960 words), three ngen statuses (96 words) and the 512-word
    trace ring.  Order A run twice and order B run twice compare word-for-word:
    `snapA1 == snapA2` and `snapB1 == snapB2`.  The first trace entry is
    `open(branch 1, gen 5)`; trace events = 20.

Exact gate output:

```
O
nkvtree: PASS (3 agents share 10-token prefix via nsym roots, child1 gen2/child2 gen3 divergent suffixes, parent gen5 suffix unchanged, boundary COW only, cross-gen/old-gen/shared-write reject, both close orders free at zero refs, exact counters + 3344-word deterministic snapshot)
```

Regression gates run after F13h:

```
O
nkvgen: PASS (parent gen5 10-token prefix, fork gen6 shares pages, cross-gen/old-gen reject, COW 2-token boundary only, parent/child isolation, exact refcounts, deterministic rerun)
O
nagent: O (gate prints only the marker, no PASS line)
O
nsym: PASS (3-agent WFQ over 2 CPUs, bounded ratio, no starvation, reservation by deadline, budget park + budget reject, deadline miss, shared-root refcount/join/leave/free, generation publish/drain/start isolation, deterministic rerun)
O
ngen: PASS (gen1 in flight, publish gen2, drain coexist, gen2 admit, old complete, post-drain stale reject, auto-drain, forced abort, dup/stale publish reject, 2-agent isolation, deterministic rerun)
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

`nagent_gate.sh` prints exactly `O`; it has no separate PASS line.

## Honest limits

- Fixed 16-page registry and at most 16 slots per page.  The gate allocates six
  pages of 8 tokens each; pages are metadata/test-sized, not real 2 MiB
  attention pages (npaged owns those).  There is no dynamic registry growth or
  page-table walk.
- The page allocator scans from index 0, so a freed page can be reused.  The
  gate pins child2 to a 6-token suffix so the freed boundary page is not
  immediately reused as child2's second page; page-index reuse under a longer
  suffix is not separately stressed.
- Page roots occupy nsym slots `page index + 1`, capping tree page roots at 14.
  Slot 0 is unused and slot 15 is the caller's weight root.  There is no
  dynamic nsym root allocation.
- The nsym coupling is an explicit one-for-one mirror of page refs onto root
  refs, checked on join, leave and free.  It is not an atomic/CAS refcount and
  does not make nkvgen depend on nsym; a caller must keep the two objects
  paired.
- `nagent_fork` copies a salted KV-root provenance tag into the child.  The
  shared prefix pages are bound through nsym roots, not through that nagent
  KVROOT tag.  Both children have KV generation 2 and the same salted tag from
  one parent fork; their tree branches and ngen generations are independent.
- Fork is supported from a CURRENT parent and children are separate ngen
  agents.  Grandchild trees, sibling joins, identical-page merging, orphan
  reclamation, and a content-hash prefix DAG are not implemented here.
- A view does not hold a page reference.  Freeing a page invalidates an
  outstanding view (`ESTALE`/`EBLK`); pages hold the refcounts.
- COW copies the whole used boundary page, not individual tokens.  The gate's
  boundary is 2 tokens; the 16-token worst case is the intended paged-KV
  granularity.
- Single-threaded metadata only: no locks, CAS, SMP publish, checkpoint/
  restore, eviction/tiering, or attention recomputation.  `ngen` supplies the
  generation state machine, not concurrency.
- The parent is an old-generation in-flight snapshot only while its ngen slot
  is DRAINING.  It cannot admit new work at the old generation after the
  publish; a fresh open at that generation fails closed.

## Frontier ideas

1. **Content-hash prefix DAG.**  Replace the per-context page table with a
   refcounted prefix-page DAG keyed by a content hash, so 3+ agents/adapters
   share one immutable prefix without duplicating page headers.  Gate a
   three-branch tree with exact per-page refs, dedup hits and per-branch ngen
   tags.
2. **Sibling merge/GC and orphan reclamation.**  Add sibling joins, merge
   identical COW pages after divergence closes, and reclaim orphaned pages
   with a deterministic tree-generation trace and exact page/root refcounts
   across a multi-level fork/close tree.
3. **Generation-tagged checkpoint/replay.**  Save a branch page table plus its
   ngen generation, replay the suffix through the view gate, and prove exact
   token/value equality plus old-view divergence at the exact event index.
4. **Multi-agent shared prefixes under SMP.**  Bind tree forks to nansched_mp
   task slots and CAS/fence refcounts; gate concurrent sibling fork/close on
   two CPUs with one winner per refcount operation, exact per-CPU counters and
   unchanged shared-root refs when scheduling only.
