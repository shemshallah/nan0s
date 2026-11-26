# NIX jobs: concurrent pipelines and background jobs

Status: **low-level primitive implemented and gated; shell integration
pending.**  Product code is `src/lib/nixjobs.nas`, the S1 gate is
`src/tests/nixjobs_test.nas` plus `tools/nixjobs_gate.sh`.  The shell,
`src/nix/nixsh.nas`, is not modified by this slice.

This document is normative for the `nj_*` ABI and for the integration work
that remains in the shell.

## 1. Scope and concurrency model

A worker is a real `SVC 9` process, not a copied buffer and not a sequential
spool.  Two workers overlap in the only sense the current single-core S1
provides:

* each has an independent trap frame, region table, stack and descriptor
  table;
* each makes progress across scheduler switches while the other is runnable
  or blocked;
* a full writer and an empty reader block in `SVC 24 sleep(1)` instead of
  spinning or requiring the other side to finish first.

This is real interleaved concurrency, not SMP parallelism.  There is one core
and one scheduler run queue.  The design leaves the ring index updates ready
for CAS/fence replacement, but the current bodies are correct only as
single-producer/single-consumer (SPSC) on one core.

Threads (`SVC 13`) were rejected for this layer:

* `nansched.nas` allows only one owning process in thread mode, and all
  threads of that owner share its region table and every flat global;
* the shell already has process-global `NX_*` and `NFD_*` state, so threads
  would make the existing non-reentrant code unsafe by construction;
* a thread exit cannot be waited for with `SVC 10`, while the background-job
  design must use the existing process wait/reap path.

Processes give private trap frames and region tables plus the frozen
`SVC 9/10` lifecycle.  The cost is one descriptor/region-table creation per
stage, not an image copy: all workers share the same RX code image.

## 2. Worker context

The context is `NJ_C_SIZE = 72` words and is caller-owned.  It must live in a
range mapped RW in both the parent (for setup/observation) and the worker.
`src/lib/nixjobs.nas` has no static context, descriptor or ring storage.

| offset | field | meaning |
|---:|---|---|
| 0 | `NJ_C_MAGIC` | `0x4E4A4F42` |
| 1 | `NJ_C_STATE` | worker bookkeeping state 0..4 |
| 2 | `NJ_C_PID` | `SVC 9` pid, 0 before spawn/after wait |
| 3 | `NJ_C_TID` | reserved 0 (process workers) |
| 4 | `NJ_C_PRIO` | spawn priority 0..31 |
| 5 | `NJ_C_FLAGS` | reserved; background bit belongs to the job table |
| 6 | `NJ_C_ENTRY` | stage function pointer |
| 7 | `NJ_C_STACK_BASE` | private stack region base |
| 8 | `NJ_C_STACK_WORDS` | stack region size |
| 9 | `NJ_C_STACK_TOP` | initial `r14`; the bootstrap context word is here |
| 10 | `NJ_C_CODE_BASE` | RX code region base (shared image) |
| 11 | `NJ_C_CODE_WORDS` | RX code region size |
| 12 | `NJ_C_ARENA_BASE` | shared arena base |
| 13 | `NJ_C_ARENA_WORDS` | shared arena size |
| 14 | `NJ_C_FDTAB` | private 16*5-word descriptor table |
| 15 | `NJ_C_SCRATCH` | private scratch byte pointer |
| 16 | `NJ_C_SCRATCH_LEN` | scratch byte length |
| 17 | `NJ_C_RING` | shared ring word address (optional) |
| 18 | `NJ_C_JOB` | job-table slot or `-1` |
| 19 | `NJ_C_RESULT` | stage return / exit status copy |
| 20 | `NJ_C_TOTAL` | per-stage expected byte count (pipeline use) |
| 21 | `NJ_C_DONE` | per-stage progress counter |
| 22 | `NJ_C_HASH` | consumer hash/result |
| 23 | `NJ_C_TICKS` | reserved timing/diagnostics |
| 24 | `NJ_C_PEER` | optional peer context for progress witnesses |
| 25 | `NJ_C_WIT` | optional shared witness block |
| 26-31 | `NJ_C_TMP*` | stage scratch |
| 32-68 | `NJ_C_DESC` | 37-word spawn descriptor built at spawn time |
| 69-71 | spare | zero |

