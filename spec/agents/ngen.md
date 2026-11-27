# ngen — live generations, drain/start, epoch fences (F13e)

Status: implemented and gated (2026-11-27). Agent slot A11.

Files (raw NaN product code, zero C):

- `src/lib/ngen.nas` — per-agent generation records, tagged enter/exit,
  atomic publish, old-generation drain, explicit freeze/start, forced abort,
  epoch fences, per-CPU counters and a deterministic trace chain.
- `src/tests/ngen_test.nas` — one scenario run twice from a cold init, with
  every status word, CPU counter and trace tail compared word-for-word.
- `tools/ngen_gate.sh`.

No shared library was modified.  `nagent.nas`, `nsecure.nas`, `nreplay.nas`,
`nansched_mp.nas`, `nobs.nas`, `nspectree.nas` and the other agent's `noc`
files were not touched.  No git commit was made.  The gate links the real
`src/lib/ngen.nas`; there is no C harness.

## Layout

32 generation records at `0x352000`, stride 128 words (4096 words total).
64 per-CPU counter pairs at `0x353000`; the global last error is at
`0x353100`.  Low scratch is not used: the library is pure stack/record state.

Record:

```
+0  magic "NGEN" (0x4E47454E)  +1 version 1
+2  owner/agent id 1..32       +3 state (1 live)
+4  current generation         +5 epoch (last transition)
+6  weight root                +7 weight-root generation
+8  KV root                    +9 KV-root generation
+10 trace head                +11 trace events       +12 trace wraps
+13 total accepted            +14 total completed    +15 total aborted
+16 total rejected            +17 publishes          +18 drains
+19 starts                    +20 aborts             +21 fences
+22 last fence epoch          +23 fence state (bit0 publish, bit1 drain,
                                                    bit2 start)
+24 total drained             +25 last agent error   +26..31 reserved
+32..63  four 8-word generation slots
+64..111  eight 6-word trace entries
+112..127 reserved
```

Generation slot:

```
+0 generation +1 state (1 current, 2 draining, 3 drained, 4 aborted)
+2 in-flight  +3 accepted +4 completed +5 aborted
+6 start/drain epoch +7 creation epoch
```

Trace entry: `kind, a, b, hash, seq, epoch`.  The hash is a deterministic
xor/multiply chain over the previous head, kind, a, b and epoch (the same
mix shape as `nagent`/`nreplay`, with an `NGEN` seed).

Per-CPU counters are `{accepts, rejects, 0, 0}` per CPU for CPUs 0..63.

## Semantics

`ngen_create(agent, weight_root, kv_root)` creates a live record at
generation 0.  `ngen_start(agent, gen)` starts from idle (`gen == 1`) or
after a drained/aborted slot (`gen == current+1`).

`ngen_publish(agent, new_gen, weight_root, kv_root)` is one atomic policy
transition:

1. validate `new_gen == current+1` (`EDUP`, `ESTALE`, `EFUTURE`, `EBAD` for
   duplicate, stale, future, zero);
2. bump the epoch once and emit `publish(new_gen, epoch)`;
3. mark the old current slot DRAINING and emit `drain(old_gen, epoch)` — no
   new old-generation admission is possible from this point;
4. if the old slot has zero in-flight requests, mark it DRAINED immediately
   and emit `drained(old_gen, epoch)`;
5. create the new CURRENT slot and emit `start(new_gen, epoch)`.

The old and new generations therefore coexist in the window between publish
and the last old exit.  A changed weight or KV root advances that root's
generation tag; an unchanged or zero root leaves it alone.

`ngen_enter(agent, gen, cpu)` returns the generation tag on admission.  It
fails closed with:

- `EDRAIN` (4) when the requested slot is DRAINING;
- `ESTALE` (1) when the slot is DRAINED or ABORTED, or has no history;
- `EFUTURE` (5) when `gen > current`;
- `EBAD` (2) for generation 0 or an unstarted record.

`ngen_exit(agent, gen)` completes one in-flight request.  When the last
in-flight request of a DRAINING slot exits, the slot becomes DRAINED, the
total-drained counter advances, and a `drained` event is emitted.

`ngen_drain(agent)` freezes the current generation without starting the next
one, for caller-controlled handoff.  `ngen_start` then starts `current+1`
only after the frozen slot is drained or aborted.

