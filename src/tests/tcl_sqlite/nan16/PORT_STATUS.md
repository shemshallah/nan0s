# Tcl 9.0.3 on NaN16 — milestone 1 status

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
tcl_nan16_port: cartridge 21305136 bytes sha256 4721632528374788f104a793a8175a90cf0ab4abd7ca17c796ba295d31a713b1
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
`4721632528374788f104a793a8175a90cf0ab4abd7ca17c796ba295d31a713b1`.
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

## Next blockers for the official SQLite Tcl suite

1. Build the SQLite `testfixture` guest (sqlite3.c + tclsqlite.c + test*.c)
   against this Tcl port and load `/sqlite/test/*.test` from the pack.
2. Add `pkgIndex.tcl`/package-path handling and `tcltest`, `msgcat` data to the
   guest library so the suite's `package require` is quiet and complete.
3. Decide whether the test suite needs `exec` (currently an explicit error) or
   file-event channels; neither exists yet.
4. ~~Produce an x86_64 S1 runner and rerun this gate in product mode~~ —
   done: `tools/s1_runner.sh`, large IDE cartridge path, PASS above.