`nj_ctx_init` zeroes the context and the descriptor table, records the spawn
parameters, and computes `stack_top = stack_base + stack_words/2`.  The upper
half of the mapped stack region is growth room for frames; the lower half is
not used by the bootstrap.

Addressing rule for all `nj_*` code: `LD`/`ST` apply their third operand as a
16-bit immediate.  A high word address must be materialized with
`LA rB,#BLOCK` and then used as the base register; only small field offsets
(`< 0x100`) are written as immediates.  No high global is ever addressed as
`LD/ST rX,r0,#HIGH_EQU`, because that would silently truncate to the low
16 bits and write low memory or code.  `tools/nixjobs_gate.sh` rejects that
form in the new sources.

`nj_spawn_worker` fills `NJ_C_DESC` in place:

```
word 0  nj_worker_entry
word 1  stack_top
word 2  priority
word 3  0
word 4  3 regions
word 5  code base        word 6  code words   word 7  1 (image) word 8  5 (RX)
word 9  stack base       word 10 stack words  word 11 3 (stack) word 12 3 (RW)
word 13 arena base       word 14 arena words  word 15 4 (shared) word 16 3 (RW)
```

`SVC 9` starts the child with `r14 = stack_top`.  The parent stores the
context word address at `[stack_top]` first; `nj_worker_entry` executes
`LD r12,r14,0`, changes nothing before that load, and then calls
`NJ_C_ENTRY` with `r12` as the context register.  The stage's first frame
write overwrites the bootstrap word.  Therefore the parent must have the
worker-stack pool mapped RW; in a shell this is one shared stack-pool region
covering all worker stacks, not a copy of the child stack.

Public `nj_*` routines preserve `r12`, `r13` and `r14`; they clobber
`r1`-`r11` and use `r15` as the call link.  A stage can keep the context in
`r12` across every library call.

## 3. Per-worker descriptor table

The table format deliberately matches `spec/NIX_FD.md`:

```
{used, kind, handle, flags, pipe_id}      16 entries, 5 words each
kind 0 unused, 1 terminal, 2 reserved worker file, 3 shared ring
```

The table is addressed from `NJ_C_FDTAB`; it is **not** `NFD_TAB`.  Kind 1
writes bytes with `PUTC`.  Kind 3 uses `handle = ring word address` and
`flags bit 0 = 1` for the write end; `nj_fd_read`/`nj_fd_write` route to the
ring.  Kind 2 is reserved because `nfd_open`/`bare_fs_*` are not reentrant:
the shell must pre-open files before spawning and assign handles, or a later
worker-safe file backend must replace this kind.

`nj_fd_pipe(ctx, ring, read_fd, write_fd)` installs both ends in one context.
A pipeline normally installs only the write end in the producer and only the
read end in the consumer.  Closing the ring end sets `WCLOSED` or `RCLOSED`;
the reader sees 0 (EOF) only after the buffer is empty and the writer closed.

The parent's `NFD_TAB` remains the shell's table.  No worker calls
`nfd_init`, `nfd_read`, `nfd_write`, `nfd_dup2` or `nfd_pipe`.  If a worker
did, two processes would race on `NFD_TAB` and on the `NFD_G` cross-call
scratch block.  The same rule applies to `nanpipe.nas`: `NP_W_*` is global
scratch and `NPIPE_BASE` is shared, so it is not a concurrent pipe.

## 4. Shared ring

`src/lib/nixjobs.nas` defines the ring record (`NJ_R_SIZE = 16` words):

