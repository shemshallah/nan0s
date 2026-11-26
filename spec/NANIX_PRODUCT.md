# NANIX: an AI-native persistent capability machine

Status: product/architecture north star.  POSIX is a compatibility skin, not
the identity of the system.

## 1. Thesis

The next serious operating environment for AI is not a package manager and
not another Unix.  AI workloads are becoming:

- long-running and stateful (agents, sessions, tool loops, model servers);
- multi-agent and concurrent (branching, evaluation, shadow runs);
- memory-heavy and heterogeneous (weights, activations, KV cache, VRAM,
  persistent memory, RAM);
- safety- and audit-critical (tool permissions, data provenance, replay);
- continuously updated (models, prompts, tools, policies).

Today those properties are rebuilt above the OS with containers, databases,
serialization layers and ad-hoc sandboxing.  NANIX makes them **first-class
machine objects**:

> An agent is a checkpointable process with a typed object graph and a
> capability set.  A tool is a capability-scoped object.  A model is a
> versioned tensor graph.  A run is a replayable trace.

That is the product.  The shell and POSIX tools exist so real work can run on
day one; they are not the reason to choose NANIX.

## 2. Why NaN16 is the right substrate

NaN16 already gives us properties a conventional OS has to emulate:

- every word carries a class and payload, so typed objects and capability
  words can live in ordinary memory;
- deterministic execution, finite register/frame state, and a scheduler with
  process/thread frames;
- PMEM ranges with types and holes, so RAM, VRAM, persistent memory and
  device windows are one address space;
- NPAF, a persistent RAM store with an ATA snapshot;
- a small native compiler and a flat-image loader, so the system can build
  and run its own tools.

The object and capability layer turns those primitives into an AI runtime.

## 3. The five product pillars

### 3.1 Checkpointable agents

A process image is an object: trap frame, entry/stack, region descriptors,
heap/stack payloads and a generation.  The OS can:

- checkpoint an agent at a safe point;
- fork an agent (copy-on-write) to explore branches;
- resume on another boot or another machine;
- roll back after a bad tool call;
- keep a pinned model/tool/policy set for the lifetime of a run.

Agent state is not a serialized database row.  It is a native object graph.

### 3.2 Capability-native tools and data

Every resource is reached through a capability word:

```
C_CAP | object id | generation | rights | offset
```

Rights include read, write, execute, grant, replace and revoke.  A tool call
is a typed message carrying capabilities, not an ambient URL/path/root.

- no implicit root;
- no ambient filesystem/network;
- revocation and quotas are primitive;
- a forged or stale capability fails the same check as a bad pointer;
- audit records are immutable objects.

### 3.3 Typed tensors, models and persistent KV

AI data is not a byte file.  Native classes:

- `TENSOR`: dtype, rank, shape, strides, storage capability, offset, flags.
  Views and slices are zero-copy capabilities.
- `MODEL`: tensor capabilities, tokenizer, config, signature, generation and
  placement policy.
- `KVCACHE`: paged blocks of tensor capabilities, persistent and resumable.
- `BLOB`: raw storage behind tensors, pageable and placeable in VRAM,
  persistent memory or RAM.

The single-level store means a KV cache can survive a restart without
serialization, and a tensor can be a view over persistent memory or VRAM.

### 3.4 Deterministic replay and evaluation

The VM is deterministic; the outside world is not.  NANIX records
nondeterminism as typed events:

- clock ticks, random seeds, external input, tool results, model outputs;
- a `TRACE` object is a hash-chained sequence of events;
- replay feeds the recorded events back into a checkpointed agent image;
- forks can compare policies, prompts, models or tools on the same prefix.

This makes agent evaluation, debugging and regression testing exact instead
of statistical.

### 3.5 Live, transactional generations

Objects are versioned.  Updating a model, tool or policy is a generation
replacement:

1. new object is written and sealed;
2. the namespace entry swaps atomically;
3. old holders keep the old generation until they release it;
4. rollback is another swap.

No package store, no derivation language, no reboot.  Canary and shadow runs
are just capabilities to different generations.

## 4. AI object model

### 4.1 Object header

| word | field | meaning |
| ---: | --- | --- |
| 0 | magic | `NOBJ` |
| 1 | id | stable id |
| 2 | generation | bumped on replacement |
| 3 | class | blob/tensor/model/kvcache/tool/agent/trace/namespace/channel |
| 4 | size | payload words |
| 5 | refs | live capability count |
| 6 | flags | persistent/executable/shared/sealed/pinned |
| 7 | checksum | payload checksum |
| 8.. | payload | class-specific |

The M1a table uses 16-word entries (8 payload words).  M1b grows to a 32-word
entry (24 payload words) for tensor/model metadata; existing classes keep
their layout.

### 4.2 Tensor payload

| words | field |
| --- | --- |
| 0 | dtype (f32/f16/bf16/int8/int4/sparse) |
| 1 | rank |
| 2 | flags (contiguous, view, persistent, accelerator) |
| 3 | storage capability |
| 4 | element offset |
| 5..12 | shape[8] |
| 13..20 | strides[8] |
| 21 | element count low / checksum |
| 22..23 | reserved |

A view is `(storage cap, offset, shape, strides)`.  Copying a view copies
metadata, not data.  Placement is a property of the storage object, not the
view.

### 4.3 Agent payload

