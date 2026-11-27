# NaN/0S process subsystem (K2) and process viewer (K11)

Status: **implementation + deterministic gate; x86_64 S1 acceptance pending.**
The process table, lifecycle, heap/region bookkeeping and guest viewer are
implemented in NaN16:

- `src/lib/nanproc.nas` — kernel process subsystem (NaN code).
- `src/prog/nanproc_test.nas` — self-checking lifecycle/accounting image.
- `src/prog/ps.nas` — guest process viewer and manager hooks.
- `tools/nanproc_gate.sh` — exact-output gate.

Primary product target is **x86_64 bare metal**. The portable C core is the
conformance oracle only, never the acceptance path. The gate accepts an
x86_64 S1 runner through `NANPROC_RUNNER` and refuses to call a C-core run a
product PASS (it prints `ORACLE MATCH` and exits 77). No product code or gate
contains a phone path; scratch lives under the worktree `build/` directory.

Thread scheduling internals (contexts, run queues, preemption, SMP work
stealing) belong to the scheduler stream. This slice owns the process table,
process-level state, parent/child links and the per-process thread **list**
only.

## 1. Process table entry

The table is an array of `NP_MAX_PROCS` entries at the kernel-chosen word
address `NP_BASE`. Defaults: **64 processes, 8 regions per process, 16
threads per process**. The entry is 96 words; words 0..63 are the original
stable 64-word ABI and words 64..95 are the capacity extension. `NP_MAX_PROCS`
is a build-time bound and may be overridden by a later `.equ` in the including
program (reserve `NP_MAX_PROCS*96` words at `NP_BASE`); `NP_MAX_REGIONS`/
`NP_MAX_THREADS` are the current entry-layout limits (8/16). See the growth
path at the end of this section.

| words | field | meaning |
| ---: | --- | --- |
| 0 | `pid` | nonzero live id; 0 means the slot is free |
| 1 | `ppid` | parent pid; 0 means root/kernel |
| 2 | `state` | 0 free, 1 ready, 2 running, 3 blocked, 4 zombie, 5 dead |
| 3 | `exit_status` | wait status; `128+signal` for signal death |
| 4 | `heap_base` | first word of the process heap |
| 5 | `heap_end` | one past the heap |
| 6 | `heap_words` | heap span in words |
| 7 | `heap_used` | nalloc rover report in words (hook-maintained) |
| 8 | `threads` | number of entries in the thread list |
| 9 | `cpu_steps` | accumulated guest steps/ticks for the viewer |
| 10 | `capabilities` | capability handle word (kernel policy) |
| 11 | `name_ptr` | guest byte/word string pointer (diagnostic) |
| 12 | `region_count` | used region descriptors, 0..8 |
| 13 | `flags` | bit 0 live, bit 1 image mapped, bit 2 heap registered |
| 14 | `first_child` | head of the child pid list |
| 15 | `next_sibling` | next child of the same parent |
| 16 | `image_base` | loaded image base word |
| 17 | `image_words` | loaded image length in words |
| 18 | `region_words` | sum of region `nwords` (image+heap+stack+shared+dev) |
| 19 | `priority` | scheduling hint 0..255 (scheduler stream consumes it) |
| 20 | `start_tick` | spawn tick (0 until the PIT stream supplies it) |
| 21 | `exit_tick` | exit tick (0 until the PIT stream supplies it) |
| 22-23 | reserved | zero |
| 24-39 | regions 0..3 | 4 descriptors, 4 words each: `{base, nwords, kind, prot}` |
| 40-47 | thread ids 0..7 | first 8 thread ids, 0 = empty slot |
| 48-63 | reserved | original ABI tail |
| 64-79 | regions 4..7 | capacity extension: descriptors 4..7 |
| 80-87 | thread ids 8..15 | capacity extension: thread slots 8..15 |
| 88-95 | reserved | zero |

The region descriptor area is therefore discontiguous by design: index 0..3
lives at word 24 and index 4..7 at word 64. `np_region_slot` is the only
address computation; callers use `np_region_add`/`np_region_get` and never
assume a contiguous 32-word array. The same rule holds for the thread list:
`np_tcb_slot` maps index 0..7 to word 40 and 8..15 to word 80.

