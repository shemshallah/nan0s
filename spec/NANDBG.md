> **Shipping note:** this copy is vendored into NaN/0S. The standalone core,
> monitor, tests, and gates are integrated. The Silver Slate terminal now wires
> a basic `debug` monitor (`carts`, `load <id>`, `step`, `run`, `regs`, `break`,
> `watch`, `bpts`, `wpts`, `mem`, `dis`, `screen`, `serial`, `reset`, `pc`,
> `quit`); the
> richer pane front end remains in `shemshallah/ndbg`.

# NANDBG — a NaN-native bare-metal debug system

**The Quiet Room.**  
Status: design + working proof + full step core. `src/dbg/ndbg.nas` proves the
typed diagnostic word; `src/dbg/core.nas` is the reusable full engine;
`src/tests/ndbg_diff_debug.nas` runs the same target natively and stepped and
must produce a byte-identical transcript; a real museum cartridge (Baby) runs
to `KEY` under it. `src/dbg/n16dbg.nas` is the first serial monitor: step, run, breakpoint,
goto, watchpoint, registers, disassembly and memory dump. In the desktop, typing `debug` opens a second terminal-shaped CLI backed by the
resident core (`gui_cart.nas` kind 8 + the ABI in `shell.nas`). It can list the
catalog (`carts`), load a sealed cartridge into the debug arena (`load <id>`),
and step/run it without touching the store. Gates: `tools/ndbg.sh`,
`tools/ndbg_diff.sh`, `tools/ndbg_mon.sh`, `tools/ndbg_img.sh`, `tools/ndbg_gui.sh`. The image tool builds a
standalone floppy with the monitor as the guest and boots it on qemu with no
host OS.

> A fault on this machine is not a string. It is a word.
> Its two heads are its type. The machine can read it, store it, seal it,
> mirror it, sort it, and decide what to do with it — without a host,
> without an OS, and without leaving NaN.

---

## 0. Executive summary

NANDBG is a debug system whose logic, data structures, protocol and output are
NaN16 words. It depends on exactly one thing from the substrate: the ability to
execute the program that contains it. It does not use a host debugger, C,
Python, gdb, ptrace, a native trap handler, or a serial console parser.

The system is built on three observations about this machine:

1. **The trap path is already typed.** Every word has two legal NaN heads, and
   their four bits are a class nibble. NANDBG assigns those sixteen classes to
   a 4×4 diagnostic matrix: four severities × four domains. A fault becomes a
   *casualty word* whose near head says how bad it is and whose far head says
   where it came from. `LDN` reads the type, `STW` writes it, `BSWAPM` mirrors
   it by `rot2(n)`, and `FCMP` can detect a NaN payload as unordered.
2. **The machine can interpret itself.** `n16i` already runs NaN16 inside
   NaN16. A debugger built on a step core can observe every fetch, predicate,
   register write and memory access, catch the gate and bad-op traps *before*
   the native core halts, and keep the target image untouched and sealed.
3. **A fault is data, not a dead end.** The native kernel prints `!G`/`!O` and
   halts. That is correct for production and is left exactly as it is. In debug
   mode the step core classifies the trap, emits a typed record, and remains
   alive. The user can inspect the machine, step backward, repair memory, and
   resume.

The first proof, `src/dbg/ndbg.nas`, demonstrates all three:

```
NDBG: NAN16 NATIVE DEBUG CORE
TYPES PASS
TYPES FC FM FD FS
TYPES PC PM PD PS
TYPES WC WM WD WS
TYPES IC IM ID IS
BREAK PASS
PC=2007 K=2 R0=00000000 R1=00000005 R2=0000000F R3=00000005 ...
STEP PASS
ARUN PASS
!DFC@10002329 W=FFFFFFFFDEADBEEF
GATE RECORD PASS
!DFC@2000232A W=0000000F7F000000
BADOP RECORD PASS
QUIET PASS
NDBG PASS
```

The four `TYPES` lines are the 4×4 diagnostic matrix, printed by the proof:
row 1 is `FAULT` over `CORE/MEMORY/DEVICE/PROGRAM`, then `PANIC`, `WARN`,
`INFO`. Every cell is a real NaN word whose heads spell that pair.

The gate record is the important line. It says:

- `!D` — a NANDBG record, not a native trap (native `!G`/`!O` are unchanged).
- `FC` — severity `FAULT`, domain `CORE`; the type nibble is `0`.
- `10` — code `GATE`.
- `002329` — site `0x2329` (word 9001, the native convention `pc+1`).
- `FFFFFFFF` — the class read from the illegal word (`LDN` returns `FFFFFFFF`
  when the gate fails); the NaN type of the bad word is in the record.
- `DEADBEEF` — the word's payload.

