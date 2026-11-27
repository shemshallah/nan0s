# Memory64: maximum address space, mapped once

Status: design + gates.  This is the address-space contract for TB-scale
AI workloads.  The map is sized for the architectural maximum now; growing
from a 32-bit window later would touch every allocator, object and agent.

## Architectural maximum

| item | value | notes |
|---|---|---|
| physical address bits | 52 (4 PiB) | CPUID.80000008H:EAX[7:0], capped at 52 |
| virtual address bits | 57 (128 PiB) | 5-level paging / CR4.LA57 |
| 4-level fallback | 48-bit virtual (256 TiB) | no LA57; physical can still be 52-bit |
| largest page | 1 GiB | direct map uses this |
| page-table entry | 64-bit native | NaN shadow entries are (lo,hi) pairs |
| NaN pointer | (lo,hi) words | 64-bit byte address = word << 3 |

The product target is 5-level paging.  4-level is a fallback for older CPUs
and caps the *simultaneously mapped* direct map at 128 TiB (kernel half);
the physical limit is still whatever MAXPHYADDR reports.

## NaN address model

A NaN word is 8 bytes: a 32-bit payload plus class heads.  Pointers and
sizes are `(lo,hi)` pairs of 32-bit words and are 64-bit byte addresses
internally.  The legacy guest mapping is preserved:

```
word_index = (physical_byte - 0x200000) / 8
```

so every existing low address keeps its meaning.  The high half extends the
same direct map to the full physical range; no low address is renumbered.

## Virtual layout (57-bit)

```
0x0000_0000_0000_0000  user space (low canonical half, 64 PiB)
0xFF00_0000_0000_0000  direct map base (kernel, high canonical half)
0xFF10_0000_0000_0000  end of a 4 PiB direct map
0xFF20_0000_0000_0000  vmalloc / memory-object mappings
0xFF40_0000_0000_0000  per-core stacks, guard pages
0xFF80_0000_0000_0000  kernel text/rodata/data, fixmap, MMIO
```

The direct map is `phys` at `MEM_DIRECT_BASE + phys`, using 1 GiB pages.
Physical holes (VGA, firmware, MMIO) stay holes; they are mapped only when
the E820/ACPI map says they are usable, or explicitly for MMIO.

## Table budget

For 4 PiB with 1 GiB pages under 5-level paging:

- 4,194,304 leaf entries = 32 MiB of PDPTs (8192 tables);
- 16 PML4 tables = 64 KiB;
- one PML5 (shared root).

The full direct map therefore costs about **32 MiB of page tables** for
4 PiB.  That is the reason the max map uses 1 GiB pages, not 2 MiB or 4 KiB:
2 MiB pages would need 16 GiB of tables for the same range.

## Objects and capabilities

`nmem` objects are 64-bit `(base,size)` capability payloads.  A 2 TiB object
and a 1 TiB view are normal; bounds are checked as 64-bit `(lo,hi)` pairs.
Weights are read-only objects, KV/activation slabs are per-agent objects,
and checkpoint roots are sealed.  The native substrate maps/protects; the
NaN layer owns placement, eviction, generations and checkpoint policy.

## Gates

- `nmem_scale_gate.sh`: 2 TiB object, 1 TiB 64-bit view, bounds/rights/node.
- `mem64_gate.sh`: native 5-level tables, full 4 PiB direct map, 1 TiB
  mapping, 2 MiB/4 KiB pages, high-half read, max-physical rejection.

## Implemented native builder

`src/native64/mem64_boot.S` enters long mode with a PML5 when CPUID exposes
LA57, or a PML4 otherwise.  `src/native64/mem64.c` owns the table pool
(1 MiB..65 MiB), allocates 4 KiB tables, and maps 1 GiB / 2 MiB / 4 KiB
leaves.  The active root is the boot root at `0x30000`; the C layer extends
it and reloads CR3 after mapping.

`tools/mem64_gate.sh` on QEMU TCG with `-cpu max,la57=on,phys-bits=52` and
only 128 MiB of RAM proves:

```
MEM64 LEVELS=5 PHYS=52 VIRT=57
MEM64 TABLES=8214 MAP=0x0010010000201000 1G=4195328 2M=1 4K=1
MEM64 PASS
```

That is a full 4 PiB direct map (4,194,304 1 GiB entries, 8,214 tables),
plus a 1 TiB object range, one 2 MiB leaf, one 4 KiB leaf, a high-half read
through the active CR3, rejection of the first byte past MAXPHYADDR, and
rejection of a non-canonical virtual address.  The 128 MiB guest is enough
because only the tables are touched; non-present physical targets are never
dereferenced.

## Still required for production memory

- Feed E820/ACPI SRAT ranges into the builder instead of the synthetic
  full-physical test range; preserve holes and MMIO.
- Per-NUMA-node free lists for 1 GiB/2 MiB/4 KiB pages, 64-bit counts.
- `map`/`unmap`/`protect` calls from `nmem` capabilities, including
  read-only weight objects and per-agent KV slabs.
- 16 KiB per-core stacks with guard pages at 4096-core scale.
- Memory-object generations, sealed checkpoint roots, eviction/tiering,
  ECC/RAS, and hotplug.