| offset | field |
|---:|---|
| 0 | magic `0x4E4A5242` |
| 1 | capacity in bytes (power of two, minimum 16) |
| 2 | mask `capacity - 1` |
| 3 | head: consumer monotonic byte index |
| 4 | tail: producer monotonic byte index |
| 5 | writer full/block count |
| 6 | reader empty/block count |
| 7 | writer closed |
| 8 | reader closed |
| 9 | buffer byte pointer |
| 10-15 | spare |

Offset = `index & mask`; used = `tail - head`; free = `capacity - used`.
The producer copies min(len, free, capacity-offset) bytes, then publishes
`tail`.  The consumer copies min(len, used, capacity-offset) bytes, then
publishes `head`.  Each side owns exactly one index.  Wrapping is split into
at most two copies; byte copy is the `LDB`/`STB` `nj_bcopy`.

Single-core safety:

* every index is one aligned 32-bit word, so a context switch between
  load/copy/store leaves either the old or the new value, never a torn one;
* the data copy happens before the index publish, and the other side only
  reads data below the published index;
* a stale `tail` or `head` makes the other side see less data/space, which
  is safe (it retries), not corruption.

This is SPSC only.  Multiple producers or consumers need an atomic claim
protocol.  SMP additionally needs a release fence after the copy and an
acquire fence after reading the index; the current `nansched` runs one core.

`nj_ring_write` and `nj_ring_read` are blocking.  When full/empty they
increment the corresponding block counter and execute `SVC 24 sleep(1)`, so
the scheduler marks the process blocked and runs the peer at any priority.
The two block counters prove that a stage would have stalled without its
peer.  They are diagnostic, not deterministic transcript values; gates print
booleans, not raw counts.

A dedicated kernel pipe wait queue (wake writer on read, reader on write)
would remove the one-tick latency and is a future kernel extension.  The
public `nj_*` ABI does not expose the timed wait, so replacing it does not
change callers.

## 5. Lifecycle, wait and reap

Worker states are bookkeeping only: `FREE`, `READY`, `RUNNING`, `EXITED`.
Kernel process state remains authoritative in `nanproc`.

1. Parent initializes the shared ring, contexts, descriptor tables and job
   table.
2. Parent calls `nj_ctx_init` for each stage.
3. Parent initializes the context's fd table and connects ring ends.
4. `nj_spawn_worker` writes the bootstrap word and calls `SVC 9`; the child
   starts at `nj_worker_entry`, sets `RUNNING`, calls the stage, stores the
   return value in `NJ_C_RESULT`, sets `EXITED`, and calls `SVC 1`.
5. Parent calls `nj_ctx_wait` (or `nj_job_wait`), which calls `SVC 10`,
   records the status, clears `NJ_C_PID`, and marks the context `FREE`.
   The kernel process is reaped by that wait; it must be called exactly once.
6. Failures before spawn leave the context `FREE`.  A spawn failure returns
   0; a ring setup failure returns -1.  A killed worker wakes the waiter with
   status `128+signal`, not a special NIX status.

There is no automatic orphan collection in this layer.  The shell must wait
all foreground children and either wait or deliberately detach background
children before exiting.  (Kernel orphan policy belongs to `nanproc`, not
`nixjobs`.)

## 6. Background job table

The job table is caller-owned and shared with the shell:

```
+0 magic 0x4E4A4A54
+1 live count
+2 capacity 1..64
+3 next id hint (unused by lookup)
+4 entries, 8 words each:
   +0 state: 0 FREE, 1 RUNNING, 2 WAITED
   +1 pid
   +2 context pointer
   +3 exit status
   +4 job id
   +5..7 reserved
```

`nj_job_start(table, ctx)` finds a free slot, spawns the context, and records
pid/context.  The context is not owned by the job layer; the shell keeps the
arena alive until reap.