The second line is a bad op with legal heads: type `FC`, code `20`, site
`0x232A`, class `F` (the word's valid ALWAYS class), payload `7F000000`.

The prototype implements the control core (MOVI/MOVHI/ADD/SUB/CMP/JMP/CALL/
RET/JMPR/LD/ST/STW/LDN/PUTC/NOP/HALT, all 16 BOOL functions, predication and
flags), the typed record path, watchpoints, history, breakpoint/watchpoint
tables, typed edits, and bounded scalar undo. The UI, multiplexed I/O and
self-hosting are the next stages in §13.

---

## 1. What “written entirely in raw NaN” means

### 1.1 The rule

Every decision in NANDBG is made by NaN16 instructions. The debugger is a
guest, assembled by `tools/nmk.awk` (host dev loop) or by `nasm0` (in-guest),
running on the same `kan16`/portable core as any exhibit. Its files end in
`.nas` or `.nan`. There is no host-side debugger, no C shim, no Python, no
gdb stub.

The substrate keeps its existing jobs: boot, memory, port I/O, display, timer,
keyboard, storage. It does not know what a breakpoint is.

### 1.2 The honest boundary

There are two ways a fault can happen, and the design states both:

| tier | who executes | what can NANDBG see? | purity |
|---|---|---|---|
| **interpreted** | NANDBG step core | every fetch, every register, every write, every trap | pure NaN |
| **native** | `kan16` / C core | only what happened before the halt, if the program wrote it | substrate |
| **instrumented** | native, with `nd_emit` calls | explicit expects/asserts/domain events | pure NaN in the guest |

A native gate/bad-op trap still prints `!G<pc>` / `!O<pc>` and halts; that text
is frozen by `tools/ngate_n16i.sh`, and this design does not change it. A pure
NaN debugger cannot catch a trap that the native core takes *outside* the
debugger's own interpreter. Therefore:

- **Debug mode runs the target under the step core.** This is the only way to
  make every trap recoverable while staying pure NaN.
- **Production mode keeps the native traps.** The native text is the last
  resort, not the debugger.
- **A future native tier** may add a trap trampoline (save the register file,
  jump into a resident NaN monitor). That is explicitly out of scope for the
  pure-NaN proof and is described as an optional accelerator in §12.

This is not a weakness hidden in a footnote. It is the reason the step core is
the centre of the design.

### 1.3 What the substrate already gives us

The portable C core exposes trace and debug accessors
(`nan_set_trace`, `nan_reg`, `nan_pc`, `nan_word`, state save/restore). A host
tool could use them, but NANDBG does not. They are useful for testing the
debugger, not for being the debugger.

---

## 2. The repo as it stands

This section records what the design has to live with. Line numbers refer to
the tree at the time of writing.

### 2.1 The word and the gate

From `spec/NAN16_SPEC.md`:

- 8 bytes: far head (big-endian, bytes 0–1), 32-bit payload (little-endian,
  bytes 2–5), near head (little-endian, bytes 6–7).
- legal heads: `7FF1` (+s), `FFF1` (−s), `7FF8` (+q), `FFF8` (−q).
- class `c = 2Q + S`; nibble `n = (c_near << 2) | c_far`.
- both heads must be legal or the fetch traps.
- `n` is the BOOL truth table and every other op's predicate.

The kernel's fetch is `x86/native/kan16.xa:97–122`. The gate and bad-op branches
are at lines 97–106; the trap printer is at 1355–1375. The portable core has
the same behaviour in `aarch64/android/core/nan16.c:203–209, 264–269, 295, 444`.

This is the single most important constraint: **the native trap is a halt, not
an exception with a resumable frame.** The debugger cannot “catch” it after the
fact without native help.

There is a second, subtler consequence: `tools/mkimg.awk` refuses a `.nan` line
whose heads are not one of the four legal values. A sealed production image
therefore **cannot contain a gate-failing word**. A gate trap in the field is
evidence of corruption (RAM, disk, or a native injection), not a malformed
cartridge. That is exactly why the typed record keeps the class read from the
word: `FFFFFFFF` says “the word's type is invalid” and is itself the integrity
signal.

### 2.2 The existing debug-adjacent assets

| asset | what it already does | what is missing for NANDBG |
|---|---|---|
| `src/tools/n16i.nas` | NaN16 interpreting NaN16, 527 words; all 16 classes, flags, memory, traps `!G`/`!O` | runs to HALT/trap; no single step, no budget, no breakpoint, no watchpoint, no typed record, op limit `0x48`, I/O passes through, `TICK` is `steps/1000` |
| `src/tools/disasm.nas` | 641-word NaN16 disassembler; address, both faces, mnemonic, predicate, operands | no symbol/line map, no UI, no live PC |
| `src/lib/nan16dump.nas` | one-word inspector: address, predicate, op/d/a/imm, payload, type | one word at a time, no history |
| `src/lib/n16de.nas` | pair-voting qNaN carrier: tag, byte-swapped twin, resync/delim | data transport, not fault records |
| `src/lib/libvec.nas:136–220` | seal v2: dual-face FNV A/B plus class channel; checks the mirror law | per-cartridge seal, not a debug log |
| `src/museum/shell.nas` | TOC loader, seal verifier, cart slot 8192, `CALL 8192`, V_* table, curator console | read-only console; no step/break/regs; no fault capture |
| `aarch64/android/tools/nan_cli.c` | headless run, serial, keys, peek, state, disk | host harness, not guest debug |
| `AArch64 core API` | trace callback, register/PC/word access, snapshots | host API, not a NaN-native monitor |

### 2.3 The loader and the museum map

- Cart slot: word `8192`; shell copies the cart there and `CALL 8192`.
- Catalog: word `22000`, 16-word entries; titles at `23600`; store at `25000`.
- Service record: word `4816` (slot-less; loaded like a cart and called at
  8192).
- Jump vectors: words 1–31 (`V_PUTS`, `V_HEX`, `V_DEC`, `V_CLS`, `V_KEY`, ...).
- System menu: `S` from the shell; currently `[1] SETTINGS`, `[2] NANNET`.
- The shell's own code and strings end around word 5700; space before 8192 is
  small. TOC/titles/store occupy 22000–~30000.
- `tools/mkimg.awk` enforces a guest image up to 4,000,000 words but the floppy
  truncates at 1,474,560 bytes; a debug region at word 40000 costs 320 KB of
  guest words and still fits the floppy with the kernel, TOC and carts.

### 2.4 ABI and conventions that matter

- `r0 = 0`, `r13 = 1` are required by cart code.
- `r14` is a software stack pointer by convention, not hardware; `r15` is the
  link. There is no enforced frame pointer and no call-frame layout. Carts save
  `r15` in private cells instead of on a stack.
- `LD d,a,imm` returns the **32-bit payload**, not the whole word. `LDN`
  returns the class nibble or `FFFFFFFF`. `STW d,a,b` writes a legal word with
  class `r[b] & 15`. `ST` writes class 10 (+q/+q). `BSWAPM` reverses the eight
  bytes and rotates the nibble by two.
- The word address is masked by the VM; there is no fault on an out-of-range
  word, it wraps. A debugger that wants to detect bad pointers must check them
  itself before the access.
- The first prototype bug was exactly this: treating `LD` as a raw 64-bit read.
  `NANDBG.md` records it so the next implementer does not repeat it.
- The native core's op table ends at `0x61` on x86 but the portable C core
  traps above `0x5F`; `0x60 CODELEN` / `0x61 EXECN` are an x86 translator shim,
  not portable ops. The debug core must classify them as host extensions or
  unimplemented, not pretend they are universal.
- `n16i` passes I/O through. A debugger cannot: a target `KEY` would block the
  monitor, a `DISPSET` would erase the UI, and `ST` could overwrite the
  monitor. I/O mediation is mandatory (§8).

### 2.5 Gaps in one table

| gap | consequence | NANDBG answer |
|---|---|---|
| no single-step | cannot inspect between instructions | step core |
| no breakpoints | cannot stop at a site | PC table check before fetch |
| no watchpoints | cannot see who wrote a value | write interception in the core |
| no shadow stack | cannot backtrace without a frame convention | CALL/CALLR/RET shadow stack |
| no budget in `n16i` | a target can hang | per-run step budget |
| traps halt | no postmortem, no resume | typed fault record + resume |
| I/O is direct | target can block or corrupt the monitor | policy/mediator |
| no memory map | target can write anywhere | region table + read-only image |
| op limit `0x48` | vector/modern carts are not debugged | full `0x00–0x5F` port |
| `TICK` is fake in `n16i` | timing bugs are invisible | explicit time policy |
| no symbols | only hex addresses | optional compact symbol blob |
| curator is read-only | cannot repair memory | guarded write commands |

---

## 3. The NaN diagnostic algebra

This is the heart of the design and the part that makes it native rather than
a conventional debugger wearing a NaN costume.

### 3.1 The two axes

Each head is 2 bits: `Q` (quiet) and `S` (sign). Assign:

- **near head = severity** (what happened)
- **far head = domain** (where it happened)

| class | head | severity | meaning |
|:-:|:-:|---|---|
| 0 | `7FF1` | `FAULT` | live, recoverable, unhandled |
| 1 | `FFF1` | `PANIC` | live, terminal |
| 2 | `7FF8` | `WARN` | quiet, noteworthy, contained |
| 3 | `FFF8` | `INFO` | quiet, trace |

| class | head | domain | covers |
|:-:|:-:|---|---|
| 0 | `7FF1` | `CORE` | gate, bad op, predicate, step, call depth |
| 1 | `FFF1` | `MEMORY` | load/store, stack, heap, region, poison |
| 2 | `7FF8` | `DEVICE` | display, keyboard, serial, disk, ports |
| 3 | `FFF8` | `PROGRAM` | loader, seal, compiler, debugger itself |

`n = (severity << 2) | domain` gives all sixteen. The matrix:

```
                 core   memory  device  program
   fault   +s     FC      FM      FD      FS
   panic   -s     PC      PM      PD      PS
   warn    +q     WC      WM      WD      WS
   info    -q     IC      IM      ID      IS
```

The mapping is not decorative. IEEE already says a signaling NaN is a value
that will raise when used and a quiet NaN is one that propagates without
raising; NANDBG uses exactly that distinction for **live vs latched**. The sign
bit separates benign from severe. The two faces separate event from origin.

### 3.2 Operations on types

All of these are one or two NaN16 instructions:

| operation | formula | instruction |
|---|---|---|
| read type | `n = LDN word` | `LDN` |
| write type | `STW payload, addr, n` | `STW` |
| quiet | `n \| 0b1010` (set Q on both faces) | `BOOL.14` |
| raise | `n & 0b0101` (clear Q on both faces) | `BOOL.8` |
| mirror | `rot2(n) = ((n&3)<<2) \| (n>>2)` | `BSWAPM` + `LDN` |
| is live? | bit 3 or bit 1 clear | mask |
| severity | `n >> 2` | `SHR` |
| domain | `n & 3` | `BOOL.8` |

The **mirror law** gives a free second reading: byte-swapping a fault word
swaps event and origin. A `FAULT/CORE` read backwards is `CORE/FAULT` — the
core is now the observed thing and the fault is the observer. That is a useful
question to ask of a crash: *who was watching?* The four diagonal types
(`FC`, `PM`, `WD`, `IS`) are neutral: they read the same backwards. They are
the four errors that are their own origin.

The design uses this in the verifier and in the display: every record can be
shown both ways, and a record that does not obey the mirror law is itself a
fault (`MIRROR_LAW`, `0x61`).

### 3.3 Payload: the instruction-shaped detail

The 32-bit payload echoes the instruction payload layout:

```
31..24  code        8-bit diagnostic code (family high nibble, detail low)
23..0   site        24-bit word address, source offset, or site token
```

For the common fast path this fits in one word. The code families are in §5.3.

For richer records the payload is expanded into the 8-word NDR (§4). For
values that need to survive FP arithmetic, an optional convention stores the
detail as an IEEE signaling-NaN payload (`0x7F800001..0x7FBFFFFF` or quiet
`0x7FC00000..0x7FFFFFFF`). Then `FCMP x,x` is unordered exactly when the value
is a diagnostic NaN, and the FP unit propagates it according to the rules
already frozen in `aarch64/android/core/OPS.md`. This is the **poison** idea in
§11.4, not a requirement for v1.

### 3.4 Why use the type nibble as the predicate too

The same four bits that name the error are also the machine's predicate. This
is not a coincidence to be avoided; it can be exploited:

- `BOOL.n` evaluates all 32 lanes with the diagnostic truth table.
- An error bus can be a 32-bit lane mask, one bit per class; `BOOL` computes
  “which of these routes are enabled” in one instruction.
- A handler table can be indexed by `LDN` directly: 16 entries, 16 behaviours.
- A log can be sorted or filtered by comparing the class as an integer without
  parsing text.
- A record with class `0` (`NEVER`) is a safe padding word: if the PC ever
  falls into it, every non-BOOL op is predicated off, so it skips. A `0` word
  is the natural “void” in the log. A record with class `15` (`ALWAYS`) is the
  opposite: it will execute if reached, so it is never used for padding.

The design keeps those two conventions: **type 0 is the safe void**, **type 15
is never a pad**.

---

## 4. The casualty word and the record

### 4.1 Casualty word (CW) — one word, fast path

```
+---------------------------------------------------------------+
| far head  |             payload              |   near head    |
|  domain   | code:8 | site:24                  |   severity     |
+---------------------------------------------------------------+
            b0 b1    b2 b3 b4 b5                b6 b7
```

Emit with one `STW`. Read with `LDN` + `LD`. Render in ~20 bytes of serial:

```
!DFC10002329          type FC, code 10, site 002329
```

The CW is the minimum error output. It needs no stack, no heap, no formatter,
and no record buffer. Any guest can produce one at a fault site. It is also the
unit of the log ring.

A record is **data**, not code. The log lives in a region the mediator marks
non-executable, so a wild PC cannot fetch a record. That region is the real
protection; the type-0 “safe void” convention is only the second line of
defence if a record ever does reach the fetch path.

### 4.2 NaN Diagnostic Record (NDR) — eight words, rich path

```
w0  HEADER   type          payload: code:8 | seq:24 (low bits may be flags)
w1  SITE     type          payload: site:24 | space:8
w2  WLO      10 (+q/+q)    payload: faulting word's 32-bit payload
w3  WHI      10 (+q/+q)    payload: its class nibble, or FFFFFFFF if gate
w4  A        10            r[a] / effective address
w5  B        10            r[b] / value
w6  D        10            r[d] / result / extra
w7  SEAL     10            FNV1a32 over w0..w6, or the mirrored twin
```

`space` distinguishes code, data, stack, register file, source, device.
`seq` makes gaps visible. The low bits of the sequence field may carry the
`quieted` bit and a trace bit; the flag channels are already in the type and
in the register words.

The proof implements w0–w3; that is enough to show the type and the exact
faulting word. The final record adds the register operands and the seal.

### 4.3 The mirror pair

For persistence on uncertain storage, each record is stored twice:

```
record[i]     = w
record[i + 1] = BSWAPM(w)
```

Verification is one `BSWAPM` and a compare; the class of the twin is `rot2(n)`.
A single-byte corruption of either copy fails the pair. This is the same
principle as `src/lib/n16de.nas`, and the same as the cartridge seal: the
second face is an independent channel. A log that cannot detect its own
corruption is not a log.

### 4.4 Wire format

The native trap grammar is frozen:

```
!G<pc>      gate trap
!O<pc>      bad op
```

NANDBG adds a separate prefix and never reuses those two:

```
!D<sev><dom><code:02X>@<site:06X> W=<hi:08X><lo:08X>\n
!D<sev><dom><code:02X>@<site:06X> A=<a:08X> B=<b:08X> D=<d:08X>\n
```

`<sev><dom>` is the two-letter tag from §3.1. The line is line-oriented so a
human, `sh`, `awk` or another NaN machine can parse it. A raw mode sends the
eight bytes of the word unchanged for exact transport; the text mode is the
default because it survives terminals, logs and diffs.

A parser must treat `!D` as “debug record”, not as a trap. Existing gates that
look for `!G`/`!O` are unaffected.

---

## 5. Error codes and policy

### 5.1 Record status

```
0  OK
1  HALT
2  BREAK
3  FAULT      (a record was emitted)
4  BUDGET
5  WAIT_KEY   (host may block; monitor controls input)
6  WAIT_TICK  (timing policy)
```

### 5.2 Reason codes in the CW/NDR

| code | name | meaning |
|:-:|---|---|
| `00` | HALT | the target executed `HALT` |
| `01` | BUDGET | step budget exhausted |
| `02` | BREAK | breakpoint hit before fetch |
| `03` | WATCH | watchpoint hit |
| `10` | GATE_NEAR | near head illegal |
| `11` | GATE_FAR | far head illegal |
| `12` | GATE_BOTH | both illegal |
| `13` | GATE_DATA | a verifier met an illegal word (not executed) |
| `20` | BADOP | opcode above the machine's maximum |
| `21` | UNIMPLEMENTED | legal opcode not implemented by this core |
| `22` | HOST_EXT | `CODELEN`/`EXECN` or another host-only op |
| `30` | DIV0 | integer divide by zero (k=3) |
| `31` | FP_UNORDERED | `FCMP` unordered / NaN operand |
| `32` | FP_INVALID | sqrt<0, inf−inf, 0×inf, ... |
| `40` | MEM_RANGE | access outside a granted region |
| `41` | STACK | shadow SP outside its region |
| `42` | CALL_DEPTH | shadow call stack overflow |
| `50` | IO_DENIED | target tried a denied device |
| `51` | IO_TIMEOUT | device did not answer |
| `60` | SEAL | cartridge seal mismatch |
| `61` | MIRROR | mirror law broken |
| `62` | TOC | catalog entry invalid |
| `70` | POISON_READ | uninitialized/poison value read |
| `71` | POISON_WRITE | write to a poisoned region |
| `7F` | INTERNAL | debugger invariant broken |

The high nibble is the family; the low nibble is detail. New codes append, the
existing numbers never move.

### 5.3 Default type policy

| event | type | n |
|---|---|---:|
| gate/bad op/host ext | `FAULT/CORE` | 0 |
| budget, break, halt | `INFO/CORE` | 12 |
| memory range, stack, call depth | `FAULT/MEMORY` | 1 |
| watchpoint | `INFO/MEMORY` | 13 |
| device denied/fault | `FAULT/DEVICE` | 2 |
| seal/loader/compiler | `PANIC/PROGRAM` | 7 |
| debugger invariant | `PANIC/PROGRAM` | 7 |
| trace | `INFO/PROGRAM` | 15 |

A caller may override the type; the default is a table lookup, not an `if`
ladder.

---

## 6. Architecture

```
                     ┌──────────────────────────────────────┐
                     │  UI / command console (80×25)         │
                     │  panes: source/disasm, regs, stack,  │
                     │  log, type matrix, help              │
                     └───────────────┬──────────────────────┘
                                     │ CALL / mailbox
                     ┌───────────────▼──────────────────────┐
                     │  CONTROL                             │
                     │  run / step / next / until / finish  │
                     │  breakpoint table, watchpoint table  │
                     │  shadow stack, history, undo         │
                     └───────────────┬──────────────────────┘
                                     │
                     ┌───────────────▼──────────────────────┐
                     │  MEDIATOR                            │
                     │  region map · I/O policy · traps     │
                     └───────────────┬──────────────────────┘
                                     │
                     ┌───────────────▼──────────────────────┐
                     │  STEP CORE (all 0x00–0x5F)           │
                     │  fetch · gate · predicate · decode   │
                     │  execute · flags · shadow effects    │
                     └───────────────┬──────────────────────┘
                                     │
                     ┌───────────────▼──────────────────────┐
                     │  TARGET (words, never modified)      │
                     └──────────────────────────────────────┘

     sidecars:  NDR writer · CW ring · flight recorder · seal verifier ·
                disassembler · symbol table · NDP transport
```

### 6.1 Components and proposed files

| file | role | state |
|---|---|---|
| `src/dbg/ndbg.nas` | proof: types, CW/NDR, step core subset, tests | working |
| `src/dbg/core.nas` | reusable full step core `0x00–0x5F`, status, shadow stack, vector delegation, write guard and watchpoint | working, differential-gated |
| `src/dbg/n16dbg.nas` | serial monitor: step, run, breakpoint, goto, watch, history, stack, types, regs, disasm, dump | working, gated |
| `src/dbg/ctrl.nas` | break/watch/run/step/backtrace/undo | next |
| `src/dbg/mediator.nas` | region map, I/O policy, vector services | next |
| `src/dbg/ui.nas` | 80×25 console, panes, keys | next |
| `src/dbg/ndp.nas` | NaN Debug Protocol frames | later |
| `src/dbg/sym.nas` | optional symbol/line lookup | later |
| `src/museum/shell.nas` | resident ABI at 5800 + core at 5900 + demo target 7600 | working, gated by `ndbg_gui` |
| `src/exhibits/gui_cart.nas` | terminal `debug` command and kind-8 second CLI | working, gated |
| `src/dbg/n16res.nas` | future full TOC/cart resident monitor | integration |
| `src/dbg/n16mon.nas` | standalone boot monitor at word 0 | integration |
| `tools/ndbg.sh` | exact proof gate | working |
| `tools/ndbg_diff.sh` | native vs interpreted trace equality | working |
| `tools/ndbg_mon.sh` | exact serial-monitor session | working |
| `tools/ndbg_img.sh` | bare-metal floppy boot of the monitor on qemu | working |
| `tools/ndbg_gui.sh` | desktop `debug` -> second CLI session | working |

The proof is deliberately self-contained, with a target embedded at 8192 and
two raw fault words at 9000. The production files split the same logic so the
core can be reused by the resident monitor, the boot monitor and a self-debug
run.

### 6.2 Register ownership

The debugger owns the real `r0–r15` while it runs. The target's registers are
always 16 words in the debugger's `nd_regs` array. The step core reads and
writes that array; the target's `CALL`/`RET` never touch real `r15`.
`r13` in the target file is initialised to 1 on reset (the proof initially
forgot this; it is a required convention, not a nicety).

The target's stack pointer is `nd_regs[14]`, but the debugger does not trust it
for its own stack and does not require a frame pointer. The shadow call stack
is the authority for backtrace.

---

## 7. Execution model

### 7.1 One step

```
pc0 = pc
word = mem[gb + (pc & mask)]          ; LDN first for the gate
n = LDN(word)
if n >= 16: fault GATE (site pc+1); stop
payload = LD(word)
pc = (pc + 1) & mask
if op == 0xFF: HALT
if op > MAXOP: BADOP (site pc)
if op != 0 and bit[k] of n is 0: OK (skip; pc already advanced)
decode d, a, imm, b
if pc in breakpoints: BREAK (before fetch is checked by control, not step)
dispatch
update flags
```

The proof uses a compare chain for dispatch; the final core uses the 98-entry
table, as `n16i` does. The step core must implement every op the machine can
execute, including the modern families that `n16i` currently rejects:

- `0x00–0x0F` core
- `0x10–0x1B` display/key/tick
- `0x20–0x2F` integer ext, byte, block
- `0x30–0x37` FP
- `0x38–0x45` far control, framebuffer, ports, CPUID/RDTSC
- `0x46–0x48` FEXP/FTANH/FLOG
- `0x4A` DP4B
- `0x4C` VDP4B4
- `0x50–0x5F` vector family
- `0x60–0x61` host extension: classify, do not silently execute as portable

Vector state is 16 × 64 bytes. The step core must keep it per-target, separate
from the debugger's own vector state (the debugger should not use vector ops,
but the target may).

