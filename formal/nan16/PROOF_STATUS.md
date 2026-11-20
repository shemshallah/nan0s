# NaN16 mirror Coq claim ledger

Date: 2026-11-19 (UTC) / 2026-11-19 (Pacific)

| Claim | Source | Computational check | Coq kernel |
| --- | --- | --- | --- |
| Mirror involution | `NaN16Mirror.v` | PASS | pending CI |
| Canonical representative and idempotence | `NaN16Mirror.v` | PASS | pending CI |
| Upper-pair enumeration sound, complete, duplicate-free | `NaN16Mirror.v` | PASS | pending CI |
| 65,536 / 256 / 32,640 / 32,896 count | `NaN16Mirror.v` | PASS | pending CI |
| Flat coordinate address injective | `NaN16Mirror.v` | PASS | pending CI |
| Bit reversal swaps physical coordinate bytes | `NaN16Bits.v` | PASS | pending CI |
| Physical bit encoding injective and fixed iff diagonal | `NaN16Bits.v` | PASS | pending CI |

Computational checks: `python3 check_counts.py` and `python3 check_bit_reverse.py`.

The computational checks are finite exhaustive experiments; only a passing `coqc` workflow can change the kernel column to PASS. No axioms or admitted proofs are intentionally used.

This is a new formalization of established NaN16 geometry, not a recovered earlier Coq project. Open obligations: (1) fully connect bit-list words to the numeric `rev8`/`rev16` address functions, (2) prove the signed S+/S− mirror-channel algebra, and (3) formalize triangle/tetrahedron incidence separately.
