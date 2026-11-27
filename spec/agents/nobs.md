# nobs — F12 observability/ops

Status: **implemented and gated** (`tools/nobs_gate.sh` emits exactly `O`).
This is the pure-NaN ops plane over the existing NanCore record, per-CPU
scheduler, NUMA topology and page allocator.  It adds statistics, quotas,
scheduler traces, health snapshots and a pressure/eviction path.  No C is
added; `aarch64/android/nan_cli` is the host oracle only.

## Scope

F12: per-core stats, allocator/OOM/eviction accounting, per-agent quotas,
scheduler trace ring, health snapshot, and an exact node/class pressure path.
The layer consumes the real `nancore` record shape (through `nansched_mp`),
the real `nansched_mp` per-CPU counters, `nnuma` topology and `nheap` pages.
All storage remains caller supplied; there is no hidden heap.

## Files

| file | role |
|---|---|
| `src/lib/nobs.nas` | new pure-NaN ops layer: core sample, memory stats, quotas, trace ring, health, pressure/eviction |
| `src/tests/nobs_test.nas` | proof image; four CPUs, two NUMA nodes, real scheduler/heap/topology; prints exactly `O` |
| `tools/nobs_gate.sh` | static layout checks, `nmk` emit/check, two byte-identical runs, exact one-byte `O` |

`nobs.nas` includes `nansched_mp.nas` and `nnuma.nas` (which includes
`nheap.nas` and `n64.nas`).  The test image adds only the single-thread nansmp
shim and its topology/table storage.

## Layouts

Context (32 words):

```
+0  magic "NOBS"          +1  version 1
+2  cpus                  +3  nodes
+4  classes (3)           +5  tick
+6  heap ctx              +7  sched ctx
+8  core stats base       +9  mem stats base
+10 quota base            +11 ring base
+12 ring capacity         +13 ring head (next slot)
+14 ring count            +15 ring total (logical events)
+16 ring wraps            +17 quota denials
+18 OOM events            +19 eviction extents
+20 eviction pages        +21 cold ledger base
+22 cold capacity         +23 cold count
+24 cold search head      +25 health status
+26 samples               +27 last trace hash
+28..31 reserved
```

Config (16 words): `cpus, nodes, classes, heap ctx (0 allowed), sched ctx
(0 allowed), core stats, mem stats, quota base, ring base, ring capacity,
cold base, cold capacity, 4 reserved`.

Per-core stats, 16 words per CPU: `ticks, tasks run, steals in, steals out,
migrations in, migrations out, faults, IPIs, queue depth, budget misses,
deadline misses, state, timer, preemptions, events, reserved`.

Per-(node,class) stats, 16 words per record: `allocs, frees, live pages
(lo,hi), live bytes (lo,hi), evicted pages (lo,hi), evicted bytes (lo,hi),
OOM events, denied pressure requests, high-water pages (lo,hi), eviction
extents, reserved`.  Classes are `0=4 KiB, 1=2 MiB, 2=1 GiB`.

Quota record, 16 words for each of 32 agents (index `agent-1`): `active,
agent id, max steps, used steps, max ticks, used ticks, max memory (lo,hi),
used memory (lo,hi), max KV tokens, used KV tokens, denied, flags, 2
reserved`.  A zero limit means unlimited.

Trace entry, 8 words: `tick, cpu, kind, id, a, b, hash, seq`.  `cpu =
0xFFFFFFFF` means the event is not CPU-local.  Kinds:

```
1 PUSH   2 POP   3 STEAL   4 MIGRATE   5 PREEMPT   6 TICK
7 FAULT  8 IPI   9 BUDGET  10 DEADLINE 11 QUOTA
12 OOM   13 EVICT 14 SNAPSHOT 15 PRESSURE
```

Cold ledger entry, 8 words: `node, class, pages (lo,hi), base (lo,hi),
state, reserved`.  It is a bounded FIFO of extents that may be evicted.

Health snapshot, 32 words:

```
+0  magic "NOBH"         +1  version
+2  cpus                 +3  nodes
+4  classes              +5  tick
+6  total ticks          +7  total tasks
+8  total steals         +9  total migrations
+10 total faults         +11 total IPIs
+12 total budget misses  +13 total deadline misses
+14 total queue depth
+15 allocs               +16 frees
+17 live pages (lo,hi)   +19 live bytes (lo,hi)
+21 OOM events           +22 eviction extents
+23 evicted pages (lo,hi)
+25 quota denials        +26 ring total
+27 ring wraps           +28 status
+29 samples              +30 ring count
+31 reserved
```

Status is `0` healthy, `1` degraded (a budget/deadline miss, eviction or
quota denial), `2` OOM.

## API