### 7.2 Status and budgets

`nd_run(max)` returns status and never loops forever. The budget is per call,
not global; the UI passes a fresh budget for each `r` command. A target that
loops on `KEY` with an empty ring returns `WAIT_KEY`; the monitor decides
whether to feed a scripted key, block, or report a deadlock.

### 7.3 Breakpoints

Breakpoints are a sorted table of 24-bit PCs:

```
count, then n entries of (pc, flags, hits_left)
```

Before every fetch, the control layer compares the PC. If it matches, it emits
an `INFO/CORE` record and returns `BREAK` *without executing*. The target image
is never patched. Consequences:

- The cartridge seal stays valid; no need to recompute hashes.
- A breakpoint in read-only store is legal.
- A breakpoint at `pc = 0` is legal.
- Conditional breakpoints add a small predicate mini-language (§9.3).
- A breakpoint hit does not consume the instruction; `s` executes it, `r`
  continues past it (temporary ignore count).

The proof verifies the key property: break at `tgt_hit` with `r1=5`, `r2=15`,
then one step sets `r4=42`, then `r` reaches HALT. The target's word at
`tgt_hit` was never changed.

### 7.4 Watchpoints

Watchpoints are write-side intercepts inside the step core, not post-step
diffs:

```
watch = (addr, mask, kind, hits_left, old, new)
```

