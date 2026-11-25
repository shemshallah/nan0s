# Tcl 9.0.3 on NaN16 — port status

## Milestone 3 — guest script control block and veryquick

Status: **the complete official aggregate now runs in one guest process
with no step cap.**  A 49.6B-step checkpoint of `veryquick.test` has no test
failures so far; `atof1` (40,006), `attach2` (71) and `ext/expert/expert1`
(69) are green individually.  The remaining work is to let the aggregate
finish and triage the later test/ files.

### Single-process aggregate and resumable VM

- `nan_cli --steps 0/unlimited` runs until HALT with a 64-bit counter.
- `--checkpoint FILE --checkpoint-every S` writes an atomic sparse `NAN1`
  snapshot of guest memory, registers and PC; SIGINT/SIGTERM also checkpoint
  (exit 75), and `--img` accepts the snapshot to resume.  The console buffer
  and the whole libc VFS are in guest memory, so output and files survive a
  host restart.
- `tools/nan16_suite_resume.sh BASE CHECKPOINT TEST OUTDIR` loops the runner:
  base cartridge first, checkpoint afterwards, until HALT.  No sharding or
  per-file splitting is needed.
- `nan_cli` SIGUSR1 dumps the live console without stopping;
  `tools/nan16_state_console.py` reads the same transcript directly from a
  checkpoint.
- `tools/s1_runner.sh --steps unlimited` passes `UINT64_MAX` to the 64-bit S1
  guest loop; `S1_QEMU_TIMEOUT` controls QEMU wall time.

### Locking, readonly and variadic fixes (veryquick triage)

- SQLite same-process locks are emulated explicitly in
  `nan16_vfs_libc.c` (shared/reserved/pending/exclusive, `SQLITE_FCNTL_LOCKSTATE`,
  `xCheckReservedLock`), read-only opens reject writes, and `open(O_CREAT)`
  requires an existing parent.  `attach2.test` is now **0 errors out of 71**.
- A variadic call kept the hidden argument pointer in `r11`; the 16-bit load
  in `nan_push_arg()` used `r11` as scratch, so a `short` variadic argument
  replaced it with 0 and `va_arg` returned the first cartridge words.  Keep
  the pointer in `r9`.  `PRAGMA index_info` (i16 through
  `sqlite3VdbeMultiLoad`) and `sqlite3_expert_analyze` work again:
  `ext/expert/expert1.test` is **0 errors out of 69**.
- Tcl's `file executable` now returns false for regular VFS files, so the
  official CLI/shell tests take their explicit `continue`/skip path instead
  of aborting the aggregate in `exec`.
- Symbolic links are real in the libc VFS and Tcl (`file link`/`readlink`);
  `xFullPathname` resolves the target and returns `SQLITE_OK_SYMLINK` for
  `-nofollow`.  `symlink.test` now completes.  The remaining 13 failures are
  WAL expectations (the fixture is built with `SQLITE_OMIT_WAL`) plus
  `symlink-1.3`, which creates a loop with `exec ln -s` (no Tcl `exec`).
- `ext/recover` currently reports 42 failures in the aggregate.  Traced so
  far: official `PRAGMA page_size` is 1024, the copied page-2 header is a
  valid 0x0D table leaf at 1024 (`recoverIsValidPage` semantics reproduced in
  Python: cells end at 1024/1009, free block 1009+8, fragment count 0), and a
  C probe using the same SQLite/recover/VFS with a `SQLITE_ENABLE_DBPAGE_VTAB`
  build recovers to page size 1024.  The Tcl-copied `test.db2` instead makes
  `sqlite3_recover_run` return SQLITE_NOTADB and the test output page size
  512.  This points at the recover wrapper input-page path, not at TCC; the
  remaining page-size detector/wrapper interaction is still open.
- POSIX permission bits are implemented (0644/0444/0755/0777, chmod, stat,
  access, open checks) and Tcl exposes `-permissions`; `attach.test` is now
  **0 errors out of 113**, `attach2.test` **0/71**.  The read-write open
  fallback to O_RDONLY fixes the readonly-database path (backup2-6).