`nj_job_wait(table, job)` requires state `RUNNING`, calls `SVC 10`, stores the
status, changes state to `WAITED`, and mirrors the status/free state into the
context.  `nj_job_reap(table, job)` requires `WAITED`, frees the entry, and
returns the recorded status.  This two-step wait/reap matches the requested
shell semantics: `wait %n` consumes the process, and the job record remains
until `jobs`/auto-reap can report it.

The job state is not the kernel process state.  In particular, a child that
exited but has not been waited for is still `RUNNING` in this table; only
`SVC 10` proves termination.  A future `SVC` exposing `nanproc` state could
add a non-blocking `DONE` state without changing wait/reap.

## 7. What is and is not isolated

Isolated by construction:

* process identity (`pid`), trap frame and kernel scheduling state;
* S1 region table and therefore the set of word ranges the worker can touch
  (except shared regions deliberately mapped in both tables);
* software stack range and stack pointer;
* worker context and its fd table, scratch range and `r12` register value;
* a worker's exit status.

Shared by address (must be treated as shared protocol):

* RX code image and any read-only tables in it;
* the caller-owned arena containing contexts, ring record/buffer, job table
  and witness words;
* the worker-stack pool range mapped in the parent (for the bootstrap word);
* kernel tables (`nanproc`, scheduler state) and device ports.

Not safe and not used by workers:

* `NX_*` parser/execution globals in `nixsh.nas`;
* `NFD_TAB`, `NFD_G`, the NFD file/pipe reference counts and `NP_W_*` in
  `nanpipe.nas`;
* any shell builtin or `fs_dispatch` path that writes those globals;
* non-reentrant `bare_fs_*` open state unless handles are pre-opened and the
  backing operations are proven handle-only.

A worker stage is reentrant only if it uses its context, its private stack and
its fd table; sharing a context between two workers is a caller bug.

## 8. Shell integration points

The shell remains the only parser and the only owner of `NFD_TAB`, cwd and
`NX_*`.  The integration is deliberately staged:

1. **Parse and plan in the parent.**  Split the command line at unquoted
   `|`, `&`, redirections and builtin boundaries as today.  A pipeline is a
   list of stage records; each record names a worker-safe command entry, argv
   copy, input kind and output kind.  No worker parses the original line.
2. **Allocate per-stage contexts.**  One `NJ_C_SIZE` context, one 80-word fd
   table and one scratch range per stage, plus one ring per pipe edge.
   Contexts and rings live in the shell's job arena; do not reuse `NX_*`.
3. **Pre-open parent-owned resources.**  Resolve paths and open files in the
   parent while the NFD/fd layer is still single-threaded.  Pass an opaque
   handle or a ring end into each stage's fd table with `nj_fd_set`/
   `nj_fd_pipe`.  Redirections become `dup2` assignments in the *stage's*
   table, never in the global table while a worker runs.
4. **Spawn.**  Call `nj_spawn_worker` for every stage.  Give all stages the
   same default priority unless the scheduler policy has a reason not to;
   timed waits make unequal priorities safe but equal priorities are easier
   to reason about.  Wait for all stage pids with `nj_ctx_wait`, close ring
   ends in the parent, and discard contexts only after every waiter returned.
5. **Worker-safe command contract.**  A command may be dispatched to a worker
   only when it:

   * takes all mutable state from `r12` (context) or its stack, never from
     `NX_*`;
   * reads/writes with `nj_fd_read`/`nj_fd_write` and the context table;
   * does not call `fs_dispatch`, `nfd_*`, `nanpipe` or the GUI/terminal
     writer directly;
   * returns an exit status in `r1`.

   `cat`, `wc`, `echo`, `printf`, `true`/`false` and simple filters can be
   ported first.  Builtins that mutate shell state (`cd`, `export`, `exit`)
   stay in the parent and are rejected as pipeline stages.  Until a command
   is ported, the shell can run it sequentially as today, but must not claim
   it is concurrent.
