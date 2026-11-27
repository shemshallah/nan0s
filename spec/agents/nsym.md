# nsym — symbiotic multi-agent scheduling (F13f)

Status: implemented and gated (2026-11-27). Agent slot A12.

Files (raw NaN product code, zero C):

- `src/lib/nsym.nas` — shared immutable weight roots with refcounts, per-agent
  ngen generations, per-agent budgets/deadlines/reservations and a deterministic
  weighted fair queue over two CPU service slots.
- `src/tests/nsym_test.nas` — full 3-agent/2-CPU scenario, run twice from a cold
  init with a word-for-word 1184-word snapshot comparison.
- `tools/nsym_gate.sh`.

No shared library was modified.  `nansched_mp.nas`, `nagent.nas`, `ngen.nas`,
`nheap.nas`, `nnuma.nas`, `nobs.nas` and the other agent's `noc` files were not
touched.  `nsym.nas` includes `ngen.nas` and reuses its generation slots; there
is no C harness and no C product code.  No git commit was made.

## Layout

Roots: 16 records, stride 32 words, at `0x354000` (512 words).

```
+0  magic "NSWR" (0x5257534E)   +1 state (1 live, 0 free)
+2  refs                        +3 immutable root id
+4  content hash                +5 immutable version (1)
+6  payload words (<=16)        +7 created tick
+8  total acquires              +9 total releases
+10 peak refs                  +11 verify calls
+12..15 reserved               +16..31 immutable payload (16 words)
```

The payload is copied exactly once by `nsym_root_create`; `nsym_join` and
`nsym_root_acquire` only increment `refs`, `acquires` and `peak`.  There is no
write API.  `nsym_root_verify` recomputes the hash over id/version/words/payload.
`nsym_root_release` frees only when `refs` reaches zero, emits a `root_free`
trace event and clears the record.

Agents: 8 records, stride 128 words, at `0x355000` (1024 words).

```
+0  magic "NSYM" (0x4D59534E)   +1 state (1 joined, 2 unjoined, 0 free)
+2  agent id                    +3 weight (1..255)
+4  reserve (current job)       +5 reserve_left
+6  budget max                  +7 budget left
+8  deadline (absolute tick)    +9 vrt (Q16)
+10 pending work ticks          +11 backlog (pending jobs)
+12 served ticks                +13 admissions
+14 completions                 +15 deadline misses
+16 budget denials              +17 reservations met
+18 reservation misses          +19 last service tick (0xFFFFFFFF none)
+20 max service gap             +21 current ngen generation
+22 ngen epoch                  +23 root index (0xFFFFFFFF none)
+24 root id                     +25 root hash
+26 root joins                  +27 root leaves
+28 parked jobs                 +29 last error
+30 dispatch events             +31 join epoch (immutable)
+32..63 four 8-word jobs        +64 ready-since tick
+65..127 reserved
```

Job: `id, work, remaining, deadline, reserve, reserve_left, state, ngen tag`.
States: 0 free, 1 queued, 2 running, 3 done, 4 deadline miss, 5 budget parked.
The budget/deadline fields mirror `nansched_mp`'s task semantics
(`NSD_T_BUDGET` = ticks left, `NSD_T_DEADLINE` = absolute tick).

Global block: 32 words at `0x356000`.

```
+0 magic +1 version +2 tick +3 service ticks +4 admits +5 completions
+6 deadline misses +7 budget denials +8 reservation misses
+9 roots created +10 root acquires +11 root releases +12 roots freed
+13 agent joins +14 agent leaves +15 publishes +16 drains +17 starts
+18 trace head +19 trace events +20 trace wraps +21 errno
+22 agents +23 rounds (dispatch ticks) +24 service dispatches +25 idle slots
+26 max service gap +27 admitted work +28 reservations met
+29 stale admissions +30 parked jobs +31 rejected admissions
```

Trace: 512 entries, 8 words each, at `0x356100`:
`tick, cpu, kind, agent, a, b, hash, seq`.  CPU `0xFFFFFFFF` means non-CPU
local (root and deadline-sweep events).  Kinds: root create, agent join, agent
leave, root free, agent create, admit, dispatch, complete, deadline miss,
budget deny, publish, drain, start, reservation met, stale admission.  The hash
is the same xor/multiply chain shape as `nagent`/`ngen`/`nreplay` with an NSYM
seed.