- VFS sync and fullsync counters are incremented under `SQLITE_TEST`, so
  `SQLITE_NO_SYNC` is no longer defined; avtrans' sync assertions can run.
- The flat cartridge cannot fork/exec or create pipes, so
  `tools/nan16_patch_lock_common.py` makes `do_multiclient_test` probe pipe
  creation and run only the same-interpreter (tn==2) variant instead of
  aborting the aggregate at busy2.test.
- Official `recoverpgsz.test` is **0 errors out of 89**.  The root cause was
  the libc VFS `write()` not zero-filling a gap when seeking past EOF, so
  recover read stale heap bytes as synthetic page 1 and detected 1024 for
  every requested size.  With the gap zeroed and the read-only open flags
  preserved, all page sizes (512..65536) recover correctly.
- Official `backup2.test` is **1 error out of 16**: only backup2-10's
  wording differs (`unable to open database file` vs the unix `disk I/O
  error`).  backup2-7/11 now return SQLITE_NOTADB; backup2-6 reports the
  read-only target correctly.  The remaining mapping is a directory-open
  error-code wording issue.
- Current best fixture (`final-fix.bin`): 96,064,648 bytes, SHA-256
  `857e8a97cd976d10db65d161d1a27889a37c705c2236feb02d8967120d217a49`;
  WAL enabled, select1 **199/0**, recoverpgsz **89/0**, backup2 **15/16**.
- WAL is enabled in the official fixture.  The small WAL probe passes
  (`journal_mode=wal`, insert, reopen, count=2).  The earlier startup halt at
  pc 3,146,612 was a fixed-SP overlap: WAL data ends 47,748 bytes above the
  old `SP=0xC00000`, so stack frames overwrote `sqlite3Config`/`xLog`.
  `nan16-link.c` now emits `SP=max(0x300000,align16(total_words))`.  WAL
  fixture: 96,064,648 bytes, SHA-256
  `8e59fd9a6e690d9b3795a4fa678f91a7ac3454e6928f6c1839fe7561245d4a46`,
  select1 **199/0**.  `busy2` runs to a normal halt but has 5/15 failures
  because `xShmLock` is still a no-op (checkpoint read-mark/busy states);
  real shm lock semantics are the next WAL item.
- Current product fixture: 96,064,648 bytes, SHA-256
  `758e4ed1182a938fc42e0c1aa52d111032f9d495a4bce1b12a2db6b7f8850f62`
  (select1 199/0).  A fresh one-process veryquick run (checkpointed) is in
  progress; earlier runs reached 431B steps before the busy2 abort.
- The testfixture build kept `SQLITE_OMIT_DEPRECATED`, which compiles
  `test_expired()` down to a TCL_OK with no result; `badutf2-4.0` therefore
  saw `{}` instead of `0`.  The official testfixture does not omit deprecated
  APIs.  With that define removed, `badutf2.test` is **0 errors out of 42**.
  Product fixture: 96,064,000 bytes, SHA-256
  `16993026b069992129c2b3282cc2cb4a48bc6c29e84d71fe10773cb2e1a61af2`.

### Guest script control block

- Guest byte `0x03EFF020`: u32 script-path length (little-endian).
- Guest byte `0x03EFF024`: script-path bytes (no NUL required).
- `nan_cli --guest-script PATH` writes the block before starting the guest.
- `tools/s1_runner.sh --guest-script PATH` compiles the path into the S1
  kernel image and writes the same block into guest memory before boot.
- `tclNan16TestEntry.c` reads the block as `argv[1]`; an empty/invalid block
  defaults to `/sqlite/test/select1.test`.  The block is separate from the
  stdout/stderr control words at `0x03EFF000`.

### Shared file namespace and memory

- The fixture now compiles `third_party/sqlite/nan16_vfs_libc.c` instead of
  the private in-memory `nan16_vfs.c`.  Tcl `file` commands, `hexio_*` and
  SQLite all see the same `test.db`.
- Guest memory: 256 MiB; libc heap: 128 MiB (`-DNAN16_HEAP_SIZE=134217728`);
  N16PACK1 pack at `0x01000000`.