Kinds: write, read, execute, value-match, change. For every memory-writing op
(`ST`, `STB`, `STW`, `BCOPY`, `BFILL`, and later device windows), the core
checks the effective range. On a hit it records old and new values and stops
before or after the write according to policy. Read watchpoints hook `LD`,
`LDB`, `LDN`.

A hash watch is also possible: maintain a rolling FNV over a region and compare
after each step; it catches writes the core did not route (none in a pure
interpreter) and hardware corruption (useful on real metal).

### 7.5 Shadow call stack

The interpreter knows every `CALL`, `CALLR` and `RET`. It maintains:

```
depth, (return_pc, caller_pc, target_sp, frame_id)
```

On `CALL`/`CALLR`, push; on `RET`, pop (mismatch is `CALL_DEPTH`/`INTERNAL`).
This gives a backtrace independent of the guest's stack discipline. Carts that
save `r15` in static cells still unwind correctly because the shadow stack is
authoritative.

### 7.6 History / flight recorder

A ring of compact entries, one per step:

```
entry = class 10, payload = pc:16 | op:8 | k:2 | flags:6
```

A 4096-entry ring is 32 KB. It records the last 4096 fetches. On a fault, the
monitor can print the last N with disassembly. A rolling seal over the ring
detects corruption. This is the “show its own work” ethos applied to a crash:
the machine can show the road to the fault, not only the hole.

### 7.7 Undo / time travel

The interpreter is the only writer, so it can keep an undo log:

```
entry = (space, addr, old_word, new_word)
```

Before each write, append the old word. A reverse-step consumes entries in
reverse until the previous PC. A 65536-entry log (16 bytes each, 1 MB) covers
most short sessions; a checkpoint plus log covers longer ones. Full snapshots
are too large for the default VM, so the design uses bounded undo and explicit
`checkpoint` commands. The log is itself stored as NaN words and can be sealed.

This is a P2 feature; it follows naturally from the interpreter and is the
feature most likely to change how the machine is taught.

The resident implementation is a bounded scalar ring at host word `0x30000`:
32 records of 32 words. Each record holds 16 guest registers, PC, condition,
shadow-call depth, a bulk flag, and two `(host address, old word, old class)`
write slots. Recording starts with `dbg_begin`/`dbg_cart` (`nd_urec=1`) and is
disabled in standalone core tests. Scalar `ST`, `STW`, `STB` and `BSWAPM`
writes append to the record; `BCOPY`, `BFILL` and vector-file operations clear
the undo depth because they change more state than the record captures. The GUI
`undo` command calls `usnap`, restores through `mem_geth`/`reg_set`/`mem_seth`/
`state_set`, then commits with `udone`. I/O side effects are not rewound.

### 7.8 Fault classification

The step core maps machine conditions to codes:

- gate (near/far/both) from `LDN = FFFFFFFF` and `nan_hvalid`;
- bad op from `op > MAXOP`;
- unimplemented from the table entry;
- host extension from `0x60/0x61`;
- div0 from `k=3` after DIV/MOD;
- FP unordered from `FCMP` when either operand is NaN;
- memory range from the mediator;
- stack/call depth from the shadow structures;
- I/O denial/timeout from the policy;
- poison from a class check on a load.

A fault record is emitted before returning to the control layer. The return
status is `FAULT`; the record holds the detail.

---

## 8. Memory and I/O mediation

### 8.1 Why a target must not run loose

The target is untrusted by definition: it is broken, hostile, or both. If the
step core lets it write anywhere, it can overwrite the monitor's code, its
record ring, or the museum shell. The interpreter already computes every
effective address, so the fix is cheap and pure NaN.

### 8.2 Region table

```
id  base      limit      perms   map           name
0   0         31         X       identity      V_* vectors
1   8192      image_end  R|X     identity      target image (or store + offset)
2   stack      stack_end  R|W     identity      target stack
3   heap       heap_end   R|W     identity      target heap
4   5800      dbg_end     none    hidden        monitor core (never target-visible)
5   ...        ...        ...     ...           granted windows
```

Every guest address is translated and checked:

- fetch: must be R|X in a code region;
- load: R in the region;
- store: W in the region;
- CALL into an `X` region: allowed; into a data region: `MEM_RANGE`;
- an address that is not in any region: `MEM_RANGE`, not a silent wrap.

The monitor's own region is never granted. A target that tries to write it
gets a typed record, not a corrupted debugger.

For museum carts, the default map is:

```
[0,32)          X       jump vectors only
[8192, image_end) R|X   cart image, read-only
[0x9000, 0xA000) R|W    cart stack (GUI uses STKL=0x9000)
[0x16A8, 0x1DB0) denied  monitor core and ABI (word 5800..7600)
```

This is enough to run the GUI cart, which keeps its stack at `0x9000` and its
data in its own image.

### 8.3 The vector problem

A cart calls `CALL #V_PUTS` (address 1), `CALL #V_HEX` (2), etc. In normal
operation those are real shell routines below the slot. In debug mode:

- **Option A (faithful):** execute the real shell routine in the `X` region,
  with its real memory. It writes the screen/serial. Simple, but the target's
  calls cross into museum code and the monitor must not let them write monitor
  memory.
- **Option B (virtual):** intercept calls into `[1,32)` and implement the
  vector service inside the monitor: `V_PUTS` goes to the debug pane, `V_KEY`
  to the key script, `V_CLS` to the target screen buffer, `V_HEX` to the
  formatter. This is the better long-term design: deterministic, sandboxed,
  and it lets the monitor show target output in a pane instead of scribbling
  over the UI.

