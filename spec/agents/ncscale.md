# ncscale — F4 4096-core x2APIC topology/scale layer

Status: implemented and gated (2026-11-26).  Agent slot B.

## Scope

F4: a pure-NaN topology layer for 4096 logical cores.  It takes a dynamic
APIC table, builds the APIC <-> logical mapping (full 32-bit x2APIC ids,
sparse), owns the 4096-bit online and dispatch-ready bitmaps, lays out one
16 KiB stack per core with a 16 KiB guard, and exposes a dispatch predicate
that is one record lookup plus one word load.  The dispatch path takes no
global lock and no spinlock; bitmap changes use `nansmp` CAS, counters use
`nansmp` fetch-add.

## Files

- `src/lib/ncscale.nas` — new pure-NaN library.  It fills the existing
  `nancore.nas` 64-word record table (`0x400000`) and does not modify
  `nancore.nas` or `nansmp.nas`.
- `src/tests/ncscale_test.nas` — 4096-core proof with single-CPU
  value-correct stubs for the nansmp atomic seam.
- `tools/ncscale_gate.sh` — emits/checks the NaN image, runs it under
  `aarch64/android/nan_cli`, requires the exact marker `O`, then runs
  `tools/nansmp_gate.sh` for the real 2-CPU and 4-CPU regression.

No C was added anywhere for this item.  No `nancore.nas`/`nansmp.nas` edit was
needed.

## Address layout (word indices; one NaN word is 8 bytes)

| range | use |
|---|---|
| `0x3FF000` | 16-word ncscale context: magic, live count, table, online/ready/map counts, stack geometry |
| `0x400000..0x43FFFF` | 4096 x 64-word NanCore records (same fields as `nancore.nas`) |
| `0x440000..0x44007F` | 4096-bit online bitmap |
| `0x440080..0x4400FF` | 4096-bit dispatch-ready bitmap |
| `0x441000..0x444FFF` | 8192-slot APIC hash: 2 words/slot, <=50% load at 4096 cores |
| `0x800000..0x17FFFFF` | per-core stacks: 4096 x `0x1000` words |

Each stack slot is `0x1000` words = 32 KiB of NaN memory:

```
[base, base+0x800)      16 KiB stack   (0x800 words = 0x4000 bytes)
[base+0x800, base+0x1000) 16 KiB guard
```

Both `base` and `top = base+0x800` are `0x800`-word (16 KiB byte) aligned.
The slot stride is `0x1000` words, so guard spacing is exactly one 16 KiB
guard.  The last base is `0x17FF000`, the last top is `0x17FF800`, and the
arena ends at `0x1800000`.

## Table contract and API

The caller supplies a header at `apic_table_base`:

```
+0 magic 0x4E435331 ("NCS1")
+1 version 1
+2 count 1..4096
+3 flags 0
+4 .. +4+count-1   APIC id of logical core 0..count-1
```

`ncs_init(r1=count, r2=table)` adopts the header count when `count==0`, and
otherwise requires an exact match.  A count of 0, a count above 4096, a bad
magic/version/flags, a reserved `0xFFFFFFFF` APIC id, or a duplicate APIC id
returns `-1`.  `0xFFFFFFFE` is a legal full-32-bit id and is used by the gate.

| routine | arguments | result |
|---|---|---|
| `ncs_init` | count, table | 0 / -1 |
| `ncs_count` | - | live dynamic count |
| `ncs_map` | apic, index | 0 / -1 (index must be free, APIC unique) |
| `ncs_unmap` | apic | 0 / -1 (core must be offline) |
| `ncs_index` | apic | logical index / `0xFFFFFFFF` |
| `ncs_apic` | index | APIC id / `0xFFFFFFFF` |
| `ncs_online_set` | index | 0 / -1 (mapped only; idempotent) |
| `ncs_online_clear` | index | 0 / -1 (clears ready too; idempotent) |
| `ncs_online_test` | index | 1 / 0 |
| `ncs_online_count` | - | live online count |
| `ncs_ready_set` | index | 0 / -1 (online only; idempotent) |
| `ncs_ready_clear` | index | 0 / -1 (idempotent) |
| `ncs_ready_test` | index | 1 / 0 |
| `ncs_ready_count` | - | live ready count |
| `ncs_dispatch_ready` | index | 1 iff online AND ready |
| `ncs_stack_base` | index | base / 0 |
| `ncs_stack_top` | index | exclusive top / 0 |
| `ncs_set_node` | index, node | 0 / -1 (NUMA hint) |
| `ncs_node` | index | node / `0xFFFFFFFF` |
| `ncs_map_count` | - | live mapped count |

