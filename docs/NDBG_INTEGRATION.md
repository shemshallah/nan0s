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
carts load <id> step next finish run regs log hist stack types break watch bpts wpts bp wp goto mem dis screen serial setr setm setw setc undo redo checkpoint restore reset pc quit
> carts
1 Baby
2 PUTC
3 BadOp
4 Call
> load 1
loaded
S=0 PC=2000
> step
S=0 PC=2001
> next
S=0 PC=2002
> finish
S=5 PC=2009
> screen
 NaN/0S  MANCHESTER SMALL-SCALE EXPERIMENTAL MACHINE - THE BABY - 21 JUNE 1948
...
> log
no log
> hist
HIST 0000 0000 0000 0000 0000 0000 2000 2001
> stack
STACK 0: empty
> types
TYPES FC:00 FM:00 FD:00 FS:00
TYPES PC:00 PM:00 PD:00 PS:00
TYPES WC:00 WM:00 WD:00 WS:00
TYPES DC:00 DM:00 DD:00 DS:00
> reset
S=0 PC=2000
> regs
R0=00000000 ...
> break
BP=2000
> step
S=0 PC=2001
> watch
W=2001
> bpts
BP=1:
2000
> wpts
W=1:
2001
> mem
M2001...
> dis
2001 FFF8_01D00001_F8FF MOVI r13,1
...
> setr 1 42
R1=00000042
> setm 3000 1234
M3000=00001234
> setw 3000 5678 9
W3000=00005678/9
> setc 3000 5
C3000=5
> reset
S=0 PC=2000
> step
S=0 PC=2001
> step
S=0 PC=2002
> undo
S=0 PC=2001
> redo
S=0 PC=2002
> redo
NOREDO
> checkpoint
CKPT=1
> step
S=0 PC=0004
> restore
S=0 PC=2002
> load 2
loaded
S=0 PC=2000
> run
S=1 PC=2012
> serial
HELLO
> quit
```

`tools/ndbg_term.sh` gates the path, including the sealed-cart catalog and
`load <id>`. `next` and `finish` use the resident shadow stack: `next` steps over a CALL
and `finish` runs out of the current frame. `log` prints the newest typed
records, `hist` the newest eight PCs, `stack` the shadow frames, and `types`
the live 4x4 type matrix. `bp <hex>`/`wp <hex>` toggle table entries and
print `BP=... +`/`-` or `W=... +`/`-`; `goto <hex>` moves the PC and invalidates
the time-travel rings. The richer 80x25 pane front end remains in
`shemshallah/ndbg`; the terminal monitor now covers its command set.

## Keeping this copy updated from ndbg

From a checkout of `shemshallah/ndbg` next to this repository:

```sh
sh tools/ndbg_sync.sh ../ndbg
```

The script copies the standalone core, monitor, tests, design document, and
standalone gates, refreshes the hooked disassembler, and runs the gates. It
deliberately does **not** copy the legacy `tools/ndbg_gui.sh` gate until the
Silver Slate pane port lands.
