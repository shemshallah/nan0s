# NaN/0S

NaN/0S is a raw-NaN16 machine: a 512-byte boot sector, one small native
NaN16 core, and a guest image written entirely in `.nas` / `.nan` words.
There is no host operating system, libc, POSIX runtime, C compiler or ELF
object between the boot sector and the system.

The product system is now the flat scheduler image:

```
BIOS
  -> 512-byte boot sector
  -> native NaN16 core
  -> guest .nan image
       PID 1  GUI desktop (word 8192)
       kernel + scheduler (word 0x10000)
       NANIX shell (word 0x80000)
```

## Current target

The product core is moving to **x86-64 long mode**.  The NaN16 guest ISA and
its 32-bit payload words stay unchanged; the native core uses 64-bit host
registers, pointers and RAM, and `nasm0` / `nasm1` / the NANIX shell run on
that core.  The existing 32-bit protected-mode core is retained only as a
bootstrap/reference until the long-mode core and its `nasm1` emitter are
complete.

## Build

```sh
sh tools/build.sh
```

This produces:

- `build/nan0s.img` — flat scheduler image: 512-byte boot, 64 KiB kernel
  window, then the full guest word image.  There is no cart TOC and no
  1.44 MiB truncation.
- `build/base.img` — bootstrap input for the raw assembler proofs.

The guest is packed from `src/gui/gui_sched_boot.nas`; the desktop is
`src/gui/gui_cart.nas`, the NANIX shell is `src/nix/nixsh.nas`, and the
kernel/scheduler are `src/lib/nankernel.nas` + `src/lib/nansched.nas`.

`src/trust/trust_cart.nas`.  It will be converted after the 64-bit core.

## Runtime boundary

`tools/boot_chain_gate.sh` and `tools/native_product_boot_gate.sh` enforce
that the shipped runtime is BIOS -> boot sector -> native core -> guest
`.nan`, with no C harness or ELF payload.  The C core under `aarch64/android`
and `src/native64` is an oracle/test bed only, never the product runtime.

## Status

- Native KABI v0.1 (`INL`, `SVC`, `SVCRET`, ports `0x4E00..0x4E07`, trap
  frames, instruction-count timer) is implemented in the 32-bit core and
  enters the scheduler.
- The scheduler picks PID 1 and restores its frame; the desktop entry and
  the shell entry are the current bring-up point.
- The product boot chain is gated; the 64-bit long-mode port is the next
  milestone.