## Scheduling semantics

Each `nsym_dispatch` advances one tick and selects up to two agents, one for
CPU0 and one for CPU1.  The CPU1 pick excludes the CPU0 agent, so an agent is
served at most once per tick.  Selection is:

1. **Reservation pass.**  A pending job with `reserve_left > 0` and a nonzero
   deadline is ordered by earliest deadline, then smallest vrt, then agent id.
2. **Fair-share pass.**  The remaining candidates are ordered by smallest vrt,
   then agent id.  A served tick adds `65536 / weight` to vrt (Q16).  Ties keep
   the lower agent id.

`nsym_admit` enters the agent's current ngen generation and fails closed with
`ESTALE` if that generation is draining/stale.  Completion, budget parking and
deadline parking call `ngen_exit`.  `nsym_publish` joins a new root (if any),
calls `ngen_publish` with one epoch, then releases the old root; the old and new
generations coexist, and the old generation's in-flight jobs still exit through
their stored generation tag.  `nsym_drain` and `nsym_start` expose the ngen
freeze/start pair directly.

Budget is a total CPU-tick cap.  A job that exhausts it is parked with its
remaining ticks, counted once in the budget-denial counter, and never runs
again.  A subsequent admission at budget zero is rejected with `EBUDGET` and
also counted.  Deadline is absolute.  After both CPU slots of tick `t` have
run, any pending job with `remaining > 0` and `deadline <= t` is parked and
charged exactly one deadline miss; a job that completes in tick `t == deadline`
is on time.

On two CPUs a single agent can occupy at most one service slot per tick, so its
maximum achievable share is 1/2.  Fairness is stated for weights whose share
`w_i / W <= 1/2`; the gate uses weights 1,2,3 (`W = 6`).  The measured bound is

```
|s_i * W - w_i * S| <= W
```

i.e. at most one weight quantum of service error for every agent.  This is the
same "no starvation" statement: a continuously backlogged agent cannot be
skipped by more than one weight quantum.

## Proof

The gate executes the following deterministic scenario twice from `nsym_init`
and compares 1184 words: 32 global, two full root records, eight full agent
records, and the last eight trace entries.

1. **Shared root.**  R0 is created with id `0x100` and a 16-word payload; the
   payload and hash are saved.  Agents 1/2/3 join R0.  Refs become 1,2,3, peak
   3, root joins 3.  The saved payload/hash still match, and every agent only
   caches the root id/hash.
2. **Three fairness rounds, 2 CPUs.**  Agents 1/2/3 have weights 1/2/3 and work
   20/40/60 with generous deadlines and budgets.  After 20 ticks, service is
   40: served `[7,14,19]`, vrt `[458752,458752,415055]`, idle 0, max gap 3.
   After 40 ticks, service is 80: served `[14,27,39]`, vrt
   `[917504,884736,851955]`, idle 0.  After 21 more ticks all work is drained:
   service 120, served `[20,40,60]`, vrt `[1310720,1310720,1310700]`, idle 2,
   max gap 3, three completions.  At each checkpoint the ratio test computes
   `s_i*6 - w_i*S`; the worst errors are `(2,4,-6)`, `(4,2,-6)` and `(0,0,0)`,
   all within the documented bound 6.  R0 refs remain 3 and its payload/hash
   are unchanged.
3. **Generation isolation.**  R1 is created with id `0x200`; its record is saved.
   Agents 2/3 admit 3-tick jobs on R0/generation 1.  Agent 1 publishes
   generation 2 onto R1 at epoch 2.  R0 refs drop 3->2 with leaves 1; R1 refs
   become 1.  Agents 2/3 remain on root 0/generation 1 with in-flight 1,
   served 40/60 and unchanged vrt; agent 1 is root 1/generation 2, epoch 2.
   Both roots' payloads and hashes still match their saved copies.  A new
   generation-2 job on agent 1 plus the two old jobs drain in 4 ticks: service
   128, completions 6, agent served `22/43/63`.
