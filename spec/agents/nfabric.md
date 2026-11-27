# nfabric / nnvme — F11 fabric and storage boundary

Status: **F11 gated**.  Two emulated product libraries, two exact gates, no C
outside `src/tests`.

| item | file |
|---|---|
| NVMe namespace, queue pairs, model streaming | `src/lib/nnvme.nas` |
| NVMe proof image | `src/tests/nnvme_test.nas` |
| NVMe gate | `tools/nnvme_gate.sh` |
| two-node loopback RDMA, remote KV, checkpoint transport | `src/lib/nfabric.nas` |
| fabric proof image | `src/tests/nfabric_test.nas` |
| fabric gate | `tools/nfabric_gate.sh` |

This is a **software boundary**, not a hardware driver.  There is no PCIe, no
real NVMe controller, no InfiniBand/RoCE NIC and no GPUDirect claim.  What is
proven is the policy and bookkeeping layer a model loader and a multi-node
agent runtime need: 64-bit LBAs/offsets, submission/completion rings,
doorbells, extent resolution, posted receives and credits, remote keys,
generation-tagged KV, and sealed checkpoint records.

## nnvme layouts

Namespace (32 words, caller supplied):

```
+0  "NVMS" 0x4E564D53     +1 version 1
+2  nsid                   +3 lba_shift 9..16
+4  lba_size               +5 capacity_lo +6 capacity_hi  (LBAs)
+7  flags (1 read-only)    +8 extent table +9 extent capacity +10 extent count
+11 backing base lo        +12 backing base hi
+13 backing size lo        +14 backing size hi
+15 generation
+16 reads +17 writes +18 trims +19 flushes
+20..21 bytes_read   +22..23 bytes_written   +24..25 bytes_trimmed
+26 lba_errors +27 ro_errors +28 io_errors
```

Extent (8 words): `+0 lba_lo +1 lba_hi +2 count_lo +3 count_hi +4 phys byte
addr +5 flags`.  Extents must lie inside the namespace capacity and inside the
backing window `[base, base+size)`, must not overlap, and must not wrap in
64-bit LBA space.

Controller (32 words): namespace pointer, queue-pair table, queue capacity,
maximum depth, generation, submitted/completed/error/queue-full/lba-error
counters, last status and errno.

Queue pair (32 words, stride 32, entry `qid-1`): SQE/CQ word addresses, depth,
`sq_head/sq_tail/cq_head/cq_tail`, doorbell, phase, state and per-queue byte
counters.

SQE (16 words): `opcode, flags, nsid, lba_lo/lba_hi, nlb_lo/nlb_hi, data byte
address`.  CQE (8 words): `status, qid, sq slot, command id, result_lo/hi, nsid,
phase`.

Tensor view (16 words): `"NVTW"`, version, dtype/rank/flags, 64-bit byte offset,
64-bit byte size, block bytes, generation.  The streaming read converts a
view-relative block index and byte offset to a 64-bit LBA with a restoring
64-bit/32-bit divide, then uses the same extent path as a normal READ.

### nnvme proof

`sh tools/nnvme_gate.sh` runs one image twice.  The image proves:

- three extents over one 32 KiB caller backing descriptor, including one at
  LBA `2^32`; overlap, past-capacity, zero-count, outside-backing and a
  64-bit-wrapping extent are rejected with exact codes;
- a 4-deep queue pair: four queued commands, the fifth submission fails
  `NVME_EQFULL`, SQ/CQ head/tail wrap at slot 0, CQ doorbell accounting;
- WRITE/READ/FLUSH/TRIM exact bytes: 4096 written, 4096 read back
  byte-for-byte, TRIM deterministically zero-fills blocks 8..15, FLUSH counted;
- a 16-block WRITE and READ at LBA `2^32` (4 GiB in LBA space), exact bytes;
- a `NVTW` view at byte offset `2^41` (2 TiB) read through the 64-bit path,
  byte-equal to the same 8192-byte block;
- exact namespace stats: reads 3, writes 2, trims 1, flushes 1, bytes_read
  20480, bytes_written 12288, bytes_trimmed 4096;
- 64-bit wrap, out-of-capacity LBA, zero data address (EADDR), zero count,
  extent-crossing I/O, bad namespace, bad opcode, read-only write and trim,
  bad queue id, stale CQE index and an over-counting CQ doorbell;
- failed commands do not change the successful byte counters.

Exact run (two runs, one byte out):

```
$ sh tools/nnvme_gate.sh
O
```

`nan_cli` line for the pass:

```
[nan_cli] nan-text: 797858 steps, rc=3, pc=3618, trap=''
```

Image is 3727 words, assembled and round-trip checked by `tools/nmk.awk`; the
last code/data label is 3725, below the 0x4000 window.

## nfabric layouts

Node (64 words, caller supplied):

```
+0  "NFND" 0x4E464E44     +1 version 1   +2 node id   +3 state
+4  qpair table +5 qpair cap +6 qpair count
+7  MR table    +8 MR cap    +9 MR count
+10 sends +11 recvs +12 writes +13 reads +14 completions +15 errors
+16 stale keys +17 credits consumed
+18..19 bytes_sent   +20..21 bytes_written   +22..23 bytes_read
+24 errno
+25 last checkpoint agent +26 agent generation +27 last epoch
```

QP (32 words, stride 32): qid, state (init/ready), local node, remote node/qid,
depth, RQ base, CQ base, `rq_head/rq_tail/cq_head/cq_tail`, credits cache,
phase, per-op counters and stale-key count.

