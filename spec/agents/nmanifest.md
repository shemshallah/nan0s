# nmanifest - F16 authenticated product image manifest

Status: **implemented and gated**. `tools/manifest_gate.sh` ends with `O`.
The product image is still raw NaN16 + native assembly; the manifest generator
is POSIX shell + gawk + `sha256sum`, and the verifier is raw 32-bit assembly in
`src/native/kan16.xa`.

## Scope statement (read this first)

This is **symmetric authentication / tamper detection**, not a public-key
signature.  The manifest carries SHA-256 digests over boot, kernel and guest,
a SHA-256 root over the header/table, and an **HMAC-SHA-256 tag keyed by a
32-byte build key embedded in the kernel**.  An attacker who can rewrite the
kernel can extract that key, change the regions, and recompute a valid tag.
The gate proves deterministic generation and fail-closed detection of
corruption/one-byte mutation; it does not prove authenticity against an active
image author.

No Ed25519, Winternitz or Lamport one-time signature is implemented or claimed.

## Emitted image layout

```
LBA 0        boot sector                 512 bytes
LBA 1..127   kernel window               65,024 bytes
LBA 128      manifest                    512 bytes
LBA 129..    guest words                 8 * LMAX bytes
```

`LMAX` is the boot record word at image offset 504 (little-endian u32).  The
manifest occupies the last 512 bytes of the kernel window, so the existing
boot sector already loads it at physical `0x1FE00` before the kernel starts.
The ATA guest fetch still starts at LBA 129.

## Manifest layout

All fields little-endian.

```
0x000 u32 magic "NMAN" (0x4E414D4E)
0x004 u32 version 1
0x008 u32 build id (first 8 hex of SHA-256(boot||kernel||guest digests))
0x00C u32 flags = 1 (SHA-256 + HMAC-SHA-256)
0x010 u32 region count = 3
0x014 u32 header length = 0x40
0x018 u32 root offset = 0xE8
0x01C u32 tag offset = 0x108
0x020 32 bytes reserved, must be zero
0x040 boot   region: id 1, algo 1, offset 0,     size 512,     SHA-256
0x078 kernel region: id 2, algo 1, offset 512,   size 65024,   SHA-256
0x0B0 guest  region: id 3, algo 1, offset 66048, size 8*LMAX,  SHA-256
0x0E8 root = SHA-256(manifest[0..0xE7])
0x108 tag  = HMAC-SHA-256(build key, root)
0x128..0x1FF reserved, must be zero
```

The build key is
`4e614e30532d4631362d6e6d616e69666573742d6275696c642d6b65792d3031`
(`NaN0S-F16-nmanifest-build-key-01`).  The ipad/opad blocks are constants in
both `tools/manifest_build.sh` and `src/native/kan16.xa`, so the native verifier
needs no key expansion code at boot.

## Build integration

- `tools/mkall.sh` now calls `tools/manifest_build.sh` after the image is
  assembled and padded.  The manifest is computed from the actual emitted
  bytes, never from source text.
- `tools/manifest_mk.awk` writes the 512-byte record; `manifest_build.sh`
  computes the three region digests, the build id, the root and the HMAC tag.
- `tools/xgold.sh` stages a full boot+kernel+guest image, writes a manifest,
  then splits it into the boot floppy and the IDE guest.  It also passes
  `NOTOC=1`; without that, `mkimg.awk` writes a cart TOC terminator at guest
  word 22000, so the floppy guest bytes differed from the ATA guest bytes and
  the native guest hash correctly failed closed.
- Everything is deterministic: no timestamps, UUIDs, or entropy.  Two isolated
  builds produce the same image and manifest sha256 (gate step 1).

## Native verifier

`man_verify_pre` is called immediately before `ata_load_guest`; on any failure
it prints exactly `!MAN` or `!SIG` and halts in a `HLT` loop, so the guest is
never fetched.  `man_verify_guest` runs after the ATA fetch and before
`hw_init`/guest entry; a guest digest mismatch prints `!MAN` and halts before
the first guest instruction.

The verifier implements SHA-256 (FIPS 180-4) in raw 32-bit assembly, including
message schedule, 64 rounds, padding and the canonical big-endian digest byte
order.  It validates:

1. magic, version, flags, region count, header/root/tag offsets;
2. exact region ids, algorithms, offsets and sizes, and `guest size == 8*LMAX`;
3. reserved header/tail bytes are zero;
4. root over `manifest[0..0xE7]`;
5. HMAC tag over the stored root;
6. boot digest over a **pristine copy** of the boot sector;
7. kernel digest over physical `0x10000..0x1FDFF`;
8. after fetch, guest digest over `0x200000..0x200000+8*LMAX`.

Failure mapping: boot/kernel/guest/manifest/root/reserved mismatch -> `!MAN`;
tag mismatch -> `!SIG`.

### Boot-copy detail

The CPU sets the GDT descriptor accessed bit in the executed boot sector
(`0x92` becomes `0x93`), so hashing `0x7C00` directly cannot match the image.
`x86/boot/kboot0.xa` makes a 512-byte copy at `0x7E00` after all BIOS calls and
before `LGDT`/protected mode, using `rep movsw` with `ES=0`.  The verifier
hashes that copy.  The `drive` byte was moved to `0x5F8` so the boot sector no
longer modifies its own hashed bytes.

## Proof

Final gate output (`sh tools/manifest_gate.sh`):

```
== 1. deterministic two-build ==
image sha256 5b3db7896968f074a63f749588caa96a3531fac4767c429491c431a421114ec6 (2 isolated builds identical, compiler-free PATH)
manifest sha256 faf7badc6e5f8eac54e4ef5a780c33fffea87bc1e9bf42de3bca0052761facfc (512 bytes at LBA 128)
== 2. manifest layout and independent hashes ==
boot 1ce89880cc209f0e kernel aaea966469173fe0 guest cff37e3c204c0063
root 9715d24ff224e3d4 tag af49f544e8f1867a guest 4244920 bytes
region digests, root and HMAC tag independently recomputed: exact
== 3. unmodified image boot ==
clean image: NANIX SHELL READY (manifest verified before guest entry)
== 4. one-byte mutation fail-closed ==
boot: byte 504 183->182
boot: exact !MAN, guest not entered
kernel: byte 2560 93->92
kernel: exact !MAN, guest not entered
guest: byte 66148 0->1
guest: exact !MAN, guest not entered
manifest: byte 65536 78->79
manifest: exact !MAN, guest not entered
region: byte 65624 28->29
region: exact !MAN, guest not entered
root: byte 65768 151->150
root: exact !MAN, guest not entered
reserved: byte 66032 0->1
reserved: exact !MAN, guest not entered
signature: byte 65800 175->174
signature: exact !SIG, guest not entered
== 5. source rule ==
no_c_outside_tests: PASS (src outside src/tests is C-free)
manifest build: POSIX sh + gawk + sha256sum + dd/od; no C source outside src/tests
manifest_gate: PASS (2 hermetic builds identical; boot/kernel/guest digests, root and HMAC tag exact; clean boot to NANIX SHELL READY; one-byte boot/kernel/guest/manifest/root mutations -> !MAN, tag mutation -> !SIG, guest never entered; no C outside src/tests)
O
```

Product image: 4,311,040 bytes, sha256
`5b3db7896968f074a63f749588caa96a3531fac4767c429491c431a421114ec6`;
kernel 11,775 bytes (was 9,913), GOLD 32 boot + 736 kernel rows.  The guest
region is 4,244,920 bytes (530,615 words).  Clean boot to `NANIX SHELL READY`
takes about 5 s wall clock in QEMU on the Termux host; each mutant halts in
about 1-2 s.

The host-side check re-derives every region digest with `sha256sum`, the root
with `sha256sum`, and the tag with the same ipad/opad construction; all match
the emitted manifest.  The native implementation therefore agrees with a
standard SHA-256/HMAC implementation on the full product bytes.

Regressions:

```
$ sh tools/noc_product_gate.sh
product build: sh/gawk/cat/dd/sha256sum only; GOLD is raw .nan; manifest is derived from emitted bytes; no C compiler step
...
shipped full image: NaN/0S BOOT + NANIX SHELL READY on COM1 (raw NaN guest, no C)
noc_product_gate: PASS (no-C product build audit, hermetic image, full product boot, raw 64-bit AP/block runtime)
O

$ sh tools/nverify_gate.sh
nverify: PASS (reproducible emission, translator goldens, native/n16i trace, block gate, non-ELF image, C-free source)
O

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)
```

