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
| emitted block page | `0x51000` |
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
CMP/CMPS, flags (FLAGM), set-XPC and RET.  Gates: `qgate64core` (42+42),
`qgate64block` (MOVI/ADD/MOVI/SUB -> 80), `qgate64alu`
(MOVI/MOVHI/ADDI/shifts/CMP -> 0x2000).  Next: CMOV/conditional branches,
memory, traps, then the full dispatcher.

## Bootstrap / self-hosting

The source of the core is NaN. The existing NaN toolchain (ncc/nasm1/translator)
builds the first executable core. Once the 64-bit NaN block core can translate
its own source, the native substrate remains only the boot/memory/EXECN layer.
The verified chain (NaN binary -> Binary TM -> Minsky UTM -> Coq) applies to
the emitted block and to the core itself.