Region kinds: `1` image, `2` heap, `3` stack, `4` shared, `5` device.
Protection bits: `1` read, `2` write, `4` execute. The descriptor shape is
the S1 region-table shape from `spec/NANVM_SPEC.md` §8–§9: the kernel can
copy these descriptors to the interpreter's per-process access-check table
without translation.

The entry layout is kernel-private; guests use the stat ABI (§7). The viewer
deliberately calls `np_stat`, not raw offsets.

**Growth path.** The 96-word entry is the current revision. A future 128-word
entry keeps words 0..95 stable and uses 96..127 for a further region/thread
extension; that requires a new `NP_ENTRY` and a documented revision, not a
change inside an existing table. `NP_MAX_PROCS` can be raised without changing
the entry: only the table span (`NP_MAX_PROCS*NP_ENTRY`) grows.

## 2. States and transitions

```
free --alloc--> ready --run--> running --block--> blocked
                  |              |                    |
                  |              +------ready---------+
                  |              |
                  +------exit----+------> zombie --reap--> dead --> free
```

Legal transitions enforced by `np_set_state`:

| from | to |
| --- | --- |
| free | ready (slot allocation only) |
| ready | running, zombie, dead |
| running | ready, blocked, zombie, dead |
| blocked | ready, zombie, dead |
| zombie | dead |
| dead | free (kernel reap only) |

Any other transition returns `2` and leaves the entry unchanged. `np_reap`
performs the final `dead -> free` by zeroing the slot, so callers should not
use `np_set_state(pid, free)` directly against a live pid. Entering/leaving
running and zombie maintains the `run` and `zomb` counters.

A process is **live** while its slot is allocated, including zombie and dead.
`np_counts` reports live, running, zombies, spawns and reaps.

## 3. Lifecycle rules

### 3.1 Init and pid allocation

- `np_init` wipes the table and counters; pid numbering starts at 1.
- `np_alloc` finds the first entry with pid 0, clears all 64 words, assigns
  the next monotonic pid, sets ready + live, and increments live. The pid
  counter never reuses a reaped id.
- `np_create(ppid, name, image_base, image_words)` allocates a slot and:
  1. records name/image;
  2. adds the image as a read+execute region when `image_words > 0`;
  3. links to a live parent (a missing, zombie or dead parent leaves ppid 0);
  4. increments the spawn counter.
  A full region table rolls the slot back and returns pid 0. The parent link
  is prepended, so the child list order is most-recent-first and deterministic.

### 3.2 Spawn / loader boundary

`np_spawn(ppid, path, image_base, image_words)` is the loader integration
point. Today it is a **flat-image stub** that forwards to `np_create`: the
caller supplies a directly mapped image; there is no sealed-image read.

Production replacement (S1, in `src/lib/nanproc.nas` only):
1. call `SVC 9 spawn(path, argv, env)` — the S1 loader verifies the L4 seal
   and returns the child pid;
2. call `SVC 2 region_map(id, base, words, kind)` for the image (read+exec),
   heap (read+write) and stack (read+write) regions;
3. mirror each region into the child's descriptors with `np_region_add`;
4. populate the same table fields as `np_create` and mark image mapped.

Exact kernel-side hook (pseudocode; the kernel dispatch calls these routines,
the process library never emits an opcode itself):

```
svc_spawn(path, argv, env):
    seal_ok = loader_verify(path)              ; L4 seal, kernel only
    if !seal_ok: return -1
    image_base, image_words = loader_place(path)
    pid = np_create(current_pid, path, image_base, image_words)  ; REG/RX, parent link
    if pid == 0: return -1
    heap_base, heap_words = region_alloc(NP_K_HEAP)
    np_heap_set(pid, heap_base, heap_words)    ; np_region_add(kind heap, RW)
    stack_base, stack_words = region_alloc(NP_K_STACK)
    np_region_add(pid, stack_base, stack_words, NP_K_STACK, NP_PROT_RW)
    np_thread_add(pid, 1)                      ; main thread bookkeeping
    np_set_state(pid, NP_ST_READY)
    return pid
```

