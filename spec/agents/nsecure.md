# nsecure — F9 isolation/security

Status: **implemented and gated** (`tools/nsecure_gate.sh` emits exactly `O`).
This is the pure-NaN isolation policy layer over `nanobj`, `nagent` and the
`n64` helpers.  It has not yet been wired to the native x86-64 page tables
(CR3/PTE writes, SMEP/SMAP); those remain integration directives below.

## Scope

F9: per-agent address spaces, W^X/NX, guard pages, capability revocation,
deny-by-default sandbox policy, and a deterministic malformed-request corpus.
No C is added.  `aarch64/android/nan_cli` is the host oracle only; the image
contains the real libraries and the proof.

| file | role |
|---|---|
| `src/lib/nsecure.nas` | address-space records, ranges, guards, 64-bit validation, cap revalidation, sandbox policy, verify |
| `src/tests/nsecure_test.nas` | proof image; prints exactly `O` |
| `tools/nsecure_gate.sh` | emit/check, enforce the guest map, run twice, require one-byte `O` |

No existing shared library was modified.  `nsecure.nas` includes `n64.nas`,
`nanobj.nas` and `nagent.nas` and therefore must be the only include of those
libraries in an image.

## Guest map

```
0x000000..0x0003FF  boot JMP and padding
0x000400..          nsecure + nanobj + nagent code (test)
0x0003A0..0x0003D2  nanobj/nantrace low globals (code starts above this)
0x0017E3..          test data words (end 6115)
0x006800..0x00683F  nagent destination generations (library)
0x006C00..0x006C3F  nsecure low scratch (library)
0x007000..0x00707F  proof-image stack
0x340000            nanobj table (64 x 32 words)
0x348000            nagent table (32 x 320 words)
0x350000            nsecure table (16 x 256 words)
```

Code must start at `0x400` or above: `nanobj` keeps scratch at `0x3A0`.  Code
and data must end below `0x6800`; the test ends at word 6115 (0x17E3).  The
gate enforces all four reserved blocks and the exact stack address.

## Address-space record (256 words, index = agent-1)

```
+0   magic "NSEC" (0x4E534543)   +1  version 1
+2   agent id 1..16              +3  state (1 live)
+4   root capability             +5  root kind (1 nanobj, 2 nagent)
+6   capability epoch            +7  live range count
+8   policy flags                +9  allowed-op mask lo
+10  allowed-op mask hi          +11 live sandbox window count
+12..15 reserved
+16..47   4 sandbox windows, 8 words each
+48..175  8 ranges, 16 words each
```

Range (16 words):

```
+0  state: bits0..2 R/W/X (NANIX 1/2/4), bit3 live,
           bit4 guard, bit5 stack, bit6 heap
+1  authorizing capability       +2  capability kind
+3  base_lo +4 base_hi           +5  size_lo +6 size_hi
+7  guard_lo +8 guard_hi         +9  capability epoch snapshot
+10 range id 1..8                +11..15 reserved
```

Window (8 words): `{live, base_lo, base_hi, size_lo, size_hi, rights,
reserved, reserved}`.

The record is caller-visible NaN memory, so it is checkpointable like every
other NaN structure.  `nsec_verify` revalidates structure, roots, capabilities,
alignment, limits and pairwise non-overlap.

## Mapping rules

* Rights are the NANIX values: `1` read, `2` write, `4` execute.
* `W|X` is rejected at map, access check and sandbox-window creation (`EWX`).
* Stack and heap ranges are always NX: `R|X` with the stack/heap flag is
  rejected at map (`ENX`) and at check.
* `base` and `size` are nonzero, 4 KiB aligned (`EPAGE`).
* `base+size` is a 64-bit `(lo,hi)` add.  A carry is `EOVER`; an end above the
  64 PiB low user half (`0x01000000_00000000`) is `ERANGE`.  Guard expansion
  (`base-page`, `end+page`) is checked the same way.
* A guarded range reserves one 4 KiB page immediately below `base` and one
  immediately above `base+size`.  Guards may not overlap any other range or
  guard.  Map-time validation reserves the full effective interval before the
  range is published.
* An access check is exact-interval: the whole request must lie inside one
  live range, with the requested rights and a live authorizing capability.
  Requests that merely touch a guard page return `EGUARD`; requests outside
  every range and guard return `ERANGE`.
* `nsec_unmap` removes by 1-based range id.  `nsec_rebind` replaces the
  authorizing handle without moving the range, which is how a revoked
  capability is upgraded to its new generation.

## Capability integration

