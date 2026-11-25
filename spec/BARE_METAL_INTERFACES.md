# Bare-metal interface plan (POSIX replacement)

Status: **table implemented, adapters wired**. `src/lib/bare.nas` provides
the guest table below and default implementations. Console output and keyboard
input pass through slots 1 and 3; block slots wrap the ATA driver; the
filesystem slots now wrap the NPAF path store (open/read/write/seek/close/
remove/rename) and work without a prior `ncc_compile` call by lazily
initializing the C heap. The C stdio layer still calls NPAF directly, so both
paths share one store. `time`/`clock` call `tick_ms` through slot 4; `rand`
takes its first seed from `entropy_u32` through slot 15 (an explicit `srand`
keeps the PRNG deterministic); `rtc_get` remains an adapter hook. Hosted
adapters can patch table words at boot without changing the C ABI.

## Principles

- The guest owns memory, the C stack, the heap, the path filesystem, and the
  compiler itself. No host libc or POSIX call is allowed in the execution path.
- The interface is a small, versioned set of guest-callable routines. It is
  not POSIX and does not try to be.
- Hosted adapters (CLI, GUI terminal, Android, x86) implement the same
  interface; only the adapter changes.
- The C library keeps its standard names. Only the bottom layer changes.

## Minimal interface

| id | interface | contract |
| --- | --- | --- |
| 0 | `iface_version` | returns the interface version |
| 1 | `con_putc(c)` | write one byte to the console; no buffering required |
| 2 | `con_getc()` | return one input byte or `-1` |
| 3 | `key_poll(key)` | non-blocking key query (GUI/CLI adapters) |
| 4 | `tick_ms()` | monotonic milliseconds |
| 5 | `rtc_get(fields)` | wall-clock fields for `time`/`gmtime` |
| 6 | `block_read(lba, buf, n)` | read `n` sectors into guest memory |
| 7 | `block_write(lba, buf, n)` | write `n` sectors |
| 8 | `fs_open(path, mode)` | path open, returns a handle |
| 9 | `fs_read(h, buf, n)` | read bytes |
| 10 | `fs_write(h, buf, n)` | write bytes |
| 11 | `fs_seek(h, off, whence)` | seek |
| 12 | `fs_close(h)` | close |
| 13 | `fs_remove(path)` | remove |
| 14 | `fs_rename(old, new)` | rename |
| 17 | `fs_stat(path)` | size, directory flag, found |
| 18 | `fs_readdir(dir, index)` | entry/name/size/dir for the next immediate child |
| 15 | `entropy_u32()` | random word for `rand`/hash seeds |
| 16 | `halt(code)` | stop the guest |

Timers (including `alarm`/`SIGALRM`) are built on `tick_ms` in guest code; the
interface itself does not deliver signals.

NPAF/NFS2 exposes `nfs_stat`, `nfs_is_dir`, `nfs_readdir`, `nfs_rename` and
`nfs_truncate` in `src/lib/nfs2.nas`; `tools/nfs2_extra_gate.sh` checks them
on the x86_64 runner or the explicitly opted-in C-core oracle.  Paths are byte
strings; `nfs_write` takes a source **word** pointer.  `nfs_truncate` does not
yet reclaim arena space, and `nfs_rename` does not rewrite directory children.

## Mapping from the current library

- `ncc_putc`, stdio output → `con_putc`
- stdin/`getchar`/`scanf` input → `con_getc`/`key_poll`
- `time`, `clock`, `gmtime`, `localtime` → `tick_ms` (slot 4); `rtc_get`
  remains an adapter hook for wall-clock fields
- path filesystem (`nfs2`, stdio files) → `fs_*` (bare adapter wraps NPAF;
  stdio still calls NPAF directly)
- `tmpfile`/`tmpnam` → `fs_*` plus a guest counter
- `rand`/`srand` → `entropy_u32` for the first seed; `srand` remains the
  deterministic guest PRNG
- `exit`/`abort`/`main` return → `halt`
- block-backed persistence → `block_read`/`block_write`; the current ATA
  adapter already snapshots NPAF to LBA 2048 and reloads it at startup

## Phases

1. Inventory every POSIX-shaped call in `src/lib/*.nas` and tag it with the
   interface id above.
2. Add a guest trampoline table and route the tagged calls through it.
3. Implement adapters: CLI serial, GUI terminal, Android, x86 BIOS.
4. Keep a hosted POSIX shim only for development and tests; it must never be
   on the guest execution path.
5. Re-run all `ncc_m*` gates and `mkproof` after each adapter.

The RAM filesystem remains the first target; block persistence comes after the
interface is stable.
