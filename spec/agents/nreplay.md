# nreplay — F8 deterministic RNG, trace replay, checkpoint replay

Status: **implemented and gated** (`tools/nreplay_gate.sh` emits exactly `O`).
This is the pure-NaN replay layer over `nantrace`/`nanobj`.  It does not replace
or rewrite either library; it adds a deterministic PRNG, a replay/expectation
engine, a divergence record, checkpoint replay and fail-closed budgets.

## Scope

F8: deterministic RNG with explicit state, hash-chained trace replay,
checkpoint suffix replay with identical head, divergence detection at an exact
event index, step/tick budgets and tick deadlines that fail closed, and no host
randomness.  No C is added.  `nan_cli` is the host oracle only.

## Files

| file | role |
|---|---|
| `src/lib/nreplay.nas` | pure-NaN PRNG, replay engine, divergence record, checkpoint replay, budgets/deadlines |
| `src/tests/nreplay_test.nas` | proof image; prints exactly `O` |
| `tools/nreplay_gate.sh` | emit/check, enforce the guest map, run twice, require one-byte `O` |

No shared library was modified.  `nreplay.nas` includes `nantrace.nas`
(which includes `nanobj.nas`) and therefore must be the only include of those
libraries in an image.

## Guest map and layout

```
0x03A0..0x03D2  nanobj/nantrace low globals (do not place code/data here)
0x0400..0x27FF  nreplay + test code in the proof image
0x2800..0x285F  nreplay engine globals (state, temps, header/event scratch)
0x3000..        test data in the proof image
0x7000..0x70FF  proof-image stack
0x340000        nanobj table (64 x 32 words)
0x362000        nantrace scratch (header/event buffers)
```

Code/data that links `nreplay` must stay out of `0x03A0..0x03D2` and end
below `0x2800`.  The proof image starts code at `0x400`, puts test data at
`0x3000`, and reserves 256 stack words at `0x7000`; the gate enforces the
layout.  nantrace objects live in the normal `nanobj` table, so their
addresses are capability words, not pointers.

## Deterministic PRNG

`nrng_*` is xorshift32 over an explicit 32-bit state at `NR_G_RNG`:

```
x ^= x << 13
x ^= x >> 17
x ^= x << 5
```

The state is always kept nonzero; `nrng_init(0)` maps to the fixed constant
`0x9E3779B9`.  `nrng_state_save` stores the state word in a caller buffer and
`nrng_state_restore` reloads it (zero maps to the same constant).  There is no
`RDTSC`, `TICK`, `KEY`, port I/O or host entropy in the library; the gate
rejects those mnemonics.  Same seed and same call sequence are bit-exact.

## Replay engine

```
nr_begin     seed, trace cap   -> 0 / -1
nr_event     kind, a, b        -> index / -1
nr_expect    kind, a, b        -> 0 / -1    (arms one expectation)
nr_observe   kind, a, b        -> index / -1
nr_ref       sealed trace cap  -> 0 / -1    (attach a verified reference)
nr_limits    step budget, tick deadline
nr_cost      steps, ticks      -> 0 / -1    (explicit accounting)
nr_head      -> trace head
nr_index     -> next event index
nr_status    -> 0 OK, 1 divergence, 2 step budget, 3 deadline, 4 trace/state
nr_div_index / nr_div_expected / nr_div_got
nr_head_check expected head    -> 0 / -1
nr_checkpoint caller buffer    -> 13 words / 0
nr_restore    caller buffer    -> 0 / -1
nr_seal / nr_verify            -> head / -1, 0 / -1
```

`nr_begin` binds an unsealed trace at its current count/head and initializes
the RNG; a resumed trace therefore continues deterministically.  `nr_event`
charges one step and one tick, appends through `ntrace_append`, and resyncs the
engine index/head from the trace header.

`nr_ref` accepts only a sealed reference trace and verifies the whole hash
chain before binding.  `nr_observe` compares the observed `{kind,a,b}` against
an armed explicit expectation first, otherwise against the reference event at
the engine's current index.  A match appends through `nr_event`; an armed
expectation is cleared on success.  An observation without any expectation, a
missing reference event, or a mismatched triple is a divergence.

The divergence record is three words:

```
index     the event index where comparison failed
expected  expected event hash (reference chain word, or hash of the
          expected triple from the current head)
got       hash of the observed triple from the current head
```

`nr_head_check` compares the engine head with a caller-supplied head and, on a
mismatch, records a divergence at the current index using `expected=head` and
`got=engine head`.

## Checkpoint record (13 words, caller supplied)

```
+0  magic "NRCP"           +1  version 1
+2  RNG state              +3  trace head
+4  event index            +5  steps used
+6  tick                   +7  status (must be 0)
+8  trace cap              +9  reference cap
+10 step budget            +11 tick deadline
+12 seal over words 0..11
```

`nr_checkpoint` requires: status 0, a bound trace, no armed explicit
expectation, an unsealed trace, and exact engine/header agreement on index and
head.  It writes the record and seals it with the same `nt_mix` chain used by
`nantrace`.

