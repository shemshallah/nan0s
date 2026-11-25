# Process and memory model (S1 milestone)

This document records the first working process layer on top of the frozen
`spec/KERNEL_ABI.md` v0.1 boundary.

## 1. Address space

A process is a region table plus a saved trap frame. Each region entry is
`{ base_word, nwords, kind, prot }` and the table is terminated by
`nwords == 0`. The kernel is trusted: `in_kernel=1` suspends region
translation, so the kernel can read the frame, TCB, table and another
process's save area.

The demonstration process uses:

| span | words | permission | purpose |
|---|---|---|---|
| `0x00000..0x007FF` | 0x800 | R, X | user code |
| `0x00800..0x00FFF` | 0x800 | R, W | user data and stack |
| grant from SVC 2 | request | R, W | per-process heap |
| `0x01000..0x01FFF` | - | unmapped | kernel, frame, table |
| `0x02000..0x02FFF` | - | unmapped | kernel stack |

A fault is not automatically fatal. The kernel receives `cause=2`, the
faulting instruction in `frame[16]` and the guest address in `frame[20]`;
it may map a missing region and retry, or rewrite `frame[16]` to a recovery
label. `src/prog/kabi_proc_demo.nas` takes the second path to prove that an
unmapped kernel word is unreachable from the process.

## 2. MEMQ and nalloc

Memory is discovered with `CPUID` leaf `0x4E4D00FF`, subleaf 1 (guest word
count). The demo refuses to start below 0x48000 words, places the kernel heap
at word `0x40000`, and initializes `nalloc` over 0x4000 words.

`SVC 2` (`region_map`) is the first MEMQ syscall:

```
r1 = words
SVC 2
r1 = base_word, or 0
```

The kernel calls `nal_alloc`, writes a new region entry for the returned span
with `prot=R|W`, advances the table terminator, and returns the base in
`frame[21]`. The process cannot see the heap before the grant: `0x40000` is
outside its table until the SVC returns.

## 3. Control ports

The trap frame, kernel stack and region table are configured through
`OUTL` before the entry port activates the ABI. After that, guest writes to
0x4E00-0x4E06 fault; the kernel may still write them. This closes the obvious
escape where a process could point the entry port at itself or clear its
region table.

## 4. Conformance

- `tools/kabi_gate.sh` - C oracle plus x86_64 ABI-mechanics slice plus
  assembler/disassembler round-trip.
- `tools/kabi_proc_gate.sh` - assembles `kabi_proc_demo.nas`, runs it on the
  C core and on the x86_64 S1, and compares exact serial output:
  `MAPPED`, `FAULT`, `ISOLATED`, `OK`.
- `tools/s1_guest_gate.sh` - flat-cartridge parity for the implemented S1
  subset, including the host-test NFS2 cartridge.

## 5. Next boundaries

- One global region table and one trap frame are still enough for a single
  runnable process. Multiple processes need per-process frames plus a
  kernel context switch that swaps `0x4E01`, `0x4E04` and the TCB port.
- The `LDS`/`STS` window base is now control port `0x4E07` (default
  `0xF0000`). A kernel can therefore point each process at its own mapped
  64K scratch window while `nmk` keeps emitting window-relative offsets.
- Far code is already encoded by `JMPF`/`CALLF`; the remaining work is a
  loader that maps multiple code extents and selects a code base per process.
