# Boot memory map ABI (MEMMAP v1)

Status: coordination contract for the 16 GB PAE and memory-types workstreams.
Producers write this block before guest code runs; consumers must read it
before placing the scheduler, heap or any loaded image.

## Location

Guest **word** address `0x3F800` (below the default nanproc table).  The block
is 260 words, enough for 64 four-word entries.  It is above the 64K cart code,
GUI stacks and the runtime pointer words, and below `0x40000`.

```
+0   magic        0x4D454D50        ("PMEM" in the word's payload)
+1   entry_count  0..64
+2   version      1
+3   flags        bit0 = E820 source, bit1 = synthetic source
+4   entries[0]   { base_word, nwords, kind, flags }
...
```

Entry `kind`:

| kind | meaning |
|---:|---|
| 1 | usable RAM |
| 2 | reserved / firmware |
| 3 | ACPI reclaim or NVS |
| 4 | device / MMIO hole |
| 5 | VRAM / DEV window |

`flags` is reserved for now (0).  Entries are guest word ranges, not physical
byte ranges: `base_word = (physical_start - G) / 8` where `G = 0x200000`, and
`nwords = (physical_end - physical_start) / 8`.  Clamp entries below `G` and
drop zero-length entries.  A 16 GB machine is 2^31 words and still fits in
the 32-bit word field.

## Producer rules

- **S1 C core**: write one synthetic usable entry `{0, MEM_WORDS, 1}` plus
  the source flag; it may also emit a device entry for VRAM.
- **native `kan16.xa`**: copy the E820 type-1/2/3/4 ranges, clipped to guest
  RAM, in ascending order.
- **PAE 16 GB kernel**: same entries, with word counts spanning every bank.
- The entry count and terminator must be visible before the guest entry PC.
- Never place usable entries across a hole; split at E820 boundaries.

## Consumer rules

- Scheduler state, nanproc and kernel stacks must sit inside the **highest
  usable entry**, with guard pages.
- Heap allocation must walk a list of usable entries; it may not cross a
  reserved/device hole.
- Loader regions and `SVC 2` grants must come from usable entries only.
- If no map is present, fall back to the legacy single range
  `{0, MEMQ_words, 1}`.

## Gates

- `tools/memmap_gate.sh`: synthetic S1 map, map magic/count/kinds, scheduler
  inside the top usable entry, and an allocation that refuses a hole.
- 16 GB PAE gate: QEMU with a large-memory E820 map; verify all banks and the
  guest map entries.  Locally the host has <4 GB RAM, so the 16 GB run belongs
  on a high-memory CI runner; a 4 GB QEMU run is the local correctness gate.