| words | field |
| --- | --- |
| 0 | process image capability |
| 1 | model capability (pinned generation) |
| 2 | tool-set capability |
| 3 | memory/namespace capability |
| 4 | policy capability |
| 5 | trace capability |
| 6 | parent agent capability |
| 7 | status |
| 8 | token/step/time budget |
| 9 | last checkpoint generation |
| 10.. | child/worker capabilities |

### 4.4 Tool payload

- schema object;
- entry code capability;
- required rights and requested quota;
- timeout and audit policy;
- result channel capability.

A tool cannot open anything it was not granted.  A tool call can be revoked
between messages; the worker sees a stale cap and fails closed.

### 4.5 Trace payload

A hash-chained event log.  Event kinds: token, tool_call, tool_result,
decision, external_input, clock, random.  Events are append-only objects; a
trace can be sealed and used for replay or audit.

## 5. Concurrency and scheduling

- Pipelines and jobs are worker contexts with their own stacks, fd tables and
  scratch; they share typed channels, not globals.
- Object channels carry capability words with backpressure.  Byte pipes stay
  for POSIX.
- The scheduler has latency classes: interactive agent, batch/eval,
  background compaction.
- Budgets are enforced (tokens, steps, wall time, memory, tool calls).
- Preemption and priority inheritance keep a slow tool from starving an
  interactive session.
- Checkpoint/fork is cheap because object graphs are copy-on-write and
  process images are small.

## 6. Memory and placement

PMEM types are placement policy inputs:

- weights: VRAM or persistent memory, pinned, shared read-only;
- KV cache: persistent memory, paged, evictable;
- activations: RAM, transient;
- traces/audit: persistent, append-only;
- code: executable region, sealed.

Migrations are capability-preserving: a tensor view keeps its identity while
its storage page moves.  Holes/reserved ranges are respected by the allocator.

## 7. Security and safety model

- Capabilities are the only authority; no uid 0 / global root.
- Typed memory and capability checks reject forged pointers and stale
  generations.
- Agents/tools run in separate processes/threads with explicit regions.
- Quotas, timeouts, revocation and audit are kernel/object services.
- A trace can be sealed and checked for provenance.
- Checkpoint/rollback limits blast radius after a bad action.
- The compatibility layer maps POSIX paths/fds to capabilities; it cannot
  manufacture rights.

## 8. Seriousness: what must be true

This is not a demo unless these hold:

1. **Crash consistency** — object store and traces survive power loss; NPAF
   snapshots validate header, counts and checksums.
2. **Determinism** — replaying a trace reproduces the same decisions/output
   for the recorded nondeterminism.
3. **Isolation** — a forged/stale capability cannot read or write an object;
   a tool cannot exceed its rights/quotas.
4. **Performance** — zero-copy tensor views, COW fork, persistent KV resume,
   channel throughput; measured against a conventional serialization path.
5. **Compatibility** — real POSIX tools, C programs and shell workflows run
   over the capability/object layer.
6. **Auditability** — every tool call and model generation is attributable to
   a trace and a capability.
7. **Operations** — live model/tool replacement, canary, rollback and
   checkpoint migration without reboot.

Benchmarks to publish: agent fork/checkpoint latency, KV resume vs reload,
tool-call round trip, replay fidelity, memory placement efficiency, and
capability-check cost.

## 9. Anti-goals

We are not building:

- a `/nix/store` or derivation-language clone;
- a package manager that owns the image;
- a Unix clone with global root as the security model;
- byte-stream-only IPC;
- an application-level checkpointing library;
- a shell-centric system.

Paths, fds, pipes and the POSIX shell are a compatibility view over objects
and capabilities.  They are allowed to be incomplete; the object layer must
not depend on them.

## 10. Layering

```
agents / model servers / tools / POSIX apps
        │  compatibility: paths, fds, pipes, shell
NANIX object + capability services
        │  objects, caps, tensors, models, traces, channels, checkpoints
nankernel + nansched + PMEM + NPAF
        │  processes, threads, regions, store, device windows
NaN16 VM / S1 / bare metal
```

## 11. Milestones

| milestone | slice | gate |
| --- | --- | --- |
| M0 | POSIX compatibility: fds, redirection, pipelines, tty, persistence | existing suite |
| M1a | object table + capability checks + revocation | `tools/nanobj_gate.sh` — **PASS** |
| M1b | 32-word entries + tensor metadata + namespace object | tensor create/view/shape/rights + namespace resolve |
| M1c | object persistence and checksum validation | create, save, reboot, verify |
| M2a | agent process image | checkpoint a counter, resume, state continues |
| M2b | trace + replay | `tools/nantrace_gate.sh` — seal/verify/tamper **PASS**; replay pending |
| M3a | object channel / tool bus | typed cap messages, backpressure, quota/revoke |
| M3b | concurrent pipeline / jobs | >4 KiB stream with real overlap, start/wait/reap |
| M4a | model + KV objects | persistent KV resume, zero-copy tensor views |
| M4b | live replace | old/new readers see generations consistently |
| M5 | evaluation/benchmarks | fork/checkpoint, replay fidelity, tool RTT, cap cost |

## 12. Immediate implementation

M1a is complete.  Next is M1b:

- grow object entries to 32 words (24 payload words);
- add `src/lib/nantensor.nas` with `ntensor_create`, `ntensor_shape`,
  `ntensor_view`, `ntensor_storage`;
- use a storage `BLOB` capability and a tensor metadata object;
- test zero-copy view identity, shape/stride checks, read/write rights and
  bounds;
- add a namespace object mapping names to capabilities, with a generation.

No shell integration in M1b.  The POSIX lanes continue in parallel.