The `SVC 2` path is the memory-region syscall: the kernel allocates the
words, maps them through the S1 region table, and then records the same
`{base,nwords,kind,prot}` descriptor with `np_region_add`. If any mapping
fails, the kernel calls `np_region_clear(pid)`, `np_exit(pid, -1)` and
`np_reap(pid)`; use the named SVC/SVCRET/INL mnemonics when nmk exposes
them, never a raw opcode word. `np_spawn` in this library lands in
`np_spawn_stub`, the deterministic flat-image stub used by the gate; it is
not the L4 loader and the gate says so.

The syscall numbers and trap-frame contract are fixed by the shared kernel
contract: `SVC 0x4E`, `SVCRET 0x4F`, `INL 0x4D`, 24-word trap frame
(`[0..15]` regs, `[16]` pc, `[17]` flags, `[18]` addrh, `[19]` cause,
`[20]` syscall, `[21]` status, `[22]` sp, `[23]` reserved). Syscalls used by
this slice: `1 exit`, `2 region_map`, `3 region_query`, `9 spawn`,
`10 wait`, `20 getpid`, `21 getppid`, `22 kill`. nmk does not yet expose
`SVC`/`SVCRET`/`INL` mnemonics; the kernel stream is adding them. Process
code must call the named mnemonics (or a documented macro) once present and
must never encode a raw `0x4E` opcode word. The current stub path uses no SVC
at all, so it is isolated from that change.

### 3.3 Exit, zombies and orphans

`np_exit(pid, status)`:
1. rejects free/zombie/dead pids;
2. records `exit_status`;
3. walks the child list and reparents every direct child:
   - to init (pid 1) when init exists and is live,
   - otherwise sets ppid 0; a zombie child becomes dead immediately;
4. clears the dying process's child-list head;
5. sets state zombie when a live parent remains, otherwise dead.

A zombie keeps its regions, heap and thread list until reaped. This is the
accounting guarantee the viewer relies on: resource totals stay attributable
to a pid until `wait`/`reap`.

### 3.4 Wait and reap

`np_wait(ppid, wanted)` scans the parent's child list for a zombie child.
`wanted = 0` means any child. It returns the child pid and status but does
**not** free the slot, so the kernel can copy the status or deliver SIGCHLD
first. If no zombie child exists it returns 0/0.

`np_reap(pid)` accepts only zombie/dead entries:
- unlinks the pid from its parent's child list;
- subtracts `region_words` from the global region total and drops heap/region
  metadata;
- decrements live (and zombies when applicable), increments reaps, zeroes all
  64 words.

Reaping twice returns `1`; reaping a non-terminated process returns `2`.
Pids are never reused.

### 3.5 Kill

`np_kill(pid, sig)` is the process-level signal hook. It refuses an already
terminating pid (`2`), increments the kill counter, sets status `128+sig`, and
uses the normal exit path, so the zombie/reap and orphan rules are identical.
Signal delivery/masks/handlers and `SIGCHLD` policy are K5 work; this slice
provides the state transition and status encoding.

## 4. Region and heap ownership

- Regions are owned by the process entry, not the caller. `np_region_add`
  appends `{base,nwords,kind,prot}`, up to 8 descriptors (current entry-layout
  limit; a 128-word entry revision extends it). Descriptor indices 0..3 live
  in words 24..39 and 4..7 in words 64..79; `np_region_slot` is the only
  translator, so callers never hardcode the discontinuity.
- `np_region_add` adds `nwords` to both `region_words` and the global
  `NP_V_MEM`; zero length returns `3`; a full 8-descriptor table returns `2`.
- `np_heap_set(pid, base, words)` registers **one** heap region automatically
  (kind heap, read+write), records `heap_base/heap_end/heap_words`, clears
  `heap_used`, and sets the heap flag. A second call returns `3`. `words=0`
  clears the bookkeeping without adding a region.
- `np_heap_used_set(pid, used)` is the nalloc hook. It rejects `used >
  heap_words` (`2`), so accounting drift cannot silently pass the viewer.
- `np_region_clear(pid)` releases all 8 descriptors and heap metadata and
  subtracts the region total; it is the explicit teardown used before a slot
  is recycled or when the loader rolls back a partially mapped image.
- The kernel, not the process, chooses bases. Heap base/size come from MEMQ
  (`SVC 3`) and the buddy/nalloc layer. A process holds capability handles,
  never raw device access, matching `spec/NANVM_SPEC.md` §8.2 and §9.4.

### 4.1 Address map and configuration

