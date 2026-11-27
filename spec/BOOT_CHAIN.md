# Boot chain and minimal host/guest boundary

Status: normative.  The product runtime chain contains no C, POSIX shell,
awk, filesystem or host syscall layer.  Those exist only in the build/test
tooling and must not be linked into the system.

## Runtime chain

```
BIOS
  -> 512-byte x86 boot sector (src/native/boot.s / kboot0.xa)
       loads the fixed image window and enters protected mode
  -> native NaN16 core (src/native/nan16_x86.nan / kan16.xa)
       decodes and executes NaN16 words, owns traps/regions/devices
  -> guest NaN16 image (src/nan/*.nan, assembled from .nas)
       kernel, scheduler, NANIX shell, objects, jobs; all raw NaN16
```

There is no host process, host libc, POSIX syscall, awk interpreter or C
runtime between the native core and the guest.  The native core is the only
host-side machine layer; the guest is the system.

`src/tests/native64/s1_kabi.c` and `tools/s1_runner.sh` are the x86_64 S1 **test
harness**.  They are never packed into `build/nan0s.img` and are not part of
the runtime boundary.

## What the linker may do

The image linker may only:

1. place the 512-byte boot sector at byte 0;
2. place the native core at its fixed image offset;
3. place the flat guest `.nan` words at their fixed offset;
4. write the guest word count/signature and zero-pad the floppy image.

It must not parse guest semantics, rewrite code, choose carts, depend on a
host filesystem at runtime, or invoke a C compiler.  Cart/TOC packing is a
build convenience, not part of the executed system.

## Build-time host tools

Current host-only tools (not runtime):

- `tools/nmk.awk` / `tools/nflat.awk` — assemble/flatten `.nas` to `.nan`.
- `tools/mkimg.awk` / `tools/mkall.sh` — pack boot + native core + guest.
- `tools/nmkfs.awk` / `tools/nmkfs.sh` — seed the NaNFS disk.
- `tools/rootfs_seed.sh` — turn committed `nanfs/` text into a `.nas` seed.

These are the remaining host POSIX/awk layer.  Replacing them is the
self-hosting step: use the raw-NaN16 `nasm0`/`nasm1` assemblers and keep only
a minimal concatenation/padding host tool.  Until then, the rule is enforced
by `tools/guest_raw_only_gate.sh` and `tools/boot_chain_gate.sh`; no host
artifact may leak into the guest trees or shipped image.

## Enforcement

`tools/build.sh` refuses `.c`, `.s`, `.S` or `.o` in the product guest dirs.
`tools/guest_raw_only_gate.sh` checks carts and images for non-NaN input.
`tools/boot_chain_gate.sh` checks the shipped image's boot signature, no ELF
payload, the native gold core, and that no C harness is referenced by the
product build.  `tools/native_product_boot_gate.sh` boots the shipped floppy
through the native boot sector and NaN16 core on qemu-system-i386 and requires
the `NaN/0S` banner, with no S1/C harness in the loop.

## Next boundary work

1. Replace the host `mkimg.awk` cart/TOC packer with a minimal linker whose
   only job is boot + native core + guest concatenation/padding.
2. Move `.nas` flattening/assembly to `nasm0` under the native core so the
   host only starts the core and hands it the source image.
3. Keep `s1_kabi.c` and `nan_cli` as oracles only; any product acceptance
   claim must come from the native core/QEMU boot, not the C harness.