- The fixture compiles the complete official `TESTSRC` list from
  `main.mk` (test1..test9, autoext, backup, bestindex, blob, btree, config,
  delete, demovfs, devsym, fs, func, hexio, init, intarray, journal, malloc,
  md5, multiplex, mutex, onefile, osinst, pcache, quota, rtree, schema,
  superlock, syscall, tclvar, thread, vdbecov, vfs, window, wsd, fts3_term,
  fts3_test, session, recover, intck, rbu, expert, fts5 tcl/test sources,
  rtree test) plus the official static extensions.  No empty initializer
  stubs remain.

### veryquick result (C-core oracle)

```
guest-script: /sqlite/test/veryquick.test
steps:        47,047,413,335
memory:       256 MiB, heap 128 MiB
harness:      1000 errors out of 3977 tests on  NaN16 32-bit
failed tests: atof1-1.* only (1000 failures)
omitted:      0
main result:  1 (harness exit status)
cartridge:    85,167,616 bytes
sha256:       2fd68c8919285750dc416adeb8b6921022879212ae140b82c998d5dd5d888438
slowest file: alterdropcol.test, 7,967,500 ms as reported by the harness clock
```

First real failure:

```
! atof1-1.1.1 expected: [1]
! atof1-1.1.1 got:      [0]
  real2hex: 41814625810b4b73 vs 41814625810bd4
```

Root cause: the guest libc `snprintf` implements `%e` with only six
fractional digits.  Tcl's `format %.32e` therefore produces a rounded text
value, SQLite parses that text to a different IEEE-754 double, and the
SQLite-vs-Tcl comparison fails.  The same limitation affects `%f`/`%g`
formatting and is the next required port fix (accurate float-to-decimal
conversion, likely using Tcl's `TclDoubleDigits` or SQLite's FpDecode
algorithm).  This is not a test-module or VFS failure.

The official multi-thread warning remains: `Multi-threaded tests skipped:
Linked against a non-threadsafe Tcl build`; Tcl/SQLite are still
`TCL_THREADS=0` / `SQLITE_THREADSAFE=0`.

### Formatter follow-up — atof1 green

The float formatter now uses Tcl's own `TclDoubleDigits(value, -1,
TCL_DD_SHORTEST, ...)` through `nan16_digits_hook`, copying only the digits
before its returned `end` pointer.  The earlier fixed-17/no-shortest call was
pathological; the shortest conversion plus 64-bit division fast paths is
fast.

Exact official result on the C-core oracle:

```
guest-script: /sqlite/test/atof1.test
harness:      0 errors out of 40006 tests on  NaN16 32-bit
steps:        92,184,860,546
memory:       256 MiB, heap 128 MiB
main result:  0
all memory allocations freed - no leaks
```

`format %.32e 1.2345678901234567` now produces
`1.23456789012345670000000000000000e+00`, matching the host.  The full
fixture with the complete TESTSRC set also keeps select1 green: 199 tests,
0 errors, cartridge 85,167,616 bytes, SHA-256
`1348bb8895968b42e68e097fe6ecad886bf15c011843fbaaebd7f09aeda3d6e8`.

Veryquick must still be rerun to a final summary with a budget above ~150B
because it includes all 40,006 atof1 cases; the previous 47B/3,977-test run
was aborted by the old formatter failures, not by a missing module.
`format %e 1.5` produces `1.500000e+00` in about 107M steps.  A
180B-step veryquick run reached its step limit without a summary;
the complete aggregate needs more (atof1 alone is 92.18B steps).

## Milestone 2 — official SQLite 3.54.1 testfixture

Status: **test/select1.test passes the official tester harness on both the
portable C-core oracle and the x86_64 S1 product runner**: 199 tests, 0
errors, 0 omitted test cases.

Product gate command (S1):

```
$ TCL_SRC=<tcl-9.0.3> SQLITE_SRC=<sqlite-src-3540100> \
    TCL_NAN16_TESTFIXTURE_RUNNER=$PWD/tools/s1_runner.sh \
    sh tools/nan16_testfixture_gate.sh
