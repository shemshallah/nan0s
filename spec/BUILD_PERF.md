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

## Block cache (implemented 2026-11-27)

The build path now translates nasm1's compiled words once into native x86
blocks and executes them directly:

```
QEMU TCG -> native cache dispatcher -> cached x86 blocks
```

No NaN fetch, class gate, predicate check or opcode dispatch happens per
instruction.  The translator is still the NaN-native `x64_block`; its output
is cached by a key over `nasm1.nas`, the translator and the dispatcher.

Measured on this host:

| step | time |
|---|---:|
| cache build (one-time, 2,992 words + masks) | 3.3 s |
| boot sector assembly through cache | 3.7 s |
| full `kan16.xa` kernel through cache | 10.9 s |
| `tools/xgold.sh` (boot + kernel + GOLD text) | 16.5 s |
| `tools/source_gold_gate.sh` end-to-end | 76.6 s raw n16i slice included |

The cache output is byte-identical to the checked-in GOLD (512-byte boot and
12,368-byte kernel).  `tools/blockcache_gate.sh` rebuilds the cache twice and
verifies determinism plus both byte streams.  Set `USE_BLOCK_CACHE=0` to force
the old raw native-kernel path.

Four real semantic bugs surfaced while wiring the cache:

1. The initial word table kept payloads only.  NaN headers carry the
   predicate class, so every instruction looked like class 10 and every
   `JMP[EQ]` was false.  The table now preserves full `.raw` words.
2. Predication is not jump-only: the kernel skips any instruction whose
   header mask misses `FLAGM`.  A per-PC mask byte now makes the dispatcher
   skip without entering a block (0xFF marks opcode 0, which is unpredicated).
3. The dispatcher must start with `FLAGM=1`, as the kernel does.  Starting at
   zero skipped `MOVI r13,1`, so the guest stack and every increment stayed 0.
4. The n16i slice passed a 256 KiB word mask while nasm1's output starts at
   word 0x100000 and stack at 0x1F0000.  Every high address wrapped and the
   interpreter looped.  The slice now passes the 8M-word host mask.

## What is fast

- A normal product build (`tools/mkall.sh`) consumes the checked-in GOLD and
  takes seconds; it does not run nasm1.
- A product boot reaches `NANIX SHELL READY` in about 5 s under QEMU.
- `nhost` self-hosts on the raw native core in 17 s (no `nan_cli`); the full
  530,842-word native guest run is ~30 min and stays an opt-in proof.
  Measured on this host: the native interpreter retires ~1.33M NaN16
  steps/s, and the full guest is 2.257B steps (~28 min).  `nan_cli` retires
  ~66M steps/s (34 s), so it remains the bootstrap default.
- `tools/nhost_emit_guest.sh NHOST_NATIVE=1` runs the complete stage0 ->
  stage1 -> guest chain natively; the two self-host stages take ~46 s.
- A GOLD rebuild through the cache takes seconds, not minutes.
- The translated block path executes NaN-emitted blocks natively; the current
  cache is the build-path version, and the product-resident per-core cache
  remains future work.

## Rules

1. Do not regenerate GOLD on every product build.  Use the checked-in GOLD;
   regenerate only when kernel source changes.
2. `xgold.sh` uses the block cache by default; `USE_BLOCK_CACHE=0` selects the
   raw native-kernel path.  `source_gold_gate.sh` still proves the raw n16i
   slice and the checked-in GOLD, so the cache is never the only witness.
3. Development iterations may use the host `nan_cli` oracle only as a
   test bench.  It must never be the producer of the committed GOLD.  The
   guest may be emitted by the self-hosted `nhost` under `nan_cli` as a
   bootstrap (`NHOST_BUILD=1`), but only when the hermetic nmk path produces
   the same word stream and `nhost_product_gate`/`noc_product_gate` verify the
   packed image byte-for-byte.  The default product build stays hermetic until
   nhost runs on the native core.
4. The real speed fix is translating nasm1/n16i into NaN-emitted x86-64 blocks
   and caching them, or finishing the self-hosted block translator.  Native C
   is not the product answer.  The build-path cache is the first shipped step;
   multi-instruction blocks and a product-resident cache remain queued.