`ncs_dispatch_ready` is deliberately minimal: bounds-checked record address,
one `LD` of the per-core flags word, one mask test.  It does not scan a bitmap
and does not acquire anything, so a core can call it while any other core is
onlining, offlining, or mapping another core.

## Mapping design

- Hash: `h = (apic * 0x9E3779B1); h ^= h >> 16; slot = h & 0x1FFF`.
- Open addressing with linear probe over 8192 slots.  Each slot is
  `(key, state)`; state is `0` empty, `0x80000000|index` occupied, or
  `0x40000000` tombstone.  A full 32-bit key is stored with no truncation.
- `ncs_index` is read-only and lock-free.  Insertion writes the key, calls
  `nsp_fence`, then publishes the occupied state.  `ncs_unmap` sets a
  tombstone and fences; it refuses while the core is online.
- APIC ids above 255, sparse ids, and low-byte collisions are all ordinary
  keys.  The gate proves `0x10000000 -> 0`, `0x10000002 -> 1`,
  `0x10001FFE -> 4095`, `0x10000100 -> 128` (same low byte as id 0),
  odd ids absent, `0xFFFFFFFE -> 100`, and `0xF0000000 -> 102`.

## Online/ready design (no global lock)

- Bit word and mask: `word = index >> 5`, `mask = 1 << (index & 31)`, using a
  32-word mask table.
- Set is a CAS loop computing `old | mask`; clear is a CAS loop computing
  `old & ~mask`.  A fetch-add is **not** used for bits: adding an already-set
  bit carries into the next core's bit (the first test run found exactly
  that: `1+1=2`).  Fetch-add is used only for the online/ready counters.
- Per-core flags word `NR_FLAGS` mirrors ONLINE|READY.  Onlining sets state
  IDLE if it was OFF; offlining clears state to OFF.
- `ncs_online_clear` clears ready first, then online, then the flag word, so
  a concurrent `ncs_dispatch_ready` can only see the core leave service.
- There is no `nsp_lock`/`nsp_trylock` reference in `ncscale.nas`; the gate
  greps for it.  The only global coordination is the CAS domain itself.

## Proof map (gate test)

1. **Bad inputs**: null table, bad magic, bad version, nonzero flags, zero
   count, count 4097, duplicate APIC, reserved `0xFFFFFFFF`, requested count
   mismatch (4095 vs 4096 and 4 vs 3), and an out-of-bounds online set all
   return `-1`/fail.  Public calls made before a successful init fail closed
   (unmap, map and index are checked in the gate).
2. **Dynamic count**: a 3-entry table initializes with count 3; a 4-entry
   table initializes with count 4; index 4 is out of bounds.  The 4096 table
   is built at runtime with `apic[i] = 0x10000000 + 2*i`.
3. **Mapping**: all 4096 forward/reverse lookups above, plus unmap of index
   100 and 102, remap of `0xFFFFFFFE` and `0xF0000000`, duplicate-APIC and
   occupied-index rejection, and refusal to unmap an online core.
4. **Stacks**: for every index 0..4095, `base == 0x800000 + (i<<12)`,
   `top == base+0x800`, `base` is 16 KiB-byte aligned
   (`(base<<3)&0x3FFF == 0`), and the arena ends exactly at `0x1800000`.
   Marker writes at cores 0, 1 and 4095 leave the guard word and the next
   stack's base zero.
