# NANDBG in NaN/0S

NANDBG is both a standalone debugger and a component of this repository.

## What ships here

- `src/dbg/core.nas` - the resident NaN16 step core, typed records, watchpoints,
  history, breakpoint/watchpoint tables, scalar undo/redo.
- `src/dbg/n16dbg.nas` - standalone serial/bare-metal monitor.
- `src/dbg/ndbg.nas` - the first typed-record proof.
- `src/tests/ndbg_*` - core, differential, guard/watch, cart, and PUTC tests.
- `tools/ndbg.sh`, `ndbg_diff.sh`, `ndbg_mon.sh`, `ndbg_img.sh` - exact gates.
- `spec/NANDBG.md` - design and rationale.
- `src/museum/shell.nas` - resident ABI1 (5800..5813), ABI2 (5950..5972),
  debug core, demo target, and TOC/title snapshot at 0x70000/0x72000.

The standalone monitor builds and boots as its own image:

```sh
sh tools/ndbg.sh
sh tools/ndbg_diff.sh
sh tools/ndbg_mon.sh
sh tools/ndbg_img.sh
```

## Desktop pane status

The full desktop pane CLI is maintained in the `shemshallah/ndbg` repository.
Its legacy GUI hook targets the pre-Silver-Slate window manager and is not
registered as a gate here yet. The Silver Slate port is pending; the resident
ABI and core are already shipped in this tree so the pane can be attached
without changing the debugger.

## Keeping this copy updated from ndbg

From a checkout of `shemshallah/ndbg` next to this repository:

```sh
sh tools/ndbg_sync.sh ../ndbg
```

The script copies the standalone core, monitor, tests, design document, and
standalone gates, refreshes the hooked disassembler, and runs the gates. It
deliberately does **not** copy the legacy `tools/ndbg_gui.sh` gate until the
Silver Slate pane port lands.
