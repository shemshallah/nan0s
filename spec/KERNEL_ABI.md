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
| 0x4E07 | OUT/IN | `LDS`/`STS` window base word (power-on 0xF0000) |

Power-on values: every address port is `0xFFFFFFFF` (`NAN_KABI_UNSET`), the
timer is 0. The kernel ABI is **active iff 0x4E00 is not UNSET**. Before then,
0x4E and 0x4F keep their previous reserved-op trap behaviour, so old programs
do not change. `INL` itself is always a valid opcode.

Once the ABI is active, writes to ports 0x4E00-0x4E07 are kernel-only. A
guest-mode write vectors as `cause=2` with the port number in `frame[20]`
instead of reconfiguring the boundary. Boot code writes the ports before the
entry port activates the ABI; kernel code writes them with `in_kernel=1`.
Control-port reads remain available so a process can inspect status.

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
| 23 | load_image (appended) | image_ptr | pid/-err |

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
  the 64 KiB kernel window to 0x10000, optionally the guest payload to
  0x40000 (up to 768 KiB), A20, flat protected mode, jump to the S1 image.
- `src/native64/s1_boot.S` - 32-bit boot to long mode, identity-map page
  tables, 64-bit GDT/stack, `.bss` zeroing, COM1 comes from C.
- `src/native64/s1_kabi.c` - freestanding x86_64 S1: guest word memory at
  0x200000 sized by `--mem` (default 64K words in the KABI build), fetch/
  gate/predication, the integer/memory/port subset, SVC/SVCRET trap frames,
  timer vector, region checks, `!K/!G/!O`.
- `src/native64/s1_kabi.ld` - image at 0x10000 with an ASSERT that the
  image/BSS end below the live page tables at 0x30000.
- `tools/kabi64_gate.sh` - QEMU x86_64 boot with an exact COM1 transcript,
  a minimal boot fixture (no museum image / `mkall.sh` dependency), 128 MiB
  default (`KABI64_MEM` override), and explicit page-table/stack overlap
  checks on `__bss_end`.

The same `s1_kabi.c` also has a `-DS1_GUEST` build that loads and runs a
flat NaN16 cartridge (see 10.1). It is still **not** full op/device parity:
it has no FP/vector/display/ATA/CPUID/RDTSC/KEY/TICK, no filesystem loader,
no seal verification, and no scheduler. Tcl/SQLite cannot be claimed yet.

### 10.1 Flat guest cartridge contract (this S1 slice)

A cartridge is a headerless sequence of 8-byte guest words:
`[far head BE][payload LE32][near head LE]`. There is no `.nan` text parser
in the product image; the gate converts with nmk before linking.

- `tools/s1_guest_gate.sh` assembles with `tools/nmk.awk`, converts the
  words, and links the payload into S1 `.rodata`; the loader copies it to
  guest word 0 at runtime. The embedded image is bounded by the 64 KiB boot
  fixture and by `S1_GUEST_MEM` (guest word count, default `0x10000`).
- Reset state: `r0=0`, `r13=1`, `r14=S1_GUEST_STACK` (default
  `mem_words - mem_words/8`), `r15=0`, other registers 0, `pc=0`, `k=0`.
- Byte addressing is `byte = word_index*4 + lane`, identical to the C core
  `LDB`/`STB` (and `nan_cli`). `LD`/`ST` use word indices.
- `HALT` stops the interpreter with the defined status `NAN_HALTED` (3).
  The guest-visible terminal is COM1/PUTC only; machine status is written to
  QEMU debug console 0xE9 (`S1GUEST LOAD n WORDS`, `S1GUEST HALT rc=3 ...`)
  so COM1 can be compared byte-for-byte with the C oracle.
- Overrides: `S1_GUEST_MEM` (words), `S1_GUEST_STEPS`, `S1_GUEST_STACK`,
  `QEMU` (binary), `QEMU_MEM` (MiB).
- Op coverage in this build: BOOL, MOVI/MOVHI/LA, ADD/SUB/ADDI, SHL/SHR/SAR,
  CMP/CMPS, MUL/MULH/MULHU, DIV/MOD/DIVU/MODU, LD/ST/LDB/STB/LDN/STW,
  BSWAPM, JMP/JMPF/JMPR/CALL/CALLF/CALLR/RET, BCOPY/BFILL, PUTC, NOP, HALT,
  OUTL/INL, SVC/SVCRET, the scalar FP family 0x30-0x37/0x46-0x48, and the
  trap/region ABI above.