`nr_restore` requires status 0 and validates, in order: magic/version, seal,
saved status 0, trace cap equal to the bound trace, reference cap equal to the
bound reference, current trace unsealed, current header index/head equal to
the engine's, and saved index no greater than the current trace count.  It then
rewinds only the trace header's count/head to the checkpoint values, restores
RNG/head/index/steps/tick/budget/deadline, clears the divergence slots and
returns 0.  Replaying the same suffix overwrites the old suffix events and must
produce the same head; `nr_head_check` proves it.  Nothing is written until all
checks pass.  Restore is a rollback to a clean checkpoint, not a recovery path
after a divergence or budget failure: once `nr_status` is nonzero, restore is
refused, matching the fail-closed contract.

## Fail-closed behavior

Every mutating/observing/checkpoint/seal/verify entry point first calls
`nr_guard`.  If status is nonzero it returns `-1` without appending or
rewinding.  Budget/deadline charging happens before `ntrace_append`; an event
that would exceed a limit is not appended and leaves the trace index
unchanged.  A divergence, tamper or trace/header disagreement latches status
`1` or `4`.  `nr_begin` is the explicit reset path for a new run.

## Proof

`src/tests/nreplay_test.nas` verifies:

1. `seed1` produces eight draws; re-initializing with `seed1` reproduces all
   eight exactly.  Saving after three draws, generating four more, restoring
   and generating four more reproduces the same four.  `seed2` produces a
   sequence with at least one differing draw.
2. Trace A: `seed1`, four events whose `a/b` are PRNG draws; seal and verify
   through `nr_seal`/`nr_verify` and directly through `ntrace_verify`.
   Trace B with the same seed produces the identical head.  Trace C with
   `seed2` produces a different head and its own valid chain.
3. Checkpoint trace P: limits `10` steps / `100` ticks; two prefix events;
   `nr_checkpoint` returns 13 words; three suffix events reach index 5; the
   limits are cleared with `nr_limits(0,0)`; `nr_restore` returns to index 2
   and the checkpoint head; replaying the same three suffix events with the
   restored RNG reproduces the identical head, verifies, seals and verifies.
   Restored budget/step state is then proved: `nr_cost(5,0)` reaches step 10
   exactly and the next `nr_cost(1,0)` fails with status `2`.
4. Reference trace R: three fixed events, sealed and verified.  Clean replay
   (`nr_ref` + three `nr_observe`) appends all three, matches the reference
   head, passes `nr_head_check`, verifies, seals and verifies.
5. Mutated replay: observe event 0, then event 1 with `b=0x201`; `nr_observe`
   returns -1, status is `1`, divergence index is exactly `1`, expected and got
   differ, the trace index stays 1, and a subsequent `nr_event` also fails
   closed.
6. Omitted replay: observe event 0, then event 2 (skipping event 1);
   divergence is reported at exactly index `1` and the trace index stays 1.
7. Explicit expectation: `nr_expect(1,0x10,0x100)` + matching observe
   succeeds; `nr_expect(2,0x20,0x200)` + observe with `b=0x201` diverges at
   index `1`.
8. Tampered trace: seal and verify a two-event trace, overwrite event 0's kind
   through `nobj_write`, then `nr_verify` returns -1 and latches status `4`;
   `ntrace_verify` also returns -1.
9. Step budget: limits `2`/unlimited; two events fit, the third returns -1,
   status `2`, index remains 2, and a fourth event also fails closed.
10. Deadline: limits unlimited/`2`; `nr_cost(0,2)` succeeds, the next event
    returns -1, status `3`, index remains 0.

## Exact output

```
$ sh tools/nreplay_gate.sh
O
```

The gate also runs the same image a second time and compares the outputs
byte-for-byte; the guest output is exactly one byte (`O`, no newline).  The
image halts cleanly (`trap=''`).

## Regressions

```
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nanobj_gate.sh
nanobj_gate: PASS (typed objects, capability rights, revocation, forged-generation rejection, free)

$ sh tools/nagent_gate.sh
O

$ sh tools/nantrace_gate.sh
nantrace_gate: PASS (hash-chained trace, seal, verify, tamper rejection)
```

## Frontier ideas

1. **Replayable agent turns.** Bind `nagent_trace_append` to `nr_event` and a
   sealed reference trace; checkpoint the 24-word agent frame, scheduler slot,
   budget/deadline and nreplay record in one buffer.  Gate a two-CPU turn that
   restores on a different CPU and reproduces the same head.
2. **Deterministic tool calls.** Log SVC 42 `tool_call` arguments/results as
   replay events and derive request ids from `nrng_next`; require a failed or
   reordered tool call to diverge at its exact index before the capability
   result is admitted.  This makes tool use auditable and retry-safe.
3. **Divergence bisection.** Add `nr_replay_until` plus periodic checkpoints;
   on a mismatch, restore to the midpoint checkpoint and compare prefix heads
   to bisect the first divergent turn in O(log n) replays instead of O(n).
4. **Trace compaction.** Chunk nantrace storage through zero-copy tensor/KV
   views (F6), keep only checkpoint roots plus suffix events, and prove that
   replay from the compacted trace produces the identical head.  Combine with
   `nagent` generation seals so compaction cannot rewind a live epoch.
