# NaN16 Coq claim ledger

Updated 2026-11-22. Coq 8.18.0 kernel verification on GitHub Actions.

## Kernel-certified R4 foundation

The full four-module package and all four Python exhaustive regressions passed in [run 45049105148](https://github.com/shemshallah/nan0s/actions/runs/45049105148) at commit `ad03dd196f07c56ef51074d29b49be7476546b1d`.

| Claim | Source | Kernel result |
| --- | --- | --- |
| Mirror involution, canonical projection, duplicate-free unordered pair enumeration | `NaN16Mirror.v` | PASS |
| 65,536 physical cells; 256 fixed; 32,640 mirror pairs; 32,896 canonical representatives | `NaN16Mirror.v` | PASS |
| Injective 256 x 256 flat addressing | `NaN16Mirror.v` | PASS |
| Bit reversal swaps encoded coordinates, and fixed iff diagonal | `NaN16Bits.v` | PASS |
| Unique S+/S- representation for off-diagonal addresses | `NaN16Signed.v` | PASS |
| Independent S+/S- memory writes and preservation of unrelated addresses | `NaN16Memory.v` | PASS |
| Canonical recovery from either signed orientation | `NaN16Memory.v` | PASS |

The Python tests are independent finite regressions, not replacements for kernel certification.

## R5 candidate (pending CI)

`NaN16MemoryAlgebra.v` proposes kernel proofs of pointwise commutativity for disjoint writes, S+/S- write-order independence, mirror-equivariance of a memory write, reflection involutivity and diagonal channel aliasing. `check_memory_algebra.py` exhaustively checks order independence on 32,640 strict pairs and samples mirror equivariance over all 65,536 possible write keys.

**R5 is not certified until its own CI succeeds.**

## Remaining open obligations

1. Connect bit-list words to numeric `rev8`/`rev16` operations.
2. Prove refinement of the actual NaN/0S implementation to the Coq store model.
3. Prove higher-order incidence and simultaneous state transitions, including the effects of shared memory.
4. Distinguish abstract mathematical safety from concurrency primitives and physical atomicity.

These Coq sources contain no intentionally introduced `Axiom` or `Admitted`. Mathematical certification does not imply correctness of any unverified C, assembly, OS or hardware implementation.
