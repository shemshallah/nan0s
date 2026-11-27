# Custom NaN ABI (n16i runtime)

Status: v0.1, implemented by `src/tools/n16i.nas`; not the S1 KABI.

The system ABI is carried in NaN words.  `n16i` emulates it in NaN16, so the
ABI is part of the NaN ISA layer rather than a native kernel interface.

## Control words

The kernel configures the runtime through the port-encoded control words
`0x4E00..0x4E07` (the encoding is retained for the existing kernel source):

| word | field |
|---|---|
| 0x4E00 | kernel entry word |
| 0x4E01 | trap-frame word |
| 0x4E02 | timer interval in guest instructions |
| 0x4E03 | kernel stack word |
| 0x4E04 | region table word |
| 0x4E05 | current TCB word |
| 0x4E06 | status |
| 0x4E07 | LDS/STS window base |

`n16i` keeps these fields in NaN words and handles `OUTL`/`INL` itself.
Writes are allowed during boot and from kernel mode.  The kernel writes
`0x4E00` last.

## Trap frame

`SVC imm` / `SVCRET` use 24 guest words:

```
[0..15]  r0..r15
[16]     pc after SVC / resume pc
[17]     flags (2Z+L)
[18]     0
[19]     cause: 0 SVC, 1 timer
[20]     SVC number
[21]     return/status
[22]     guest SP
[23]     0
```

On `SVC`, `n16i` saves the guest registers, sets `r14` to the kernel stack,
enters kernel mode and jumps to the kernel entry.  `SVCRET` restores the frame,
sets `r1` from the return word for SVC, and resumes.

## Timer

When a timer interval is set, `n16i` counts guest instructions.  On expiry it
saves a cause=1 frame and enters the kernel.  The kernel's `SVCRET` resumes the
interrupted instruction.

## Program counter and windows

`n16i` uses a 24-bit guest PC and supports `JMPF`/`CALLF`, so the scheduler's
kernel (`0x10000`), shell (`0x80000`) and high process tables are reachable.
The guest window is `[0, mask]`, supplied by the boot stub.  Guest `CPUID`
magic `0x4E4D00FF`, subleaf 1, returns `mask + 1`, not the host word count.

## Runtime placement (next integration)

The native core bootstraps `n16i` as the first NaN guest:

```
system image      word 0 .. mask       (scheduler)
n16i runtime      word 0xF00000 ..     (stub + n16i + NaN stack)
native core       x86-64 substrate only
```

The native ATA loader reads two segments: the system image at LBA 129 and the
n16i runtime after it.  The system window is `0xEFFFFF` (15 Mi words), leaving
`0xF00000` for the n16i runtime.  `n16i` interprets the system with `GB=0`.

## Gates

- `tools/n16i_kabi_gate.sh` — bare n16i SVC/SVCRET/control-word test (`GKOD`).
- `tools/ngate_n16i.sh` — native vs n16i differential for the ISA core.

# AI-native ABI extensions

Status: v0.2 design, aligned with `nanobj`, `nantensor` and `nantrace`.

The system is meant for checkpointable agents, capability-secured tools,
typed tensors/models/KV, deterministic traces and live generations.  The NaN
ABI therefore has to make those first-class, not bolt them onto POSIX.

## Versioned ABI block

The kernel publishes a read-only ABI block at guest word `0x3F200`
(`NABI_BASE`):

| word | field |
|---|---|
| 0 | magic `NABI` (`0x4E414249`) |
| 1 | version (`0x0002`) |
| 2 | feature bits |
| 3 | guest word mask |
| 4 | monotonic tick |
| 5 | trace head hash |
| 6 | checkpoint generation |
| 7 | capability root |
| 8 | scheduler table word |
| 9 | object table word |
| 10 | tensor namespace word |
| 11 | trace storage head |
| 12..15 | reserved |

Feature bits: `1` capabilities, `2` checkpoint/restore, `4` tensors/KV,
`8` traces, `16` live generations, `32` deadlines/budgets, `64` replay.

## Handles and capabilities

A handle is the existing 32-bit capability word:

