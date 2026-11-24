# NaN/0S kernel ABI v0.1 (frozen)

Status: **frozen 2026-11-23**. This document is normative for the S1 trap,
syscall, timer, region and port boundary. It resolves the old `0x39`
conflict by keeping `0x39` as far `CALL` and assigning SVC its own opcode.
The portable C core is the conformance oracle; the product target is x86_64
bare metal.

Related: `spec/NANVM_SPEC.md` §8-9, `spec/NAN16_SPEC.md`,
`spec/TCL_SQLITE_OFFICIAL_SUITE.md` S1.1-S1.3.

## 1. Instructions

All instructions use the normal NaN16 payload layout
`[31:24]=op [23:20]=d [19:16]=a [15:0]=imm16` and normal predicate rules.
Use `n=15` (ALWAYS) for trap instructions. A predicated-off SVC/SVCRET does
nothing.

| opcode | mnemonic | encoding | meaning |
|---|---|---|---|
| 0x4D | `INL d,a` | `d` destination, `a` port register | 4-byte port read: `r[d] = inl(r[a] & 0xFFFF)` |
| 0x4E | `SVC imm` | `imm` = syscall number, `d=a=0` | save trap frame with cause=0, vector to kernel entry |
| 0x4F | `SVCRET` | `d=a=imm=0` | restore the trap frame and resume |

`0x39` remains far `CALL` (`CALLF`). `OUTL` remains opcode `0x43`:
`outl(r[a] & 0xFFFF, r[d])`. `INL` has no other side effect.

## 2. Control ports

Ports are written with `OUTL` (0x43) and read with `INL` (0x4D). All address
values are **guest word indices**, not byte addresses.

| port | direction | value |
|---|---|---|
| 0x4E00 | OUT/IN | kernel entry word address |
| 0x4E01 | OUT/IN | trap frame word address |
| 0x4E02 | OUT/IN | timer interval in instructions, 0 = off |
| 0x4E03 | OUT/IN | kernel stack pointer word |
| 0x4E04 | OUT/IN | region table word address |
| 0x4E05 | OUT/IN | current TCB word address (opaque to S1) |
| 0x4E06 | IN | status: bit0 timer pending, bit1 trap pending |

Power-on values: every address port is `0xFFFFFFFF` (`NAN_KABI_UNSET`), the
timer is 0. The kernel ABI is **active iff 0x4E00 is not UNSET**. Before then,
0x4E and 0x4F keep their previous reserved-op trap behaviour, so old programs
do not change. `INL` itself is always a valid opcode.

Word alignment is inherent: a port value is an index of an 8-byte guest word.
A byte address is not representable; a value whose word span leaves
`[0, mem_words)` is rejected. The last legal 24-word frame starts at
`mem_words - 24`; a frame ending after `mem_words` is a configuration error.

## 3. Trap frame

The frame is 24 aligned guest words, each a normal `+q/+q` NaN word whose
32-bit payload is the value. `frame[k]` means word address `kframe + k`.

| word | contents |
|---|---|
| 0..15 | r0..r15 at trap time |
| 16 | pc (resume address for SVC/IRQ, faulting instruction for fault) |
| 17 | flags/k (0..3) |
| 18 | ADDRH (0 in the 32-bit S1 core) |
| 19 | cause: 0 SVC, 1 IRQ, 2 fault |
| 20 | SVC number; fault address for cause=2; 0 for IRQ |
| 21 | SVC return/status; SVC entry writes 0 here |
| 22 | saved guest SP (same value as frame[14]) |
| 23 | reserved, written 0 |

The kernel may modify any frame word before `SVCRET`. The frame must lie
entirely inside guest word memory; otherwise the trap is a configuration
error `!K`.

## 4. Trap and return rules

On SVC (`cause=0`):
- `frame[16]` is the pc **after** the SVC instruction; `frame[20]=imm`.
- `frame[21]` is 0. The kernel writes the syscall return value there.
- `r1..r4` carry the arguments and are also saved in frame[1..4].
- If `kstack != UNSET`, the S1 sets `r14 = kstack` for kernel code. The guest
  SP remains in frame[14]/frame[22].

