# NaN kernel threads

Status: **implemented in NaN and gated on the C-core oracle; x86_64 S1
integration pending.**  This document is the thread half of the system model
in `spec/NANVM_SPEC.md` §9.2 and is normative for `src/lib/nanthr.nas`.

Product target is x86_64 bare metal.  The portable C core
(`aarch64/android/nan_cli`) is a conformance oracle and development S1 only;
it is never the acceptance path.  The gate runs the identical `.nan` image on
both paths when an x86_64 S1 runner is supplied, and says so explicitly when
it is not.

## 1. SVC ABI

The frozen gate is shared with the kernel stream:

| item | value |
| --- | --- |
| SVC opcode | `0x4E` |
| SVCRET opcode | `0x4F` |
| INL opcode | `0x4D` |
| syscall number | SVC `imm16` |
| arguments | `r1`, `r2`, `r3` |
| result | `r1` |
| clobbered | `r4` and flags |
| preserved | `r2`, `r3`, `r5`-`r12`, `r13`=1, `r14`/`r15` per call |

`tools/nmk.awk` now accepts `SVC imm` (opcode `0x4E`) so the production
stubs are ordinary assembled instructions and `nmk CMD=check` verifies them.
`SVCRET` and `INL` are documented here but are not emitted by user code.

Syscalls used by this subsystem (numbers from the shared contract):

| # | call | arguments | result |
| --- | --- | --- | --- |
| 0 | yield | - | 0 |
| 13 | thread_create | entry, stack base or 0, arg | tid or 0 |
| 14 | thread_join | tid | exit code, or -1 |
| 15 | thread_exit | code | does not return |
| 16 | mutex | op, address | 0/1/-1 |
| 17 | cond | op, address, mutex address | 0/-1 |
| 18 | tls | op, key/index, value | value/0/-1 |
| 19 | thread_detach | tid | 0/-1 |

Number 19 is an append-only extension beyond the frozen list in the shared
contract; the x86_64 kernel must accept it (or implement detach through the
thread attribute used by its create path) before the `nthr_detach()` stub is
usable on S1.  The oracle gate exercises it through the mock dispatcher.

Mutex ops: 0 lock, 1 unlock, 2 trylock, 3 init.  Cond ops: 0 wait,
1 signal, 2 broadcast, 3 init.  TLS ops: 0 get, 1 set, 2 key_create,
3 key_free.

`stack=0` in `thread_create` asks the kernel to allocate a stack from the
configured arena.  A non-zero stack is a caller-owned base word address; the
caller must provide `stack[-1]` and `stack[stack_size]` guard words and keep
the region alive until join.

## 2. Trap frame and context

The context-switch ABI is exactly the 24-word frame from the shared contract:

| word | contents |
| --- | --- |
| 0-15 | r0-r15 |
| 16 | pc |
| 17 | flags / k |
| 18 | ADDRH |
| 19 | cause |
| 20 | syscall / imm |
| 21 | status |
| 22 | sp |
| 23 | reserved |

The scheduler stores/restores that frame.  `nthr_syscall_dispatch(frame)`
is the S1 entry point:

1. copy the vector's frame into the current TCB;
2. run the common dispatcher from `frame[20]` and `frame[1..3]`;
3. `nthr_restore` copies the selected TCB frame back over the vector's
   frame and returns 1 when the current thread changed (0 if it did not);
4. the vector executes `SVCRET` with the frame.

`nthr_preempt(frame)` is the timer hook: it decrements the slice and, when the
slice expires and another thread is ready, saves the frame in the current
TCB, puts the current thread at the ready-queue tail, selects the next thread,
copies its frame over the supplied frame, and returns 1.  A return of 0 means
the frame is unchanged.  The vector then `SVCRET`s the frame.

The cooperative mock (`nthr_mock_entry`) builds the same 24-word frame from
live registers, writes `frame[16] = nthr_sysret`, switches `r14` to the
kernel stack, and calls the same `nthr_dispatch` core.  `nthr_sysret` restores
the user return link from the TCB.  This is why the mock never consumes a
user-stack word for switching and why the scheduler logic is the same code
the S1 frame path runs.  The only differences are trap-frame construction and
the final return (`RET` to `nthr_sysret` versus `SVCRET`).

## 3. TCB layout

`NT_T_SIZE` is 56 words.  Word 0 starts the trap frame above.

