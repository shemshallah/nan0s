# Tcl + SQLite official suite on NaN: OS/Tcl port checklist

Status: **foundation running**. Target: run SQLite 3.54.1's official Tcl
test suite (`test/*.test`, 1,199 files / 489,129 lines) against the NaN16
SQLite port, with `testfixture` and Tcl built by **tcc1/tcc2 on the VM**.
Everything above the S1 machine boundary is NaN code (Tcl/SQLite/libc are C
compiled to NaN16; kernel services are NaN16). No host libc, host process,
host filesystem or host Tcl is allowed in the execution path.

Current foundations: the x86_64 S1 boots and runs flat guest cartridges
(console/NFS2/VFS/time gates pass with `tools/s1_runner.sh`); Tcl 9.0.3
milestone 1 runs a 110-command tclsh with real `init.tcl`/clock on the guest
VFS (oracle, pending S1 FP/vector ops); the 2,133-file N16PACK1 suite pack
registers with the dynamic VFS. Testfixture, threads, sockets, `exec` and
the official run remain.

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
| S1.1 | Trap/SVC gate, trap frame, kernel entry | **frozen v0.1** (`spec/KERNEL_ABI.md`); C oracle + x86_64 ABI slice + flat/large cartridge runner + Tcl milestone 1 product PASS; filesystem/sealed loader pending | syscalls, faults, preemption |
| S1.2 | Timer/PIT, IRQ0, pending bit | instruction-timer vector in C oracle + x86_64 slice; hardware PIT/IRQ0 pending | preemptive threads, `after`/timeouts |
| S1.3 | Region table + per-access checks | software checks in C oracle + x86_64 slice; per-process tables pending | process isolation, fork/exec |
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
| C1b | tcc1 builds its own libtcc from raw source via VFS | **done** (`tcc_nan16_selfbuild`: R = 1,940,008 bytes, raw `test.c` -> 42) | final bare-metal image |
| C2 | tcc1 build of Tcl/testfixture | planned (raw SQLite-on-R probe is the open blocker) | final image |
| C3 | tcc1==tcc2 fixpoint after C1/C2 | **done** at 1,904,320 bytes after C1 (SHA-256 `3c4acd8e...`); rerun after C2 | final proof |
| V1 | Deterministic gates for each layer | partial | CI |
| V2 | Official result archive + exact counts | planned | proof |

## Execution order (each step gets a gate before the next)

### P0 — x86_64 S1 and kernel foundation

- [~] Bring the x86_64 S1 to the same op/feature baseline as the C oracle
      (ports, timer, trap frames, region checks, device windows) and make
      `qgate_x86_64` the acceptance path; the C core only cross-checks.
      Landed: `src/native64/s1_kabi.c` ABI-mechanics slice + floppy and IDE
      large-cartridge loaders (21.3 MB Tcl tclsh PASS) + scalar FP ops +
      `tools/kabi64_gate.sh` / `tools/s1_guest_gate.sh` /
      `tools/s1_runner.sh` gate CLI.
      Missing: vector ops not needed by tclsh, sealed/filesystem loader,
      devices.
- [x] Resolve the `0x39` opcode conflict: keep far `CALL` and assign a new
      SVC/trap opcode. Frozen: 0x4E SVC, 0x4F SVCRET, 0x4D INL; see
      `spec/KERNEL_ABI.md`.
- [~] Implement S1 trap frames: save r0-r15/pc/flags/ADDRH at fixed offsets;
      kernel entry from a vector; return path restores a chosen frame.
      Done in the C oracle and the x86_64 slice; scheduler/TCB wiring is next.
- [ ] Implement SVC dispatch, `yield`, `exit`, `spawn`, `wait`, memory
      region map/query, file descriptors.
- [~] Implement region checks for every load/store/byte/block access and
      guarded stack growth. Done for all memory-touching ops in the C oracle
      and the implemented x86_64 op subset; guarded stack growth pending.
- [~] Implement timer IRQ0/pending bit and preemptive vectoring; keep
      `TICK` deterministic for tests. Instruction-timer vector landed in the
      C oracle and x86_64 slice; hardware PIT/IRQ0 pending.
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

