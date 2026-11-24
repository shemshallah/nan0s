# Tcl 9.0.3 on NaN16 — port status

## Milestone 2 — official SQLite 3.54.1 testfixture

Status: **test/select1.test passes the official tester harness on the
portable C-core oracle**: 0 errors out of 199 tests, 0 omitted test cases.
Product acceptance (x86_64 S1 runner) is still pending.

Exact gate command:

```
$ TCL_SRC=<tcl-9.0.3> SQLITE_SRC=<sqlite-src-3540100> \
    TCL_NAN16_TESTFIXTURE_ALLOW_ORACLE=1 \
    sh tools/nan16_testfixture_gate.sh
```

Exact gate result:

```
tcl_testfixture: build tcc0
tcl_testfixture: pack official VFS
pack: 2133 files, 25806592 bytes -> <TMPDIR>/suite.n16pack
tcl_testfixture: generate SQLite build headers
tcl_testfixture: compile fixture
tcl_testfixture: run test/select1.test
tcl_testfixture: 0 errors out of 199 tests on  NaN16 32-bit
tcl_testfixture: steps=1428202449 memory=128MiB
tcl_testfixture: WARNING: Multi-threaded tests skipped: Linked against a non-threadsafe Tcl build
tcl_testfixture: omitted=0 cartridge=85167616 sha256=2822a34a6ca569cfb92ba7728b5a1753e07fe5a6bdd207c6785567bbe7944c3f main=00000000
tcl_testfixture: omitted test cases:
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
event channels remain explicit errors/no-ops.  The entry point currently
hardcodes `/sqlite/test/select1.test`; the 1,199-file sweep needs a guest
control block or a single-process Tcl driver to avoid reloading the 85 MB
cartridge per file.

## Milestone 1 — tclsh on NaN16

Goal: a `tcc0`-built, single-threaded `tclsh` cartridge that mounts an
N16PACK1 guest VFS, runs `/test.tcl`, and prints an exact transcript.

Status: **milestone 1 passes on the portable C-core oracle**.  Product
acceptance (x86_64 S1 runner) is still pending; the gate labels the C-core
result `ORACLE MATCH`.

## Exact gate result

```
$ TCL_SRC=<tcl-9.0.3> TCL_NAN16_PORT_ALLOW_ORACLE=1 \
    sh tools/tcl_nan16_port_gate.sh
tcl_nan16_port: build tcc0
tcl_nan16_port: pack guest VFS
pack: 841 files, 3441604 bytes -> <TMPDIR>/suite.n16pack
tcl_nan16_port: compile guest (83 generic + 8 OO + 69 tommath + 11 zlib + 10 port)
tcl_nan16_port: run guest
tcl_nan16_port: cartridge 21270360 bytes sha256 756f7dafb9eb56f5db7fd4cda95314404451057305289de56cf6c153a4451086
tcl_nan16_port: ORACLE MATCH (x86_64 S1 acceptance pending)
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

The oracle run used 128 MiB and halted after about 2.8e9 NaN16 steps.  The
gate default is 8e9 steps.

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

Image: 21,270,360 bytes.  SHA-256:
`756f7dafb9eb56f5db7fd4cda95314404451057305289de56cf6c153a4451086`.

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
4. Produce an x86_64 S1 runner and rerun this gate in product mode (no
   `TCL_NAN16_PORT_ALLOW_ORACLE`).