The design chooses B for the UI build and keeps A as a “raw mode” for exact
visual fidelity. The proof does not need either; its target uses `PUTC`
directly.

### 8.4 I/O policy

Each device class has a policy:

```
allow    pass through (PUTC to the record stream, TICK to the clock)
trace    pass through and log (port I/O, DISPSET)
buffer   capture into a target screen/serial buffer (VPOKE, FBCOPY)
script   return bytes from a key script (KEY, KEYQ)
deny     emit IO_DENIED and stop
```

Defaults in the monitor:

- `PUTC`: allow, tagged as target output (`T>` in the UI, raw on serial).
- `KEY`: script; if the script is empty, return `WAIT_KEY` to the control
  loop, never block the monitor.
- `KEYQ`: script; `0` when empty.
- `TICK`: a deterministic policy: `steps/1000` (n16i compatible) or host ms,
  selectable, and recorded in the run header so a replay knows which.
- `VPOKE/VPEEK/DISP*`: target VRAM buffer, not the real UI.
- `FB*`: same.
- `IN/OUT`: allow only a device whitelist; log every access; deny DMA-like
  or unknown ports.
- Disk: read-only by default; writes require an explicit capability.

This is how a debugger survives a target that calls `KEY` at boot.

---

## 9. Interfaces

### 9.1 The 80×25 console

The console is a normal museum screen, drawn with `VPOKE`/`V_PUTS`, not a host
window. Proposed panes:

```
┌ NANDBG · target: BABY (1948) · state: BREAK · t=0000007 ──────────────┐
│ 2007  FFF1_0A002002_F87F  JMP[LT] 8194   ; loop                       │
│ 2008  ...                                                             │
│                                                                       │
│ R0 00000000  R1 00000005  R2 0000000F  R3 00000005                    │
│ R4 00000000  R5 00000000  R6 00000000  R7 00000000                    │
│ SP 00000000  LNK 00000000  K 2 (Z=0 L=1)  TYPE FC                     │
│                                                                       │
│ LOG  !DFC10002329 GATE @2329  W=FFFFFFFFDEADBEEF                      │
│      !DFC2000232A BADOP @232A W=0000000F7F000000                      │
│                                                                       │
│ FC FM FD FS   PC PM PD PS   WC WM WD WS   IC IM ID IS   (live counts) │
└ s step  n next  r run  b break  w watch  g goto  x mem  u undo  q ────┘
```

The type matrix at the bottom is a 4×4 grid of the sixteen diagnostic types;
each cell shows a count or a live indicator. Errors light their cell. This is
the machine's own taxonomy made visible, and it is the natural debug analogue
of the museum's existing plaques.

### 9.2 Keys and commands

| key | action |
|---|---|
| `s` | step one instruction |
| `n` | next (step over CALL) — planned |
| `r` | run until break/fault/halt/budget |
| `b` | toggle breakpoint at the current PC |
| `g <hex>` | prompt for a 4-digit hex PC and set it |
| `w <hex>` | prompt for an address; toggle a before-write watchpoint |
| `x` | dump 8 words at PC |
| `p` | dump registers and flags |
| `d` | disassemble 4 words at PC |
| `t` | show the shadow call stack |
| `m` | show the 4×4 type matrix with per-type counts |
| `l` | show the last 16 fetched PCs |
| `u` | undo one step (P2) |
| `k` | key script / input queue — planned |
| `?` | help — planned |
| `q` | leave |

The serial monitor currently implements `s r b g w l t m x p d q`; `n` (next)
and an NDR log view are the same control API with a later front end.

Commands are ASCII in v1 because the keyboard delivers bytes. The engine API
below is not ASCII; the UI is a thin adapter.

### 9.3 Conditional breakpoints

A condition is a small vector of NaN words, not an expression parser in the
core:

```
kind: reg | mem | type | count | pc-range
operand: index, mask, value
```

Examples: `break at 0x2007 if r1 == 5`, `break on write to 0x9000`,
`break on class FC`, `break after 100 hits`. The control layer evaluates the
condition before deciding to stop; the step core only reports state.

### 9.4 NaN Debug Protocol (NDP)

For a second NaN machine, a remote link, or an automated test, the monitor
speaks a framed word protocol:

```
frame = [header, arg0, arg1, seal, mirror(header), mirror(seal)]
header: class = command type (info/core for requests, warn/... for replies)
        payload = opcode:8 | len:8 | seq:16
seal:   class 10, FNV1a32 of the preceding payloads and classes
mirror: BSWAPM of header (and seal), checked by the receiver
```

Opcodes: `HELLO`, `READ`, `WRITE`, `REGS`, `STEP`, `RUN`, `BREAK`, `WATCH`,
`RESET`, `EVENT`, `ACK`, `NAK`. The protocol can run over `PUTC`/`KEY` bytes or
over a shared memory mailbox. It is deliberately not ASCII; the text `!D` line
is the human view, NDP is the machine view. Because every frame has a mirrored
twin, a corrupted byte is a NAK, not a wrong memory write.

This is a P2 feature, but it is the reason the error type system is a *word*
rather than a string: a second machine can act on it without parsing English.

---

## 10. Residency and boot modes

### 10.1 Museum-resident monitor (`n16res`)

Place the engine above the cart store so no cart can overwrite it:

```
word 0..31       V_* jump vectors (shell)
word 32..5698    shell, strings, system menu
word 5800..5813  NANDBG ABI trampolines (dbg_cart is 5813)
word 5814..5949  dbg_begin / dbg_cart / HALT return
word 5950..5966  ABI2: mem get/set/class, log, reg set, BP/WP, undo
word 5967..6199  ABI2 helpers and undo recording
word 0x30000     32 x 32-word scalar undo records
word 0x60000     captured cart text screen (2000 words)
word 0x61000     captured cart serial (length + up to 4094 characters)
word 0x62000     32 x 32-word redo records
word 0x90000     checkpoint header (regs, pc, k, cd, magic)
word 0x91000     checkpoint arena copy (64K words)
word 6200..8099 NANDBG core, records, history, log, vector file, BP/WP tables
word 8100..      demo target (built into the resident image)
word 8192..      cart slot (target)
word 22000       live TOC (may be overwritten by a large cart)
word 23600       live titles
word 25000..     cart store
word 0x70000     TOC snapshot (taken before the GUI boots)
word 0x72000     title snapshot, pointers rewritten
word 0x80000     debug arena (sealed cart copy)
```


The gap 5700..8191 is the shell's free tail. The core fits below the cart slot,
so a loaded cart at 8192 cannot overwrite it. `sh_snap_toc` copies the catalog
and title area to `0x70000/0x72000` at cold boot, because a large cart loaded at
8192 overwrites 22000/23600. The debugger reads the snapshot, not the live TOC.

Entry today: the desktop terminal's `debug` command (`fs_dispatch` prefix in
`gui_cart.nas`) or the system utilities window's `[3] DEBUG` opens a second
terminal-shaped CLI of kind 8. It drives the
resident core at 6200. The ABI is fixed:

```
5800 nd_reset   5801 nd_step    5802 nd_run     5803 dbg_begin
5804 dbg_reg    5805 dbg_pc      5806 dbg_status 5807 dbg_hist
5808 dbg_stack  5809 dbg_counts  5810 dbg_break  5811 dbg_watch
5812 dbg_rec    5813 dbg_cart

5950 mem_get    5951 log        5952 mem_cls    5953 reg_set
5954 mem_set    5955 bp_list    5956 bp_toggle  5957 wp_list
5958 wp_toggle  5959 pc_set     5960 tbuf       5961 mem_geth
5962 mem_seth  5963 usnap      5964 uinval     5965 udone
5966 state_set 5967 state_get 5968 upop       5969 mem_geth_cls
5970 ckpt_to   5971 ckpt_from 5972 map
```

`dbg_cart` copies a sealed TOC payload to `0x80000` and maps guest words
`[8192, 8192+max(len,0x8000))` onto that arena. The target runs at guest 8192;
the store is never modified, so its seal remains valid. The demo target at
8100 remains for `reset`.

