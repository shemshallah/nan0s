# Block cache: translating nasm1/n16i instead of interpreting them

Status: design.  This is the performance fix for the slow raw build path.

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
2. Basic-block splitter + translated cache for the 3-block qgate program.
3. nasm1 cache: translate its 2,992 words, load guest/source from IDE,
   reproduce the 512-byte boot GOLD slice.
4. Full-kernel cache and replace the xgold slow path by default.
5. Dynamic cache miss/self-translation and cache invalidation.
