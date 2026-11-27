# Custom NaN ABI (n16i runtime)

Status: v0.1, implemented by `src/tools/n16i.nas`; not the S1 KABI.

The system ABI is carried in NaN words.  `n16i` emulates it in NaN16, so the
ABI is part of the NaN ISA layer rather than a native kernel interface.

## Control words

The kernel configures the runtime through the port-encoded control words
`0x4E00..0x4E07` (the encoding is retained for the existing kernel source):

| word | field |
|---|---|
| 0x4E00 | kernel entry word |
| 0x4E01 | trap-frame word |
| 0x4E02 | timer interval in guest instructions |
| 0x4E03 | kernel stack word |
| 0x4E04 | region table word |
| 0x4E05 | current TCB word |
| 0x4E06 | status |
| 0x4E07 | LDS/STS window base |

`n16i` keeps these fields in NaN words and handles `OUTL`/`INL` itself.
Writes are allowed during boot and from kernel mode.  The kernel writes
`0x4E00` last.

## Trap frame

`SVC imm` / `SVCRET` use 24 guest words:

```
[0..15]  r0..r15
[16]     pc after SVC / resume pc
[17]     flags (2Z+L)
[18]     0
[19]     cause: 0 SVC, 1 timer
[20]     SVC number
[21]     return/status
[22]     guest SP
[23]     0
```

On `SVC`, `n16i` saves the guest registers, sets `r14` to the kernel stack,
enters kernel mode and jumps to the kernel entry.  `SVCRET` restores the frame,
sets `r1` from the return word for SVC, and resumes.

## Timer

When a timer interval is set, `n16i` counts guest instructions.  On expiry it
saves a cause=1 frame and enters the kernel.  The kernel's `SVCRET` resumes the
interrupted instruction.

## Program counter and windows

`n16i` uses a 24-bit guest PC and supports `JMPF`/`CALLF`, so the scheduler's
kernel (`0x10000`), shell (`0x80000`) and high process tables are reachable.
The guest window is `[0, mask]`, supplied by the boot stub.  Guest `CPUID`
magic `0x4E4D00FF`, subleaf 1, returns `mask + 1`, not the host word count.

## Runtime placement (next integration)

The native core bootstraps `n16i` as the first NaN guest:

```
system image      word 0 .. mask       (scheduler)
n16i runtime      word 0xF00000 ..     (stub + n16i + NaN stack)
native core       x86-64 substrate only
```

The native ATA loader reads two segments: the system image at LBA 129 and the
n16i runtime after it.  The system window is `0xEFFFFF` (15 Mi words), leaving
`0xF00000` for the n16i runtime.  `n16i` interprets the system with `GB=0`.

## Gates

- `tools/n16i_kabi_gate.sh` — bare n16i SVC/SVCRET/control-word test (`GKOD`).
- `tools/ngate_n16i.sh` — native vs n16i differential for the ISA core.