| offset | field | meaning |
| --- | --- | --- |
| 0-23 | frame | 24-word trap frame |
| 24 | state | 0 free, 1 ready, 2 running, 3 blocked, 4 zombie |
| 25 | tid | 1 is the boot/main thread; new threads start at 2 |
| 26 | stack | stack base word address |
| 27 | stack_words | stack size |
| 28 | joiner | TCB pointer of a thread blocked in join, or 0 |
| 29 | detach | 1 if detached |
| 30 | exit | exit code |
| 31 | next | ready-queue link |
| 32 | wait_next | mutex/cond wait-queue link |
| 33 | arg | entry argument |
| 34 | entry | entry point |
| 35 | wait_mutex | mutex released by cond_wait |
| 36 | aux | bit 0: kernel owns the stack region |
| 37-52 | tls[16] | per-thread TLS values |
| 53 | link | saved user r15 for the mock syscall return |
| 54-55 | reserved | zero |

State transitions:

    create:  FREE -> READY (enqueue)
    dispatch: READY -> RUNNING
    yield:   RUNNING -> READY (tail) -> pick
    block:   RUNNING -> BLOCKED (mutex/cond/join wait queue)
    wake:    BLOCKED -> READY (tail)
    exit:    RUNNING -> ZOMBIE or FREE
    join:    ZOMBIE -> FREE (after returning the code)

The exiting TCB is freed immediately when a joiner is woken (the joiner has
already received the code and never re-enters join).  A detached thread frees
itself at exit.  An undetached, unjoined thread stays ZOMBIE so a later join
can reap it.  Repeated create/join therefore reuses TCB slots; the gate does
60 cycles with a 32-slot arena.

## 4. Stacks

A kernel-allocated stack region is:

    [ guard ][ stack[0] .. stack[size-1] ][ guard ]

The guard words are `0x4E544847`.  The base returned/used is `stack[0]`;
the stack grows upward with `r14`.  The arena is configured in
`nthr_init(tcb_base, tcb_count, stack_base, stack_words, stack_size)`.
Regions are recycled through a LIFO free list; the guard below the base is
overwritten with the free-list link only while the region is free and is
rewritten before reissue.  Stack overflow beyond the upper guard, or
underflow below the lower guard, is a kernel fault policy point; the guard
words are checked by the kernel before a production switch (the mock relies
on the region size and the gate's bounds check).  Caller-provided stacks are
not freed by the kernel.

## 5. Ready queues and scheduling

The implemented slice has one per-core ready queue:

* `create` appends READY threads at the tail.
* `yield` appends the current READY thread at the tail, then picks the head.
* `block` removes the thread from the ready queue and parks it on the
  mutex/cond/join queue.
* `wake` appends at the ready-queue tail.
* `nthr_pick` pops the head, marks it RUNNING, makes it current, and reloads
  the quantum.

Round robin quantum is `NT_QUANTUM = 8` ticks.  `nthr_tick` increments the
tick counter, decrements the slice, and sets `pending` at zero.
`nthr_preempt(frame)` performs the actual switch only when another thread is
ready.  Cooperative `SVC 0` is always legal and is the tested path on the
oracle.

SMP scope is honest: this slice is single-core.  The shared contract calls
for per-core queues and work stealing; the TCB/queue split here leaves room
for a core field and per-core heads, but those are not implemented in this
worktree and must not be claimed.  Atomics/fences are the synchronization
boundary (below).

No runnable thread is a kernel bug: the mock prints `!D` and halts, and the
production policy must idle or panic explicitly rather than run a dead TCB.

## 6. Mutex

A mutex is four words:

| offset | field |
| --- | --- |
| 0 | owner tid (0 = free) |
| 1 | wait head |
| 2 | wait tail |
| 3 | recursion count |

* `lock`: acquire by CAS from 0 to the caller tid; a recursive lock increments
  the count; a different owner appends the caller to the wait queue and blocks.
* `trylock`: same checks, returns 1 instead of blocking.
* `unlock`: only the owner; decrements recursion; at zero, if waiters exist,
  transfers ownership and count=1 to the queue head and wakes it, otherwise
  clears the owner.
* `init`: zeroes the four words.

The cooperative mock's CAS is exact on one core.  On SMP the bodies of
`nthr_atomic_load/store/exch/cas` are the single replacement point for the S1
`0x41-0x44` atomic family; the mutex policy itself does not change.

## 7. Condition variables

A cond is two words: wait head, wait tail.

`cond_wait(cond, mutex)` requires the caller to own `mutex` with recursion
count exactly 1.  It appends the caller to the cond FIFO, records the mutex,
sets BLOCKED, releases the mutex, and switches.  `cond_signal` pops the FIFO
head and moves it to the mutex's wait queue when the mutex is owned (the
normal signal-under-lock case), or grants the mutex directly when it is free.
`unlock` then transfers ownership and wakes it, so the waiter resumes holding
the mutex.  `cond_broadcast` repeats this for every waiter.  `cond_init`
zeroes the two words.