4. **Drain/start.**  Agent 1 drains generation 2 at epoch 3; an old-generation
   admission returns 0 with `ESTALE`, charging one stale rejection and one
   rejected admission.  `nsym_start(1,3)` starts generation 3 at epoch 4 with
   the same R1 reference.  Agent 3 still admits and completes one job on
   generation 1; the run advances to tick 66, service 129.
5. **Reservation under contention.**  Agents 4/5/6 join R1 (refs 4, peak 4)
   with weights 1/2/3.  Agent 4 has work 6, reserve 6 and an absolute deadline
   six ticks ahead.  With three agents competing for two CPUs, agent 4 receives
   its six reserved ticks and completes by tick 71 (deadline 72): reserve met
   1, deadline misses 0, served 6, budget left 14.  Agents 5/6 receive 24/12
   ticks.  The phase takes 28 ticks with 17 cumulative idle slots and global
   max gap 3.
6. **Budget enforcement.**  Agents 7/8 join R1 (refs 6, peak 6).  Agent 7 has
   weight 2, budget 5 and 10 ticks of work; it is served exactly 5 ticks, then
   its job is parked with 5 ticks left and one budget denial.  Agent 8 finishes
   12 ticks.  A later admission on agent 7 at budget 0 is rejected with
   `EBUDGET`, taking global budget denials to 2 and rejected admissions to 2.
7. **Deadline miss.**  Agent 4 admits 20 ticks with deadline `now+1`.  It is
   served on the first tick and the next tick; at the end of the deadline tick
   it still has 18 ticks left, so it is parked and charged exactly one deadline
   miss.  Final tick 108, service 190, idle 26, max gap 3.
8. **Refcount/join/leave/free.**  Leaving agent 2 drops R0 to refs 1; R0 is
   still live and its payload/hash still match.  Leaving agent 3 drops R0 to
   zero: R0 is freed, its id/refs/state become zero, `verify` and `acquire`
   fail, and global root frees is 1.  R1 goes 6->5->4->3->2->1->0; it stays
   live at one reference and is freed on the last leave.  Root frees 2, releases
   9, leaves 8.
9. **Final exact counters.**  tick 108, service 190, admits 13, completions 11,
   deadline misses 1, budget denials 2, reservation misses 0, roots created 2,
   acquires 9, releases 9, frees 2, joins 8, leaves 8, publishes 1, drains 9,
   starts 1, trace events 250, wraps 0, agents 8, rounds 108, service
   dispatches 190, idle 26, max gap 3, admitted work 213, reservations met 1,
   stale admissions 1, parked jobs 2, rejected admissions 2.  The final trace
   head is `0x25CB33BE`; the last two entries are `leave(agent 8)` and
   `root_free(R1, id 0x200, seq 249)`.  Final errno is `ENOENT` from the
   freed-root queries.
10. **Determinism.**  The scenario is replayed from `nsym_init`; all 1184
    snapshot words (including the exact trace head and the last eight hash
    chains) are identical.

Per-agent exact final values from the run include: agent 1 served 22, admitted
2, completed 2, budget left 78, vrt 1441792, max gap 3, generation 3, epoch 5,
root joins/leaves 2/2; agent 2 served 43, max gap 2; agent 3 served 64, max gap
1; agent 4 served 8, admitted 2, budget left 12, deadline misses 1, reservation
met 1, parked 1; agent 5 served 24, max gap 3; agent 6 served 12, vrt 262140;
agent 7 served 5, budget denial 2, parked 1; agent 8 served 12, completed 1.

## Exact gate output

```
$ ./tools/nsym_gate.sh
O
nsym: PASS (3-agent WFQ over 2 CPUs, bounded ratio, no starvation, reservation by deadline, budget park + budget reject, deadline miss, shared-root refcount/join/leave/free, generation publish/drain/start isolation, deterministic rerun)
```

Regressions run after the change:

```
tools/nansched_mp_gate.sh   PASS (O)
tools/nagent_gate.sh        PASS (O)
tools/ngen_gate.sh          PASS (O + ngen PASS line)
tools/nheap_gate.sh         PASS (nheap PASS line)
tools/nnuma_gate.sh         PASS (nnuma PASS line)
tools/nobs_gate.sh          PASS (O)
tools/no_c_outside_tests.sh PASS (src outside src/tests is C-free)
```