`NP_BASE` and `NP_VARS` are kernel/configuration values, not fixed product
addresses. The library reaches both through `LA` (`MOVI`+`MOVHI`), so neither
is restricted to the 16-bit immediate window; `NP_MAX_PROCS` may be overridden
by the including program and the table span is `NP_MAX_PROCS*96` words. The
test images use a convenience map that the gate checks statically:

| range (words) | use |
| --- | --- |
| 0..~2890 | test/viewer code and strings |
| 0x1F00..0x1F43 | `NP_VARS` and stat scratch |
| 0x7000+ | software stack |
| 0x10000..0x117FF | process table (64 x 96) |
| 0x30000..0x3FFFF | test heap fixtures |
| 0x400000+ | descriptor-capacity probe (metadata only) |

None of these ranges overlap: code < vars, vars/scratch < stack, stack <
placed after the built image and its cartridge store, not at 0x10000: the
read the image word count and choose `NP_BASE` from free memory (MEMQ), e.g.
above `image_words` with a gap, then choose heaps/stack above the table and
verify the same non-overlap. The gate enforces the standalone map; the shell
link must enforce its own map check before boot. This is why the test
constants are documented as test conveniences, not kernel ABI.

## 5. Thread list (bookkeeping only)

`np_thread_add` / `np_thread_remove` maintain sixteen ids and the `threads`
count. Thread slots 0..7 are at word 40, slots 8..15 at word 80. Duplicate
ids return `3`, a full list returns `2`, removing an absent id returns `2`.
The scheduler stream owns contexts, stacks, run queues, preemption and joins;
it updates this list when a thread is created/destroyed and uses `priority`,
`cpu_steps` and the region descriptors as inputs.

## 6. API summary

All routines use `r0=0`, `r13=1`, `r14=software stack`,
`r15=link`; `r13`/`r14` are preserved.

| routine | arguments | result |
| --- | --- | --- |
| `np_init` | — | `r1=0` |
| `np_lookup` | `r1=pid` | `r1=entry or 0` |
| `np_alloc` | — | `r1=pid or 0` |
| `np_create` | `r1=ppid r2=name r3=image_base r4=image_words` | `r1=pid or 0` |
| `np_spawn` | same as create (path replaces name) | `r1=pid or 0` |
| `np_exit` | `r1=pid r2=status` | `r1=0/1` |
| `np_wait` | `r1=ppid r2=wanted or 0` | `r1=pid or 0 r2=status` |
| `np_reap` | `r1=pid` | `r1=0/1/2 r2=status` |
| `np_kill` | `r1=pid r2=signal` | `r1=0/1/2` |
| `np_set_state` | `r1=pid r2=state` | `r1=0/1/2` |
| `np_region_add` | `r1=pid r2=base r3=words r4=kind r5=prot` | `r1=0/1/2/3` |
| `np_region_get` | `r1=pid r2=index` | `r1=base r2=words r3=kind r4=prot r5=found` |
| `np_region_clear` | `r1=pid` | `r1=0/1` |
| `np_heap_set` | `r1=pid r2=base r3=words` | `r1=0/1/2/3` |
| `np_heap_used_set` | `r1=pid r2=used` | `r1=0/1/2` |
| `np_mem_stats` | `r1=pid` | `r1=used r2=heap_words r3=region_words r4=regions r5=headroom` |
| `np_add_steps` / `np_set_steps` | `r1=pid r2=delta/value` | `r1=0/1` |
| `np_thread_add` / `np_thread_remove` | `r1=pid r2=tid` | `r1=0/1/2/3` |
| `np_set_priority` | `r1=pid r2=0..255` | `r1=0/1/2` |
| `np_child_count` | `r1=pid` | `r1=count` |
| `np_counts` | — | `r1=live r2=running r3=zombies r4=spawns r5=reaps` |
| `np_stat` | `r1=pid r2=out` | `r1=0/1` |

## 7. Viewer/manager ABI

`np_stat(pid, out)` fills a 20-word guest-owned block:

| word | field | word | field |
| ---: | --- | ---: | --- |
| 0 | pid | 10 | heap_end |
| 1 | ppid | 11 | heap_used |
| 2 | state | 12 | heap_words |
| 3 | exit_status | 13 | child_count |
| 4 | threads | 14 | priority |
| 5 | cpu_steps | 15 | flags |
| 6 | capabilities | 16 | image_base |
| 7 | region_count | 17 | image_words |
| 8 | region_words | 18 | name_ptr |
| 9 | heap_base | 19 | start_tick |