`ngen_abort(agent, gen)` is the forced path.  It accepts only a DRAINING slot
with in-flight requests, moves the whole in-flight count into the aborted
counter, marks the slot ABORTED and emits `abort` + `drained`.  A CURRENT,
DRAINED or already-ABORTED slot is an ordering error (`EBUSY`) or stale.

`ngen_fence(agent)` returns the epoch only when the last publish transition
has set all of `publish|drain|start` (fence state 7).  It does not consume
the fence; repeated queries return the same epoch and advance the fence
query counter.  A standalone drain or start by itself never satisfies the
three-part fence.

API:

```
ngen_init
ngen_create      r1=agent r2=weight root r3=KV root -> 0/errno
ngen_start       r1=agent r2=gen -> epoch / 0
ngen_drain       r1=agent -> epoch / 0
ngen_publish     r1=agent r2=new gen r3=weight root r4=KV root
                 -> epoch / 0
ngen_enter       r1=agent r2=gen r3=cpu -> gen / 0
ngen_exit        r1=agent r2=gen -> 0 (errno set on failure)
ngen_abort       r1=agent r2=gen -> aborted count / 0
ngen_roots       r1=agent r2=weight root r3=KV root -> 0/errno
ngen_fence       r1=agent -> epoch / 0
ngen_status      r1=agent r2=out(32) -> 0/-1
ngen_slot        r1=agent r2=gen r3=out(8) -> 0/-1
ngen_trace       r1=agent r2=index r3=out(6) -> 0/-1
ngen_trace_head  r1=agent -> head / 0
ngen_cpu         r1=cpu r2=out(4) -> 0/-1
ngen_inflight    r1=agent r2=gen -> count / 0xFFFFFFFF
ngen_epoch       r1=agent -> epoch / 0xFFFFFFFF
ngen_errno       -> last error
```

Error codes: `0 OK, 1 ESTALE, 2 EBAD, 3 ENOENT, 4 EDRAIN, 5 EFUTURE,
6 EBUSY, 7 EDUP, 8 ENOSPC`.  `ngen_status` reports magic, agent, current
generation, epoch, record state, total in-flight, live slots, accepting,
draining/drained/aborted slot counts, all accepted/completed/aborted/
rejected/publish/drain/start/abort/fence totals, the last fence epoch and
fence state, total drained, weight/KV roots and their generation tags, trace
head/events/wraps, and the last per-agent error.

## Proof

The gate runs the following scenario twice from `ngen_init` and compares a
128-word snapshot (two 32-word status blocks, four CPU counter pairs and two
four-entry trace tails):

1. Agent 1 starts gen1 at epoch 1; two gen1 requests enter on CPU0/CPU1.
   In-flight 2, accepted 2, trace events 3.
2. Publish gen2 with a new weight root at epoch 2.  The trace is exactly
   `publish(2,2)`, `drain(1,2)`, `start(2,2)` at indices 3,4,5.  Fence is 2,
   queried twice; old gen1 is DRAINING with in-flight 2; gen2 is CURRENT.
   Weight generation advances 1->2, KV generation stays 1.
3. A new gen1 admission returns 0 with `EDRAIN`; gen1 in-flight stays 2 and
   rejected becomes 1.  A gen2 admission returns 2 immediately.  Total
   in-flight is 3 while both generations coexist.
4. Exit gen1 once: in-flight 1, completed 1.  Exit gen1 again: in-flight 0,
   slot DRAINED, completed 2, total drained 1, trace emits complete+drained.
5. A post-drain gen1 admission returns 0 with `ESTALE`.  Gen2 still accepts.
6. Exit gen2; publish gen3 with a new KV root at epoch 3.  The empty gen2
   slot auto-drains: trace is publish, drain, drained, start at indices
   13..16; total drained 2; KV generation advances 1->2.
7. Two gen3 requests enter; publish gen4 at epoch 4 leaves gen3 DRAINING with
   in-flight 2.  Forced abort moves both to aborted, sets state ABORTED,
   total aborted 2, total drained 3.
8. A second abort is `EBUSY`; an exit/enter on the aborted gen3 and an enter
   on drained gen2 are `ESTALE`.  Gen4 accepts.
9. Duplicate publish gen4 is `EDUP`; publish gen3 is `ESTALE`; publish gen6
   is `EFUTURE`; publish gen0 is `EBAD`; publish agent 99 is `ENOENT`.