## Honest limits

- This is a deterministic single-threaded policy state machine.  "2 CPUs" means
  two service selections per dispatch tick, not two hardware threads touching
  shared records concurrently.  There is no CAS/fence in this slice; a real SMP
  caller must serialize root acquire/release, admission and the ngen transition
  (for example through the `nansched_mp`/`nansmp` ops seam) or execute a
  transition as one immutable block.  The gate proves ordering and accounting,
  not a memory-race outcome.
- The root payload is 16 words: a sealed control descriptor/hash, not a
  multi-terabyte tensor store.  It proves immutable identity, refcount and
  zero-copy join/leave at the policy layer; it does not prove weight bandwidth
  or page-table sharing.  Real weights would be a read-only capability/root
  pointer with the same refcount discipline.
- WFQ uses integer Q16 vrt with truncating `65536 / weight`.  The documented
  bound is checked for weights 1/2/3.  Other weights, especially non-divisors,
  can drift by more than one quantum; do not generalize the measured constant.
  A single agent cannot exceed 1/2 of two-CPU service, so weight shares above
  1/2 are capped and are outside the fairness claim.
- Capacity is 8 agents, 16 roots, 4 outstanding jobs per agent and 512 trace
  entries.  A done/missed/budget-parked slot is recycled only when no unused
  slot is available, so an agent can run more than four jobs over its lifetime.
  Jobs are not individually identified beyond the caller's job id; queue
  ordering is smallest-id-first (callers should use monotonic ids).
- Budget is a total tick cap, not a per-window replenishing quota.  A parked
  job's remaining work is dropped from the pending set (counted in the park
  counters); there is no resume/rollback of parked work in this slice.
- Deadline resolution is one tick.  A job still pending after the deadline tick
  is parked; the scheduler does not attempt partial late service or deadline
  inheritance.  Deadline sweeps are serialized after both CPU picks.
- `nsym_leave` requires no pending jobs and refuses with `EBUSY` otherwise.
  Parked/missed jobs are already out of the pending set and their generations
  have exited, so leave is allowed and their unserved work is dropped.  Rejoin
  after leave is not supported (`EJOINED`).
- The ngen slice still has four generation slots, counts in-flight requests
  rather than identifying them, and treats publish as atomic only within one
  function call.  Those limitations carry over unchanged.
- No real timer, interrupt or IPI drives the scheduler; the caller advances
  ticks with `nsym_dispatch`/`nsym_run`.  The gate is a policy proof, not a
  latency measurement.

## Frontier ideas

1. **Symbiotic agent teams.**  Give a team one shared root and a team-level
   budget, then schedule producer/consumer agents as a group: a drafter and a
   verifier exchange KV prefixes, and a tool agent's deadline gates the team's
   admission.  Gate a two-agent token handoff where the verifier accepts only
   the drafter's published generation and team fairness is measured against a
   team share rather than per-agent weights.
2. **Shared-prefix weights.**  Make weight roots hierarchical (`root ->
   prefix pages`) with a refcount per prefix and copy-on-write only on the
   diverging suffix.  Tag every `nkv`/`npaged` prefix block with the root
   generation, then gate a parent/child adapter branch that shares almost all
   pages, publishes its own generation, and keeps the parent's reads unchanged.
3. **Deadline-aware KV.**  Reserve KV pages and allocation budget together with
   CPU ticks.  At admission, use `nobs` quota headroom and `npaged` residency to
   reject or defer a job whose deadline cannot be met after a page fault or
   eviction; gate a pressure case where eviction is chosen over a deadline miss,
   then the reverse when the deadline is already infeasible.
4. **Cooperative migration.**  Move an agent's queue, vrt, reservation, budget,
   generation tag and root reference as one handoff between CPUs/nodes.  Use the
   `nansched_mp` ops seam for a two-lock remove/enqueue and a destination epoch
   fence, and gate that no tick is served twice, the source queue is empty, and
   the shared root refcount and generation are unchanged by the move.