A handle is never a pointer; it is the existing 32-bit word
`0xCA | index | generation | rights`.  Kind 1 calls `nobj_check`; kind 2 calls
`nagent_cap_check(agent, handle, rights)`.  Both re-read the live table on
every map/check/rebind, so:

* a revoked handle fails the generation check (`ECAP`);
* a rights downgrade fails the rights containment check (`ECAP`);
* the address-space root is checked on every public operation, so revoking
  the root makes the whole space fail closed until `nsec_root_set`.

The test proves all three with both libraries: nanobj root + nanobj stack cap
and nagent data cap.  After revocation the stored old handle fails; a rebind
to the new-generation handle succeeds; the independent heap cap still works.

Honest limitation: handles are agent-local indexes.  A handle word from agent
A used on agent B names B's entry at the same index/generation/rights.  If that
word is bit-identical it is a valid B capability by construction; if rights or
generation differ, the exact-handle comparison fails.  The test uses the
rights-differing case.  Agent-scoped handle salts (below) would make the word
itself unforgeable across spaces.

## Sandbox policy

* Op ids `0..31` are SVCs, `32..47` tool calls, `48..63` memory operations;
  `48..55` are read-shaped and `56..63` write-shaped.
* The 64-bit allowed-op bitmap starts at zero.  Windows start empty.  Both
  must be granted explicitly: **deny by default**.
* `nsec_sandbox_check(agent, op, base_lo, base_hi, len_lo, len_hi)`:
  1. op bit must be set (`EDENY`);
  2. buffer must be page-aligned, nonzero, wrap-free and below the ceiling;
  3. the whole buffer must be inside one live window (`EWIN`);
  4. the window rights must cover the op shape: read ops need R, write-shaped
     memory ops need W (`EWIN`);
  5. the underlying address space and capability must still check out.
* Windows are per agent; the test proves A's window is invisible to B and
  vice versa.

## API

```
nsec_init
nsec_agent_create  agent, root_cap, root_kind          -> 0/code
nsec_root_set      agent, root_cap, root_kind          -> 0/code
nsec_map           agent, cap, base_lo, base_hi, size_lo, size_hi,
                   rights, flags, cap_kind             -> range id / 0 (errno)
nsec_unmap         agent, range                        -> 0/code
nsec_rebind        agent, range, new_cap               -> 0/code
nsec_check         agent, base_lo, base_hi, len_lo, len_hi, rights -> 0/code
nsec_sandbox_init  agent                               -> 0/code
nsec_sandbox_allow_op    agent, op                     -> 0/code
nsec_sandbox_allow_mask  agent, mask_lo, mask_hi       -> 0/code
nsec_sandbox_window      agent, slot, base_lo, base_hi, size_lo, size_hi,
                         rights                        -> 0/code
nsec_sandbox_check agent, op, base_lo, base_hi, len_lo, len_hi -> 0/code
nsec_verify        agent                               -> 0/code
nsec_errno                                             -> last map/policy error
```

Codes: `0 OK, 1 EBAD, 2 ENOENT, 3 ESPACE, 4 ERANGE, 5 EOVER, 6 EWX,
7 EGUARD, 8 ECAP, 9 EPAGE, 10 EDENY, 11 EWIN, 12 ENX, 13 ERIGHT`.

## Proof

`src/tests/nsecure_test.nas` runs one deterministic image:

1. two agents (id 1 nanobj-rooted, id 2 nagent-rooted), independent code RX
   and data RW/NX; guarded stack/heap RW/NX; `nsec_verify` on both;
2. allowed reads/exec/writes and exact `ERIGHT`/`ENX` for NX and wrong-rights
   requests; A cannot touch B's bases and vice versa;
3. guard tests: lower page, upper page, partial lower guard, a request that
   straddles the upper guard, and one page below the guard returning `ERANGE`;
4. map rejection matrix: W+X, stack execute, 64-bit wrap, 64 PiB ceiling,
   huge length wrap, unaligned base, unaligned length, zero length, overlap,
   guard collision, guarded range with no low room, unknown kind, bad agent,
   cross-agent rights mismatch, read-only handle on RW, `ESPACE` on a full
   table, and unmap bad/empty ids;
5. revocation matrix: nanobj root revoke -> all checks `ECAP` -> root set ->
   recovery; nagent data revoke -> `ECAP` -> rebind -> success; nanobj stack
   revoke -> `ECAP` -> rebind -> success while the heap cap is unaffected;
6. sandbox: deny before any policy; `EDENY` for unallowed op; `EWIN` without a
   window; allowed window; outside-window, unaligned, spanning and write-shape
   failures; malformed window definitions; per-agent isolation; root revoke
   after policy fails closed and recovers;