5. **Online/ready**: initial offline, online set/test/count, idempotent set,
   not dispatch-ready until ready-set, ready flag/count, second core 4095,
   gap core 100 not ready, offline clears both bits and both counters,
   idempotent clear, and bounds for 4096.
6. **Atomic seam**: stubs implement the nansmp value semantics and count
   calls; the test requires fetch-add > 0, CAS > 0 and fence > 0.  Therefore
   the library really publishes through the seam.

## Gate transcript

```
$ sh tools/ncscale_gate.sh
ncscale: PASS (4096 cores, x2APIC 0x10000000+2i, map/unmap, online/ready flags, 16 KiB stacks, 1656-word image)
nansmp: PASS (-smp 2: 2 CPUs, NaN A/B, IPI reschedule, LAPIC timer, atoms, 189-word image)
nansmp: PASS (-smp 4: 4 CPUs, NaN A/B, IPI reschedule, LAPIC timer, atoms, 189-word image)
nansmp: RESULT PASS (x86_64 S1 2-CPU and 4-CPU prototype, exact transcripts)
ncscale: RESULT PASS (4096-core scale + x86_64 S1 2/4-CPU regression)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

The guest serial output is exactly `O`; the test executes 4,652,737 guest
steps and the image is 1,656 words (well below the `0x7000` software stack and
all fixed structures).  `nmk CMD=check` reports `check: 0 mismatches` inside
the gate.  The 2/4-CPU regression is the existing `nansmp` exact-transcript
gate; its C is only the test bench under `src/tests/native64`.

## Honest boundary

The pure-NaN gate runs one host CPU, so its `nsp_fetch_add`/`nsp_cas`/
`nsp_fence` implementations are value-correct single-CPU stubs, not the real
S1 control ports.  Real multi-core atomic/queue/IPI behavior is proven by
`tools/nansmp_gate.sh`, which runs the same NaN16 image on 2 and 4 QEMU CPUs.
`ncscale` calls only the nansmp ABI, so the S1 image can substitute the real
ports without a code change.  The gate counts stub calls to prove that seam
is on the path.

## Frontier ideas

1. **x2APIC cluster topology.** Parse ACPI MADT type 9 entries plus the
   x2APIC cluster/package fields and extend the record with
   `cluster_id`, `package_id` and `smtt` (sub-NUMA) hints.  Steal and IPI
   targeting then prefer the same cluster before crossing the package, which
   matters once 4096 cores sit behind a mesh.
2. **Per-core cache coloring.** Derive a cache-color index from the APIC
   hash and place each 16 KiB stack/record on a color that avoids siblings
   sharing a set.  Gate it with a synthetic 4096-core color histogram that
   bounds the maximum per-color count and keeps guard pages out of the
   shared/text colors.
3. **NUMA-aware APIC mapping.** Merge `nnuma`'s SRAT/SLIT node and distance
   map into `ncs_init`: store `NR_NODE` from the CPU entry, expose
   `ncs_index_node(apic)` and `ncs_node_distance(a,b)` as hints, and let
   dispatch prefer a ready core on the local node.  The mapping stays a pure
   hint; no allocator or policy moves into the native layer.
4. **4096-core scheduler handoff.** Add a lock-free per-core handoff word
   (`NC_QHEAD`/`NC_QTAIL` already exist) and a `ncs_claim(index)` that
   atomically clears READY and returns whether the claim won.  The scheduler
   can then push a TCB, publish READY, and let exactly one core claim it;
   stealers only read the online/ready bitmaps.  Gate a 4096-core synthetic
   push/claim race with a single winner per item.

## Proposed directives

- Parse x2APIC cluster/package fields from MADT type 9 and carry cluster
  hints in the NanCore record; gate a 4096-core cluster histogram.
- Add `ncs_claim(index)` (atomic READY claim) and a 4096-core single-winner
  handoff gate that exercises concurrent claims through nansmp.
- Fold SRAT/SLIT node and distance hints into `ncs_init`/`ncs_index`; gate a
  sparse-node, distance-aware dispatch preference without changing policy
  ownership.
- Add a per-core cache-color/stack placement pass with a 4096-core histogram
  bound and guard-page color exclusion.
