# NaN-only execution boundary

Status: 2026-11-25, branch `nan-only-suite`.  This document is authoritative
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
`NaN/0S` banner on COM1.  The upgraded machine target is **x86_64 S1**
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
- `tools/nancli64_gate.sh` — a 64-bit text command line (mkdir/write/cat/ls/
  stat/truncate/rm/rmdir/help/exit) compiled to NaN and running on x86_64
  S1; every filesystem operation goes through the NaN POSIX table.

## Remaining integration work

1. Port the frozen KABI machine mechanics (SVC/SVCRET, trap frame, ports,
   regions) from the S6 C model into `kan16.xa`, or run the equivalent NaN
   call table inside the unified guest.
2. Replace libc POSIX calls with the NaN service table; delete each C body as
   it is switched.  The metadata half is done; open/read/write/seek/close is
   done at the FS service level; stat/fstat/opendir/readdir/rename/link/
   symlink/chmod/utime/getcwd/chdir remain to wire.
3. Package the Tcl/SQLite testfixture and the suite tree as a NaN cartridge
   and load it through NaN ATA + nanfs under `build/nan0s.img`.
4. Keep `n16i` as the self-hosted interpreter and differential validator.
5. Close self-replication by regenerating `kboot0.xa`/`kan16.xa` from the
   NaN-written x86 emitter (bootstrap plan R4).

## Migration checklist

- [x] Unified image builds and boots (`tools/mkall.sh`, `tools/qgate.sh`).
- [x] NaN SVC file interface on the bare machine.
- [x] NaN POSIX metadata (mkdir/stat/readdir/rmdir/access/truncate).
- [x] SQLite persistence through NaN services.
- [x] n16i executes on the bare machine.
- [ ] KABI machine mechanics in the nan0s core.
- [ ] libc POSIX switched to NaN; C bodies deleted.
- [ ] Suite as a NaN cartridge under `build/nan0s.img`.
- [ ] C removed from normal operation; `s1_kabi.c`/`nan_cli` remain test only.