The second CLI accepts `carts load <id> step next finish run regs mem [addr]
log hist stack types screen serial dis [addr] undo [n] redo [n] break bp bpts
watch wp wpts setr setm setw setc goto checkpoint restore reset help quit`.
`break` is a fast single breakpoint at PC; `bp <hex>`/`wp <hex>` toggle table
entries and `bpts`/`wpts` list them. `setr <n> <hex>`, `setm <addr> <hex>`, `setw <addr> <word> <class>`,
`setc <addr> <class>` and `goto <hex>` are typed edits backed by ABI2
`reg_set`, `mem_set`, `mem_seth`, `map` and `pc_set`.
`undo [n]` rewinds one or `n` recorded scalar steps, restoring registers, PC,
condition, shadow-call depth and up to two guest memory words per step; each
restored PC is printed. `redo [n]` restores the saved post-step states in
reverse order and re-exposes their undo records. Manual edits and new steps
clear the redo history. `checkpoint` snapshots the 16 registers, PC, condition,
call depth and the 64K cart arena; `restore` copies them back and clears the
undo/redo history. Checkpoints are invalidated by `load`, `reset` and a new
debug window. `dis [addr]` disassembles eight words from PC or an address using
the shared `src/tools/disasm.nas`; guest addresses are mapped to host words
through ABI2 `map`. `screen` prints the captured 80x25 cart text screen. `serial` prints
the captured `PUTC` stream. It prints into its own window buffer and mirrors
command lines and hex values to COM1 for headless gates. `tools/ndbg_gui.sh` builds a minimal
image with the Baby cart, types `debug`, lists the catalog, loads cartridge 1,
breaks, inspects the log and memory, then next/finish to `KEY`:

```
carts
1
load 1
S=0 PC=2000
break
!DIC@02002000 W=0000000F09F0201C
S=2 PC=2000
log
DC02002000
mem
M200009F0201CF
next
S=0 PC=2001
finish
S=5 PC=2009
```

Cart display writes are now captured: `dbg_begin` and `dbg_cart` set
`nd_iocap=1` and point `nd_tbuf` at word `0x60000`. The core intercepts
`VPOKE`/`VPEEK`, `DISPQ`, `DISPSET`, `FBINFO`, `VSYNC`, `FBCOPY` and `FBFILL`;
`VPOKE` cells below 2000 go to the private text buffer, and `screen` prints the
25x80 result. `PUTC` appends one byte per word at `0x61000` (length word) and
`0x61001+`, capped at 4094 bytes; `serial` prints it. The real cart still draws and writes nothing
outside the debug buffers.

Still ahead: the system menu entry and a full region map for arbitrary data
addresses outside the cart image.

### 10.2 Standalone boot monitor (`n16mon`)

For the “bare metal” mode, build a guest image whose word 0 is the monitor,
with no museum and no shell. The boot sector and kernel are unchanged. The
monitor:

- prints its banner on COM1;
- offers `load` from ATA/NaNFS, `run`, `step`, `break`, `dump`;
- can inspect the kernel's handoff words and the boot record;
- can read a cartridge directly from the store;
- can be the first program after the kernel, so it sees the machine before any
  exhibit.

This is the closest thing to a ROM monitor while still being pure NaN. It can
be built to `$TMPDIR`, not `build/`, to respect the two-image rule.

### 10.3 Self-debug

The monitor is a NaN program; it can run under itself:

```
n16dbg  debugging  n16dbg  debugging  target
```

The inner monitor's records are data to the outer one. The expected gate is
that the three transcripts agree at the boundary and that the outer monitor
can break on the inner monitor's fault path. This is the strongest available
proof that the tool is native: it dissects itself with the same scalpel.

---

## 11. Brainstorm: ideas worth keeping, deferring, or rejecting

### 11.1 The diagnostic word as a first-class value (keep)

Already central. A fault can be stored in an array, compared, sorted, hashed,
sealed, sent over a link, and used as a truth table. The log is not a text file;
it is a vector of words the machine can compute with.

### 11.2 Typed output for the compilers (keep, P2)

`ncc` and the TCC port already produce diagnostics (assert, errno, parse
errors). They can call `nd_emit` with `PROGRAM` domain and a source offset in
`site`. The same log then contains compiler errors, loader seal errors and
runtime traps, all in one 16-type vocabulary. This is the strongest argument
for “error output” as a system-wide ABI rather than a debugger feature.

### 11.3 NaN poisoning (keep as an option)

Fill free memory, uninitialized stack, and freed heap with a diagnostic word
(e.g. `INFO/PROGRAM` with a known payload). On load, `LDN` checks for the poison
class. `FCMP x,x` can also detect an IEEE NaN payload. This turns
use-of-uninitialized and use-after-free into typed records without a sanitizer
runtime. Cost: one class check per load in debug mode. It must be optional, and
the poison word must be type 15 (`ALWAYS`) only if the region is never executed;
otherwise type 0 (`NEVER`) is safer as a pad.

### 11.4 The mirror channel as ECC (keep)

Store every record as a `(word, BSWAPM word)` pair. A single corrupted byte
fails the pair. The class of the twin is `rot2(n)`, so even the type has a
second reading. This is cheap enough for the log ring and is in the spirit of
the cartridge seal.

### 11.5 The 16-cell type matrix as UI (keep)

A 4×4 grid with live counts is both a debugger dashboard and a teaching
exhibit. It makes the abstraction visible. It can double as a museum plaque:
“these are the sixteen ways this machine can be wrong”.

### 11.6 Fault chime (optional, low priority)

`BEEP` a short pattern by severity. Early machines used sound as a debug
channel. It fits the museum, but it is not load-bearing.

### 11.7 Reverse execution (keep, P2)

The interpreter can log old values. Reverse-step is a natural extension and a
powerful teaching tool. It is bounded by the undo ring; full checkpoints are
explicit. Do not promise unlimited time travel.

### 11.8 Patch-and-trap native breakpoints (reject for v1)

Classic, fast, and impossible in pure NaN because there is no `BRK`, the gate
trap halts, and patching breaks the seal. Keep it as a future native
accelerator, not the core.

### 11.9 Hardware single-step via a native trace port (defer)

A new host primitive (run N instructions, return a trace) would give native
speed with visibility, but it enlarges the trusted native base and is a new ISA
surface. The pure-NaN core must exist first; then this becomes an optional
backend behind the same control API.

### 11.10 Host gdb stub (reject)

It would make the host part of the system, violate the project's purity rule,
and teach the wrong thing. The host may capture serial and send keys; it may
not be the debugger.

### 11.11 Static pre-flight lint (keep as a complement)

A NaN-native verifier can scan a cartridge before it runs: every head legal,
every opcode known, every branch target in range, every seal valid. This is not
a replacement for dynamic debugging, but it catches the boring faults before
the monitor starts. It reuses the disassembler and seal code.

### 11.12 Call-stack sampling profiler (defer)

The shadow stack plus `TICK` gives a sampling profiler almost for free. Not a
debugger requirement, but a natural next exhibit.

### 11.13 Symbol and line maps (keep, P2)

The host assembler already emits labels (`nmk.awk -v LABELS=file`). A debug
build can pack a compact symbol blob into the image: sorted `(addr, name_ptr)`
pairs plus a string pool, or a 4-character-per-word compressed table. The
monitor shows `tgt_hit` instead of `2007`. Source lines need `.line` support in
the assembler; that is a separate toolchain change, not a debugger change.

---

## 12. Performance and limits

The interpreted core is roughly 45× slower than native per level (`n16i`
measurements). That is fine for stepping and for small/medium carts; it is not
fine for a 60 fps GUI. The design therefore offers three run modes:

- `step` — interpreted, full visibility, slow;
- `run` — interpreted with break/watch checks, still slow;
- `free` — native execution, no breakpoints, with a pre-flight lint and a
  postmortem ring; fast, but a native trap still halts.

A future native trace port or patch-and-trap mode can fill the middle. The
honest statement: **the pure-NaN debugger is for understanding, not for
frame-rate work.**

Other limits:

- No hardware watchpoints; write interception is exact but costs per store.
- No MMU; the region map is software. A bug in the map is a bug in the
  sandbox.
- The target can still DoS the monitor with a huge `BCOPY`/`BFILL`; the core
  must bound counts and budget long ops.
- Self-modifying code is visible (the interpreter sees every write) but makes
  disassembly and breakpoints stale. Mark the range dirty and invalidate the
  decode cache.
- Device side effects are virtualized; timing-sensitive bugs may not reproduce.
  The run header records the time policy and I/O script so a replay is honest
  about what it changed.
- The native `!G`/`!O` path remains outside the debugger. A crash before the
  monitor starts is a native crash.
- Log persistence needs a storage path; NaNFS is RAM-only today, ATA writes
  are gated. The first version logs to RAM and serial; disk postmortem is P2.

---

## 13. Roadmap and gates

### P0 — proof and semantics (done / next)

- [x] `src/dbg/ndbg.nas`: 16 types, STW/LDN, mirror, quiet/raise, step core
      subset, breakpoint, gate/bad-op records, exact serial output.
- [x] `tools/ndbg.sh`: exact transcript gate.
- [x] `src/dbg/core.nas`: full `0x00–0x5F` step core (all defined ops,
      including vectors, DP4B, VDP4B4); `0x60/0x61` classified as host
      extensions; shadow call stack; KEY rewinds instead of blocking.
- [x] `tools/ndbg_diff.sh`: a target with integer/float/control/memory/vector
      ops runs natively and under the step core; serial transcripts and
      per-section checksums must match exactly.
