# NaN-only execution boundary

Status: convergence checkpoint 2026-11-25. `nan-only-suite` is merged into
`nan0s/main`; main is canonical. This document is authoritative for what may
be C and what must be raw NaN16.

## The rule

C is a **guest programming language and build tool**.  A C program is
acceptable only after it has been compiled to a raw NaN16 cartridge.  Normal
operation — boot, kernel, scheduling, processes, VFS, console, device and
service dispatch — must execute NaN16 instructions.  C may not be the
implementation of the running system.

`DONT_USE_NAN16_C.md` records the narrower rule that `nan16.c`/`nan_cli` are
an oracle, not the product.

## Layers

| layer | allowed implementation | current state |
|---|---|---|
| host build tools | C (tcc0, packers, CI scripts) | OK |
| conformance oracle | C (`aarch64/android/core/nan16.c`, `nan_cli`) | OK only when labelled oracle; never acceptance |
| S1 machine model | C is acceptable only as the hardware/ISA emulator (`src/native64/s1_kabi.c`), never as kernel services | currently mixes machine and kernel services |
| NaN kernel/services | raw NaN16 (`.nas`): traps, SVC, scheduler, processes, spawn/wait, sleep, VFS, console, devices | incomplete; C KABI currently supplies process/spawn/sleep/load |
| guest runtime (libc) | C compiled to NaN; service calls must go through the NaN machine interface (`src/lib/bare.nas`) or SVC ABI | file persistence is now proven through NaN services (`cbare_sqlite`, `cbare_fs`); console/time and the Tcl libc VFS are still self-contained C |
| guest applications (Tcl/SQLite/testfixture) | C compiled to NaN | OK |

## Known violations in the current suite path

1. `tools/s1_runner.sh` loads the testfixture **directly at guest word 0** on
   the C S1 KABI.  No NaN kernel boots and no NaN service layer runs.
2. `third_party/nan16-libc/src/libc.c` implements console, file I/O, clock
   and sleep itself; it does not call `src/lib/bare.nas` slots or the SVC
   ABI.  Normal operation is therefore C runtime services.
3. `src/native64/s1_kabi.c` has grown kernel services (process table,
   `spawn`/`wait`, blocking sleep, image loading) in C.  Those belong in the
   NaN kernel, with the C KABI restricted to ISA/trap/port/timer/region
   mechanics.
4. The CI `oracle` mode runs `nan_cli`; it is functional evidence only and
   must never be reported as S1/product acceptance.
5. The suite branch has been integrated into `nan0s/main`; the NaN process
   and thread subsystems now run on the S1 machine model. Remaining work is
   the NaN boot image and the libc/testfixture service boundary.

## Proven NaN service boundaries

The following are raw-NaN gates, not oracle claims:

- `tools/cbare_gate.sh` — a C guest calls NaN console and tick services.
- `tools/cbare_fs_gate.sh` — a C guest creates, writes and reads a file
  through `bare_fs_open/write/read/close`.
- `tools/cbare_sqlite_gate.sh` — SQLite (C compiled by TCC) opens a
  database, inserts, closes, reopens, updates and reopens again.  The only
  persistence boundary is `bare_fs_load/save/remove/size`; the database
  header and rows are verified after each reopen.
- `tools/nfs2_capacity_gate.sh` — NPAF stores 512 files / about 4 MiB and
  verifies the first, middle and last entries.  `NFS_MAX` and `NFS_CAP` are
  compile-time `.equ` values that `tools/nmk.awk` accepts from the
  environment; the arena base is derived from `NFS_BASE + 8 + NFS_MAX*16`.

## Migration checklist

- [x] Merge/rebase the suite tools and Tcl/SQLite port onto current
      `nan0s/main`; do not fork a parallel system lineage.
- [ ] Restrict `src/native64/s1_kabi.c` to the S1 machine model: ISA, trap
      frames, ports, timer, regions.  Move process/spawn/wait/sleep/load
      semantics into NaN.
- [ ] Define the NaN boot image: boot sector → NaN kernel → console/VFS →
      guest loader.
- [ ] Provide `bare.nas` (or SVC) as the only service boundary for the C
      guest runtime; replace the C VFS/console/clock implementations with
      calls through it.
- [ ] Load the official testfixture as a guest image under the NaN kernel;
      the Tcl/SQLite/testfixture code stays C compiled to NaN.
- [ ] Product gate: S1 QEMU/bare metal boots the NaN kernel and runs the
      suite.  `nan_cli` remains an oracle only.
- [ ] Remove every C execution path from normal operation and from the
      product gate; document any temporary hardware-model exception.