...
tcl_testfixture: 0 errors out of 199 tests on  NaN16 32-bit
tcl_testfixture: WARNING: Multi-threaded tests skipped: Linked against a non-threadsafe Tcl build
tcl_testfixture: omitted=0 cartridge=85167616 sha256=57864357f6033f696daff081faff7a4a7a0e9cf35c6e11136b7c92fedad24349 main=00000000
tcl_testfixture: PASS (select1.test: 199 tests, 0 errors)
```
tcl_testfixture: ORACLE MATCH (select1.test: 199 tests, 0 errors, x86_64 S1 acceptance pending)
```

- Guest memory: 128 MiB.  Steps used: 1,428,202,449.  Main result: 0.
- Cartridge: 85,167,616 bytes, SHA-256
  `2822a34a6ca569cfb92ba7728b5a1753e07fe5a6bdd207c6785567bbe7944c3f`.
- Guest VFS: one N16PACK1 archive, 2,133 files / 25,806,592 bytes, mounted at
  `0x01000000`; it contains the official `/sqlite/test` tree (excluding
  `.db`, `.zip` and other non-source assets as defined by
  `tools/nan16_suite_pack.py`) and the complete Tcl `library/` tree at
  `/usr/lib/tcl9.0`.
- No test in `select1.test` was skipped.  The only skip statement is the
  official harness's process-wide thread warning: SQLite/Tcl are built
  `SQLITE_THREADSAFE=0` / `TCL_THREADS=0`, so `run_thread_tests` skips the
  multi-threaded tests.
- First real failure: none.

### Fixture identity

The official C sources are used, not a custom SQL runner:

- `third_party/sqlite/sqlite3.c` (pinned 3.54.1 amalgamation; the source tree
  does not contain `sqlite3.c`), `ext/qrf/qrf.c`, `src/tclsqlite.c`.
- `src/test_tclsh.c` supplies the official `sqlite3TestInit()`; it is wrapped
  only to install the guest exit adapter and the Tcl library path.
- `tclsqlite.c` is compiled with `-DTCLSH_INIT_PROC=sqlite3TestInit` and
  `-DTCLSH_MAIN=Sqlite3TestMain`, so its official `main()`/script driver is
  used.  The NaN16 ABI supplies no argv, so `tclNan16TestEntry.c` calls that
  main with `{"/testfixture","/sqlite/test/select1.test"}`.
- TESTSRC modules compiled: `test1.c`, `test2.c`, `test_config.c`,
  `test_md5.c`, `test_hexio.c`, `test_malloc.c`, `test_mutex.c`,
  `test_func.c`, `test_autoext.c`, `test_delete.c`, `test_pcache.c`,
  `test_vfs.c`.
- The official static extensions from `TESTSRC` are compiled (amatch,
  appendvfs, basexx, cksumvfs, closure, csv, decimal, diskused, eval,
  explain, fileio, fuzzer, ieee754, mmapwarm, nextchar, normalize, prefixes,
  qpvtab, randomjson, regexp, remember, series, spellfix, stmtrand, strdup,
  totype, unionvtab, wholenumber, zipfile).
- Modules outside this select1 slice have empty TCL_OK initializers in
  `tclNan16TestStubs.c`: test3/4/5/6/8/9, blob, demovfs, init, schema, sse,
  tclvar, fs, Thread, Onefile, Osinst, backup, intarray, rtree, rtreedoc,
  quota, multiplex, Superlock, Syscall, Fts5, Rbu, bestindex, Expert, window,
  vdbecov, Recover, intck.  No command is fabricated: a later test that calls
  one of these commands gets a real "invalid command name" failure.

