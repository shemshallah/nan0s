# F2 — pure-NaN per-CPU NanCore scheduler

Status: **implemented and gated** (`tools/nansched_mp_gate.sh` emits exactly
`O` for 2-CPU and 4-CPU simulations).  This is the policy layer, not a claim
that the AP trap/IPI path is already wired; that belongs to F1/F4.

## File-name note (important)

`src/lib/nansched.nas`, `src/tests/nansched_test.nas` and
`tools/nansched_gate.sh` already exist for the production single-core nan0s
kernel scheduler.  They were not overwritten.  The F2 layer is a separate
self-contained module imported at the end of `src/lib/nansched.nas`, and the
F2 proof uses `_mp` names so both schedulers keep their gates:

| requested name | existing owner | F2 file |
|---|---|---|
| `src/lib/nansched.nas` | kernel process scheduler | imports `src/lib/nansched_mp.nas` at EOF |
| `src/tests/nansched_test.nas` | kernel scheduler transcript test | `src/tests/nansched_mp_test.nas` |
| `tools/nansched_gate.sh` | kernel scheduler gate | `tools/nansched_mp_gate.sh` |

## Files

| file | role |
|---|---|
| `src/lib/nansched.nas` | kernel scheduler; one additive `.include "nansched_mp.nas"` at EOF |
| `src/lib/nansched_mp.nas` | per-CPU FIFO, steal, affinity, migration, budget/deadline, stats |
| `src/lib/nansched_nansmp.nas` | binds the scheduler ops table to real `nsp_*` |
| `src/tests/nansched_mp_test.nas` | 2-CPU and 4-CPU proof image (`TEST_CPUS`) |
| `tools/nansched_mp_gate.sh` | exact `O` gate using `tools/nmk.awk` + `nan_cli` |

No C was added.  `nancore.nas` and `nansmp.nas` were not modified.

## Record and queue layout

The per-CPU run queue lives in the existing 64-word NanCore record:

```
NC_QHEAD  (+14)  encoded task id + 1, 0 empty
NC_QTAIL  (+15)  encoded tail
NC_QCOUNT (+27)  runnable count
word +32         current task id + 1, 0 none   (scheduler extension)
word +33         queue lock word                (scheduler extension)
```

Words 0..31 keep the NanCore meaning from `src/lib/nancore.nas`; F2 only owns
32/33 and the three queue fields.  A task link is the task record's `next`
word, encoded `id+1`.

The caller supplies the arena.  A 16-word task record contains state, current
CPU, home CPU, 32-bit affinity mask, remaining budget, deadline, next link, id,
flags (deadline miss / migration pending), migration target, migration epoch,
magic `0x4E53`, quantum and four payload words.  The context contains CPU and
arena geometry, the ops table pointer, tick/epoch, global counters, and eight
stats words per CPU.

## API

```
nsched_init(ctx,cpus,arena,stride,capacity,ops)
nsched_task_add(ctx,id,home,affinity,budget,deadline)
nsched_push(ctx,cpu,id)
nsched_pop(ctx,cpu)
nsched_steal(ctx,cpu)
nsched_preempt(ctx,cpu)
nsched_tick(ctx,cpu)
nsched_migrate(ctx,id,from,to)
nsched_migrate_request(ctx,id,to)
nsched_affinity(ctx,id,mask)
nsched_budget(ctx,id,value)
nsched_deadline(ctx,id,value)
nsched_peek(ctx,cpu) / nsched_current(ctx,cpu) / nsched_qlen(ctx,cpu)
```

`pop` refuses to orphan a running task (`0xFFFE`), `steal` only runs when the
thief queue is empty, and affinity is checked on push, steal, migration and
affinity narrowing.  A deadline miss is recorded once per task (flag bit 0);
a budget-exhausted tick requeues the task at the tail.  `pop` refills the
remaining budget from the task quantum.

## Atomics and real nansmp binding

Policy code never embeds a host call.  Queue locks and counters go through a
six-word ops table:

```
cas / fetch_add / fence / trylock / unlock / ipi
```

`nsched_bind_nansmp(ctx)` fills it with `nsp_cas`, `nsp_fetch_add`,
`nsp_fence`, `nsp_trylock`, `nsp_unlock` and `nsp_ipi`.  The test image includes
the adapter, executes the binding, compares all six pointers with the assembled
symbols, then restores a single-thread shim with the same value semantics.  The
gate therefore proves both the nansmp wiring and the policy; it does not claim
that APs executed the atomics yet.  The actual AP execution is F1/F4.

The gate runs `nan_cli --mem 64`: the NanCore table starts at guest word
`0x400000` (16 MiB of words), so a 16 MiB guest wraps that address.  The 64 MiB
window makes the table real.

## Proof (2 CPUs)

`TEST_CPUS=2` performs:

1. FIFO `push 0, push 1, pop 0, preempt, pop 1, preempt`;
2. steal task 0 from CPU0 into empty CPU1;
3. two affinity rejections followed by legal pushes;
4. migration request, then `migrate 3 CPU0->CPU1` (source queue removal is the
   non-head scan path);
5. FIFO drain of CPU1 (`0,4,3`) with preemptions;
6. seven ticks exhausting task 1's quantum, then a deadline miss and budget
   exhaustion for task 3 on CPU1.

