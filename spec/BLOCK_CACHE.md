# Block cache: translating nasm1/n16i instead of interpreting them

Status: implemented for the build path (2026-11-27).  The cache translates
nasm1 into native x86 blocks and `tools/xgold.sh` consumes it by default.
Multi-instruction basic blocks and a product-resident per-core cache are still
future work.

## Implemented layout

```
code base   0x2000000   one 512-byte slot per guest PC
mask base   0x2176000   one byte per PC: 0xFF = opcode 0 (unpredicated),
                        else the NaN header class mask (1=GT, 2=LT, 4=EQ, ...)
dispatcher  0x100000    multiboot 32->64-bit stub, 1 GiB identity page
```

`tools/blockcache_build.sh` compiles `src/prog/nasm1.nas`, extracts the full
`.raw` words (headers included), substitutes the word count into
`src/prog/nasm1_cache.nas`, runs the NaN translator under the reference VM,
and writes `nasm1.cache` plus `nasm1.masks`.  `src/native64/cache_body.S` is
the dispatcher: it loads `XPC` from 0x80D4, checks the mask against `FLAGM`
at 0x8040, calls the slot, then reads `XPC`/`HALT`/`TRAP`.  It never decodes a
NaN word.

The cache key covers `nasm1.nas`, the generator, `x64_block.nas`,
`x86_64.nas`, `abi64.nas`, `cache_body.S`, `cache.ld` and the builder.
`cache.sha256` binds the three runtime artifacts.  A stale or corrupted cache
fails closed instead of silently producing different GOLD.

Predication matters: the kernel skips any instruction whose header mask does
not intersect `FLAGM`; only opcode 0 (BOOL) is unconditional.  The mask table
reproduces that rule.  Starting `FLAGM` at zero is wrong; the kernel starts at
1.  These two details caused the first cache runs to jump through data.

## Measured

`tools/blockcache_gate.sh` rebuilds the cache twice (deterministic), then
assembles the 512-byte boot sector and the 12,368-byte `kan16.xa` kernel.  Both
are byte-identical to the source-derived GOLD.  Kernel time is about 11 s on
this host; `tools/xgold.sh` is about 16.5 s total, down from the 621 s raw
n16i path.

`cache.sha256` is a corruption check, not a signature.  The cache is a build
artifact; the checked-in GOLD is still independently witnessed by the raw n16i
slice in `source_gold_gate.sh`.  A product-resident cache will need a trusted
digest before it can replace the interpreter.

## Problem

`xgold.sh` runs nasm1 on the native 32-bit NaN core under QEMU TCG.  The full
`n16i` proof adds another interpreter layer:

```
QEMU TCG -> native core -> n16i (NaN) -> nasm1 (NaN)
```

The full-kernel path measured 621 s.  The source window was 64 KiB until
2026-11-27; it is now a 3.6 MiB arena, but widening the window does not remove
the interpreter cost.

## Target

Translate the NaN code once into x86-64 basic blocks, cache them, and execute
the cache natively:

```
QEMU TCG -> native cache loader -> cached x86-64 blocks
```

No NaN decode, gate, or class check on the hot path.  The block cache is
immutable and shared; it is keyed by the exact NaN code and translator
version.  A cache miss either re-translates (slow, build-time) or fails closed
with an explicit `!CACHE`.

## Cache image

```
header (64 bytes)
  magic "NBC1"  version  flags
  entry_pc      code_base    code_size
  table_off     table_count  code_sha256
  source_sha256 translator_sha256
code blob        (x86-64, position-independent relative to code_base)
table            (u64 offset, u32 size, u32 flags) indexed by guest pc
```

`code_base` is fixed by the loader (0x51000 initially).  The table is direct
indexed by guest PC; out-of-range or null entries trap.

## Translation

1. Decode the NaN image into basic blocks with an explicit terminator:
   `JMP`, `JMP[cond]`, `CALL`, `CALLR`, `RET`, `HALT`, `SVC`, `SVCRET`.
2. Call the NaN translator (`x64_block`) for each block; record consumed
   source words, emitted bytes and branch targets.
3. Enqueue fallthrough, branch and call targets; reject indirect targets that
   cannot be resolved statically (`JMPR`/`CALLR`) unless a runtime lookup stub
   is emitted.
4. Serialize the code blob + table + hashes.  Translation is deterministic.
5. The first translation is slow; subsequent builds load the cache by hash.

## Runtime

The native loader is mechanical:

- map/copy the cache code read-only/executable;
- map the NaN guest image and source into the fixed guest window;
- set XPC to `entry_pc` and dispatch:

```
loop:
  pc = XPC
  if pc >= table_count: trap
  off = table[pc]
  if off == 0: trap
  call code_base + off
  if HALT: stop
  goto loop
```

The block code uses the existing fixed register file/XPC/flags/vector ABI.
The loader does not decode guest instructions.

## Integration

- `tools/xgold_cached.sh` already caches the GOLD artifact by source hash.
- Add `tools/xgold_blockcache.sh` to build the cache once, then make
  `xgold.sh` consume it when `USE_BLOCK_CACHE=1`.
- `source_gold_gate.sh` verifies the cache against the raw translator output.
- The cache is committed only when the kernel/nasm1/translator key changes.

## Milestones

1. Artifact cache (done): source-keyed GOLD, no repeated slow rebuild.
2. Threaded one-instruction cache (done): every PC has a translated block and
   a predicate mask; boot and full kernel match GOLD.
3. Multi-instruction basic blocks: split at terminators and branch targets to
   amortize dispatch (queued).
4. Product-resident cache: load the cache in the native kernel and dispatch
   before the interpreter loop (queued; needs a trusted cache digest).
5. Dynamic cache miss/self-translation and eviction policy (queued).