10. Agent 1 final: current 4, epoch 4, 4 live slots, accepting 1, draining 0,
    drained 2, aborted 1, accepted 5, completed 3, aborted 2, rejected 5,
    publishes 3, drains 3, starts 4, aborts 1, fences 4, fence state 7,
    total drained 3, weight root 0x3000/gen2, KV root 0x4000/gen2, trace
    events 27 / wraps 19, last agent error `ESTALE`.
11. Agent 2 starts independently at epoch 1, drains gen1 explicitly, admits
    nothing on the draining slot (`EDRAIN`), completes both requests, starts
    gen2 at epoch 3, aborts its one in-flight gen2 request, rejects gen2
    (`ESTALE`), starts gen3 at epoch 5, and rejects a future gen4
    (`EFUTURE`).  Its root tags, counters, trace head and fence state stay
    independent of agent 1.
12. A cross-agent gen1 enter on agent 1 and gen4 enter on agent 2 prove the
    two records do not share counters or generations.

Exact final per-CPU counters over both agents: CPU0 5 accepts / 6 rejects,
CPU1 2/1, CPU2 1/1, CPU3 1/1.  The two cold runs produce byte-identical
snapshots.

## Exact gate output

```
$ ./tools/ngen_gate.sh
O
ngen: PASS (gen1 in flight, publish gen2, drain coexist, gen2 admit, old complete, post-drain stale reject, auto-drain, forced abort, dup/stale publish reject, 2-agent isolation, deterministic rerun)
```

Regressions run after the change:

```
tools/nagent_gate.sh        PASS (O)
tools/nsecure_gate.sh       PASS (O)
tools/nreplay_gate.sh       PASS (O)
tools/nansched_mp_gate.sh   PASS (O)
tools/nobs_gate.sh          PASS (O)
tools/no_c_outside_tests.sh PASS (src outside src/tests is C-free)
```

## Honest limits

- This is a deterministic single-threaded policy state machine.  "Atomic
  publish" means one function performs validation, epoch bump, drain mark,
  start mark and root update with no intermediate return; it is not a
  hardware CAS.  Under real SMP a caller must serialize `ngen_publish` with
  a per-agent lock/CAS (for example the `nansched_mp` ops seam) or the
  substrate must execute the transition as one immutable block.  The gate
  proves the state/epoch ordering, not a concurrent race.
- There are four generation slots.  Publishing a fifth generation reuses a
  DRAINED or ABORTED slot (index `gen & 3`); if the target slot is still
  DRAINING the publish fails with `EBUSY`.  An agent cannot have more than
  the current plus three completed generations recorded at once.
- In-flight requests are counted, not individually identified.  `ngen_exit`
  trusts the caller's generation tag; it does not carry a request id.  A
  duplicated exit on a current slot with positive in-flight count would
  over-complete; callers must pair enter/exit exactly.
- Drain completion is immediate on the last exit.  There is no drain deadline
  or timeout in this slice; `ngen_abort` is the explicit forced path.
- The trace ring is 8 events.  The head and event count are exact, but old
  entries are overwritten; `ngen_trace` fails closed once an index has been
  overwritten.
- Root generation tags are monotonic counters, not hashes of the root
  contents.  A caller that mutates a root in place without publishing a new
  root value will not see a tag change.

## Frontier ideas

1. **Live model swap.** Bind `ngen_publish` to an immutable weight root and a
   per-generation model-load record, then gate an in-flight old-generation
   turn completing on the old root while the new generation decodes on the
   new root with bit-equal logits for each root.
2. **Generation-tagged KV.** Put the generation tag into every `nkv`/`npaged`
   block header, reject cross-generation block reads at the view layer, and
   gate a COW fork that publishes a new KV generation without copying shared
   prefix pages.
3. **Drain deadlines.** Add a deadline to a DRAINING slot, account ticks
   while it drains, and let the scheduler force `ngen_abort` at expiry with
   an exact abort reason and trace event; gate an early-complete path and a
   deadline-abort path.
4. **Rollback.** Keep the last N drained generation descriptors and allow
   `ngen_rollback(agent, gen)` only when the target is drained, its epoch is
   not newer than the last checkpoint, and every capability/KV generation
   still matches; gate successful rollback and rejection after a newer
   checkpoint.
