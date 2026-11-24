# Tcl + SQLite official suite on NaN: OS/Tcl port checklist

Status: **planning + foundation**. Target: run SQLite 3.54.1's official Tcl
test suite (`test/*.test`, 1,199 files / 489,129 lines) against the NaN16
SQLite port, with `testfixture` and Tcl built by **tcc1/tcc2 on the VM**.
Everything above the S1 machine boundary is NaN code (Tcl/SQLite/libc are C
compiled to NaN16; kernel services are NaN16). No host libc, host process,
host filesystem or host Tcl is allowed in the execution path.

This is deliberately larger than the SQLite amalgamation port. Tcl 9.0.3 is
262,209 lines in 112 `generic/*.c` files; `testfixture` adds the SQLite test
C support plus `tclsqlite.c`; the official suite expects POSIX processes,
sockets, threads, dynamic loading, signals and a real filesystem. The VM
currently has none of those. The checklist below is the authoritative order.

## Definition of done

1. A single NaN16 image can boot into the NaN kernel/shell and spawn the Tcl
   test fixture as a process.
2. `testfixture` runs the official `.test` files from the guest filesystem;
   results are emitted to the guest terminal and captured by the CLI.
3. The official SQLite harness reports zero errors for every test it
   considers applicable on the NaN POSIX profile. Platform-conditional skips
   must be explicit in the harness output, not silent omissions.
4. The same image is rebuilt with **tcc1** (self-hosted compiler) compiling
   Tcl, SQLite and `testfixture` from guest sources; no host tcc0, host
   preprocessor or host source path is used for the final image.
5. `tcc1 == tcc2` byte-for-byte after the changes, with the official suite
   passing under the tcc1-built image.
6. A guest process viewer lists processes/threads, memory, state and CPU
   steps, and can later grow into a manager (kill, priority, spawn, inspect).

## Target and host policy

**Primary product target: x86_64 bare metal (S1 + QEMU).**  The Android/Termux
`nan_cli` and the portable C core are development/conformance oracles only.
No product image, gate, script, or documentation may hardcode a phone path
(`/data/data/com.termux/...`) or assume the Android host.  Every acceptance
gate for this work must have an x86_64 execution path; until the x86_64 S1 has
feature parity, the C core may be used only to cross-check compiler output,
never as the acceptance path.

- The normative machine is the NaN image; the C core in
  `aarch64/android/core/` is the conformance host harness and the development
  S1. The product boundary is S0/S1: fetch/decode/gate/trap, memory, clock,
  keyboard ring, text plane, port I/O, halt. No ATA/filesystem/allocator/
  shell/Tcl logic may live in native C.
- One VM, one memory, one thread model, one device interface
  (`spec/NANVM_SPEC.md`). Processes are software regions + heaps + capability
  tables; threads are contexts in one address space.
- System calls cross S1 through a trap gate. Trap frames are the context
  switch ABI. The NaN kernel owns process/thread tables and all policy.
- Device access is port I/O/DEV windows only; a process holds capability
  handles, never raw device access.
- Files are extents in NaNFS; the block device is behind ATA PIO. A process
  receives handles; path lookup and permissions are kernel policy.
- Tcl/SQLite are compiled by tcc. The C libc keeps standard names, but its
  bottom layer calls the NaN kernel interface. No POSIX host emulation in the
  product.

## Component inventory

Status legend: **done**, **partial**, **planned**.