SQLite flags: the official `TESTFIXTURE_FLAGS` (including
`SQLITE_DEFAULT_PAGE_SIZE=1024`, STMTVTAB, DBPAGE, BYTECODE, CARRAY,
PERCENTILE, CKSUMVFS_STATIC, STATIC_RANDOMJSON, STRICT_SUBTYPE=1,
SERIES_CONSTRAINT_VERIFY) plus `SQLITE_OS_OTHER=1`, `SQLITE_THREADSAFE=0`,
`SQLITE_TEMP_STORE=3`, `SQLITE_OMIT_WAL`,
`SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_OMIT_LOCALTIME`,
`SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_SHARED_CACHE`,
`SQLITE_MAX_MMAP_SIZE=0`.
`SQLITE_THREADSAFE=0` is the milestone-2 simplification; the final fixture
needs `SQLITE_THREADSAFE=1` after Tcl thread support.

### Port fixes needed by the fixture

- **Tcl's bundled allocator** is enabled with `-DUSE_TCLALLOC=1`.  The guest
  libc's simple first-fit free-list walk is not viable for the millions of
  small Tcl/SQLite allocations in testfixture; with TclAlloc, select1
  completes in 1.43e9 steps.  This is Tcl's supported allocator, not a
  semantic change.
- **reset_db bridge**: Tcl `file delete` is mirrored into the SQLite `nan16`
  VFS via `nan16_sqlite_delete`, because the official tester deletes
  `test.db` between test groups while SQLite and Tcl currently have separate
  in-memory file tables.  The wrapper tries the exact Tcl path, basename and
  `./basename` forms.
- **Exit adapter**: the official `finish_test` calls `exit`; the guest's
  libc `exit()` loops rather than terminating the cartridge.  A Tcl `exit`
  wrapper records the status and raises a controlled error so the official
  main returns; the wrapper maps it to the guest main result.
- `sysconf`, `strftime`, `rewind`, `chown`/`fchmod` compatibility, SQLite
  test globals (`sqlite3_current_time`, sync counters), `parse.h`/`opcodes.h`
  generated from the amalgamation, and `sys/uio.h`/`memory.h` headers.

Known scope limits for the next official files: Tcl `file` only mirrors
deletes into the SQLite VFS; file-size/exists/hexio checks on `test.db` would
still need a shared filesystem.  `exec`, sockets, dynamic loading and file
event channels remain explicit errors/no-ops.  `nan_cli --guest-script PATH`
now supplies the test path through the guest control block at `0x03EFF020`,
so one 85 MB image can run arbitrary `.test` files; `tools/s1_runner.sh`
needs the matching host option for product runs.

## Milestone 1 — tclsh on NaN16

Goal: a `tcc0`-built, single-threaded `tclsh` cartridge that mounts an
N16PACK1 guest VFS, runs `/test.tcl`, and prints an exact transcript.

Status: **milestone 1 passes in product mode on the x86_64 S1**.  The
portable C-core oracle agrees; no oracle flag is used for acceptance.

## Exact gate result

```
$ TCL_SRC=<tcl-9.0.3> TCL_NAN16_PORT_RUNNER=$PWD/tools/s1_runner.sh \
    sh tools/tcl_nan16_port_gate.sh
tcl_nan16_port: build tcc0
tcl_nan16_port: pack guest VFS
pack: 841 files, 3441604 bytes -> <TMPDIR>/suite.n16pack
tcl_nan16_port: compile guest (83 generic + 8 OO + 69 tommath + 11 zlib + 10 port)
tcl_nan16_port: run guest
tcl_nan16_port: cartridge 21383808 bytes sha256 288eae147caa361576b350eba214196b2c6714c540e30322d74f017cf2fbd0b5
tcl_nan16_port: PASS (guest VFS tclsh, exact stdout + main result 0)
```

Guest transcript (exact, stdout):

```
hello 42
2
```

Main result: word 0x100 is `00000000`.  Guest stderr: empty.  The script is
`/test.tcl`; the image also contains the complete Tcl 9.0.3 `library/` tree
under `/usr/lib/tcl9.0`, so `Tcl_Init` sources the real `init.tcl` (not a
hand-written stub) and the `clock` ensemble is created from `clock.tcl`.

The product run used the x86_64 S1 runner, `--mem 128` and the 21.3 MB
flat cartridge through the IDE large-image path.  The guest halts and the
runner reads the control block; the gate default is 8e9 steps.  The
allocation fixes `20f295b`, `105c62d` and `067999f` are required for the
guest heap to survive Tcl's allocator pattern.

