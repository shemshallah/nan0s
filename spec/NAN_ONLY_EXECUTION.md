# NaN-only execution boundary

Naming: **NaN/0S** is the operating system and desktop.  **NANIX** is its
native POSIX replacement layer: the raw-NaN16 command line, filesystem
metadata, process control and service ABI that replace the C libc POSIX
surface for normal operation.

Status: 2026-11-25. `nan-only-suite` and its POSIX metadata follow-up are
merged into `nan0s/main`; main is canonical. This document is authoritative
for what may be C and what must be raw NaN16.

## The rule

C is a **guest programming language and build tool**.  A C program is
acceptable only after it has been compiled to a raw NaN16 cartridge.  Normal
operation — boot, kernel, scheduling, processes, VFS, console, device and
service dispatch, POSIX — must execute NaN16 instructions.  C may not be the
implementation of the running system.

`DONT_USE_NAN16_C.md` records the narrower rule that `nan16.c`/`nan_cli` are
an oracle, not the product.

## Canonical product

The product is the unified nan0s image, not the suite harness:

```
tools/mkall.sh  ->  build/nan0s.img
  kboot0.xa       512-byte assembly boot sector
  kan16.xa        native NaN16 core, x86 assembly (~8.5k words)
  guest           NaN16: kernel, nanfs, shell, museum, cartridges
```

`sh tools/qgate.sh` boots that image on bare x86 (QEMU) and requires the
`NaN/0S` banner on COM1.  The default boot is the GUI desktop; `qgate_gui`
checks the 1024x768 framebuffer.  A pending ESC at cold boot enters the text
shell (no museum menu); the GUI/museum code is legacy, not the boot path.  The upgraded machine target is **x86_64 S1**
(`tools/s1_runner.sh`); `tools/nan0s_guest_gate.sh` runs a NaN guest on it by
default and keeps `NAN0S_GUEST_ARCH=32` as legacy parity for the
`kboot0+kan16` image.  Acceptance claims must come from the x86_64 S1 machine
or the unified image, never from `nan_cli` alone.

## Layers

| layer | allowed implementation | current state |
|---|---|---|
| product boot + native core | assembly (`kboot0.xa`, `kan16.xa`) | OK; no C in the product image |
| S6 suite harness | C (`src/native64/s1_kabi.c`, `s1_runner.sh`, `nan_cli`) | test bench only; may not be reported as the system |
| NaN kernel/services | raw NaN16 (`.nas`): SVC, FS, console, processes, timers | FS + metadata + SVC file calls proven; KABI machine features still being ported into `kan16.xa` |
| guest runtime (libc) | C compiled to NaN; service calls must go through NaN (`bare.nas`/SVC) | DB persistence and metadata are proven through NaN; console/time and the rest of the C libc VFS are still self-contained C |
| guest applications (Tcl/SQLite/testfixture) | C compiled to NaN | OK |

## What is still C and must be deleted

Deletion ledger (delete the C body when its NaN replacement is wired):

| file / area | current role | target |
|---|---|---|
| `third_party/nan16-libc/src/libc.c` file I/O, console, time, sleep | C POSIX implementation | call the NaN service table/SVC; delete the C bodies |
| `third_party/sqlite/nan16_vfs_libc.c` | SQLite OS layer over C libc | call the NaN POSIX table; delete the file |
| `third_party/sqlite/nan16_vfs_nan.c` | probe VFS over NaN services | keep as the reference VFS; extend it to the full POSIX surface |
| `src/native64/s1_kabi.c` | S6 machine + test hooks | keep only as ISA/trap/port/timer/region test bench; no kernel services |
| `aarch64/android/core/nan16.c`, `nan_cli` | portable conformance oracle | keep, labelled oracle only |
| host build tools / packers / CI | build-time components | keep |

The suite still boots directly on the S6 harness.  That is a test path, not
the product.  The product integration target is the testfixture as a NaN
cartridge under `build/nan0s.img`.

## Proven NaN service boundaries

Raw-NaN gates, not oracle claims:

- `tools/cbare_gate.sh` — C guest calls NaN console and tick services.
- `tools/cbare_fs_gate.sh` — C guest creates, writes and reads a file through
  `bare_fs_open/write/read/close`.
- `tools/cbare_sqlite_gate.sh` — SQLite (C compiled by TCC) creates a DB,
  closes, reopens, updates and reopens again; persistence is only
  `bare_fs_load/save/remove/size`.
- `tools/nfs2_capacity_gate.sh` — NPAF stores 512 files / about 4 MiB;
  `NFS_MAX` and `NFS_CAP` are compile-time `.equ` values taken from the
  environment.
- `tools/nanfs_svc_gate.sh` — guest `SVC 4..8` traps into a NaN kernel entry
  and performs open/write/read/seek/close on NPAF, on S1.
