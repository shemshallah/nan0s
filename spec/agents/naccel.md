# naccel — F10 accelerator boundary

Status: **implemented and gated** (`tools/naccel_gate.sh` emits exactly `O`).

This is an **emulated software boundary**, not a claim of real GPU, PCIe or
IOMMU support.  It provides the policy and accounting layer a native driver
would program: per-device IOMMU domains with 64-bit IOVAs, a DMA descriptor
ring, a software copy/GEMV device, and a 64-bit VRAM/BAR model with explicit
CPU fallback.  No C was added.  `nan_cli` is the host oracle only.

## Files

| file | role |
|---|---|
| `src/lib/niommu.nas` | IOMMU domains, 64-bit IOVA shadow map, R/W/X checks, epochs, generation/revocation, fault records |
| `src/lib/naccel.nas` | caller-supplied DMA ring, software copy/GEMV, VRAM bitmap, model/KV placement and fallback |
| `src/tests/naccel_test.nas` | proof image; prints exactly `O` |
| `tools/naccel_gate.sh` | emit/check, layout checks, two deterministic runs, exact one-byte `O` |

No existing shared library was modified.  `niommu.nas` owns guest words
`0x360000..0x361BFF` (domain table plus shadow map) and the last-error word
`0x6E00`.  An image that links the boundary must keep its own code/data clear
of those words.  The test puts code below word `0x4000`, byte-addressed DMA
buffers at `0x10000..0x16FFF`, ring/VRAM contexts at `0x6000..0x6700`, and the
stack at `0x8F00`.

## IOMMU domain

Domain table: 8 records x 64 words at `0x360000`.

```
+0  magic "NIOM"        +1  version 1
+2  domain id 1..8      +3  device id
+4  state (1 live)      +5  domain generation
+6  invalidation epoch  +7  live map count
+8  fault count         +9  last fault code
+10 last iova_lo        +11 last iova_hi      +12 last fault epoch
+16..31 four 4-word fault records: code, iova_lo, iova_hi, epoch
```

Shadow map: 8 domains x 32 entries x 12 words at `0x361000`.

```
+0 state  +1 map id 1..32
+2 iova_lo +3 iova_hi +4 size_lo +5 size_hi
+6 phys_lo +7 phys_hi
+8 rights (1 R, 2 W, 4 X)  +9 domain generation snapshot  +10 flags
```

Rules enforced by `niom_map`/`niom_rebind`/`niom_translate`:

- IOVA, physical and size are 4 KiB aligned; size is nonzero.
- `end = base + size` is a 64-bit `(lo,hi)` add.  Carry is `EOVER`, never a
  truncated mapping.  Physical-end carry is rejected too.
- Live ranges are half-open and may not overlap in one domain (`ESPACE`).
- Rights must be a nonzero subset of 7; `W|X` is rejected with `ERIGHT`.
- Translation must be covered by **one** live entry with the domain-generation
  snapshot and a rights superset; partial coverage is `ENOENT`.
- `map`, `unmap`, `rebind`, `revoke` and `destroy` bump the invalidation
  epoch.  `revoke` and `destroy` also bump the generation and clear all maps.
- Faults append to the 4-entry ring and update the last-fault words; the last
  code is also in `NIOM_G_ERR` / `niom_errno`.

`niom_map` returns a map id on success and `0` on rejection with the exact
code in `niom_errno`.  `niom_translate` returns `0` or the exact code
(`ENOENT`, `ERIGHT`, `ESTALE`, `EOVER`, ...).

## DMA ring and software device

Ring context (24 words, caller supplied):

```
+0 magic "NACC"  +1 version 1
+2 descriptor base +3 slots 1..64
+4 issued +5 reaped +6 pending
+7 domain +8 generation snapshot
+9 last fence sequence +10 last reaped fence
+11 error count +12 last error
+14 maximum copy bytes (64 KiB)
```

Descriptor (16 words):

