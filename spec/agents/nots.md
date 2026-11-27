# nots — Winternitz-4 OTS product manifest (F16b)

Status: gated by `tools/ots_gate.sh` (exact `O`).

## Implemented

- 4 KiB manifest at LBA 120..127 and a 512-byte OTS anchor at LBA 128.
- Winternitz-4 over SHA-256, 67 chains (64 root nibbles + 3 checksum nibbles),
  2144-byte signature, 32-byte public key hash, 16-byte key id.
- Per-root one-time keys derived from an offline 32-byte master:
  `H(master || root || LE32(i) || domain)`.  The secret never enters the
  image; only the public key/signature/anchor do.
- Native verifier in `kan16.xa` before the first guest fetch: region digests,
  manifest root, key id/public key against the anchor, 67 hash chains, final
  public-key hash, HMAC defense-in-depth, and guest digest after fetch.
- `!MAN` for structural/digest/root failures, `!OTS` for key/signature/anchor
  failures, `!SIG` for the HMAC tag.  Guest is never entered on failure.

## Gate

Two isolated builds with a fixed development key are byte-identical.  The
gate independently rehashes boot/kernel/guest, the root and HMAC, verifies the
signature with the independent gawk verifier, boots to `NANIX SHELL READY`,
and mutates:

- boot/kernel/guest/manifest/root/reserved -> `!MAN`
- key id/public key/signature/anchor -> `!OTS`
- HMAC tag -> `!SIG`

All fail closed with the guest never entered.

A real bug was found and fixed: gawk `"a"+0 == 0`, so hex digits `a..f` were
signed as 0 by the old signer/self-verifier.  The native/Python verifier
exposed it.  `ots.awk` now uses an explicit hex-digit conversion and the
selftest covers a-f digits.

## Honest security scope

- This is a real one-time signature, but the **development seed is public**
  (`tools/ots_dev_seed.hex`).  Production must set `OTS_MASTER` to an offline
  secret.
- A one-time key is derived per root; reusing the master across roots is safe
  by derivation, but the same root must not be signed with two different
  derivations.
- The anchor and verifier live in the image; an attacker who can rewrite the
  whole boot/kernel must still be prevented by a root of trust outside the
  image (boot ROM/TPM/secure variable).  That is not implemented.
- No Ed25519, key rotation, anti-rollback, measured boot or per-page Merkle
  guest verification yet.