- FP contract: FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/CVTIF/CVTFI (0x30-0x37) and
  FEXP/FTANH/FLOG (0x46-0x48) use 32-bit IEEE floats in guest registers and
  the same NaN/zero-divisor/saturation rules as `aarch64/android/core/
  nan16.c`/OPS.md. The x86_64 build uses SSE2 (enabled in the boot stub) with
  `-ffp-contract=off -fno-fast-math`; there is no guest XMM register file,
  so no XMM state is saved/restored. exp/log/tanh are freestanding
  approximations with the same NaN/zero/negative edge behavior.
- Missing for full parity: vector 0x50-0x5F (implemented only when a real
  cartridge needs a specific op), display/keyboard/timer ops
  0x10-0x13/0x18-0x1B, CPUID/RDTSC 0x44/0x45, FBCOPY/FBFILL 0x3C/0x3D, and
  all devices/storage beyond the raw IDE cartridge read. The real NFS2 RAM
  test and the Tcl tclsh cartridge run today.

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
- `tools/kabi_sched_gate.sh` - timer-preempted two-process scheduler demo
  with per-process scratch windows; exact serial text on both engines.
- `tools/kabi_spawn_gate.sh` - process table, spawn/wait/exit lifecycle and
  round-robin scheduling; exact `12OK` on both engines.
- `tools/kabi_load_gate.sh` - allocate, copy, relocate and spawn a program
  image from a heap extent; exact `LOK` on both engines.
- `tools/s1_guest_gate.sh` - flat-cartridge acceptance: focused coverage,
  scalar FP, and real `src/tests/nfs2_test.nas`, x86_64 QEMU COM1 exactly
  equal to the C oracle; debug console reports loader word count/HALT.
- `tools/s1_big_guest_gate.sh` - >16 MiB (21,266,432-byte) flat cartridge;
  the guest sums every payload word against a host-computed constant and
  prints `BIG PASS`, proving the IDE large-image path is byte-exact.
- `tools/tcl_nan16_port_gate.sh` - product Tcl milestone 1: a 21,298,008-byte
  tcc0-built tclsh cartridge (SHA-256 `72bebb01...`) on the large IDE path,
  exact stdout `hello 42\n2\n`, main word 0x100 = 0, empty stderr; PASS with
  `TCL_NAN16_PORT_RUNNER=tools/s1_runner.sh` and no oracle flag.
- `tools/s1_runner.sh` - product gate CLI:
  `--img FILE [--mem MB] [--steps N] [--serial] [--guest-stdout FILE]
  [--guest-stderr FILE] [--peek 'ADDR[:LEN],...']`. It accepts nmk `.nan`
  text or flat word cartridges and runs it on the x86_64 S1. Two load paths:
  payloads <= 768 KiB use the boot fixture (LBA 129 -> physical 0x40000,
  up to 1536 sectors); larger payloads are attached as a raw IDE disk
  (`-drive if=ide,index=0`, LBA28) and read by the S1 ATA PIO loader
  directly into guest word 0. The 21.3 MB Tcl cartridge uses the large path;
  there is no 768 KiB cap on it. `--mem` follows nan_cli (MiB of guest C
  payload, power-of-two word count); QEMU defaults to 256 MiB and
  `S1_QEMU_MEM` / `QEMU` / `S1_QEMU_TIMEOUT` / `S1_GUEST_STACK` override it.
  Because the kernel image window is 64 KiB, the guest payload is a separate
  load segment, not `.rodata`; `S1_GUEST_SECTORS`, `S1_GUEST_DISK` and
  `s1_guest_bytes` are generated by the runner.
- Guest console ABI: the tcc libc writes the control block at guest byte
  0x03EFF000 (stdout ptr/len, stderr ptr/len). After HALT the S1 emits raw
  guest PUTC bytes, then the framed protocol
  `@@NAN16 SOUT <len>\n<bytes>\n@@NAN16 SERR <len>\n<bytes>\n`
  `@@NAN16 PEEK <8hex>\n...@@NAN16 END <rc>\n`. The wrapper writes the
  stdout/stderr files, prints peek words as `%08X`, and exits 0 only for a
  clean HALT (`END 3`); on budget exhaustion or a trap it writes no peek
  lines and exits nonzero, so gates cannot mistake a partial run for a pass.
  Time/steps are published at guest byte 0x03EFF010 (ms, steps low, steps
  high) every 1024 instructions, matching nan_cli.
