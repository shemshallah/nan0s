# Native x86-64 browser target

The previous v86 player uses an i386 hardware runtime. Upstream v86 does not
implement x86-64 long mode. The experimental player uses a pinned v86_64 fork,
commit `c394574477b57eadfc859f593b4aecb08fa37cb6`.

- `tools/build_wasm64.sh` rebuilds the normal system, extracts its complete
  NaN-word payload, and packages it with the existing S1 x86-64 boot fixture.
- The floppy contains S1; the IDE disk contains the actual system word image.
  This is not the original legacy floppy relabeled as a 64-bit image.
- S1 indexed VRAM is read at physical 0x11000000. The host uses the guest's
  source palette; it does not reconstruct native widgets.
- Raw NaN mailbox at word 0xE8000 carries guest readiness, dimensions, and a
  256-byte host-to-guest PS/2 ring. Both the existing keyboard driver and
  native click dispatch consume it. There is no new C kernel code.
- Browser mode uses 512 MiB emulated physical RAM and 64 MiB of C payload
  space, keeping the S1 VRAM outside the guest's NaN-word arena.
- The normal URL selects 64-bit only when the browser acceptance gate has
  published a verified manifest. Use `?arch=32` to retain the old player.

The S1 port is not full device parity: its existing ATA/PS2, graphics pixel
read, timing, and other services have limitations. The 64-bit browser gate
requires actual rendered framebuffer colors, a guest terminal response to
keyboard input, and a guest Settings window response. It does not certify
self-replication, full C editor, native PS/2 drivers, or all applications.
