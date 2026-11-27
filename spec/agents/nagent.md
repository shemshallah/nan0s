# nagent — F5 AI-native agent ABI

Status: **implemented and gated** (`tools/nagent_gate.sh` emits exactly `O`).
This is the pure-NaN agent policy/record layer.  It has not yet been wired to
the x86-64 S1 trap path or to `nansched_mp` dispatch; those are integration
directives below.

## Scope

F5: capability generations and revocation, checkpoint/restore/fork, cross-CPU
and cross-node migration, shared immutable weights with a COW KV root, trace
continuity, and a deterministic in-NaN hash chain.  No C is added.  The gate
runs the real library under `aarch64/android/nan_cli`; `nan_cli` is the host
oracle only.

## Files

| file | role |
|---|---|
| `src/lib/nagent.nas` | new pure-NaN agent record, capability table, checkpoint/restore/fork/migrate/trace/verify |
| `src/tests/nagent_test.nas` | proof image; prints exactly `O` |
| `tools/nagent_gate.sh` | emit/check the image, enforce the guest map, run it, require one-byte `O` |

No existing shared library was modified.  `nagent.nas` uses its own table at
guest word `0x348000` (32 records x 320 words) and its own destination
generation tables at `0x6800`/`0x6820`; an image that links it must keep
code/data below `0x6800`.  The test reserves 256 stack words at `0x7000`.

## Agent record (320-word stride)

```
+0  magic "NAGN"           +1  version 1
+2  id (1..32)             +3  agent generation
+4  state (1 live)         +5  cpu
+6  node                   +7  scheduler slot
+8  trap-frame base        +9  capability table base
+10 capability count       +11 immutable weight root
+12 KV root                +13 KV root generation
+14 trace head             +15 trace event count
+16 budget                 +17 deadline
+18 last checkpoint hash   +19 checkpoint epoch
+20 parent id              +21 migration epoch
+22 capability epoch       +23 record seal
+24..47   24-word trap frame (same shape as spec/NAN_ABI.md)
+48..     capability entries, 8 words each, up to 32
```

A capability entry is `{live, index, generation, rights, kind, root, handle,
reserved}`.  Kinds are `1` immutable weights, `2` KV root, `3` tool/generic.
A handle is the existing 32-bit capability word:

```
0xCA | index(8) | generation(8) | rights(8)
```

There are no raw pointers in a handle.  Revoking bumps the entry generation
and mints a new handle; every older handle fails both the generation and the
stored-handle comparison.  A capability table is per agent, so a parent handle
is not valid on a child even when the index/rights happen to match.

The record seal is a deterministic mix chain over fields `0..22` and the
capability words.  It deliberately excludes the live 24-word trap frame, so
normal frame execution does not require resealing; the checkpoint hash covers
the frame.  `nagent_verify` recomputes the seal and validates every capability
entry without writing anything back.

## API

```
nagent_init
nagent_create       id=cpu,node,slot
nagent_cap_grant    id,kind,rights,root          -> cap / 0
nagent_cap_revoke   id,cap                       -> new cap / 0
nagent_cap_check    id,cap,rights                -> entry / 0
nagent_checkpoint   id,storage,words             -> epoch / 0
nagent_restore      storage,words                -> id / 0
nagent_fork         parent,cpu,node              -> child id / 0
nagent_migrate      id,cpu,node,cpu_gen,node_gen -> 0 / 1 / 2
nagent_trace_append id,kind,a,b                  -> head / 0
nagent_verify       id                           -> 0 / 2 / 3 / 4
nagent_record       id                           -> record / 0
nagent_roots        id,weight(0 keep),kv(0 keep) -> 0 / 2 / 5
nagent_budget_set   id,budget,deadline           -> 0 / 2
nagent_dest_set     cpu,cpu_gen,node,node_gen    -> 0 / 2
nagent_ck_seal      storage,words                -> hash / 0
```

`nagent_cap_grant` binds the immutable weight root once; a later grant with a
different weight root is refused.  A KV grant binds the KV root and starts its
generation at 1; a later KV grant advances the generation.  `nagent_roots`
is the owner/restore path for a COW KV root change; it still refuses a
different weight root.

## Checkpoint record (caller supplied)

```
+0  magic "NAGC"          +1  version 1
+2  agent id              +3  agent generation
+4  state                 +5  cpu
+6  node                  +7  slot
+8  cap count             +9  capability epoch
+10 weight root           +11 KV root
+12 KV generation         +13 trace head
+14 trace event count     +15 budget
+16 deadline              +17 parent id
+18 migration epoch       +19 checkpoint epoch
+20 hash                  +21 frame words (24)
+22 cap words (8*n)       +23 total words
+24..47 frame
+48..   capabilities with generations
```

`nagent_checkpoint` first verifies the live agent, writes the header, copies
the 24 frame words and every capability entry, then seals.  `nagent_restore`
validates, in order: checkpoint magic/version/shape, the checkpoint hash, the
live agent id/generation/magic/version, the live record seal, the capability
epoch, and every checkpoint capability entry (live, index, generation 1..255,
rights 1..31, kind 1..3, nonzero root, exact handle).  It writes nothing until
all checks pass.  A failed restore returns 0 and leaves the agent unchanged.

### Deterministic mix chain

Both seals use the same 32-bit NaN chain:

```
h = seed
for each word w:
    h ^= w
    h += 0x9E3779B9
    h ^= h >> 16
    h *= 0x85EBCA6B
    h ^= h >> 15
    h *= 0xC2B2AE35
    h ^= h >> 16
```