```
0xCA | object id (8) | generation (8) | rights (8)
```

Rights: `1` read, `2` write, `4` execute, `8` grant, `16` replace.  A handle
is never a raw pointer.  `revoke` bumps the generation and invalidates every
older handle.  Checkpoint/restore preserves the generation counter; a restored
agent cannot use a handle from a newer generation.

## SVC ranges

The scheduler keeps SVC `0..28` (yield, exit, region, file, spawn, wait,
kill, sleep, priority, count/limit).  The AI ABI reserves:

| SVC | operation |
|---|---|
| 29 | `abi_version` -> version/feature bits |
| 30 | `cap_check(cap, rights)` -> object/0 |
| 31 | `cap_grant(cap, rights)` -> new cap/0 |
| 32 | `cap_revoke(cap)` -> new generation |
| 33 | `object_create(class, words)` -> cap |
| 34 | `tensor_view(cap, offset, shape, rank)` -> view cap |
| 35 | `kv_attach(kv cap, key, generation)` -> view cap |
| 36 | `trace_append(kind, a, b)` -> index |
| 37 | `checkpoint(agent, flags)` -> checkpoint cap |
| 38 | `restore(checkpoint cap)` -> agent |
| 39 | `generation_publish(agent, generation)` -> 0 |
| 40 | `agent_spawn(image cap, caps cap set, priority, budget)` -> pid |
| 41 | `agent_yield(deadline)` |
| 42 | `tool_call(tool cap, arg cap)` -> result cap |
| 43 | `random_seed(seed)` / deterministic RNG |
| 44 | `stream_read(stream cap, buffer, len)` |
| 45 | `stream_write(stream cap, buffer, len)` |
| 46..63 | reserved |

All arguments and returns use the 24-word trap frame; a handle travels in
`frame[1]` and a pointer/word count in `frame[2..4]`.

## Checkpoint / restore

A checkpoint is a capability over an object whose payload is a sealed,
hash-chained record of:

- the 24-word trap frame and kernel mode;
- scheduler slot, process/thread state, priority, deadline, budget;
- region table and open fd/capability table with generations;
- object table generations and object payload roots;
- tensor metadata, storage capabilities and KV block roots;
- trace head, RNG seed, tick and pending timers;
- image identity/seal.

`restore` validates every generation and hash before resuming.  A checkpoint
may be forked: the restored agent gets a new scheduler slot but the same
immutable storage roots, so model weights are shared zero-copy while KV/trace
state is copy-on-write or explicitly shared.

## Traces and replay

Every SVC, tool call and agent switch can append
`{kind, a, b, hash}` where `hash = mix(previous, kind, a, b)`.  The ABI block
publishes the head.  Replay re-runs with the same seed, tick and input caps and
must reproduce the same head; divergence is a first-class failure.  Traces are
sealed before a checkpoint is published.

## Tensors, models and KV

Tensor descriptors follow `nantensor`:

```
dtype, rank, flags, storage cap, element offset,
shape[8], strides[8], element count, reserved
```

Views copy metadata only and share the storage cap.  Weights should be
read-only `1` caps; KV blocks are `2|8` caps with a generation and a key hash.
A model is a namespace cap mapping name hashes to tensor caps.  Loading a model
and attaching a KV block are capability operations; no ambient file path or
host pointer is required.

## Scheduling for agents

The scheduler already has priorities, timer preemption, sleep/wait/kill and
spawn.  The AI ABI adds:

- `budget` (instructions/tokens) and `deadline` (tick) per agent;
- cooperative `agent_yield(deadline)` and cancellation;
- checkpointable blocked states (sleep, wait, tool call, stream);
- a per-agent trace head and RNG seed, so a restored agent is deterministic;
- generation-tagged capabilities for live upgrade/revoke.

## Versioning and enforcement

The ABI block is versioned; an agent must refuse a feature it does not know.
`n16i` emulates the ABI in NaN16; the native substrate never interprets these
fields.  The gate `tools/n16i_kabi_gate.sh` covers the trap/control core; the
AI object gates (`nanobj`, `nantensor`, `nantrace`, `nantrace`) cover the
object semantics.