| # | Component | Current | Needed for Tcl/SQLite |
| - | --- | --- | --- |
| S1.1 | Trap/SVC gate, trap frame, kernel entry | planned; opcode conflict to resolve (`0x39` is far CALL today) | syscalls, faults, preemption |
| S1.2 | Timer/PIT, IRQ0, pending bit | planned; only `TICK` read exists | preemptive threads, `after`/timeouts |
| S1.3 | Region table + per-access checks | planned | process isolation, fork/exec |
| S1.4 | Atomics/fences | opcodes partly present | mutexes, thread-safe SQLite |
| S1.5 | Port I/O/DEV boundary | partial (`0x3E-0x44`) | ATA, NIC, console, timer |
| K1 | Memory regions, page-frame/buddy allocator | nalloc/nalloc64 done in NaN; region layer planned | per-process heaps |
| K2 | Process table, lifecycle, spawn/wait/exit | planned | `fork`/`exec`, tests |
| K3 | Thread table, scheduler, context switch | partial: NaN TCB/scheduler/frame path gated on oracle (`spec/THREADS.md`); x86_64 S1 vector pending | Tcl threads, SQLite THREADSAFE=1 |
| K4 | Mutex/cond/semaphore, TLS | partial: mutex/cond/TLS in `nanthr.nas`; semaphore/barrier and S1 wiring pending | pthread/Tcl |
| K5 | Signals, alarm, timers, process groups | planned | Tcl `after`, SQLite crash tests |
| K6 | NaNFS read/write, directories, rename/unlink/stat | read exists; write planned | Tcl `file`, SQLite temp DBs |
| K7 | Console/terminal, stdin/stdout/stderr, tty | serial/text plane exists; POSIX tty planned | Tcl channels, test output |
| K8 | Sockets: loopback TCP/UDP, bind/listen/accept, poll | planned | Tcl `socket`, SQLite tests |
| K9 | Pipes, `fork`/`exec`, wait, signals | planned | `exec`, crash/fork tests |
| K10 | Dynamic loader for NaN16 modules + symbol table | planned | Tcl `load`, SQLite extensions |
| K11 | Process viewer/manager (guest app) | planned | required deliverable |
| L1 | POSIX libc: file/dir/stat/glob | partial flat in-memory VFS | Tcl/SQLite |
| L2 | stdio: printf/scanf/fwide/encoding | partial; stdout captured in RAM | harness output |
| L3 | pthreads, TLS, semaphores | stubs | Tcl threads, SQLite |
| L4 | sockets, select/poll, getaddrinfo | stubs | Tcl sockets |
| L5 | fork/exec/wait/pipe/signal/termios | missing | official harness |
| L6 | time/clock/gettimeofday/localtime | stubs returning zero | `after`, timestamps |
| L7 | dlopen/dlsym | stub | Tcl `load` |
| L8 | environ, pwd/grp, locale/UTF-8 | missing | Tcl init, encoding |
| T1 | Tcl 9.0.3 platform port (`tclNan16Port`) | planned | core |
| T2 | Tcl channel drivers: console, VFS file, pipe, socket | planned | `open`, `puts`, `source` |
| T3 | Tcl notifier/event loop + timers | planned | `after`, `update`, `vwait` |
| T4 | Tcl thread package (or compatible core) | planned | thread tests |
| T5 | Tcl dynamic loading adapter | planned | load tests |
| T6 | Tcl library scripts (`init.tcl`, encoding, clock, package) on VFS | planned | interpreter init |
| T7 | `tclsh` and script/file execution on NaN | planned | test harness |
| Q1 | SQLite guest VFS on NaNFS, full flags | in-memory VFS today | testfixture DBs |
| Q2 | `testfixture` build (all test C + tclsqlite + SQLite) | native baseline built | official suite |
| Q3 | Official harness capability detection/skips | native run works | testrunner |
| Q4 | `test/*.test` corpus on guest filesystem | not vendored | 1,199 files |
| C1 | tcc1 raw-source/VFS input compile (no host `.i`) | **done** (`tcc_nan16_rawcc`) | Tcl/SQLite on VM |
| C1b | tcc1 builds its own libtcc from raw source via VFS | planned (image still uses host libtcc.i) | final bare-metal image |
| C2 | tcc1 build of Tcl/testfixture | planned | final image |
| C3 | tcc1==tcc2 fixpoint after C1/C2 | **done** at 2,529,728 bytes after C1 (SHA-256 `32c3b8e8...`); rerun after C2 | final proof |
| V1 | Deterministic gates for each layer | partial | CI |
| V2 | Official result archive + exact counts | planned | proof |

## Execution order (each step gets a gate before the next)

### P0 — x86_64 S1 and kernel foundation

- [ ] Bring the x86_64 S1 to the same op/feature baseline as the C oracle
      (ports, timer, trap frames, region checks, device windows) and make
      `qgate_x86_64` the acceptance path; the C core only cross-checks.
- [ ] Resolve the `0x39` opcode conflict: keep far `CALL` and assign a new
      SVC/trap opcode (candidate: an unused v1 slot), update
      `spec/NANVM_SPEC.md` and all encoders/decoders.
- [ ] Implement S1 trap frames: save r0-r15/pc/flags/ADDRH at fixed offsets;
      kernel entry from a vector; return path restores a chosen frame.
- [ ] Implement SVC dispatch, `yield`, `exit`, `spawn`, `wait`, memory
      region map/query, file descriptors.