```
+0 state 0 free 1 queued 2 done 3 error 4 cancelled
+1 sequence
+2 src iova_lo +3 src iova_hi
+4 dst iova_lo +5 dst iova_hi
+6 len_lo +7 len_hi
+8 flags (bit0 FENCE, bit1 GEMV) +9 op (1 copy, 2 GEMV placeholder)
+10 domain +11 generation snapshot +12 status +13 fence sequence
```

`nacc_submit` snapshots the live domain generation and fails closed with
`NA_LASTERR` after revocation.  `nacc_complete` reaps strictly in submission
order and **stops after reaping a FENCE descriptor**, so work submitted after a
barrier cannot become visible before it.  `nacc_fence` returns `EBUSY` until
the most recent fence has been reaped.  `nacc_cancel` marks a queued
descriptor `cancelled`; it is still reaped in order, so the ring cannot skip a
generation.  A full ring is rejected even when the head descriptor was
cancelled.

A copy translates src with `R` and dst with `W`, then copies byte-exactly
through the mapped physical addresses.  The GEMV flag uses the same IOVA path
to compute one exact integer MAC placeholder:

```
acc = sum(3*b[i] + 1)        # 64-bit little-endian result written to dst
```

Descriptor status uses the IOMMU code space (`ENOENT`, `ERIGHT`, `ESTALE`,
`EOVER`) plus `ECANCEL` and `EIO`.  The emulated copy requires the translated
physical byte address to be below 4 GiB and lengths at most 64 KiB; otherwise
it fails closed with `EOVER`/`EIO` rather than truncating.

## VRAM, BAR and placement

VRAM context (32 words, caller supplied):

```
+0 magic "VRA1" +1 version 1
+2 bar_lo +3 bar_hi +4 size_lo +5 size_hi
+6 granule +7 total units_lo +8 total units_hi
+9 bitmap +10 bitmap words
+11 used units_lo +12 used units_hi
+13 allocs +14 frees +15 VRAM placements +16 host placements
+17 fallback: exhausted +18 fallback: unmapped BAR
+19 failures +20 policy +21 last error
```

The allocator is a deterministic first-fit bitmap over `granule` units.  Sizes,
BARs, offsets and accounting are 64-bit; the bitmap model caps live units at
`2^32` and rejects larger geometries with `ESPACE`.  `nacc_vram_free` is
range-addressed and verifies every bit before clearing it, so a double free or
an unallocated range is `ENOENT`.

Placement record (8 words): `tier` (0 host, 1 VRAM), `offset_lo`, `offset_hi`,
`units_lo`, `units_hi`, `bytes_lo`, `bytes_hi`, `kind` (1 weight, 2 KV,
3 activation).  Weights and KV try VRAM first (policy bits 1 and 2, default
both); activations are host-only.  A VRAM allocation is translated through the
IOMMU for the whole request before it is accepted.  If the BAR is unmapped, the
allocation is rolled back and the caller gets `tier=host`; exhaustion also
returns `tier=host`.  Both paths increment separate fallback counters, so there
is no silent truncation or hidden tier switch.

## Proof

The gated image proves, in one deterministic run:

1. Domain creation for devices `0x1234`, `0x5678`, `0x9ABC`; a duplicate live
   device is rejected.
2. Seven DMA-domain maps at IOVAs above 4 GiB with `R`, `RW`, `W` and `RW`
   rights; the epoch is exactly 8 after the maps.
3. Rejection cases: overlap `ESPACE`, unaligned `EALIGN`, top-of-space wrap
   `EOVER`, `W|X` `ERIGHT`, zero size `EBAD`, and duplicate device `EBAD`.
4. Three submissions: copy, copy with FENCE, post-fence copy.  Before
   completion `nacc_fence` is `EBUSY`.  The first `nacc_complete` returns 2 and
   stops at the fence: dst and dst2 hold the exact 64-byte pattern while dst3
   is still `0x77`.  The second completion returns 1 and dst3 becomes exact.
5. Cancel: a queued copy is reaped as `cancelled` / `ECANCEL`, dst is
   unchanged, and the next copy still completes.
6. A DMA to an unmapped IOVA completes with `ENOENT`; a DMA whose source is a
   write-only mapping completes with `ERIGHT`.
