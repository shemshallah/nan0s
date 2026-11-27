# NaN/0S task list

## P0 — 64-bit long-mode core

- Port the native NaN16 core and boot from 32-bit protected mode to x86-64
  long mode (64-bit host registers/pointers, NaN16 guest ISA unchanged).
- Add `.code64`, 64-bit registers, REX prefixes, 64-bit push/pop and the
  long-mode system instructions to `nasm1`; regenerate the core with
  `nasm1`/`xgold`.
- Add a single-image boot path: BIOS -> 512-byte boot -> long mode -> core
  -> guest, with no floppy/IDE split.
- Bring up `nasm0`, `nasm1`, the NANIX shell and the scheduler on the
  64-bit core.

## P0 — scheduler/desktop bring-up

- The scheduler restores PID 1's frame (`cart_entry`) but the entry has not
  yet executed on the 32-bit reference; verify the initial fetch and timer
  handoff.
- Once PID 1 runs, verify the NANIX shell (`nx_main`) and Terminal dispatch.
- Keep the KABI gate/transcript on the 64-bit S1 oracle in sync.

## P1 — Trust conversion

- Convert `src/trust/trust_cart.nas` to the scheduler/flat-image ABI.
- Add a Trust gate that runs the converted cart on the product core.

## P1 — loader and build

- Replace the remaining host `sh`/`gawk`/`xxd` image packers with the
  minimal linker + `nasm0`/`nasm1` path.
- Update `tools/boot_chain_gate.sh`, `native_product_boot_gate.sh` and
  `guest_raw_only_gate.sh` for the 64-bit image format.
- Remove legacy 32-bit build paths after the long-mode core passes.

## Done

- Flat scheduler image is packed without a cart TOC and no longer truncated
  to a floppy.
- Native KABI v0.1 added to the 32-bit core (ports, SVC/SVCRET, trap frame,
  timer).
