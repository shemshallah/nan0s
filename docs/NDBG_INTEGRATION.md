# NANDBG in NaN/0S

NANDBG is both a standalone debugger and a component of this repository.

## What ships here

- `src/dbg/core.nas` - the resident NaN16 step core, typed records, watchpoints,
  history, breakpoint/watchpoint tables, scalar undo/redo.
- `src/dbg/n16dbg.nas` - standalone serial/bare-metal monitor.
- `src/dbg/ndbg.nas` - the first typed-record proof.
- `src/tests/ndbg_*` - core, differential, guard/watch, cart, and PUTC tests.
- `tools/ndbg.sh`, `ndbg_diff.sh`, `ndbg_mon.sh`, `ndbg_img.sh`, `ndbg_term.sh` - exact gates.
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

The Silver Slate terminal now has a wired `debug` monitor:

```text
> debug
NANDBG TERMINAL MONITOR
carts load <id> step run regs break watch bpts wpts mem dis screen serial undo redo checkpoint restore reset pc quit
> carts
1 Baby
> load 1
loaded
S=0 PC=2000
> step
S=0 PC=1FA5
> regs
R0=00000000 ...
> break
BP=1FA5
> watch
W=1FA5
> bpts
BP=1:
2001
> wpts
W=1:
2001
> mem
M2000...
> dis
2001 FFF8_01D00001_F8FF MOVI r13,1
...
> screen
 NaN/0S  MANCHESTER SMALL-SCALE EXPERIMENTAL MACHINE - THE BABY - 21 JUNE 1948
...
> undo
S=0 PC=2001
> redo
S=0 PC=2002
> redo
S=0 PC=0004
> redo
NOREDO
> checkpoint
CKPT=1
> restore
S=0 PC=2001
> serial
HELLO
> run
!DIC@02001FA5 ...
S=2 PC=1FA5
> quit
```

`tools/ndbg_term.sh` gates the path, including the sealed-cart catalog and
`load <id>`. The richer pane CLI (memory, captured screen/serial, undo/redo,
checkpoints) remains in `shemshallah/ndbg`; the resident ABI and core are
already shipped here so those commands can be attached without changing the
debugger.

## Keeping this copy updated from ndbg

From a checkout of `shemshallah/ndbg` next to this repository:

```sh
sh tools/ndbg_sync.sh ../ndbg
```

The script copies the standalone core, monitor, tests, design document, and
standalone gates, refreshes the hooked disassembler, and runs the gates. It
deliberately does **not** copy the legacy `tools/ndbg_gui.sh` gate until the
Silver Slate pane port lands.