- [x] Vendor Tcl 9.0.3 with VENDOR hashes; the `tclNan16*` platform layer
      replaces the Unix port (`TCL_THREADS=0`, real init.tcl/clock/msgcat).
      Milestone 1: `tools/tcl_nan16_port_gate.sh` builds tclsh with tcc0 and
      runs `/test.tcl` from the guest VFS; 110 commands after real `Tcl_Init`,
      exact stdout `hello 42` / `2`. Integration cartridge 21,278,520 bytes,
      SHA-256 `d95de99d80fd0e36d3ed8b712b01b3e39aac0d2cf9dae31b923f2b5fcbe3440c`.
      Oracle only: the S1 interpreter still lacks FP/vector ops.
- [x] Channel drivers: console and VFS files (open/read/write/seek/truncate,
      relative paths, implicit dirs). Pipes/sockets remain explicit errors.
- [~] Notifier/event loop: timers, `after`, `update`, `vwait` work; VFS file
      handlers are accepted but never fire (no select/poll yet).
- [ ] Thread package backed by the NaN thread ABI.
- [ ] Dynamic loader adapter for `load`.
- [x] Library scripts on the guest VFS; real `init.tcl`, `clock` and `msgcat`
      run from `/usr/lib/tcl9.0`; `source`/glob/proc/OO verified.
- [ ] Tcl's own test suite subset first; then thread/socket/load tests.
- [~] Tcl builds with tcc0; tcc1/tcc2 build still pending.
- [x] Guest console capture: fixed stdout/stderr control block at
      `0x03EFF000`, `nan_cli --guest-stdout/--guest-stderr`, exact console gate.
- [x] x86_64 S1 product runner: `tools/s1_runner.sh` passes console, NFS2,
      VFS dirs/paths/capacity, time and the 21.3 MB Tcl milestone-1 tclsh
      gate. Scalar FP is implemented; vector ops are added only when a real
      cartridge needs them.
- [x] Guest testfixture selector: `--guest-script PATH` writes u32 length at
      `0x03EFF020` and up to 255 bytes at `0x03EFF024` before the cartridge
      starts, distinct from stdout/stderr at `0x03EFF000`.

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
      `tools/tcc_nan16_vfs_pack.sh` also registers a real 2,133-file pack and
      reads the last entry back. Remaining: run the actual suite archive
      through the loader on x86_64 S1.
- [ ] Full `testfixture` build with the official flags, THREADSAFE=1, all
      extensions and test hooks; guest VFS on NaNFS.
- [ ] Port `tester.tcl` capability probes and the test runner; no host
      `exec`/`file` dependencies.
- [ ] Run `select1`, `quick`, `veryquick`, then all 1,199 `.test` files;
      archive exact pass/skip/error counts.
- [ ] Fix every compiler/libc/kernel defect; no SQLite field-size or page
      workarounds.
- [ ] Re-run the native reference on the same tree for differential results.

### P4 source manifest (SQLite 3.54.1)

Official `main.mk` builds `testfixture` from:

- the `sqlite3.c` amalgamation (our vendored copy) or, with
  `USE_AMALGAMATION=0`, `TESTSRC2` (core src + fts3/session/fts5 sources);
- `src/tclsqlite.c` (the build's `tclsqlite-ex.c`);
- `TESTSRC`: 44 `src/test*.c` files plus `ext/{fts3,session,recover,intck,rbu}`
  test sources and the statically linked extensions in `TESTSRC`
  (`ext/expert`, `ext/misc/*`, `ext/fts5/fts5_tcl.c`, `ext/rtree`);
- official `TESTFIXTURE_FLAGS`: `-DSQLITE_NO_SYNC=1`,
  `SQLITE_DEFAULT_PAGE_SIZE=1024`, `SQLITE_ENABLE_STMTVTAB`,
  `SQLITE_ENABLE_DBPAGE_VTAB`, `SQLITE_ENABLE_BYTECODE_VTAB`,
  `SQLITE_ENABLE_CARRAY`, `SQLITE_ENABLE_PERCENTILE`,
  `SQLITE_CKSUMVFS_STATIC`, `SQLITE_STATIC_RANDOMJSON`,
  `SQLITE_STRICT_SUBTYPE=1`, and the configured `THREADSAFE` value.

Our SQLite slice is currently `THREADSAFE=0`; the official fixture needs
`THREADSAFE=1` once the Tcl thread package and NaN thread ABI are wired. The
fixture must be built by tcc1 from guest sources for the final image; a tcc0
build is the first differential step. `testfixture` starts with
`/sqlite/test/veryquick.test` and `TCL_LIBRARY=/usr/lib/tcl9.0`.

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