- [x] Real cartridge: `src/tests/ndbg_cart_test.nas` runs the Baby cart under
      the core to its first `KEY` (status `WAIT_KEY`) with `CART PASS`.
      Trust was also run manually to `CART PASS`.
- [ ] `tools/ndbg_trap.sh`: gate/bad-op sites match native `!G`/`!O` exactly,
      while the record adds type/code/word.
- [x] Negative gate: mutate one expected line; the gate must reject it.
- [x] `tools/ndbg_mon.sh`: exact serial session (step/run/break/goto/watch/
      history/stack/type matrix/regs/disasm/dump).
- [x] `tools/ndbg_img.sh`: bare-metal floppy boot of the monitor on qemu.

**Acceptance so far:** the full core reproduces the native transcript for the
differential target and runs Baby to `KEY`; the target image is never patched.
The next acceptance step is every text cart, then the GUI and NCC output.

### P1 — control and containment

- [~] Breakpoint: single `nd_brk` with pre-fetch compare; table/ignore counts later.
- [~] Watchpoint: single write watchpoint, stops before the store and rewinds
      PC; table/ranged watch later.
- [x] Shadow call stack (CALL/CALLR/CALLF/RET), depth cap, backtrace data.
- [~] Write window `[nd_wlo, nd_whi)`: target cannot write the monitor; full
      region/permission map and I/O policy later.
- [x] Budgets, `WAIT_KEY`, deterministic `TICK`.
- [~] Serial UI has the live 16-type matrix, history, stack and commands;
      the 80×25 pane layout remains.
- [x] Desktop terminal command `debug` opens a second CLI (kind 8) running
      NANDBG against the resident demo target; `tools/ndbg_gui.sh` gates it.
- [x] Desktop `carts` / `load <id>` picker; sealed cart copied to the debug
      arena and interpreted at guest 8192. Baby runs to `KEY`.
- [x] Debug-pane vector I/O capture: `VPOKE`/`VPEEK` and display ops go to
      a private 25x80 text buffer; `screen` command.
- [x] Serial capture: target `PUTC` goes to 0x61000; `serial` command.
- [x] System utilities `[3] DEBUG` entry opens the desktop debug CLI.

**Acceptance:** debug the GUI cart; break on a window-manager routine; feed a
scripted key; verify the monitor survives a target that writes to `0`, to the
TOC, and to the monitor region (each becomes a `MEM_RANGE` record); leave the
cart seal valid.

### P2 — records, history, protocol

- [ ] 8-word NDR with operands and seal; mirror pair storage.
- [ ] Flight-recorder ring (4096 steps) and log ring (256 records).
- [x] Bounded scalar undo ring (32 records, two writes each); `undo [n]`.
- [x] Redo ring (32 records) with post-step state and write values; `redo [n]`.
- [x] Cart checkpoint/restore: registers, PC, condition, call depth, 64K arena.
- [x] Desktop `dis [addr]` using the shared disassembler and `map`.
- [ ] Full-memory checkpoints and bulk-write checkpoints.
- [ ] NDP over serial and mailbox; `HELLO/READ/WRITE/STEP/RUN/EVENT`.
- [ ] Symbol blob from `nmk.awk -v LABELS`; source lines if the assembler
      gains `.line`.
- [ ] Poison fill and read checks.
- [ ] ATA/NaNFS postmortem persistence.

**Acceptance:** replay a recorded session byte-for-byte; a corrupted log twin
is detected; a second machine can step the first over NDP.

### P3 — boot monitor, self-debug, native accelerator

- [ ] `n16mon` standalone image at word 0; load from NaNFS/ATA.
- [ ] `n16dbg` under `n16dbg` under a target; three transcripts agree.
- [ ] Optional native trap trampoline and trace port, behind the same API.
- [ ] Sampling profiler on the shadow stack.

---

## 14. The proof in detail

`src/dbg/ndbg.nas` is 9003 words including its embedded target and raw fault
words. It runs on the portable C core with:

```sh
awk -f tools/nmk.awk -v CMD=emit src/dbg/ndbg.nas > /tmp/ndbg.nan
aarch64/android/nan_cli --img /tmp/ndbg.nan --steps 2000000 --serial
```

or:

```sh
sh tools/ndbg.sh
# ndbg: PASS (types, mirror, quiet, step, breakpoint, gate record, bad-op record, exact)
# ndbg: NEGATIVE PASS (mutated transcript rejected)
```

What each test asserts:

1. **types** — for every `n` in 0..15, `STW` writes a legal word, `LDN` reads
   the same nibble, `BSWAPM` yields `rot2(n)`, and the payload survives the
   round-trip. Quiet sets both Q bits; raise clears them. The four matrix rows
   are printed so the whole taxonomy is visible in the transcript.
2. **breakpoint** — the target at 8192 loops until `r1=5`, `r2=15`; the
   breakpoint at `tgt_hit` stops before the `MOVI r4,42` executes; one step
   then sets `r4=42`; clearing the break and running reaches `HALT`. The target
   word is never modified.
3. **gate record** — word 9000 has illegal heads; the step core returns
   `FAULT`, code `10`, site `2329`, class `FFFFFFFF`, payload `DEADBEEF`.
4. **bad op** — word 9001 has legal heads and op `0x7F`; code `20`, site
   `232A`, class `F`, payload `7F000000`.
5. **quiet** — the last record's header type can be quieted and the result
   equals the type with both Q bits set.

The exact transcript is in `tools/ndbg.sh`, so a change in any field is a
gate failure. That is deliberate: the proof is a specification.

---

## 15. Open questions for the author

1. **Name.** NANDBG / `n16dbg` is the working name. The museum voice might
   prefer “The Quiet Room”, “The Anatomy Theatre”, or “The Coroner's Office”.
   The code prefix `nd_` is neutral.
2. **Residency.** Resident core in the shell gap at 5800 (current), system
   menu entry, standalone boot monitor, or all three?
   The design recommends both; only the resident one needs the museum image.
3. **Type axes.** Severity×domain (this design) or a pure IEEE reading
   (live/latched × guest/machine)? The matrix is more useful for humans; the
   IEEE reading is more faithful to the word. The author's call.
4. **Target memory.** Strict read-only image plus granted stack/heap, or
   “debug in place” with writes allowed? Strict is safer and preserves seals;
   in-place is closer to the production machine.
5. **UI or protocol first?** The proof uses serial. A 80×25 UI is a large
   amount of NaN code; NDP plus a host capture might be enough for the first
   usable version. The design recommends UI first because the museum is a
   visual place.
6. **Native accelerator.** Is a trap trampoline acceptable as a later
   substrate primitive, or must the monitor always be interpreter-only? The
   design treats it as optional and keeps the pure path complete.
7. **Symbols.** Is a host-generated `.sym` blob acceptable debug data, or must
   symbols also be assembled by `nasm0`? The blob is data, not logic.

---

## 16. Appendix: file and line references

| fact | location |
|---|---|
| word, heads, class, gate | `spec/NAN16_SPEC.md:1–14` |
| op map and predicate table | `spec/NAN16_SPEC.md:15–19` |
| native fetch/gate/badop | `x86/native/kan16.xa:89–122` |
| native trap printer | `x86/native/kan16.xa:1355–1375` |
| native `MAXOP 0x61` | `x86/native/kan16.xa:10` |
| x86 host extension `0x60/0x61` | `x86/native/kan16.xa:889–910, 1689` |
| C core trap | `aarch64/android/core/nan16.c:203–209, 264–269, 295, 444` |
| C core debug accessors | `aarch64/android/core/nan16.h:64–90` |
| FP NaN rules | `aarch64/android/core/OPS.md:67–80` |
| `n16i` entry and op limit | `src/tools/n16i.nas:1–12, 43–51` |
| `n16i` trap printing | `src/tools/n16i.nas:92–108` |
| `n16i` I/O pass-through | `src/tools/n16i.nas:253–270` |
| disassembler | `src/tools/disasm.nas` |
| word inspector | `src/lib/nan16dump.nas` |
| pair-voting codec | `src/lib/n16de.nas` |
| seal v2 | `src/lib/libvec.nas:136–220` |
| loader slot and TOC | `src/museum/shell.nas:337–380, 650–725` |
| image builder / store | `tools/mkimg.awk:1–120` |
| assembler directives | `tools/nmk.awk:160–225` |
| gate style | `tools/ngate_n16i.sh`, `tools/ncc_lex.sh` |
| proof | `src/dbg/ndbg.nas`, `tools/ndbg.sh` |
| serial monitor | `src/dbg/n16dbg.nas`, `tools/ndbg_mon.sh` |
| full step core | `src/dbg/core.nas` |
| core self-test | `src/tests/ndbg_core_test.nas` |
| differential target | `src/tests/ndbg_diff_body.nas`, `src/tests/ndbg_diff_native.nas`, `src/tests/ndbg_diff_debug.nas`, `tools/ndbg_diff.sh` |
| real cart under the core | `src/tests/ndbg_cart_test.nas` |