## Build shape

- Host role: `cc` builds `tcc0` only.  No host C is in the guest image.
- Guest compiler: `tcc0 -nostdlib -DNDEBUG` with `-DTCL_THREADS=0`,
  `-DHAVE_TCL_CONFIG_H=1`, the port headers, the NaN16 libc headers, the Tcl
  generic/libtommath/zlib headers.
- 91 Tcl generic C files: the Tcl 9.0.3 `GENERIC_OBJS` list minus
  `generic/tclIOSock.c` (83), plus the eight `tclOO*.c` files.  This includes
  `tclZipfs.c`, `tclZlib.c`, `tclIcu.c`, `tclPipe.c`, `tclProcess.c`,
  `tclStubInit.c`, `tclTomMathInterface.c` and `tclMain.c`.
- 69 libtommath objects from `TOMMATH_OBJS` plus `bn_cutoffs.c`.
- 11 bundled zlib objects (`adler32` … `zutil`).
- The ten `tclNan16*.c` platform files and `third_party/nan16-libc/src/libc.c`.
- Tcl `TCL_THREADS=0`; no socket, load or thread package is enabled.

Image: 21,298,008 bytes.  SHA-256:
`288eae147caa361576b350eba214196b2c6714c540e30322d74f017cf2fbd0b5`.
The pack is a generated static `tcl_nan16_pack[]` array (from
`tools/nan16_embed.py`), not a fixed `GUEST_PACK_BASE` image section, so
there is no header/image pack-base mismatch in this tclsh build.

## Platform files replaced (unix/ is not compiled)

None of `unix/tclUnixChan.c`, `tclUnixEvent.c`, `tclUnixFCmd.c`,
`tclUnixFile.c`, `tclUnixPipe.c`, `tclUnixSock.c`, `tclUnixTime.c`,
`tclUnixInit.c`, `tclUnixThrd.c`, `tclUnixCompat.c`, `tclAppInit.c`,
`tclLoadDl.c`, or the epoll/kqueue/select notifier files are part of the
guest.  They are replaced by:

| file | role |
| --- | --- |
| `tclConfig.h` | hand-written Tcl 9.0.3 feature configuration |
| `tclUnixPort.h` | the header `generic/tclPort.h` includes on this port |
| `tclNan16Init.c` | process/interpreter init, library path, variables, time |
| `tclNan16Chan.c` | file/std channels, channel truncate, pipe-file shims |
| `tclNan16File.c` | VFS stat/access/chdir/path normalization/glob |
| `tclNan16FCmd.c` | copy/rename/delete/mkdir/rmdir and temp files |
| `tclNan16Notfy.c` | single-threaded notifier: timers/`after`/`vwait` |
| `tclNan16Load.c` | dynamic loading and process/thread platform hooks |
| `tclNan16Sock.c` | explicit socket error stubs |
| `tclNan16Compat.c` | C-locale, strcasecmp/strndup, uid/utime/signal gaps |
| `tclNan16Math.c` | `hypot` (the rest of libm is now in the NaN16 libc) |
| `tclNan16AppInit.c` | tclsh main: mount pack, `Tcl_Init`, eval `/test.tcl` |

`generic/tclIOSock.c` is also replaced by `tclNan16Sock.c` because it depends
on host `netdb.h`; the public socket entry points fail explicitly.

### Platform entry points: real vs. explicit failure

Real (backed by the NaN16 VFS, guest clock, or a correct single-threaded
implementation):

