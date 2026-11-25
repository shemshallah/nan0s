# src/dbg — NANDBG

The NaN-native debug system. Design and rationale: `spec/NANDBG.md`.

## What is here

| file | role |
|---|---|
| `ndbg.nas` | first proof: 16 diagnostic types, records, subset step core, breakpoint, gate/bad-op records |
| `core.nas` | reusable full `0x00–0x5F` step core: typed traps, shadow call stack, non-blocking KEY, DP4B, vectors, scalar undo hooks |
| `n16dbg.nas` | serial monitor: step, run, breakpoint, goto, watch, history, stack, types, registers, disassembly, dump, NDR, mirror verify |
| `undo_stub.nas` | no-op recording hooks for standalone core builds |
| `ndr.nas` | included by `core.nas`: NDR w4-w6 operands and FNV-1a/32 seal in w7 |
| `../tests/ndbg_core_test.nas` | reset/run/step on a small target |
| `../tests/ndbg_diff_body.nas` | deterministic target: integer, float, memory, calls, DP4B, vectors |
| `../tests/ndbg_diff_native.nas` / `ndbg_diff_debug.nas` | the same target natively and through `core.nas` |
| `../tests/ndbg_cart_test.nas` | a real museum cartridge (Baby) run under the core to `KEY` |
| `../museum/shell.nas` | resident ABI1 5800, ABI2 5950, core 6200, demo target 8100, undo ring 0x30000 |
| `../exhibits/gui_cart.nas` | terminal `debug` command + kind-8 second CLI + `carts`/`load` + `next`/`finish` + `mem [addr]`/`dis [addr]`/`log`/`ndr`/`hist`/`stack`/`types`/`bpts`/`wpts`/`bp`/`wp`/`goto` + `screen`/`serial` + `undo [n]`/`redo [n]`/`checkpoint`/`restore` + `setw`/`setc` + `dis` |
| `../tests/ndbg_guard_test.nas` | write-window fault and before-write watchpoint |
| `../tests/ndbg_putc_cart.nas` | tiny PUTC cartridge for the serial-capture gate |
| `../tests/ndbg_ndr_test.nas` | NDR operands and seal over a deliberately bad word |

## Run

```sh
T=${TMPDIR:-/tmp}
awk -f tools/nmk.awk -v CMD=emit src/dbg/ndbg.nas > "$T/ndbg.nan"
aarch64/android/nan_cli --img "$T/ndbg.nan" --steps 2000000 --serial
```

Gates:

```sh
sh tools/ndbg.sh
# ndbg: PASS (types, mirror, quiet, step, breakpoint, gate record, bad-op record, exact)
# ndbg: NEGATIVE PASS (mutated transcript rejected)

sh tools/ndbg_diff.sh
# ndbg_diff: PASS (core reset/run, real cart to KEY, native == stepped, golden transcript, vectors)
# ndbg_diff: NEGATIVE PASS (mutated transcript rejected)

sh tools/ndbg_mon.sh
# ndbg_mon: PASS (step, disasm, regs, hist, stack, types, goto, breakpoint, watch, run, quit, exact)
# ndbg_mon: NEGATIVE PASS (mutated transcript rejected)

sh tools/ndbg_img.sh
# ndbg_img: PASS (bare-metal boot, monitor banner + prompt, ... bytes COM1)

sh tools/ndbg_gui.sh
# ndbg_gui: PASS (carts/load, break/log/mem, next/finish; setr/setm/goto;
#             bp/wp tables; undo [n]/redo [n]; checkpoint/restore)
# ndbg_gui: NEGATIVE PASS (mutated transcript rejected)
```

The proof embeds a target at word 8192 and two deliberately illegal words at
9000. `tools/mkimg.awk` refuses illegal heads, so a production floppy image
cannot contain those words; they are test injections, not image data. A gate
trap in the field is a corruption signal.

The cart test puts the core at word 40000, the cart at 8192, and harmless
`JMP -> RET` vectors at words 1..31. It validates running a real cartridge
without loading it into the debugger's own address range.

In the desktop terminal, type `debug` to open the second CLI; the system
utilities window's `[3] DEBUG` entry opens the same CLI. `carts` lists the
catalog; `load <id>` copies a sealed cart into the debug arena at `0x80000` and
maps guest 8192 onto it. `reset` returns to the built-in demo target at 8100. `next` steps over a call;
`finish` runs until the current shadow frame returns. `break`, `bpts`, `watch`,
`wpts`, `log`, `ndr`, `hist`, `stack`, `types`, `mem [addr]`, `dis [addr]`, `screen`
and `serial` cover breakpoints, watchpoints, the last four typed records, the
newest eight PCs, the shadow frames, the live 4x4 type matrix, eight words at
PC or a chosen address, the captured 80x25 cart text buffer, and the captured
`PUTC` stream. `bp <hex>` and `wp <hex>` toggle table entries.
`setr <n> <hex>`, `setm <addr> <hex>` and `goto <hex>` write a register, a
memory word, and the PC; `setw` and `setc` write a word and/or class nibble.
`undo [n]` rewinds one or `n` recorded scalar steps,
including the guest words they wrote. `redo [n]` restores the saved post-step
states and write values; new steps and edits clear the redo ring. The serial
monitor's `n` command prints the eight-word NDR (header, site, payload, class,
a/b/d, FNV seal). `checkpoint`
saves registers, PC, condition, call depth, the 64K cart arena, and the captured
screen/serial window; `restore` reloads them and clears the time-travel
history.

The undo ring is 32 records at host word 0x30000, enabled by `dbg_begin` and
`dbg_cart`; standalone core builds link `src/dbg/undo_stub.nas` instead. The
same debug starts set `nd_iocap=1`, so cart `VPOKE`/display ops write to the
private text buffer at 0x60000 and target `PUTC` at 0x61000 instead of the
desktop/COM1. The undo/redo rings live at 0x30000/0x62000 and the sixteen
eight-word NDRs live at 0x31000, with BSWAPM twins at 0x31100; checkpoints use a header at 0x90000, an arena
copy at 0x91000, and a capture copy at 0xA1000. Next stages (80x25 pane
UI, NDR log/checkpoints, NDP) are in `spec/NANDBG.md`.

Screenshot of the desktop terminal with `debug` open and `screen` showing the
captured Baby text buffer: `screencaps/ndbg_gui.png`.

## NaN/0S vendoring

This suite is shipped as a component of `shemshallah/nan0s`. Refresh that
checkout with `sh tools/ndbg_sync.sh /path/to/ndbg` from the nan0s tree. The
standalone gates (`ndbg`, `ndbg_diff`, `ndbg_mon`, `ndbg_img`) are integrated
there together with the Silver Slate terminal monitor: sealed-cart
`carts`/`load`, `mem [addr]`, `dis [addr]`, captured `screen`/`serial`, typed
setters, multi-level `undo [n]`/`redo [n]`, and checkpoint/restore. The richer pane remains in this
repository.

> **NaN/0S integration:** this directory ships with NaN/0S. `tools/ndbg.sh`,
> `ndbg_diff.sh`, `ndbg_mon.sh`, and `ndbg_img.sh` are the integrated gates.
> The desktop pane front end lives in `shemshallah/ndbg`; the Silver Slate port
> is pending.
