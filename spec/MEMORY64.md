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