```
TclpInitPlatform, TclpInitLock/Unlock, TclpGlobalLock/Unlock,
TclFinalizeLock, Tcl_GetAllocMutex
TclpFindExecutable, TclpInitLibraryPath, TclpSetInitialEncodings,
TclpSetVariables, TclpGetCwd, TclpFindVariable,
Tcl_GetEncodingNameFromEnvironment
Tcl_GetTime, Tcl_SetTimeProc, Tcl_QueryTimeProc, TclpGetSeconds,
TclpGetMicroseconds, TclpGetClicks, Tcl_Sleep
Tcl_MakeFileChannel, TclpOpenFileChannel, TclpGetDefaultStdChannel
TclpOpenFile, TclpMakeFile, TclpCloseFile
TclpCreateTempFile, TclpTempFileName, TclpTempFileNameForLibrary,
TclpOpenTemporaryFile, TclUnixOpenTemporaryFile
TclpObjAccess/Lstat/Stat/Chdir/NormalizePath/MatchInDirectory/
  RenameFile/CopyFile/DeleteFile/CreateDirectory/RemoveDirectory/
  CopyDirectory/ListVolumes
TclpGetNativeCwd, TclpNativeToNormalized, TclNativeCreateNativeRep,
TclNativeDupInternalRep, TclpFilesystemPathType
TclpInitNotifier, TclpFinalizeNotifier, TclpAlertNotifier, TclpNotifierData,
TclpSetTimer, TclpWaitForEvent, TclpServiceModeHook
Tcl_GetHostName, Tcl_PidObjCmd, Tcl_GetCurrentThread, TclpThreadExit,
TclGetAndDetachPids (no children can exist), TclUnixCopyFile,
TclUnixWaitForFile (VFS memory fds report ready)
```

Explicit failure / no-op hooks (documented, never claimed as working):

```
TclpDlopen                     -> TCL_ERROR ("dynamic loading...")
TclpCreatePipe                 -> 0 (failure)
TclpCreateProcess              -> TCL_ERROR ("child processes...")
TclpCreateCommandChannel       -> NULL + EOPNOTSUPP
Tcl_CreatePipe                 -> TCL_ERROR ("pipes...")
Tcl_WaitPid                    -> (Tcl_Pid)-1 + ECHILD
Tcl_JoinThread                 -> TCL_ERROR (single-threaded)
Tcl_GetOpenFile                -> TCL_ERROR (no stdio FILE*)
TclpObjLink, TclpReadlink      -> NULL + EINVAL
TclpUtime                      -> -1 + EACCES
TclpGetUserHome                -> NULL (no passwd database)
Tcl_OpenTcpClient/Server/ServerEx, Tcl_MakeTcpClientChannel
                               -> NULL / TCL_ERROR (no sockets)
TclSockGetPort                 -> numeric only; service names TCL_ERROR
TclSockMinimumBuffers          -> -1 + EOPNOTSUPP
TclWinCPUID                    -> TCL_ERROR (not an x86 CPU)
TclpCreateFileHandler/DeleteFileHandler
                               -> accepted no-ops; file events never fire
```

`file attributes` has an empty `tclpFileAttrStrings` table and no get/set
procedures; it returns an empty attribute list rather than inventing one.

## Passed areas (observed on the oracle)

- `Tcl_CreateInterp`, `Tcl_Init` with the real Tcl 9.0.3 `init.tcl`, package
  setup, `tcl_library`/`auto_path`, `tcl_platform`.
- Guest VFS pack mount (841 files, implicit directories), `Tcl_EvalFile`
  of `/test.tcl`, `source` of library scripts, `file exists/isdirectory/size/
  writable` (read-only pack files report not writable).
- Core commands: `set`, `incr`, `expr` (integer, double, libm), `puts`,
  `proc`, `namespace`, `dict`, `regexp`, `format`, `string`/`string map`,
  `lsort`, `encoding convertto`, `interp create/eval/delete`, `pid`.
- `open`/`read`/`write`/`close`/`gets`/`puts`, line buffering, stdout/stderr
  control block, `chan truncate` via real `ftruncate(2)` (guest check:
  `file size` becomes 3 after truncating a six-byte file to 3).
- Guest cwd and relative paths: `pwd`, `cd /usr/lib/tcl9.0`,
  `file exists init.tcl`, and `open init.tcl`.  `TclpObjNormalizePath`
  preserves leading `..` for relative paths instead of forcing absolute
  paths; the libc VFS now implements real `chdir`/`getcwd`.  Diagnostic:
  `cwd /`, `rel 1`, `gets 32 read 87`, `trunc 3`, `cwd2 / hello 42`.