Exact final values checked by the image at the stats checkpoint:

| counter | value |
|---|---|
| pushes / pops | 4 / 7 |
| steals / migrations | 1 / 1 |
| affinity rejects | 2 |
| budget exhausts / deadline misses | 2 / 1 |
| preemptions / IPIs | 7 / 1 |
| migration requests / epoch | 1 / 1 |
| global tick | 9 |

Per-CPU stats `(push,pop,steal_in,steal_out,mig_in,mig_out,preempt,ticks)`:

```
CPU0 = (3,3,0,1,0,1,3,7)   queue [1]
CPU1 = (1,4,1,0,1,0,4,2)   queue [0,4,3]
```

Both currents are none; task 1 and task 3 have budget 0, task 3 has the
deadline flag and migration epoch 1.  A final smoke step pops task 1 (running
on CPU0) and migrates the live task to CPU1; the image checks that CPU0's
current is cleared, CPU0's queue is empty and CPU1's queue grew to four.

## Proof (4 CPUs)

`TEST_CPUS=4` adds CPU2/CPU3, exercises the same FIFO/steal/affinity patterns,
migrates task 3 from CPU0 to CPU3, runs a two-quantum task with deadline 1 on
CPU2, and narrows a ready task's affinity while rejecting a narrowing that
would strand the current CPU.

| counter | value |
|---|---|
| pushes / pops | 5 / 6 |
| steals / migrations | 1 / 1 |
| affinity rejects | 2 |
| budget exhausts / deadline misses | 1 / 1 |
| preemptions / IPIs | 5 / 1 |
| epoch / global tick | 1 / 2 |

Per-CPU stats:

```
CPU0 = (3,2,0,1,0,1,2,0)   queue [1]
CPU1 = (0,1,1,0,0,0,1,0)   queue [0]
CPU2 = (1,1,0,0,0,0,1,2)   queue [5]
CPU3 = (1,2,0,0,1,0,1,0)   queue [4], current task 3
```

The image also checks task 5 budget 0, deadline flag set, affinity narrowed to
7, and task 3 epoch 1.

## Gate transcript

```
$ sh tools/nansched_mp_gate.sh
O
```

The gate captures exactly one byte (`0x4F`): no trailing text, no C harness.  It also
requires `nmk check: 0 mismatches`, an image smaller than the test stack, the
named scheduler symbols, the NanCore queue fields, and the `nsp_*` references
in the binding.

## Regression gates re-run

```
nansched: PASS (1024-slot nanproc, 32 priority queues, timer preemption,
  yield/exit/spawn/wait/kill/sleep; SVC 4..8 NPAF + process SVCs on
  C oracle == x86_64 S1)
nansched_stress: PASS (1024-slot nanproc, 512 live processes, ...)
nixjobs_gate: PASS (image 47949 words, steps 40000000)
nan0s_gui64_sched: PASS (raw-NaN16 boot kernel, PID 1 desktop, PID 2 NANIX shell)
nansmp: PASS (-smp 2 ... ) / PASS (-smp 4 ...)
nancore_scale: PASS (4096 records, bounds, online bitmap)
```

`nancore.nas` and `nansmp.nas` are untouched; those two gates were run as a
safety check because F2 mirrors their field offsets and consumes their ABI.

## Honest limits

- The 2/4-CPU proof is single-thread deterministic simulation.  It proves the
  FIFO/steal/migration/accounting state machine and the nansmp binding table,
  not cross-AP memory reordering.  Real AP execution needs F1's trap frames and
  F4's IPI wakeups.
- Affinity is a 32-bit mask in this slice.  The 4096-core target needs the
  affinity bitmap extension in F4.
- The kernel process scheduler and this per-CPU layer are not yet connected;
  `nsch_*` still owns the nanproc/TCP slots and `nsched_*` is the substrate
  policy below it.  The integration point is the per-CPU current/trap-frame
  pair once F1 lands.

## Frontier capability ideas

1. **Symbiotic agent scheduling.**  Give planner, tool and verifier roles
   different budget classes and keep a role's KV shard on its home NUMA node.
   Work stealing then balances cache/KV locality rather than only queue length.
2. **Deadline/KV-aware placement.**  Put KV slab id, bytes and NUMA node in the
   task record; make `nsched_steal` prefer a victim whose KV node matches the
   thief and whose deadline has slack.  This turns the scheduler into a
   placement policy for F6.
3. **Speculative tool-call admission.**  Reserve a fraction of each budget for
   tool calls and admit speculative branches only when deadline slack is
   positive; on a miss, park the branch and keep the committed trace.  The
   existing budget/deadline flags are the enforcement point.
4. **Live-generation handoff.**  Migrate an agent with its generation epoch,
   KV epoch and trace head; the destination starts on the new weight
   generation while the source drains the old one.  `nsched_migrate` already
   stamps an epoch and requests a destination IPI.

## Suggested next work

- Wire `nsched_*` current/trap-frame switching into F1's AP runtime.
- Add the per-task KV/NUMA fields and a same-node steal preference (F3/F6).
- Widen affinity to the 4096-core bitmap and pull `NC_NODE` hints (F3/F4).
- Add speculative admission and generation handoff (F13/F5).