7. deterministic corpus: 1024 requests, 16 classes, all denied and the denial
   count must equal 1024:

   | class | shape |
   |---|---|
   | 0 | 64-bit wrap on check |
   | 1 | huge length wraps both halves |
   | 2 | out of range above 64 PiB |
   | 3 | W+X access check, varying offset |
   | 4 | stale nagent cap on map |
   | 5 | lower guard hit, varying byte offset |
   | 6 | unaligned map |
   | 7 | zero-length check |
   | 8 | unmapped check, varying page |
   | 9 | execute on NX data |
   | 10 | sandbox op 32..39 never allowed |
   | 11 | allowed op outside every window |
   | 12 | check straddles the upper guard |
   | 13 | bad agent id |
   | 14 | check at the 64 PiB ceiling |
   | 15 | sandbox address wrap |

8. admitted corpus: 64 mixed read/write checks inside data, 32 sandbox reads
   in the data window, one read through the code window and one write through
   data all return 0;
9. success prints exactly one byte `O`.

The image is run twice by the gate and the two outputs must be byte-identical.
The library contains no `RDTSC`, `TICK`, `KEY*`, port I/O or other host
entropy/time/device opcode; the gate rejects those mnemonics.

### Exact output

```
$ sh tools/nsecure_gate.sh
O
```

The gate writes one byte (`0x4F`) and nothing else; `stderr` is empty and the
exit status is 0.

### Regressions (same tree)

```
$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/nagent_gate.sh
O

$ sh tools/nanobj_gate.sh
nanobj_gate: PASS (typed objects, capability rights, revocation, forged-generation rejection, free)

$ sh tools/nmem_scale_gate.sh
nmem_scale: PASS (2 TiB object, 1 TiB 64-bit view, bounds/rights/node)

$ sh tools/nheap_gate.sh
nheap: PASS (1 TiB/512 GiB nodes, 1 GiB split/free/reuse, 4 KiB/2 MiB classes, 64-bit bases, stats)
```

## Limitations / non-claims

* This is policy and record management, not the native page-table writer.  It
  does not yet program CR3, PTEs, NXE or PAT; the substrate must enforce what
  `nsec_check` admits.
* Guards are policy metadata.  Until the CR3 integration, the native mapper
  must leave guard PTEs non-present (or read-only/NX as appropriate).
* No SMEP/SMAP/UMIP policy bits yet; the record has flag space for them.
* No ASLR, no encrypted memory, no attestation.
* Handles are agent-local indexes, not globally unique unforgeable tokens (see
  the limitation above).
* A capability authorizes the operation and its rights, but `nsecure` does not
  yet intersect the requested range with a bounds-carrying `nmem` class-20
  payload; any address inside the agent's 64 PiB space can be mapped with a
  rights-covering handle.  Bounds-carrying caps are the next hardening step.
* The corpus is deterministic coverage of the enumerated malformed classes,
  not a coverage-guided fuzzer and not a proof of parser correctness.

## Frontier ideas

1. **Per-agent CR3 roots and PCID/ASID.**  Turn each `nsecure` record into the
   authoritative source for a per-agent PML5/PML4 root: `map` allocates the
   leaf tables, `unmap` clears them, `nsec_rebind`/`revoke` trigger an epoch
   bump and a TLB shootdown.  Gate a two-agent context switch where agent B
   cannot read A's pages even through a stale TLB entry.  This is the missing
   hardware half of F9.
2. **SMEP/SMAP/NX hardware policy.**  Extend the record flags with
   `SMEP/SMAP/WP` and make `nsec_check` return the required CR4/PTE bits, so
   kernel access to agent pages is governed by the same policy object.  Gate
   a kernel read of an agent buffer with SMAP on (fault) and with an explicit
   window (success).
3. **Capability-revocation shootdown with epoch fences.**  Combine the nagent
   capability epoch and the nsecure range epoch into a per-CPU published
   generation; after a revoke, every CPU must observe the new epoch before the
   old handle is refused.  Gate a two-CPU race where CPU1's stale range entry
   fails after CPU0's revoke and succeeds after `nsec_rebind` plus a fence.
4. **Agent-scoped handle salts and sandbox fuzzing.**  Add a 16-bit agent salt
   to the handle word (or an HMAC-like mix) so a handle is meaningful only in
   its own space, then fuzz the sandbox with a deterministic generator that
   mutates op ids, windows, lengths and rights and asserts deny-by-default
   plus no admitted request outside a window.  A coverage counter over
   `nsec_check`/`nsec_sandbox_check` branches would make the corpus measurable
   rather than merely enumerated.
