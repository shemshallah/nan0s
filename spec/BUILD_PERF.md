# Build performance: nasm1, xgold and n16i

Status: measured notes, 2026-11-27.

## Why the source window was 64 KiB

`src/prog/nasm1.nas` used a fixed scratch map:

```
SRC   0x20000    input text (4 chars/word)
OUT   0x24000    emitted bytes
LAB   0x30000    labels
LONGB 0x31000    long labels
STACK 0x3F000
```

The gap `SRC..OUT` was 16,384 words = 65,536 text characters.  That was sized
for the small boot/kernel sources, not for a growing 64-bit kernel.  `kan16.xa`
reached 67,586 characters and crossed into `OUT`, so nasm1 read its own output
as source.  This was a layout limit, not an assembler algorithm limit.

The map is now:

```
SRC   0x20000
source arena 0x20000..0x100000   (about 3.6 MiB of text)
OUT   0x100000..0x140000         (1 MiB emitted bytes)
LAB   0x140000
LONGB 0x141000
STACK 0x1F0000
```

If the kernel source or output outgrows those bounds, nasm1 should move to a
caller-supplied arena or fail with an explicit size error.  Silent overlap is
not acceptable.

## Why the raw path is slow

The slow path is not a normal assembler run.  It is:

```
QEMU TCG -> native 32-bit NaN core -> nasm1 (a NaN program)
```

and the full `n16i` proof adds another layer:

```
QEMU TCG -> native core -> n16i (NaN) -> nasm1 (NaN)
```

nasm1 is a two-pass assembler with branch relaxation, written in NaN16.  Every
source character, token, label lookup and emitted byte is interpreted.  The
full-kernel `n16i` path measured **621 s** end-to-end; the 512-byte boot-slice
proof is about **36 s**.  The C `nan_cli` oracle runs the same nasm1 source in
roughly 32M NaN steps and is much faster, but it is a host test oracle, not the
product producer.

The algorithm is not accidentally quadratic; the cost is nested
interpretation plus QEMU TCG.  The raw path exists for source-derived GOLD and
self-hosting verification, not for every edit.

## What is fast

- A normal product build (`tools/mkall.sh`) consumes the checked-in GOLD and
  takes seconds; it does not run nasm1.
- A product boot reaches `NANIX SHELL READY` in about 5 s under QEMU.
- The translated 64-bit block path executes NaN-emitted blocks natively; that
  is the intended long-term replacement for the flat interpreter.

## Rules

1. Do not regenerate GOLD on every product build.  Use the checked-in GOLD;
   regenerate only when kernel source changes.
2. `xgold.sh`/`source_gold_gate.sh` are the raw, slow verification path.
   Keep them in release gates, not in the inner edit loop.
3. Development iterations may use the host `nan_cli` oracle only as a
   test bench.  It must never be the producer of a committed GOLD or product
   image.
4. The real speed fix is translating nasm1/n16i into NaN-emitted x86-64 blocks
   and caching them, or finishing the self-hosted block translator.  Native C
   is not the product answer.