```
nobs_init          ctx, config                         -> 0 / -1
nobs_tick          ctx, delta                          -> new tick
nobs_core_sample   ctx, cpu                            -> 0 / -1
nobs_core_event    ctx, cpu, kind, amount              -> 0 / -1
nobs_core_get      ctx, cpu, out(16)                   -> 0 / -1
nobs_mem_alloc     ctx, node, class, pages_lo, pages_hi, out(2)
                                                       -> 0 / -1
nobs_mem_free      ctx, node, class, base_lo, base_hi, pages_lo, pages_hi
                                                       -> 0 / -1
nobs_mem_cold      ctx, node, class, spec(4)           -> 0 / -1
nobs_mem_pressure  ctx, node, class, pages_lo, pages_hi
                                                       -> 0 / 1 / 3
nobs_mem_stats     ctx, node, class, out(16)           -> 0 / -1
nobs_quota_set     ctx, agent, spec(6)                 -> 0 / -1
nobs_quota_check   ctx, agent, kind, lo, hi            -> 0 / 1 / 3
nobs_quota_account ctx, agent, kind, lo, hi            -> 0 / 1 / 3
nobs_quota_get     ctx, agent, out(16)                 -> 0 / -1
nobs_trace         ctx, kind, cpu, id, a, b            -> hash / 0
nobs_trace_at      ctx, index, out(8)                  -> 0 / -1
nobs_trace_snapshot ctx, out, max                      -> entries copied
nobs_trace_last    ctx, out(8)                         -> 0 / -1
nobs_health        ctx, out(32)                        -> 0 / -1
```

Core event kinds are `0` fault, `1` budget miss, `2` deadline miss, `3` IPI,
`4` timer and `5` generic event.  Quota kinds are `0` CPU steps, `1` CPU
ticks, `2` memory bytes and `3` KV tokens.  A bad context, CPU, node, class,
agent or kind returns `-1`/`3` without mutating counters.  `nobs_init`
validates the config, zeroes every caller buffer and requires three page
classes.

### Core sampling

`nobs_core_sample` reads the NanCore record (`NC_STATE`, `NC_QCOUNT`,
`NC_IPI`, `NC_TIMER`, `NC_PREEMPT`) and, when a scheduler context is bound,
the `nansched_mp` per-CPU counters (`NSD_S_POP`, `NSD_S_STEAL_IN/OUT`,
`NSD_S_MIG_IN/OUT`, `NSD_S_PREEMPT`, `NSD_S_TICKS`).  It publishes
`NC_TICKS` and `NC_PREEMPT` back into the NanCore record, so the record stays
the single per-core status word.  Fault and budget/deadline counters have no
NanCore field; they are attributed with `nobs_core_event` at the hook that
knows the CPU.  Sampling is idempotent for the counters it reads and only
increments the context `samples` count.

### Memory and pressure

`nobs_mem_alloc` calls `nheap_alloc` and accounts `allocs`, live pages/bytes
(64-bit) and the high-water mark.  A failure increments the class/global OOM
counters and appends an OOM trace event.  `nobs_mem_free` calls `nheap_free`
and accounts `frees` and the live-page/byte decrement.  `nobs_mem_cold`
registers an already-live extent in the cold ledger.

`nobs_mem_pressure` first retries the allocation.  If the class is exhausted,
it walks the cold FIFO for a matching node/class, returns that extent to
`nheap`, accounts one eviction extent plus its pages/bytes (and removes them
from live), records an `EVICT` event, and retries.  It repeats until the
allocation succeeds or no cold extent is left; the latter increments the
class `oom`/`deny` and global OOM counters, records an `OOM` event and returns
`1`.  The heap is therefore the authority for free pages while `nobs` owns
the live/eviction/OOM ledger.

### Quotas

`nobs_quota_set` installs the four limits and resets the used/denied words.
`nobs_quota_check` is a pure fit test.  `nobs_quota_account` admits and
charges the used word(s), or denies without charging, increments the record
and context denial counters, and appends a `QUOTA` event carrying the agent,
resource kind and amount.  A denied request never partially charges.

### Trace ring

The ring is a bounded overwrite ring.  `ring_total` is the logical sequence;
`seq % capacity` is the slot, so once the ring wraps, older logical indices
fail closed in `nobs_trace_at` (`index < ring_total - capacity`), while
`ring_count` stays at capacity and `ring_wraps` is `ring_total - capacity`.
`nobs_trace_snapshot` copies the live window oldest-to-newest.
`nobs_trace_last` returns the newest entry.  The 32-bit entry hash is a mix
chain over `tick, cpu, kind, id, a, b, seq` with the same constants as the
agent/replay seals; it is deterministic and never zero.

## Proof