On timer IRQ (`cause=1`):
- `frame[16]` is the next instruction; `frame[20]=0`, `frame[21]=0`.
- SVC return semantics do not apply; `SVCRET` restores r1 from frame[1].

On fault (`cause=2`):
- `frame[16]` is the faulting instruction (so the kernel can fix a region and
  retry), and `frame[20]` is the faulting guest address. For an instruction
  fetch/gate/bad-op fault it is the instruction word address.
- Gate failures and unpredictable opcodes vector as cause=2 only while the
  kernel ABI is active and the CPU is in guest mode. Otherwise they retain
  the legacy `!G`/`!O` halt behaviour.

`SVCRET` is valid only while `in_kernel=1`:
1. restore r0..r15 from frame[0..15];
2. `k = frame[17] & 3`; `pc = frame[16]`;
3. if `frame[19] & 3 == 0`, `r1 = frame[21]` (the SVC return);
4. clear `in_kernel`, both status pending bits and `halted`.

`SVCRET` in guest mode is an invalid op (`!O`). Executing SVC while already
in the kernel is an invalid op; the kernel calls internal code directly.

## 5. Kernel mode and region checks

**Normative clarification (loud):** the region table is the *guest-mode*
address space. A trap sets `in_kernel=1`; S1 suspends region translation
until `SVCRET` so the kernel can read/write the trap frame, TCB, page tables
and other address spaces. The kernel is the trusted S1 policy layer and must
validate every guest pointer it accepts. This keeps the frozen frame/port
encoding unchanged.

In guest mode S1 applies the region table to:
- instruction fetch: `X`;
- `LD`/`LDN`/`LDB`/`OUTSW`/`VLOAD`: `R`;
- `ST`/`STW`/`STB`/`BFILL`/`VSTORE`: `W`;
- `BSWAPM`: `R|W`; `BCOPY`: `R` on the source span and `W` on the destination.

Device/VRAM/vector-register operations are deliberately exempt because they
do not touch guest word memory: `VPOKE`/`VPEEK` (0x10/0x11), `DISP*`, `VSYNC`,
`FBCOPY`/`FBFILL`, the port family 0x3E-0x43, `PUTC`, `KEY`/`KEYQ`, `TICK`,
and 0x50-0x5F except `VLOAD`/`VSTORE`. The portable core also checks the
64-byte VLOAD/VSTORE span.

An invalid region-table pointer (one that cannot hold a 4-word entry) is a
configuration error `!K`, not a guest fault.

## 6. Region table

Table address = port 0x4E04. Each entry is 4 guest words:

```
{ base_word, nwords, kind, prot }
```

- `nwords == 0` terminates the table; scan also stops at the end of memory.
- `kind`: 0 = RAM, 1 = DEV. S1 treats it as informational and uses `prot`
  for access decisions; later device policy may tighten this.
- `prot` bits: 1 = R, 2 = W, 4 = X. An access must have every requested bit
  set in the entry that covers the address.
- Spans may cross adjacent entries with the same permission; a gap or a
  missing permission is a fault. The table itself is not translated and
  should live outside every user-mapped region (a hole) or in a sealed page.

## 7. Syscall numbers (append-only)

The S1 saves the number in `frame[20]`; it does **not** implement policy.
Later streams implement these in the NaN kernel and only append new numbers.

| # | call | arguments (r1..r4) | return (frame[21]) |
|---|---|---|---|
| 0 | yield | - | 0 |
| 1 | exit | code | does not return |
| 2 | region_map | id, base, words, kind | 0/-err |
| 3 | region_query | id, out_ptr | 0/-err |
| 4 | open | path, flags | handle/-err |
| 5 | read | handle, buf, len | bytes/-err |
| 6 | write | handle, buf, len | bytes/-err |
| 7 | seek | handle, off, whence | pos/-err |
| 8 | close | handle | 0/-err |
| 9 | spawn | path, args | pid/-err |
| 10 | wait | pid | status/-err |
| 11 | time | - | ticks |
| 12 | share | pid, region, perms | 0/-err |
| 13 | thread_create | entry, arg, stack | tid/-err |
| 14 | thread_join | tid | status/-err |
| 15 | thread_exit | code | does not return |
| 16 | mutex | op, id, timeout | 0/-err |
| 17 | cond | op, id, timeout | 0/-err |
| 18 | tls | index, value | old/-err |
| 19 | (reserved) | - | - |
| 20 | getpid | - | pid |
| 21 | getppid | - | pid |
| 22 | kill | pid, sig | 0/-err |