RQ entry (4 words): buffer byte address, length, `wr_id`, status.  CQE (8
words): status, opcode, qid, bytes_lo/hi, `wr_id`, phase.  Opcodes are SEND=1,
RECV=2, WRITE=3, READ=4.

MR (8 words): live, 64-bit base, 64-bit size, rights (1 read, 2 write),
generation, key.  Remote key format:

```
0x52 | slot[23:16] | generation[15:8] | 0x00
```

A revoke bumps the generation and mints a new key.  Every older key fails
key-equality with `NFAB_ESTALE`; a live key without the required right fails
`NFAB_ERIGHT`; unknown slots fail `NFAB_ENOENT`.

Fabric record (16 words): `"NFAB"`, version, node0, node1, link, send/recv/
write/read/stale/error counters, errno.

### nfabric proof

`sh tools/nfabric_gate.sh` runs one image twice.  The image proves:

- two 4-deep queue pairs with posted receives and credits: no-credit send
  fails `NFAB_ECREDIT`, posting a receive restores one credit, two back-to-back
  sends complete in FIFO order on both send and receive completion queues;
- reverse traffic node1 -> node0 with exact bytes;
- RDMA WRITE and READ through an rkey with 64-bit offsets, exact source/
  destination bytes, a 64-bit bounds violation (`NFAB_EBOUNDS`), a write to a
  read-only MR (`NFAB_ERIGHT`) and a successful read of that MR;
- rkey revoke: the old key fails `NFAB_ESTALE`, the new key writes the same
  128 bytes, and node1 writes into node0's MR;
- two real `nkv` slabs built from `nheap` 4 KiB pages: `nfab_kv_put` moves a
  token to the peer MR, `nfab_kv_get` pulls it into the second slab, token
  bytes are equal, stale slab generations fail `NFAB_ESTALE` on both put and
  get, and current generations succeed;
- a 56-word nagent-style `NAGC` blob: seal/verify, push to node1 with epoch 5,
  byte equality, pull from node0 with epoch 5, word equality, epoch-4 send and
  pull rejected as `NFAB_ESTALE`, a corrupted seal rejected `NFAB_ECK`, and
  epoch 6 accepted on both sides;
- the checkpoint transport uses `word pointer << 2` as the byte view, so the
  same record is interpreted as NaN words for the seal and as payload bytes
  for the fabric; word payload equality is exact.

Exact run (two runs, one byte out):

```
$ sh tools/nfabric_gate.sh
O
```

`nan_cli` line for the pass:

```
[nan_cli] nan-text: 101705 steps, rc=3, pc=5475, trap=''
```

Image is 5701 words, assembled and round-trip checked; the last label is 5699.

## Regression outputs

Exact, from this worktree:

```
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nmem_scale_gate.sh
nmem_scale: PASS (2 TiB object, 1 TiB 64-bit view, bounds/rights/node)

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)

$ sh tools/naccel_gate.sh
O

$ sh tools/nagent_gate.sh
O

$ sh tools/nkv_gate.sh
nkv: PASS (2 TiB views across 4 GiB, per-agent KV append/read/view, 1 GiB/2 MiB nheap slabs, isolation, capacity, generation)
```

## Honest limits

- Emulated loopback only.  No real DMA, RDMA transport, congestion control,
  retransmission, memory registration pinning, or hardware completion queues.
- The remote memory copy uses guest `LDB`/`STB`; the effective byte address
  must fit the 32-bit guest byte window.  LBA, offset, size and capacity
  arithmetic is full 64-bit.
- NaN class heads are not carried across the byte transport.  Bytes are the
  contract; the destination words are data-class.  The gates compare word
  payloads and byte payloads, not the 8-byte class-bearing word image.
- `nnvme` requires an I/O to lie inside one extent.  There is no scatter-
  gather list and no real namespace format.
- TRIM is defined as deterministic zero-fill; real NVMe leaves trimmed bytes
  undefined.  This is a gate choice, documented in the library.
- Both libraries use fixed single-core scratch and are not reentrant.
- `nfab_ck_recv` reads the record before verifying it, so a stale or corrupted
  remote record clobbers the local receive buffer.  There is no transactional
  staging buffer yet.

## Frontier directions

1. **GPUDirect/RDMA over naccel.**  Register a `naccel` VRAM range as an MR
   through `niommu`, add peer memory keys and IOVA translation to WRITE/READ,
   and gate a model load that streams tensor blocks directly into VRAM without
   a host bounce buffer.  This is the first step from the emulated fabric to
   the accelerator path, and must stay honest until a real NIC/GPU pair is
   exercised.
2. **Paged remote KV.**  Give each 2 MiB KV block its own rkey and generation,
   transfer blocks in parallel queue pairs, and gate partial-failure rollback
   plus a parent/child COW prefix moved between nodes.  This would connect
   `nkv_slab_*` paging to the fabric instead of moving one token per call.
3. **NVMe-oF over nfabric.**  Layer `nnvme` SQEs/CQEs on the fabric as
   capsules plus separate data buffers, add controller id and namespace
   generation checks, and gate remote READ/WRITE/FLUSH/TRIM with exact bytes
   and a stale controller generation.  The current libraries already share the
   same LBA and completion vocabulary.
4. **Multi-node checkpoint ring.**  Extend the NAGC transport to a 4-node ring
   with per-link epoch fences, a quorum seal check, and restore of an
   `nagent` record on a different node.  Gate torn-write, duplicate-epoch and
   rollback rejection, then join the restored agent to the current capability
   generation instead of rewinding it.