The agent seal chain is fields `0..22` then capability words.  The checkpoint
chain is seeded with the total word count, then includes every checkpoint word
except the hash itself (including the 24 frame words).  The checkpoint epoch is
part of the hashed header, and the agent records the checkpoint hash/epoch.
There is no host helper and no key; this is a corruption/integrity seal, not
authentication.

### No capability rollback

The capability epoch is monotonic and is sealed into the record.  A checkpoint
stores the epoch.  Restore requires equality with the live epoch, so a
checkpoint taken before a grant/revoke cannot resurrect a revoked capability.
An older checkpoint may still restore frame/roots/trace when the capability
table has not changed.  This is the deliberate split between time-travel state
and non-rollback security state.

## Fork and migration semantics

`nagent_fork(parent,cpu,node)` allocates a new id, copies the 24-word frame,
copies the trace head/count and budget/deadline, keeps the weight root
byte-identical, derives a new KV root token and sets `kvgen = parent.kvgen+1`,
copies every capability with generation `parent.gen+1` (refusing a parent
generation of 255), mints child handles, and sets `parent = parent.id`.
The parent record is not written.  The child starts with checkpoint/migration
epochs 0 and no checkpoint hash.

`nagent_migrate(id,cpu,node,cpu_gen,node_gen)` checks both destination
generations against the published `nagent_dest_set` tables before changing
anything.  A mismatch returns 1 and leaves the record untouched.  A successful
change writes cpu/node, increments the migration epoch, and reseals; caps,
roots, trace and budget are untouched.  Migrating to the current cpu/node is a
successful no-op and does not bump the epoch.

## Proof

`src/tests/nagent_test.nas` verifies:

1. create cpu0/node0/slot7; record fields, frame base, cap count, trace seed,
   capability epoch, migration/checkpoint epochs, verify = 0;
2. grant weight (read|replace), KV and tool capabilities; WRITE on the weight
   handle is rejected; a different weight root is refused; revoke mints
   generation 2, the old handle fails, the new handle works; capability epoch
   becomes 5;
3. frame words `0xA1/0xA2/0xABCD`, trace events 1 and 2, budget 500/deadline
   900; checkpoint epoch 1; checkpoint header, frame copy, roots and trace
   checked;
4. mutate frame (`0xB1/0x9999`), KV root `0x2002`/generation 2, trace and
   budget; restore returns id 1 and restores frame, caps, weight root `0x1001`,
   KV root `0x2001`/generation 1, trace head/count, budget/deadline,
   checkpoint hash/epoch; verify = 0;
5. fork to cpu1/node0: new id, parent id, shared weight root, different KV
   root/generation 2, same trace head, child cap generations parent+1, child
   handles work, a parent handle fails on the child; append to the child and
   prove the parent trace/frame/roots are unchanged;
6. migrate cpu0->cpu1 (node0), then node0->node1 (cpu1), preserving caps,
   roots, trace and budget and bumping migration epoch 1 then 2; a stale
   destination cpu generation (0) is rejected with state unchanged; publish
   cpu1/node1 generation 2, reject old (1,1), accept (2,1) and (2,2), then
   migrate back to cpu0/node0 (1,1) at epoch 5;
7. tamper the checkpoint frame without resealing: restore returns 0 and the
   agent is unchanged; take a fresh checkpoint, set a capability generation
   to 0, reseal the checkpoint with `nagent_ck_seal`: restore still rejects it
   because the per-capability generation check runs after the hash;
8. tamper a live capability generation: `nagent_verify` fails; repair and
   verify = 0;
9. checkpoint, revoke the weight capability to generation 3, then restore the
   old checkpoint: returns 0 (stale capability epoch); the old generation-2
   handle fails, the generation-3 handle works, and the trace/frame/cap count
   are unchanged.

## Exact output

```
$ sh tools/nagent_gate.sh
O
```

The gate requires one output byte and no newline.  The equivalent direct run
at this revision:

```
$ ./aarch64/android/nan_cli --img tmp/nagent.nan --mem 64 \
    --steps 5000000 --serial
O
[nan_cli] nan-text: 183746 steps, rc=3, pc=2208, trap=''
```

`rc=3` is the normal guest HALT in `nan_cli`; the gate treats it as success
only after the exact one-byte `O`.

## Regressions

```
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nmem_scale_gate.sh
nmem_scale: PASS (2 TiB object, 1 TiB 64-bit view, bounds/rights/node)

$ sh tools/nanobj_gate.sh
nanobj_gate: PASS (typed objects, capability rights, revocation, forged-generation rejection, free)

$ sh tools/nansched_mp_gate.sh
O
```

`tools/nobj_gate.sh` does not exist in this tree; `tools/nanobj_gate.sh` is
the object/capability gate that covers the same subsystem.

## Frontier ideas

1. **Live generations.**  Join the agent/capability epoch with the NanCore
   `NC_GEN` and destination generation tables, then publish a new generation
   across CPUs and drain old handles before the next dispatch.  A restore must
   join the current generation, never rewind it.
2. **Shared-weight fork with COW KV.**  Put the weight root in `nanobj` with a
   reference count, make fork zero-copy for weights, and allocate a COW KV
   page table per child.  Gate fork cost and RSS independent of model size.
3. **Cross-node KV migration.**  Move the KV root/generation with the agent,
   page KV slabs through `nheap`/`nmem`, and require the destination node
   generation fence plus a trace-head compare before the first token.
4. **Agent replay.**  Add a per-agent deterministic RNG and a checkpoint chain
   (`prev_hash` in the next checkpoint), replay from a checkpoint with the
   same seed/inputs, and make trace-head divergence a first-class failure.