---

## 17. Core implementation notes

The reusable core is `src/dbg/core.nas`. It is a step version of `n16i` with
the op limit raised to `0x5F`, typed records, a shadow call stack, non-blocking
`KEY`, and the missing families. The implementation turned up four facts worth
recording.

### 17.1 `LD` returns the payload

`LD d,a,imm` returns the **32-bit payload**, not the 64-bit raw word. A step
core that shifts it by 16 loses the opcode. The proof hit this first; the core
now stores `LDN` (class) and `LD` (payload) separately and never reconstructs a
raw word it does not have.

### 17.2 Vector state: use the host file as a scratch execution unit

`nd_vreg` is 16 × 64 bytes (256 words). To execute a target vector op, the core
loads the guest vectors into the host vector file with `VLOAD`, executes the
**same opcode** natively, and writes the result back with `VSTORE`. This works
for VZERO, VBCAST, VADD8, VSUB8, VADD32, VSUB32, VMUL32, VDP4B and VDP4B4, and
it avoids a hand-written per-byte ALU. VGET/VSET are direct 32-bit word accesses
to `nd_vreg`; VLOAD/VSTORE use a fast host path when `nd_gb == 0` and a byte
loop otherwise.

The first version of `nd_vbase` multiplied the vector index by 16 instead of
64, so vectors overlapped every four words. The differential target caught it
immediately: native `VADD32` added 6 to the checksum, the stepped core added 0.
The fix is one constant; the lesson is that the differential gate must include
vectors, not only scalar code.

### 17.3 Shadow calls must wrap far calls too

`CALL`, `CALLR` and `CALLF` all push a shadow return frame; `RET` pops. The
first version forgot `CALLF`, and the first `RET` after a far call underflowed.
The second version pushed from `CALLF` but then used `r3` as the target after
`nd_push` had clobbered `r3`; the target became the shadow-stack base. The fix
is to reload the target from `nd_raw` after the push. A differential target
with all three call forms is the regression.

A cart entered by the monitor is CALLed by the shell in production. In a debug
session the monitor should push a synthetic sentinel frame before running a
cart so the cart's final `RET` returns to the monitor rather than underflowing.
The current cart test stops at `KEY`, before that return.

### 17.4 `KEY` is a debug event

`n16i` calls the blocking `KEY` op. A debugger cannot. The core uses `KEYQ`; if
the ring is empty it rewinds the pc to the KEY instruction and returns status
`WAIT_KEY` (5). The monitor can then feed a scripted key, block on the host, or
report a deadlock. Baby stops exactly this way, which is the cart pass
condition.

### 17.5 What the differential target covers

`src/tests/ndbg_diff_body.nas` runs natively and stepped and prints ten
checksummed sections:

| marker | covers |
|---|---|
| A | ADD/SUB/MUL/DIVU/MODU/SHL/SHR/SAR/DIV/MOD/CMPS/CMP/predicates/ADDI |
| B | MOVHI/MULH/MULHU, LD/ST/STW/LDN/BSWAPM/LDB/STB/BCOPY/BFILL |
| C | CALL/CALLR/RET/JMPR/JMPF/CALLF |
| D | CVTIF/CVTFI/FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/FEXP/FTANH/FLOG |
| E | DP4B |
| G–J | VBCAST/VGET/VSET/VADD32/VSUB32/VMUL32/VADD8/VSUB8/VDP4B/VLOAD/VSTORE |
| F | final checksum and HALT |

The native and stepped transcripts are byte-identical, and both equal the
golden transcript in `tools/ndbg_diff.sh`. The test also mutates one byte and
requires the gate to fail.

### 17.6 Real cartridges

`src/tests/ndbg_cart_test.nas` places the core at word 40000, the cart at 8192,
and installs `JMP -> RET` vectors at words 1..31. The Baby cart runs its plaque
loop and reaches `KEY`; the core returns `WAIT_KEY`, and the harness prints
`CART PASS`. The Trust cart does the same in a manual run. The GUI cart is the
next target; it needs the display mediator so target drawing does not overwrite
the monitor.

### 17.7 Containment and watchpoint

The core has a write window: `nd_wlo` (default 8192) and `nd_whi` (default
`FFFFFFFF`). Every interpreted `ST`, `STB`, `STW`, `BCOPY` and `BFILL` checks
the host word address before writing. A store below the window is a
`FAULT/MEMORY` record:

```
!DFM@40002003 W=0000000000000100
```

A single write watchpoint `nd_watch` is compared on the same path. A hit is an
`INFO/MEMORY` record and stops **before** the store, with the old value in the
low half and the new value in the high half:

```
!DIM@03002008 W=0000000A00000000
```

The PC is rewound to the watched instruction. Clearing the watch and stepping
performs the store, so a watchpoint is non-destructive by construction.
`BCOPY` and `BFILL` check every word; a hit leaves a partial copy, which is
visible and reportable.

Two implementation lessons: helper calls clobber `r15` unless the helper saves
it, and new helper calls can clobber loop registers. `nd_cp1` now saves its own
link and the copy loop keeps its destination/index in cells. The differential
and guard gates cover both.

### 17.8 Flight recorder and backtrace

The step core appends the just-incremented PC to `nd_hist[64]` on every fetch.
`nd_hi` is the next slot, so the last 16 fetches are always available in time
order. The monitor's `l` command prints them:

```
HIST 0000 0000 ... 2000 2001
```

The shadow call stack (`nd_cd`, `nd_cs`) records CALL/CALLR/CALLF return
addresses. `t` prints them newest-first, or `STACK empty` at top level. This is
a real backtrace without a frame-pointer convention; it follows the interpreter,
not the guest's stack.

The recorder is a ring in the monitor's data section, not target memory. A
target cannot write it through the guarded window.

`nd_emit` also increments `nd_counts[16]`; the monitor's `m` command prints the
live 4×4 matrix, e.g. `IM:01` after a watchpoint. The error taxonomy is now a
running instrument, not only a diagram.

### 17.9 The desktop `debug` command and cart picker

The GUI terminal is a line-mode shell. `fs_dispatch` in `gui_cart.nas` checks
full-line prefixes before the old single-letter commands. Adding `debug` is two
pieces: a prefix test and `gui_open_new` with kind 8.

Kind 8 is a terminal-shaped app, not a new window manager:

- `dbg_init` fits the text grid and prints the NANDBG banner;
- `dbg_key` delegates ordinary line editing to the existing `term_key`, but
  intercepts Enter and calls `dbg_dispatch`;
- `dbg_dispatch` parses `step`, `run`, `regs`, `hist`, `stack`, `types`,
  `break`, `reset`, `help`, `quit`;
- `term_draw` draws the same private text buffer as the terminal;
- every command and every hex value is mirrored to COM1, so a headless gate
  can drive the window without reading pixels.

The core lives at 6200..8099 in the shell's free tail, the demo target at
8100, and the GUI calls the fixed ABI at 5800..5813 and 5950..5966. The core's real `r14` is
preserved around ABI calls because GUI code uses it as a stack pointer; the
first version forgot this and looped in `dbg_begin`. The ABI's `dbg_begin`
also saves its own `r15` across `CALL @nd_reset`; without that, its `RET` went
back into its own body.

Cart picking adds two more lessons:

- The live TOC at 22000 is overwritten when a large cart is loaded at 8192.
  `sh_snap_toc` copies the TOC and titles to 0x70000/0x72000 at cold boot and
  rewrites title pointers; the debugger reads the snapshot.
- Absolute cart addresses cannot be relocated by a single `gb` value because
  calls to the low `V_*` vectors must still reach the shell. `dbg_cart` maps
  only `[8192, 8192+span)` to the arena and leaves lower addresses plain. The
  span is at least `0x8000` so small carts can use data such as Baby's `SB`
  without leaving the sandbox. The store copy remains sealed and read-only.

`tools/ndbg_gui.sh` rebuilds a minimal image containing the museum + GUI cart
and the Baby cart, boots the guest under the portable core, types `debug`, and
drives the second CLI. Its transcript is exact:

```
carts
1
load 1
S=0 PC=2000
break
!DIC@02002000 W=0000000F09F0201C
S=2 PC=2000
log
DC02002000
mem
M200009F0201CF
next
S=0 PC=2001
finish
S=5 PC=2009
```

`S=5` is `WAIT_KEY`: Baby reached its first `KEY` and the core stopped without
blocking. `next` steps over a call; `finish` runs until the current shadow frame
returns (or to halt at top level). The store copy is unchanged.

---

## 18. Final statement

A debugger is a machine that watches another machine. On NaN/0S it can be made
of the same words as the thing it watches, and its observations can be typed by
the same four NaN faces that decide whether an instruction runs. That is the
whole idea:

> **the fault is a word, the word has two faces, and both of them are true.**

The machine already refuses to guess. NANDBG lets it refuse without dying.
