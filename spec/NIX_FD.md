# NANIX fd / stdio contract (phase 1.5)

Status: coordination contract for shell-I/O, persistence and stdio wiring.

## Descriptor table

Each shell process has a small fd table (16 entries) in raw NaN16:

| fd | default | backing |
|---:|---|---|
| 0 | terminal input | FNB / line queue |
| 1 | terminal output | Terminal `vc_putc` |
| 2 | terminal error | Terminal `vc_putc` (separate slot, same display) |
| 3..15 | free | NPAF file stream or pipe |

Descriptor entry: `{used, kind, handle, flags, pipe_id}`.
`kind`: 0 unused, 1 terminal, 2 NPAF file, 3 pipe.

## ABI (`src/lib/nixfd.nas`)

- `nfd_init` — install fd 0/1/2.
- `nfd_open r1=path byte r2=flags(0 read,1 write,2 append)` -> fd or -1.
  - Files use `bare_fs_open/read/write/close`.
- `nfd_read r1=fd r2=dst byte r3=len` -> bytes or -1.
- `nfd_write r1=fd r2=src byte r3=len` -> bytes or -1.
- `nfd_close r1=fd` -> 0/-1.
- `nfd_dup2 r1=old r2=new` -> 0/-1.
- `nfd_pipe r1=out_fd_ptr` -> writes read fd, write fd; returns 0/-1.
  - Pipes use `nanpipe.nas` (`NPIPE_MAX`).
- `nfd_putc r1=fd r2=char`; `nfd_puts r1=fd r2=word string`.
- `nfd_fd0_line` supplies the current shell line; `cat` with no file reads the
  current line then EOF for phase 1.5 (a blocking tty read is phase 2).

Do not access the fd table directly outside `nixfd.nas`; the shell and stdio
libraries use this ABI.

## Shell syntax (phase 1.5)

- `cmd > FILE`, `cmd >> FILE`, `cmd 2> FILE`, `cmd 2>&1`
- `cmd < FILE`
- `cmd1 | cmd2` — sequential pipe execution first: run left with fd 1
  connected to the pipe, then right with fd 0 connected.  True concurrent
  pipelines need process/thread spawn and are phase 2.
- Redirections restore fd 1/2/0 after the command.
- Builtins and external command functions write through fd 1; diagnostics
  through fd 2.

## Persistence

`nfs_save` writes the NPAF snapshot (header + arena) to ATA LBA 2048.
Boot uses `nfs_load` when a valid snapshot exists, otherwise formats and
seeds `nanfs/`.  `sync` saves explicitly; a host tool can unpack the disk
image back into `nanfs/` for a commit.  Runtime writes remain volatile until
`sync`.

## Ownership

- shell-I/O agent: `src/lib/nixfd.nas`, `src/nix/nixsh.nas`,
  `src/lib/nanpipe.nas`, `tools/nixsh_gate.sh`.
- persistence agent: `src/lib/nfs2.nas`, `src/lib/bare.nas`,
  `src/exhibits/gui_cart.nas` NFS boot block, `tools/rootfs_sync.sh`,
  `tools/nfs_persist_gate.sh`, `nanfs/`.
- stdio agent: `src/lib/stdio.nas`, `src/lib/ncc.nas` output hooks,
  `tools/stdio_gate.sh`; consume `nixfd.nas`, do not edit shell files.