- [ ] Implement region checks for every load/store/byte/block access and
      guarded stack growth.
- [ ] Implement timer IRQ0/pending bit and preemptive vectoring; keep
      `TICK` deterministic for tests.
- [ ] Implement atomics/fences and a kernel trap-safe critical section.
- [ ] Add `qgate`/`kern` tests for trap frames, nested traps, region faults,
      timer preemption, and syscall ABI.

### P1 — NaN kernel services

- [ ] Process table: pid, state, regions, heap, TCB list, capabilities,
      parent, exit status; spawn from a sealed NaN image; wait/reap.
- [ ] Thread table: context, stack region, state, TLS; round-robin
      scheduler; join; per-thread errno/TLS.
- [ ] Mutex/cond/semaphore/barrier; priority inheritance or documented
      bounds.
- [ ] Signals: pending mask, handlers, `kill`, `alarm`, `SIGCHLD`; safe
      syscall restart rules.
- [~] NaNFS write/extend, directory tree, create/unlink/rename/stat/seek:
      NFS2 now has `nfs_stat`/`nfs_readdir`/`nfs_rename`/`nfs_truncate` and
      an exact gate (`tools/nfs2_extra_gate.sh`).  Permissions, free-space
      reuse and crash consistency remain.
- [ ] Console/tty: input ring, cooked/raw modes, termios, window size,
      stdout/stderr channels.
- [ ] Pipes and process I/O redirection.
- [ ] Loopback sockets: TCP/UDP, bind/listen/accept/connect, shutdown,
      select/poll; IPv4 + localhost; host bridge only behind a capability.
- [ ] Dynamic loader: NaN16 relocatable module format, symbol/reloc tables,
      `dlopen`/`dlsym`, dependency loading, W^X/region sealing.
- [ ] Guest process viewer: process/thread table, memory, CPU steps, state;
      spawn/kill/priority hooks for the future manager.
- [ ] Kernel test suite (NaN code) for every service.

### P2 — POSIX libc for Tcl/SQLite

- [ ] File/dir API on NaNFS: `open/read/write/seek/close`, `stat/lstat`,
      `mkdir/rmdir`, `opendir/readdir`, `rename/unlink`, `glob`, `realpath`,
      `chdir/getcwd`, `access`, `utime`, `fcntl`, `dup/dup2`.
- [ ] stdio: unbuffered/buffered console, `printf` full format set, `scanf`,
      `fwide`, UTF-8, `tmpfile`.
- [ ] pthreads: create/join/detach, mutex, cond, rwlock, once, TLS, keys,
      attributes, barriers, spinlocks; `sem_*`.
- [ ] fork/exec/wait/waitpid, pipes, `posix_spawn`, `system`, `popen`.
- [ ] signals: `sigaction`, masks, `sigwait`, `raise`, `kill`, `alarm`.
- [ ] sockets/select/poll: BSD socket API, `getaddrinfo`, `gethostbyname`,
      `inet_*`, `fcntl` nonblocking, `shutdown`.
- [ ] time: `gettimeofday`, `clock_gettime`, `nanosleep`, `localtime`,
      `gmtime`, `strftime`, timezone data.
- [ ] dynamic loading: `dlopen/dlsym/dlclose/dlerror` on the NaN loader.
- [ ] environment, `pwd.h`/`grp.h`, locale/iconv, `isatty`, `ioctl`.
- [ ] Re-run the full C regression and TCC gates after each libc slice.

### P3 — Tcl port

- [ ] Vendor Tcl 9.0.3 with VENDOR hashes. Adapt `tclPort.h` to a
      `tclNan16Port.h`; implement the `Tclp*` platform layer.
- [ ] Channel drivers: console/tty, VFS files, pipes, sockets; nonblocking
      modes and `fconfigure`.
- [ ] Notifier/event loop: file events, timers, `after`, `update`, `vwait`.
- [ ] Thread package backed by the NaN thread ABI.
- [ ] Dynamic loader adapter for `load`.
- [ ] Library scripts on the guest VFS; `tclsh` runs script files and `-c`.
- [x] Guest console capture: fixed stdout/stderr control block at
      `0x03EFF000`, `nan_cli --guest-stdout/--guest-stderr`, exact console gate.
- [ ] Tcl's own test suite subset first; then thread/socket/load tests.
- [ ] Tcl build by tcc0, then by tcc1 on the VM.