- `tools/nanfs_meta_gate.sh` — mkdir, stat, readdir, rmdir, access and
  truncate are NaN services over NPAF, on S1.
- `tools/n16i_s1_gate.sh` — the NaN-coded n16i interpreter runs the same
  guest as the native machine with byte-identical output on S1.
- `tools/nan0s_guest_gate.sh` — a NaN guest (POSIX metadata/FS) runs on the
  x86_64 S1 machine by default and on the 32-bit `kboot0+kan16` image in
  `NAN0S_GUEST_ARCH=32` parity mode.
- `tools/nan0s_existing_s1_gate.sh` — extracts the guest region from the
  existing `build/nan0s.img` and boots it on x86_64 S1.  The OS boots the GUI
  desktop by default; ESC at cold boot enters the text shell, whose command
  transcript is checked.  This is the upgraded existing system, not a
  separate CLI.
- `tools/nan0s_gui64_gate.sh` — boots the same OS guest on x86_64 S1, dumps
  the 1024x768 8bpp framebuffer and the Terminal's private character buffer,
  and requires the GUI desktop plus a full NANIX POSIX command transcript
  (mkdir/write/cat/ls/stat/truncate/rm/rmdir) through `bare_fs_*`.  The
  Terminal keyboard path is driven with delayed PS/2 make codes so the
  command line runs after `kbd_init`.
- `tools/nan0s_gui64_sched_gate.sh` — the raw-NaN16 kernel-boot image
  (`src/exhibits/gui_sched_boot.nas`): the GUI is PID 1 (desktop/window
  manager) and PID 2 is the NANIX command process, both created by
  `nsch_init`/`nsch_spawn_desc` and scheduled by `nansched`.  The Terminal
  writes a completed line to `FNB` and yields; PID 2 runs `fs_dispatch` /
  `term_cmd` and writes into the shared virtual console.  The gate requires
  the complete NANIX transcript plus live PID 1/PID 2 states and non-zero
  timer preemption on x86_64 S1.
- `tools/mem_scale_gate.sh` — boots the kernel image at 64 MiB and 128 MiB
  and requires the NANIX shell's `mem` command to report `16777216` and
  `33554432` words.  The count comes from MEMQ, not a guest constant.
- `tools/alloc_scale_gate.sh` — `SVC 2` carves 4,096-word and 8,388,608-word
  RW regions from the bump heap and returns their bases.  This is the
  allocation primitive for variable-size program images; the region spans
  the machine's discovered RAM.
- `tools/execbig_scale_gate.sh` — the base-relative executable path:
  `execbig 70000` allocates a 70,000-word RWX region, fills it with valid
  NOP words, copies a tail that uses `r12` as its runtime base, calls it,
  and verifies the result.  This executes a program larger than the 64K
  code window at a heap base chosen at runtime.
- `tools/nanpipe_libc_gate.sh` — guest libc `pipe()/dup2()/read()/write()`
  over the NaN byte-pipe table; `PIPE PASS` on x86_64 S1.
- `tools/nansched_gate.sh` — the kernel scheduler (`src/lib/nansched.nas`):
  1024-slot nanproc table, 32 priority run levels, timer preemption,
  yield/exit/spawn/wait/kill/sleep, plus SVC 25 setpriority, 26 getpriority,
  27 proc_count and 28 proc_limit.  It installs through `nk_install_proc`;
  `nankernel` keeps SVC 4..8 and delegates process SVCs.  `SCHED PASS`,
  timer preemption nonzero, C oracle == x86_64 S1.
- `tools/nansched_stress_gate.sh` — 512 live child processes under the
  1024-slot scheduler, 73 killed, 512 waited/reaped, status sum 31672, then
  four cooperative nanthr threads with mutex/cond/join.  `SCHED STRESS PASS`,
  timer-preemption counter 711 on S1, C oracle == x86_64 S1.
- `tools/nansmp_gate.sh` — the x86_64 S1 2-CPU and 4-CPU prototype:
  ACPI MADT discovery, INIT-SIPI-SIPI AP startup, per-CPU LAPIC timers,
  cross-CPU reschedule IPIs, NaN spinlock/CAS/fetch-add/fence, and the same
  NaN workload on every core.  Exact transcripts on QEMU `-smp 2` and
  `-smp 4`.  This is a separate prototype; `nansched` still uses one run
  queue.
- `tools/nancli64_gate.sh` — a 64-bit text command line (mkdir/write/cat/ls/
  stat/truncate/rm/rmdir/help/exit) compiled to NaN and running on x86_64
  S1; every filesystem operation goes through the NaN POSIX table.
- `tools/nanpipe_gate.sh` — a 4 KiB NaN byte pipe (open/write/read/wrap/
  close).  This is the storage primitive for POSIX `pipe()`/`dup2()` and
  shell pipelines; the libc/shell wiring is the next step.