Integration regression (F18/ngold path, which now stages the manifest too):

```
$ sh tools/source_gold_gate.sh
xgold: boot 512 + kernel 11775 bytes (no C/Python)
checked-in GOLD == native xgold.sh rebuild: 3c00580aa24fea66ffa085c5ef862e06313927cbf831193a7d779fec83c60806
GOLD grid: 32 boot + 736 kernel rows (11775 kernel bytes; old 532 expectation removed)
n16i slice: 512/512 boot GOLD bytes match; slice sha256 1271f786c1e5ab7b49d08ab110e361e22f5c271764a24753e5a1f7226ae992ff; marker OK
nan_cli comparator: MATCH (517/517 bytes; oracle only, not a producer)
source_gold_gate: PASS (raw n16i assembles the 512-byte boot GOLD; native xgold.sh reproduces the checked-in 512+11775 GOLD; rows 32+736)
O
```

## Security scope: what is signed vs tamper-detected

| property | status |
|---|---|
| boot/kernel/guest byte integrity | SHA-256, native, before guest entry |
| manifest header/table integrity | SHA-256 root, native |
| authentication against accidental corruption / naive mutation | HMAC-SHA-256 with embedded build key |
| authentication against an active attacker who can rewrite the kernel | **not provided** (the key is in the image) |
| public-key signature (Ed25519) | **not implemented** |
| one-time signature (Winternitz/Lamport) | **not implemented** |
| key rotation / revocation | not implemented |
| rollback / anti-downgrade | not implemented |
| independent root of trust for the boot sector | not implemented (the boot code makes the copy it later verifies) |
| measured boot / attestation log | not implemented |

The wording in code, gate and this note is deliberate: **authenticated
manifest / tamper detection**, not "signed image".

## Gaps and integration notes

- The build key is public in the repository.  This is acceptable only for
  tamper detection, as labelled; it is not an authenticity boundary.
- The boot sector is verified from a copy it makes itself.  If the boot code is
  corrupted before the copy, the verifier fails closed (no guest) but there is
  no independent ROM/BIOS signature check.
- `tools/source_gold_gate.sh`/`tools/xgold_gate.sh` are owned by the concurrent
  F18 (ngold) work.  The kernel grew from 9,913 to 11,775 bytes, so the old
  620-row GOLD pin is stale; the committed gates derive rows from the GOLD
  header (736 rows), and `source_gold_gate.sh` passes on this tree.
  `xgold_gate.sh` still expects a committed GOLD, so it is not meaningful to
  run it from an uncommitted worktree.
- Other tools that call `tools/mkimg.awk` directly and boot the 32-bit kernel
  must now either call `tools/manifest_build.sh` or expect a fail-closed
  `!MAN`.  `mkall.sh`, `xgold.sh`, the noc smoke path and the product gate were
  updated; older bench images are intentionally not silently admitted.
- The gate flips one byte per region.  It does not yet fuzz lengths, truncation,
  bad magic/version matrices, or rollback.  Structural checks cover the obvious
  malformed cases, but this is not a complete parser-hardening corpus.
- Guest verification hashes all 4.24 MB before entry.  That is ~5 s here; a
  per-page Merkle tree would permit lazy/streamed verification.

## Frontier ideas

1. **Real public-key verification.**  Implement Ed25519 verification in native
   assembly (or a Winternitz/Lamport OTS over SHA-256 with a 2-4 KiB manifest),
   keep the private key out of the image, and gate a re-tag attempt by an
   attacker who knows the whole image.
2. **Key rotation and anti-rollback.**  Add a key id / generation field, a
   small allowed-key set rooted in the boot ROM, signed key transitions, and a
   monotonic image generation so an old valid image cannot be replayed.
3. **Measured boot.**  Extend one PCR-like chain across boot, kernel, guest and
   service carts, emit an event log over COM1, and gate both the happy path and
   a rollback/replay attempt.
4. **Per-region Merkle pages.**  Replace the flat guest digest with a page
   Merkle tree, verify root + inclusion proofs before each guest page is
   entered, and report the exact failing page instead of one flat `!MAN`.