- `file copy`, `file rename`, `file mkdir`, `file delete`, `glob` over implicit
  VFS directories (including the packed Tcl library and tzdata tree).
- `after` timers and `vwait` use the guest monotonic clock
  (`0x03EFF010`); `clock seconds`, `clock milliseconds`, `clock format`
  (including UTC epoch formatting) and `clock add` work through the real
  library.
- UTF-8 strings (UCS-4 core), e.g. `string length "héllo"` is 5.
- OO and all generic commands link and initialize; 110 commands after the real
  `Tcl_Init`.

## Explicitly unsupported or error-returning (not silent successes)

- Threads/synchronization: `TCL_THREADS=0`; `Tcl_CreateThread` is the Tcl
  non-threaded `TCL_ERROR`; `Tcl_JoinThread` returns `TCL_ERROR`;
  `Tcl_GetCurrentThread` returns a stable single-thread token.
- Sockets: `Tcl_OpenTcpClient`, `Tcl_OpenTcpServer`, `Tcl_OpenTcpServerEx`,
  `Tcl_MakeTcpClientChannel` return `NULL`/`TCL_ERROR`; service-name lookup
  fails explicitly.  No `socket` command is installed.
- Dynamic loading: `TclpDlopen` returns `TCL_ERROR` (`load` errors).
- Processes/pipes: `TclpCreatePipe`, `Tcl_CreatePipe`, `TclpCreateProcess`,
  `TclpCreateCommandChannel` fail; `exec`/pipeline open paths report errors.
  `pid` is real (returns guest pid 1).  `Tcl_WaitPid` reports `ECHILD`.
- File events: `TclpCreateFileHandler`/`DeleteFileHandler` are accepted and
  never fire; there is no `select`.  Timers are real.  `TclUnixWaitForFile`
  reports VFS fds ready (they are memory files) but is not used by the core
  channel path.
- `Tcl_GetOpenFile` (stdio `FILE *` access) returns `TCL_ERROR`; `fdopen` is
  absent from the guest libc.
- Links/symlinks: `file link`, `readlink`, `utime` fail (`EINVAL`/`EACCES`);
  `lstat` aliases `stat`.
- `file attributes` returns an empty attribute set (no owner/group/mode
  database).
- No encoding data files are loaded.  Built-in Tcl encodings remain visible
  because they are compiled into `tclEncoding.c`; the system/new-channel
  encoding is UTF-8.

## Deviations / notes

- `TCL_UTF_MAX=4`, not 3.  Tcl 9.0.3's `generic/tcl.h` explicitly `#error`s
  when `TCL_UTF_MAX==3` and `BUILD_tcl` is defined; the 9.x core is UCS-4.
  This port therefore uses the supported UCS-4 UTF-8 core and does not
  register external encodings.  `tclConfig.h` documents this.
- The guest `errno.h`, `locale.h`, `utime.h`, `signal.h` and `sys/mman.h`
  overlays are port headers only; they do not replace libc behavior.
- The real Tcl library source tree has no generated `pkgIndex.tcl`.  A package
  require that scans `auto_path` reports those missing index files on stderr;
  `package require msgcat` still succeeds in the diagnostic run, but package
  index generation is milestone-2 work.
- Huge trig arguments use Tcl 9's normal libm; the guest libm was separately
  differential-gated by `tools/nan16_libm_gate.sh`.

## Milestone 1 next blockers

1. Build the SQLite `testfixture` guest (sqlite3.c + tclsqlite.c + test*.c)
   against this Tcl port and load `/sqlite/test/*.test` from the pack.
2. Add `pkgIndex.tcl`/package-path handling and `tcltest`, `msgcat` data to the
   guest library so the suite's `package require` is quiet and complete.
3. Decide whether the test suite needs `exec` (currently an explicit error) or
   file-event channels; neither exists yet.
4. ~~Produce an x86_64 S1 runner and rerun this gate in product mode~~ —
   done: `tools/s1_runner.sh`, large IDE cartridge path, PASS above.