This gives FIFO wakeup, no lost wakeup inside the syscall, and pthread-style
mutex reacquisition for the non-recursive case.  Timed waits, priorities and
spurious-wake loops are outside this slice.

## 8. Join, detach, TLS

`join(tid)` on a ZOMBIE returns its exit code and frees the slot; on a live
thread it records the joiner and blocks, and the exiting thread writes the
code into the joiner's frame `r1`.  Joining self or a detached thread returns
-1.  `detach(tid)` marks the target; a detached thread frees itself at exit.
A join consumes the code exactly once.

TLS has a 16-key global used map and 16 values per TCB.  `key_create` returns
the first free key or -1; `key_free` clears it; `get`/`set` operate only on
the current thread's array.  Values start at zero.  Destructors are not part
of this slice.  `nthr_self()` is a kernel/mock helper, not a user SVC.

## 9. Atomics and fences

`nthr_atomic_load`, `store`, `exch`, `cas` are word operations used by the
mutex and by kernel clients.  On the cooperative mock they are ordinary
accesses and are sequentially consistent because only one thread runs.
`nthr_fence` calls the kernel-installed hook at `NT_G_FENCE` when non-zero;
the default is a no-op.  The production bodies must be replaced by the S1
atomic/fence implementation; no host C and no hidden lock policy lives here.
The spec's caveat applies: atomics operate on the 32-bit payload of one
aligned word and are sequentially consistent with FENCE.

## 10. Mock isolation and S1 replacement

The mock is entirely NaN assembly in `src/lib/nanthr.nas`.  It is explicitly
installed by `nthr_mock_install()` and uses no host callback, host C thread,
host mutex or host stack.  It exists because this worktree does not contain
the x86_64 S1 trap/timer path.  The production user entry points are the
`SVC imm` words listed in §1; `S1` replaces the mock by:

1. decoding `0x4E`/`0x4F`/`0x4D` and building the 24-word frame;
2. calling `nthr_syscall_dispatch(frame)` from the SVC vector;
3. executing `SVCRET` with the returned frame;
4. calling `nthr_tick()` on each timer IRQ and, when it reports pending,
   `nthr_preempt(frame)` before `SVCRET`;
5. calling `nthr_init()` with the kernel's TCB arena and stack arena, and
   never calling `nthr_mock_install()`.

The exact remaining x86_64 work is therefore: the opcode decode, vector and
`SVCRET`; the timer IRQ wiring; a kernel stack/TCB arena allocation; and an
S1 runner that consumes a `.nan` image.  None of it is mocked by host C.

## 11. Gate

`tools/nanthr_gate.sh`:

* emits `src/tests/nanthr_test.nas` with `nmk`;
* requires `nmk CMD=check` to report 0 mismatches (the SVC words must decode);
* requires eight production SVC payloads (0, 13-19) in the image;
* requires the image to fit below the TCB arena at word 0x4000;
* compares the exact transcript on the C-core oracle;
* runs the **same image** through `NANTHR_X64_RUNNER` (or
  `build/nanthr_x64_runner`) when present; the runner contract is
  `runner image.nan`, transcript on stdout;
* `--require-x64` makes a missing/mismatching x86_64 runner fail the gate.

Transcript (`src/tests/nanthr.expected`):

    IL ABABAB
    JOIN 10 20
    MUTEX 100
    COND 31 32 0 1
    TLS 1 1 999 41 42
    YIELD 1000 77
    TICK 0
    ATOM 0 1 7
    DETACH 0 -1
    FRAME 0
    REUSE 60 5
    THREADS PASS

`ATOM 0 1 7` records the first CAS returning 0, the second CAS returning
the previous value 1, and exchange/load leaving 7;
`DETACH 0 -1` means detach succeeded and joining the detached thread was
rejected; `FRAME 0` is the S1 frame-dispatch entry returning "same thread"
for a synthetic yield frame; `TICK 0` is the timer hook with no peer ready.
`IL ABABAB` is the exact two-thread interleave.  `MUTEX 100` means two
threads each did 50 increments across a forced yield inside the critical
section.  `COND ... 0 1` records that signaling C1 left C2 asleep and woke
C1.  `REUSE 60 5` proves 60 create/join cycles on a 32-slot TCB arena.