The guest viewer (`src/prog/ps.nas`) renders:

```
 PID PPID STATE  THR    MEM    CPU PRIO
   1    0 RUN      1   1024      10    0
   2    1 READY    1    512      42    3
   3    1 BLOCK    2   2240    5000    5
   4    1 ZOMBIE   1    320       7    0
LIVE 4  RUN 1  ZOMBIE 1  SPAWN 4  REAP 0
```

`MEM` is `region_words` (image+heap+stack+shared+device), `CPU` is
`cpu_steps`, `THR` is the thread count. Rows are emitted in slot order, so
the screen is deterministic for a given table.

Manager hooks:
- `ps_kill(pid)` — SIGTERM (15) through `np_kill`; returns `0/1/2`.
- `ps_priority(pid, prio)` — `np_set_priority`; returns `0/1/2`.
- `ps_spawn(ppid, path, image_base, image_words)` — `np_spawn` (flat stub
  until the S1 loader lands); returns the new pid or 0.

The viewer is a standalone NaN image for now. Shell integration is a menu
entry that jumps to `ps_render` after the shell's segment is linked at a
known base; no kernel change is needed because `ps_render` only uses the stat
ABI, `np_counts` and the console `PUTC`. Keyboard commands (`k`, `p`, `s`)
wire to the hooks; the hooks themselves are already real table operations.

## 8. Invariants and error policy

- A live entry has a nonzero pid; a free slot has pid 0 and an all-zero body.
- `ppid` is 0 or a live/zombie pid; `np_exit` reparenting keeps this true.
- `region_count <= NP_MAX_REGIONS`; `region_words` equals the sum of stored
  descriptors; `NP_V_MEM` equals the sum over live entries.
- `heap_used <= heap_words` (enforced by the hook).
- Zombie/dead entries are the only reap candidates.
- No routine silently ignores a bad pid: it returns 1 and leaves state alone.
- The table is non-reentrant; the kernel serializes calls with its trap lock.
- All state lives in guest NaN words. The viewer and tests are NaN code; the
  C core never participates in the product execution path.

## 9. Gate and what runs where

`tools/nanproc_gate.sh`:
1. rejects phone paths, host includes and raw `0x4E` SVC words in the guest
   sources, and checks the standalone image map (code < vars < stack < table
   < heaps);
2. assembles `nanproc_test.nas` and `ps.nas` with the in-tree NaN assembler
   and checks the emitted disassembly;
3. runs both images and byte-compares the full output against the embedded
   expected text: creation, parent/child, spawn/image, region/heap accounting,
   stat ABI, exit status, zombie, wait/reap, orphan reparenting, region
   release, kill, capacity (64 processes, 8 regions, 16 threads, overflow
   rejection), and the viewer screen + manager hooks;
4. prints `PASS` and exits 0 only when `NANPROC_RUNNER` names an x86_64 S1
   runner. With `NANPROC_ALLOW_ORACLE=1` it prints `ORACLE MATCH` and exits
   77: exact conformance evidence, explicitly not product acceptance.

The gate's final line names the **flat `np_spawn` stub** so a passing run can
never be mistaken for a sealed-image L4 loader test. The test image currently
reports `PASS checks=000001A4` (420 checks) and the viewer prints
`VIEWER OK`; both outputs are locked byte-for-byte.

Current state: the x86_64 S1 runner is not in this slice/tree yet, so the
acceptance run is pending. The gate was executed with the portable C core as
an oracle; both images matched the expected output exactly. Remaining x86_64
integration work is the loader/syscall wiring from §3.2 plus the S1 runner
CLI (`--img FILE --steps N --serial`), not a change to the process logic.

## 10. Non-goals in this slice

Thread scheduling/preemption/SMP, signals beyond the kill status/state path,
Tcl/SQLite, networking, storage write, and the sealed-image loader are other
streams. The flat `np_spawn` stub and zero start/exit ticks are the only
mocked interfaces; both are marked at their source sites and here. The
process table and viewer are ISA-neutral NaN code; the C core only supplies
oracle execution until the x86_64 S1 runner is available.