7. GEMV placeholder over bytes `1,2,3,4` writes the exact 64-bit value `34`.
8. Unmap of the 4 GiB source mapping makes direct translation and a queued DMA
   fail `ENOENT`.  Remapping then rebinding to 28 GiB makes the old IOVA fail
   and the new IOVA translate to the same physical page; a DMA succeeds.
   The epoch is exactly 11 after unmap + remap + rebind.
9. Revoke bumps the generation, clears maps and makes the old generation
   `ESTALE` (direct and queued DMA) and the new generation `ENOENT`.  New
   submissions fail closed with `NA_LASTERR = ESTALE`.  The fault count is 8
   and the 4-entry ring retains the last four exact faults, including the
   queued stale-generation DMA.
10. Large VRAM: 2 TiB BAR, 64 MiB granule, 32768 units.  32 GiB of weights go
    to offset 0; 2 GiB of KV goes to 32 GiB (`offset_hi = 8`).  Accounting is
    544 units and 34 GiB (`used_lo = 0x80000000`, `used_hi = 8`).
    Activations are host-only.  Freeing KV and weights returns used units to 0.
11. Unmapped-BAR placement with a free VRAM context uses domain 0, allocates,
    fails translation, rolls the allocation back, records one unmapped
    fallback and one host placement, and leaves used units at 0.
12. Small VRAM: 4 x 64 MiB units.  Three units of weights fit at 0; a two-unit
    KV request is exhausted and falls back to host with one exhaustion counter.
    A direct one-unit allocation gets the last unit at 192 MiB; a two-unit
    request is `ENOSPC`; a double free is `ENOENT`; a misaligned free is
    `EALIGN`; freeing the weights restores four free units.
13. Ring capacity: a fresh 4-slot ring on domain 2 accepts exactly four queued
    descriptors; the fifth submit returns 0 with `NA_LASTERR = ENOSPC` while
    pending remains four, so a full ring never overwrites its head.

## Exact output

```
$ sh tools/naccel_gate.sh
O
```

The gate writes one byte and no newline.  The direct run at this revision:

```
$ awk -f tools/nmk.awk -v CMD=emit src/tests/naccel_test.nas > tmp/naccel.nan
words 4796
$ ./aarch64/android/nan_cli --img tmp/naccel.nan --mem 64 \
    --steps 20000000 --serial
O
[nan_cli] nan-text: 104264 steps, rc=3, pc=4705, trap=''
```

`rc=3` is the normal guest HALT in `nan_cli`; the gate treats it as success
only after the exact one-byte `O`.

## Regressions

```
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nmem_scale_gate.sh
nmem_scale: PASS (2 TiB object, 1 TiB 64-bit view, bounds/rights/node)

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)

$ sh tools/nsecure_gate.sh
O
```

## Non-claims

- No native PCIe/GPU/IOMMU support or performance claim.
- No real device memory is touched; VRAM placement is an accounting/BAR model.
- DMA copies are capped at 64 KiB and physical guest bytes below 4 GiB.
- The GEMV path is an exact integer placeholder, not a Q4/Q8 tensor kernel.
- The bitmap VRAM model caps at `2^32` units; a production allocator needs
  nheap-backed 4 KiB/2 MiB/1 GiB classes and eviction.

## Frontier ideas

1. **GPU command queues.**  Extend the ring to ordered command buffers with
   timeline fences, multiple queues/contexts and completion interrupts; gate
   two queues with a cross-queue barrier and a cancelled-head full ring.
2. **GPUDirect/RDMA.**  Map peer memory through a remote-key IOMMU domain and
   move KV/checkpoint pages zero-copy; require the destination epoch and a
   completion fence before the first token, with fault isolation per peer.
3. **VRAM eviction and tiering.**  Track allocation records, pin weights, and
   evict cold KV to the host `nheap` under pressure; remap the IOVA with a new
   epoch and gate exact used/free/eviction accounting across a 2 TiB BAR.
4. **IOMMU shootdown.**  Add per-domain in-flight counters and an epoch fence
   around unmap/rebind/revoke; drain in-flight DMA before reusing an entry and
   gate a two-queue stale-completion race after shootdown.