6. **Background `&`.**  A background job is a stage list (usually one stage)
   plus a job-table slot.  Start it with `nj_job_start`; return to the prompt
   immediately.  `jobs` reports slot state/pid/status; `wait %n` calls
   `nj_job_wait`; the reaper calls `nj_job_reap`.  A child that writes to the
   terminal after the prompt must be serialized through the existing terminal
   lock, or redirected to a file/ring.
7. **Error paths.**  If stage N fails to spawn, close already-created ring
   ends, wait already-spawned stages (or kill them with `SVC 22`), then report
   the pipeline status.  A ring reader that sees writer-closed EOF exits
   cleanly; a writer whose reader closed gets -1 and should exit with a
   broken-pipe status.

The current shell's sequential `nx_exec_line` remains the fallback.  The
phase-2 replacement is: plan -> spawn all stages before running any of them,
then wait.  That is the change that removes the 4 KiB `nanpipe` spool limit.

## 9. Gate evidence

`src/tests/nixjobs_test.nas` boots the real scheduler and builds:

* an 8 KiB ring (twice `NPIPE_CAP`) at word `0x2C000`, buffer at `0x2C040`;
* producer context `0x2C900`, consumer `0x2CA00`, background `0x2CB00`;
* job table `0x2CC00`, witness block `0x2CD00`, per-worker fd tables
  `0x2D000`/`0x2D080`/`0x2D100`, scratch `0x2D200`/`0x2D300`/`0x2D400`;
* private worker stacks at `0x2E000`/`0x2E800`/`0x2F000` inside the stack
  pool `0x2E000..0x2F800`; root stack `0x2A000..0x2A800`;
* shared arena `0x2C000..0x2E000`.

The test starts the background worker first, then starts the producer alone.
The producer fills the 8 KiB ring and blocks; the root polls the ring's writer
block count before creating the consumer.  The consumer records that the
producer is still partial before its first read (overlap witness), then drains
16 KiB and checks every byte plus a `h = h*33 + b` hash (seed 5381, expected
`F8DFF505`).  Finally the root waits both foreground contexts and
waits/reaps the background job.  Expected transcript:

```
NJ BEGIN
RING 00002000
FDS OK
BG START 00000001
PREBLOCK 1
PIPE 00004000 F8DFF505
OVERLAP 1
WBLK 1
BG WAIT 0000002A 00000002
BG REAP 0000002A 00000000
NJ PASS
```

`PREBLOCK 1` is the "would block without a consumer" proof.  `WBLK 1` records
that the blocking path really ran.  `PIPE ... F8DFF505` is the full
greater-than-4-KiB transfer and hash.  `OVERLAP 1` records that the producer
was partial when the consumer began.  The job lines prove start, wait
(state 2), status 42 and reap (state 0).

`tools/nixjobs_gate.sh` assembles the image, requires zero `nmk` round-trip
mismatches and an image below the nanproc table, runs the C-core oracle and
the identical image through the x86_64 S1 runner, requires byte-identical
transcripts ending in `NJ PASS`, and statically rejects NFD/nanpipe use in
the primitive.

## 10. Remaining work

* Port worker-safe shell commands and replace `nx_exec_line`'s sequential
  pipe path with spawn-all/wait-all.
* Add a reentrant file/open layer or pre-opened-handle worker fd kind 2.
* Add kernel pipe wait queues (or a futex-like wait) to replace `sleep(1)`
  polling; keep the `WBLK`/`RBLK` diagnostics.
* Add job-control reporting (`jobs`, `wait %n`, auto-reap) and terminal output
  serialization for background children.
* Add an SMP-safe SPSC/MPSC ring variant (release/acquire fences, CAS claim)
  before claiming multi-core concurrency.
* Add a `nanproc` state query or a scheduler exit callback if non-blocking
  job completion reporting is required.