Numbers 0-18 and 20-22 are frozen; 19 is reserved. Sockets/loader calls
append after 22.

## 8. Timer

Port 0x4E02 is a count of completed guest instructions. At each instruction
boundary, if the timer is nonzero and the CPU is in guest mode, S1
decrements a remaining counter; at zero it reloads the interval, raises
`cause=1`, and vectors to the kernel entry. Writes to 0x4E02 reset the
remaining count. The timer never vectors from inside the kernel.

Status port 0x4E06 is `1` for timer pending and `2` for trap pending; both
bits clear on `SVCRET`. A trap is taken immediately, so the bits describe the
current kernel entry, not a queue. `TICK` (0x13) keeps its host-millisecond
meaning and is independent of this instruction timer.

## 9. Configuration errors

When a trap must be taken and `kentry` is UNSET/outside word memory, or the
frame is invalid, or `kstack` is outside memory, S1 halts with `!K<hex pc>`
instead of wrapping. The same applies to an invalid region-table pointer.
This is distinct from guest faults (`cause=2`) and from the legacy
`!G`/`!O` gate/op traps.

## 10. x86_64 S1 status and port points

This tree contains a concrete, buildable **ABI-mechanics slice** on the
primary target:

- `src/native64/s1_bootsec.S` - self-contained 512-byte boot fixture: loads
  64 KiB to 0x10000, A20, flat protected mode, jump to the S1 image.
- `src/native64/s1_boot.S` - 32-bit boot to long mode, identity-map page
  tables, 64-bit GDT/stack, `.bss` zeroing, COM1 comes from C.
- `src/native64/s1_kabi.c` - freestanding x86_64 S1: 64K guest words at
  0x200000, fetch/gate/predication, the integer/memory/port subset,
  SVC/SVCRET trap frames, timer vector, region checks, `!K/!G/!O`.
- `src/native64/s1_kabi.ld` - image at 0x10000 with an ASSERT that the
  image/BSS end below the live page tables at 0x30000.
- `tools/kabi64_gate.sh` - QEMU x86_64 boot with an exact COM1 transcript,
  a minimal boot fixture (no museum image / `mkall.sh` dependency), 128 MiB
  default (`KABI64_MEM` override), and explicit page-table/stack overlap
  checks on `__bss_end`.

The slice is **not** the full NaN16 core and not a guest cartridge loader:
it runs compiled-in ABI tests. It has no FP, vector, display, ATA, loader,
scheduler, Tcl or SQLite. The next x86_64 step is a guest word image loader
(sealed cartridge -> word memory) plus the complete op table; only then can
the tcc/SQLite path be claimed on x86_64.

Exact port points for the full `kan64` port:
- `x86/native/kan16.xa`: `loop:` (fetch/gate/predication), `tbl:` (opcode
  dispatch), `h_ld`/`h_st`/`h_ldb`/`h_stb`/`h_bcopy`/`h_bfill` (region
  checks), `h_outl` (control ports), and the `mem_size`/CPUID discovery.
- `src/native64/longmode.S`: proven long-mode/COM1 bootstrap.
- `src/native64/core64_body.S`: substrate that calls a NaN-emitted block;
  reuse its COM1 and long-mode setup, not its "no decode in native" policy,
  for `kan64`.
- `src/translate/x86_64.nas`: NaN-coded translator, not the S1.

`tools/qgate64.sh` remains the long-mode/4-level-mapping gate and is
unaffected by this ABI.

## 11. Conformance gates

- `tools/kabi_gate.sh` - C oracle (`make -s -C aarch64/android test`,
  including `tests/test_kernel_abi.c`) + x86_64 slice + assembler.
- `tools/kabi64_gate.sh` - exact x86_64 COM1 transcript.
- `tools/kabi_asm_gate.sh` - `INL`/`SVC`/`SVCRET` nmk emit, exact words,
  `CMD=check` round-trip and the NaN disassembler table.