`src/tests/nobs_test.nas` builds a two-node topology (four 4 KiB pages and
two 2 MiB pages on node 0, four 4 KiB pages on node 1, plus a reserved range
and an MMIO range that must never reach `nheap`), feeds it through
`nnuma_heap_add`, and then runs four logical CPUs through the real
`nansched_mp` policy with a single-thread nansmp shim.

The gate proves, with exact values:

1. **Topology/heap**: `nnuma_verify` passes; node0 has 4x4K + 2x2M, node1 has
   4x4K; reserved/MMIO ranges are absent.
2. **Scheduler**: 4 pushes, 5 pops, 2 steals, 2 migrations, 1 budget miss,
   1 deadline miss, 5 preemptions, 6 accounted ticks, 2 IPIs.  After sampling,
   CPU0 = `(ticks0, tasks1, steal_out2, mig_out1, q0)`, CPU1 =
   `(tasks1, steal_in1, mig_in1, ipis2, q1)`, CPU2 =
   `(faults3, ipis1, mig_in1, q1)`, CPU3 =
   `(ticks6, tasks3, steal_in1, preempt3, budget1, deadline1, q2)`.
   `NC_TICKS` on CPU3 is published as 6 and `NC_IPI` on CPU1 is 2.
3. **Memory**: five allocations, one free, live pages 5 / 0x5000 bytes;
   pressure evicts one cold extent of 2 pages (0x2000 bytes), retries and
   succeeds; the second pressure request denies with one OOM event.  The
   per-class stats are exact and `nheap_stats` cross-checks 0/2/3 free pages
   on node0/4K, node0/2M and node1/4K.
4. **Quotas**: agent 1 limits `steps10/ticks5/mem64/KV3`; usage ends at
   `4/3/32/2`, four requests denied (steps, ticks, memory, KV), check/account
   agree, and four `QUOTA` events are in the ring.
5. **Trace ring**: capacity 8, 24 events, 16 wraps, 8 live entries; logical
   indices 0 and 15 fail closed, index 16 is a CPU3 `POP`, the 8-entry
   snapshot ends with the KV denial at tick 1024/seq 23, and its hash is the
   exact deterministic value `0x7CCD2B3F`.
6. **Health**: magic `NOBH`, version 1, 4 CPUs, 2 nodes, 3 classes, tick 1024,
   totals `ticks6/tasks5/steals2/migrations2/faults3/IPIs3/budget1/
   deadline1/qdepth4`, `allocs5/frees1/livep5/liveb0x5000/OOM1/evict1/
   evp2`, `qdeny4`, `ring24/wraps16/count8`, `samples4`, status 2 (OOM).

The image is 5923 words and stays below the 0x7000 stack; `nmk check`
reports 0 mismatches.  Two gate runs are byte-identical.

## Exact output

```
$ sh tools/nobs_gate.sh
O
```

The gate requires one output byte and no newline.  A direct run at this
revision:

```
$ ./aarch64/android/nan_cli --img tmp/nobs/final.nan --mem 64 \
    --steps 5000000 --serial
O
[nan_cli] nan-text: 32123 steps, rc=3, pc=5737, trap=''
```

`rc=3` is the normal guest `HALT`; the gate accepts success only after the
exact one-byte `O`.

## Regressions

```
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nansched_mp_gate.sh
O

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)

$ sh tools/nnuma_gate.sh
nnuma: PASS (sparse nodes 0/2, 5 GiB bases, holes/reserved/ACPI/MMIO skipped, APIC->node, per-node 4K/2M/1G heap stats + exhaustive allocation)

$ sh tools/nagent_gate.sh
O
```

## Frontier ideas

1. **Live agent dashboard.**  Bind `nobs_core_sample` and the quota table to
   `nagent` ids, expose a per-agent view (cpu/node, steps, ticks, bytes, KV,
   denials, trace head) and refresh it from the scheduler tick.  Gate a
   two-agent dashboard where one agent's quota denial does not perturb the
   other's counters.
2. **OOM policy as data.**  Replace the fixed cold-FIFO policy with a scored
   victim table (recency, KV attention mass, node distance, quota overage)
   and gate policy selection with a deterministic score and a no-cross-node
   eviction rule.  Keep the deny path and OOM event identical.
3. **Quota-aware scheduling.**  Feed the remaining quota into `nansched_mp`
   admission: park an agent at its CPU-step or memory limit before dispatch,
   reserve a class for interactive agents, and gate admit/park/resume with
   exact per-core budget and deadline counters.
4. **Trace export and replay join.**  Stream the ring into `nantrace`/`nreplay`
   chunks with the same hash chain, then gate that replaying an exported
   scheduler window reproduces the same ring head and the same health totals.