### P4 — SQLite testfixture and official suite

- [x] Pin Tcl 9.0.3 and `sqlite-src-3540100` provenance in
      `src/tests/tcl_sqlite/VENDOR`; `tools/fetch_tcl_sqlite_suite.sh` verifies
      both archives by SHA-256 and extracts outside the repo.
- [x] `tools/tcl_sqlite_native_baseline.sh`: x86_64-gated native Tcl +
      `testfixture` build and official-test baseline (development oracle is
      explicitly opt-in on other hosts).
- [ ] Run the x86_64 baseline and archive exact result counts.
- [x] Pack the Tcl library and official test tree into an `N16PACK1` suite
      image: `tools/nan16_suite_pack.py` produced 2,133 files / 25,806,592
      bytes (Tcl library + `/sqlite/test`).
- [x] Guest `N16PACK1` parser in the C libc VFS: dynamic pointer table
      (`NAN16_VFS_INIT_CAP`, optional `NAN16_VFS_MAXFILES`), linear pack
      registration, 5,000-file capacity gate. The real 2,133-file suite is
      within the tested range; no host filesystem in the product path.
      Remaining: run the actual suite archive through the loader on x86_64 S1.
- [ ] Full `testfixture` build with the official flags, THREADSAFE=1, all
      extensions and test hooks; guest VFS on NaNFS.
- [ ] Port `tester.tcl` capability probes and the test runner; no host
      `exec`/`file` dependencies.
- [ ] Run `select1`, `quick`, `veryquick`, then all 1,199 `.test` files;
      archive exact pass/skip/error counts.
- [ ] Fix every compiler/libc/kernel defect; no SQLite field-size or page
      workarounds.
- [ ] Re-run the native reference on the same tree for differential results.

### P5 — tcc1 bare metal (final)

- [x] Guest VFS for raw input sources/headers: `tcc_nan16_rawcc` compiles
      raw `libc.c` + a program using `/usr/include/...` from the VFS and
      links an 835,928-byte inner cartridge returning 42.
- [ ] tcc1 builds its own libtcc from raw source (no host `libtcc.i`).
- [ ] tcc1 compiles the SQLite/Tcl/testfixture tree from guest files.
- [ ] tcc1 links the final image; run the official suite under it.
- [ ] tcc2 fixpoint byte-identical; SHA-256 recorded.
- [ ] Full pre-SQLite battery + SQLite gate + official-suite gate.
- [ ] Remove all bring-up hacks; document exclusions (target none silently).

## Existing assets to reuse

- `src/lib/bare.nas`: machine interface table; extend with kernel calls.
- `src/lib/nanfs.nas`, `src/lib/nfs2.nas`: NaNFS read; extend to write/dirs.
- `src/lib/ata.nas`: ATA PIO read/write primitives.
- `src/prog/nalloc*.nas`, `nalloc64`: allocators.
- `src/lib/stdio.nas`, `ncc.nas`, `iso.nas`, `signal`/`time` pieces:
  existing NaN runtime surfaces.
- `third_party/nan16-libc`: C libc/VFS used by tcc-compiled programs.
- `third_party/sqlite`: vendored 3.54.1 + in-memory VFS + differential gate.
- `third_party/tinycc` + `tools/tcc_nan16_*`: compiler self-host/fixpoint.

## Known risks

- The S1 trap/IRQ/region design is normative but unimplemented; opcode
  assignments must be frozen before Tcl work.
- Tcl 9's notifier/channel/thread expectations are POSIX-shaped; the NaN
  port must define a single-process, capability-based equivalent rather than
  hide host calls.
- The official suite has Windows/Linux-specific tests; "full" means the
  harness's applicable set on the NaN profile, with every skip printed and
  justified.
- tcc1 compiling Tcl/SQLite on the VM is a multi-billion-step workload; the
  gate must be resumable and memory-bounded.
- No native C may leak into the product to make a test pass. The C core is
  only a conformance harness/S1 development vehicle.

## First concrete steps

1. Freeze the SVC/IRQ/region ABI, bring up x86_64 S1, and add QEMU tests
   (P0).
2. Extend the C libc VFS to a real NaNFS-backed filesystem (P1/K6, P2/L1).
3. Add the tcc1 raw-source driver and compile a two-file program with
   includes from the guest VFS (C1) as the first bare-metal compiler gate.
4. Then attack Tcl's platform layer against the now-stable interfaces.
