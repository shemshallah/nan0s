# NaN-coded 64-bit core

## Rule

The core is NaN-coded. Native x86-64 is limited to the mechanical substrate:

- boot, GDT, IDT, page tables, long-mode switch
- physical/linear memory access and page mapping
- port I/O, CPUID, RDTSC, MSRs
- copying the NaN-emitted block to an executable page, calling it, and
  reading back the architectural register file

Instruction selection, decoding, block formation, register allocation and
x86-64 encoding are **NaN code** (`src/translate/*.nas`). The native layer does
not know the guest ISA and never decodes a guest instruction.

## Fixed 64-bit ABI

| item | address |
| --- | --- |
| guest register file (16 x u32) | `0x50000` |
| XPC | `0x50800` |
| emitted block pages | `0x51000`, `0x52000`, `0x53000` |
| page tables | `0x30000-0x33fff` |
| C stack (native call) | `0x1F0000` |

The emitted x86-64 uses SIB absolute `disp32` addressing, e.g.
`C7 04 25 04 00 05 00 2A 00 00 00` = `mov dword [0x50004], 42`.

## Proof in tree

`tools/qgate64core.sh`:

1. runs the NaN translator (`src/tests/xlate64_test.nas` +
   `src/translate/x86_64.nas`) on the C reference;
2. extracts the emitted bytes;
3. embeds them into the native substrate (`src/native64/core64_body.S`);
4. boots `qemu-system-x86_64`, copies the block to `0x51000`, zeroes the
   register file, calls it, and prints r1;
5. requires `NAN64 CORE 00000054 OK` (42+42=84).

Current NaN encoder coverage: MOVI, MOVHI, ADD, SUB, ADDI, SHL, SHR, SAR,
CMP/CMPS, FLAGM, JMP[cond], LD/ST, LDB/STB (word/byte guest memory at
G=0x200000 with the mask at 0x50404), set-XPC, HALT, RET, JMPR, CALL,
CALLR, NOP, BOOL, MUL/MULH/MULHU, DIV/MOD/DIVU/MODU, FADD/FSUB/FMUL/
FDIV/FSQRT/FCMP/CVTIF/CVTFI.  Gates:
`qgate64core`, `qgate64block`, `qgate64alu`, `qgate64branch`,
`qgate64mem` (0x12345678), `qgate64byte` (0xAB), `qgate64call`
(CALL/RET across blocks, r1=16), `qgate64mul` (MUL/BOOL/MULHU, r1=0x2D),
`qgate64div` (signed/unsigned DIV/MOD with zero divisors, r1=0x37),
`qgate64fp` (FP quartet/sqrt/cvt/cmp, XPC=0x200) and `qgate64fpe`
(0/0, sqrt(-1), +-inf conversions, r1=0x2D).

## Multi-block dispatch

`tools/qgate64prog.sh` translates a three-block program:

```
PC0: MOVI r1,0 ; MOVI r2,3
PC2: ADDI r1,r1,1 ; CMP r1,r2 ; JMP[LT] 2
PC5: HALT
```

The wrapper embeds the three NaN-emitted blocks and a mechanical table of
`(guest pc, code address)` qwords.  `src/native64/core64_dispatch_body.S`
scans that table for the current XPC, calls the matching block, and stops when
the block sets the halt flag at `0x50C00`.  The substrate never inspects a
guest instruction.  Expected result: `r1=3`, `XPC=5`.

Two bugs found by the multi-block gate and fixed in the NaN driver:

- `xb_ended` was both the branch join label and the flag slot, so branches
  jumped into data and re-entered the harness.  The flag slot is now
  `xb_endflag`.
- a conditional branch's fallthrough used the translator's source pointer + 1
  instead of the guest's declared next PC; it now uses `@xb_next`.

`qgate64call` adds a second lesson: a block may set XPC *backwards* (RET), so
the native dispatcher must rescan the table from its base after every block
rather than continuing from the matched entry.  Block images are copied in
2 KiB pages, so a block is no longer limited to 512 bytes.

Division is branchless: a zero or -1 divisor is replaced by 1, the
architectural result is selected with `cmov`, and `k=3` is forced when the
divisor is zero.  This avoids x86 #DE without a native helper.

Scalar FP uses SSE (`addss`/`subss`/`mulss`/`divss`/`sqrtss`,
`cvtsi2ss`/`cvttss2si`, `ucomiss`) with branchless post-checks matching the
reference: div-by-zero and negative-sqrt NaNs become `0x7FC00000`, CVTFI
clamps to INT_MAX/INT_MIN and maps NaN to 0, and FCMP forces `k=3` for
unordered operands.  The substrate sets CR4.OSFXSR/OSXMMEXCPT and clears
CR0.EM so SSE is usable in long mode.

Next: LDN/STW/BSWAPM, BCOPY/BFILL, traps, scalar FP, the vector families,
a guest loader that preserves NaN header predicates, and self-hosting.

## Bootstrap / self-hosting

The source of the core is NaN. The existing NaN toolchain (ncc/nasm1/translator)
builds the first executable core. Once the 64-bit NaN block core can translate
its own source, the native substrate remains only the boot/memory/EXECN layer.
The verified chain (NaN binary -> Binary TM -> Minsky UTM -> Coq) applies to
the emitted block and to the core itself.