- `kabi_spawn` / `kabi_sched` / `kabi_sleep` / `kabi_kill` — mechanism
  proofs for the process SVCs on x86_64 S1.  These are **not** the final
  scheduler; they use a small demo table.  The kernel scheduler is
  `src/lib/nansched.nas` and is installed through `nk_install_proc` in
  `nankernel.nas` (process SVCs 0/1/9/10/20/21/22/23/24).

## What NANIX replaces today

Normal NaN/0S operation does not enter the C libc POSIX implementation:

| surface | implementation |
|---|---|
| desktop, window manager, keyboard, framebuffer | raw NaN16 cartridges |
| desktop Terminal and ESC shell command line | raw NaN16 `fs_dispatch` / `cli_dispatch` |
| file create/read/write/append/truncate | `bare_fs_*` over NPAF (`nfs2.nas`) |
| mkdir/stat/readdir/rmdir/access | `bare_fs_*` metadata over NPAF |
| persistence | NPAF snapshot through the ATA block adapter |
| process/thread control | `nansched` + `nanproc` + `nanthr`, SVC 0/1/9/10/13..28 |
| C guests / TCC / SQLite | C compiled to NaN, still carrying `libc.c` VFS helpers |

The remaining C POSIX surface is therefore the **guest-compatibility
library**, not the running desktop or native shell.  It is listed in the
deletion ledger above and is removed as each call is switched to the NaN
service table.

## Remaining integration work

1. Promote the proven kernel-boot image (`gui_sched_boot.nas`, desktop PID 1
   + NANIX shell PID 2) to the default published `build/nan0s.img`; the S1
   gate already boots it, but the GUI/museum image remains the published
   single-cart boot.
2. Extend `nanthr` from one cooperative thread-owner process to per-process
   thread state and per-thread preemption for AI workloads.
3. Integrate per-CPU queues, IPIs and locks from the proven SMP prototype
   (`src/lib/nansmp.nas`) into `nansched`; the 2/4-CPU gate passes, but the
   product scheduler is still single-core until that wiring lands.
5. Port the frozen KABI machine mechanics (SVC/SVCRET, trap frame, ports,
   regions) from the S6 C model into `kan16.xa`, or run the equivalent NaN
   call table inside the unified guest.
6. Replace libc POSIX calls with the NaN service table; delete each C body as
   it is switched.  The metadata half is done; open/read/write/seek/close is
   done at the FS service level; stat/fstat/opendir/readdir/rename/link/
   symlink/chmod/utime/getcwd/chdir remain to wire.
7. Package the Tcl/SQLite testfixture and the suite tree as a NaN cartridge
   and load it through NaN ATA + nanfs under `build/nan0s.img`.
8. Keep `n16i` as the self-hosted interpreter and differential validator.
9. Close self-replication by regenerating `kboot0.xa`/`kan16.xa` from the
   NaN-written x86 emitter (bootstrap plan R4).

## Migration checklist

- [x] Unified image builds and boots (`tools/mkall.sh`, `tools/qgate.sh`).
- [x] NaN SVC file interface on the bare machine.
- [x] NaN POSIX metadata (mkdir/stat/readdir/rmdir/access/truncate).
- [x] SQLite persistence through NaN services.
- [x] n16i executes on the bare machine.
- [x] NaN process/thread kernel scheduler (1024 slots, 32 priorities,
      preemption, sleep/wait/kill, set/getpriority, count/limit) installed
      via `nk_install_proc`.
- [x] 512-process stress plus four cooperative threads (mutex/cond/join)
      under the kernel scheduler.
- [x] Kernel-boot image: desktop PID 1 + NANIX shell PID 2 under
      `nankernel` + `nansched`, gated on x86_64 S1.
- [x] Runtime MEMQ word count, both process region tables and the boot region
      table widened to real RAM (64 MiB/128 MiB gates).
- [x] `SVC 2` bump heap sized from MEMQ (4K and 64 MiB allocations gated).
- [x] Base-relative variable-size executable path on the SVC 2 heap
      (`execbig 70000`, 70,000 words, >64K code window).
- [ ] General executable format with data/code relocation tables and a
      filesystem-backed loader.
- [ ] VRAM/DEV windows sized from the device's real BAR, with sealed DMA.
- [ ] Promote the kernel-boot image to the default published image.
- [ ] Per-thread preemption and per-process nanthr state.
- [x] SMP 2/4-CPU prototype (AP startup, per-CPU timers, IPIs, NaN atomics).
- [ ] SMP per-CPU queues/IPIs integrated into the product scheduler.
- [ ] KABI machine mechanics (SVC/trap/ports/regions) in the NaN-coded
      64-bit core itself.
- [ ] libc POSIX switched to NaN; C bodies deleted.
- [ ] Suite as a NaN cartridge under `build/nan0s.img`.
- [ ] C removed from normal operation; `s1_kabi.c`/`nan_cli` remain test only.
