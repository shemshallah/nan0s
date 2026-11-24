# Testing workflow

The full gate battery is for cross-cutting changes and release commits. Day-to-day
work uses the targeted runner: it maps changed files to affected gates, runs
them in parallel, and caches successful results by input family.

## Commands

```sh
# changed files from git (staged, unstaged and untracked)
sh tools/gate_targeted.sh

# explicit files
sh tools/gate_targeted.sh src/lib/ncc.nas src/tests/foo.c

# the NaN-native debug core (typed diagnostic words + step core)
sh tools/ndbg.sh
sh tools/ndbg_diff.sh
sh tools/ndbg_mon.sh
sh tools/ndbg_img.sh   # bare-metal qemu boot of the monitor
sh tools/ndbg_gui.sh   # desktop terminal `debug` -> second CLI

# complete battery
sh tools/gate_targeted.sh --full

# selected aggregate gates (patterns are shell cases)
sh tools/presqlite_gate.sh --only 'qgate64* ncc_abi_sizes'
sh tools/presqlite_gate.sh --list

# bypass/clear the cache
NO_CACHE=1 sh tools/gate_targeted.sh src/lib/ncc.nas
rm -rf .gate-cache
```

`JOBS` controls parallelism (default 4). `TIMEOUT`/`LONG_TIMEOUT` control the
per-gate limits.  `PRESQLITE_TIMEOUT` (default 900 s) and `PRESQLITE_MTIMEOUT`
(default 300 s) bound aggregate gates.  The full aggregate can take many
minutes; it prints `RUN`/`PASS`/`FAIL` with timestamps and a heartbeat, and
appends the same lines to `build/gate-progress.log`, so watch it from another
terminal with `tail -f build/gate-progress.log`.  A single gate that exceeds
its timeout is reported as `FAIL`, not left hanging.

## Gate families

| changed input | gates |
| --- | --- |
| `src/lib/ncc.nas`, preprocessor/ISO libs, `src/tests/ctests`, `src/tests/ncc_*`, nmk tables | all compiler gates: M1-M62, alloc/heap/aligned, headers/ppexpr/torture/donut, macro/include/libm/ISO, ctests, dp4b |
| `aarch64/android/core`, C tests, Makefile | `make test`, compiler smoke, C-reference vector/Q4/bench gates |
| native kernel/gold, boot, `x86/native` | vector/Q4/translator gates, arena/tensor/matmul, `mkall`, `qgate`, `qgate_gui`, `xmemgate` |
| `src/native64`, qgate64 | `mkall`, `qgate64` (long-mode boot + 64-bit COM1 banner) |
| translator sources | `xlate_x86` |
| arena/tensor/matmul libs | `narena`, `narena64`, `nten`, `nmatmul`, `nmat64`, `nmat64x64` |
| vector/Q4/bench sources | `nan_simd`, `nan_vec*`, `nan_q4*`, `nan_bench`, `xlate_x86` |
| `src/dbg/*`, `src/tests/ndbg_*`, `tools/ndbg*`, `src/exhibits/gui_cart.nas`, `src/museum/*` | `ndbg` (typed words, step core), `ndbg_diff` (real cart, guard/watch, native-vs-stepped transcript), `ndbg_mon` (serial monitor session), `ndbg_img` (bare-metal qemu boot), `ndbg_gui` (desktop `debug` -> cart picker -> break/log/mem -> next/finish -> captured `screen`/`serial` -> typed edits, `bp`/`wp` tables, scalar undo with memory restore (`undo [n]`), redo with write replay (`redo [n]`), cart checkpoint/restore, and typed `setw`/`setc` class edits) |
| build tools (`nmk.awk`, `mkimg.awk`, `xgold.sh`, `mkall.sh`) | full battery |
| `spec/`, docs | no gates |
| unknown source path | full battery (safe default) |

## Cache

`.gate-cache/<gate>.sha` stores the content hash of the gate's input family
(compiler family or native/image family). A gate is skipped with `CACHED` only
when the family hash matches. A failed gate deletes its cache entry. `--full`
and `NO_CACHE=1` bypass the cache.

Measured on the compiler family (75 gates):

- cold, parallel: **239 s**
- cached: **9 s**

## When the full battery is mandatory

- ABI changes (pointers, `double`, varargs, struct layout)
- ISA/opcode changes or translator changes
- `nmk.awk`/image/toolchain changes
- before a release or a push that touches multiple subsystems
- whenever a targeted run hits an unmapped file (it escalates automatically)

## Rules

- A gate that hangs must fail within its timeout; never leave an unbounded gate.
- New gates are added to `presqlite_gate.sh` and mapped in `gate_targeted.sh`.
- Targeted mode is an optimization, not a substitute for the full run at
  integration boundaries.
