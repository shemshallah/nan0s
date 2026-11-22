# NaN16 Coq claim ledger

Updated 2026-11-22. Coq 8.18.0 kernel verification on GitHub Actions.

## Kernel-certified R5 theorem package

The complete five-module package and all five Python regressions passed in [run 45049242569](https://github.com/shemshallah/nan0s/actions/runs/45049242569) at commit `1f691922f467eb38bf7ffce30530aec51dea4e36`. The R4 foundation was independently certified by [run 45049105148](https://github.com/shemshallah/nan0s/actions/runs/45049105148).

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

| Disjoint-address writes commute pointwise | `NaN16MemoryAlgebra.v` | PASS |
| Signed pair write order is independent off diagonal | `NaN16MemoryAlgebra.v` | PASS |
| Mirror-equivariant update and involutive reflection | `NaN16MemoryAlgebra.v` | PASS |
| Diagonal S+/S- orientations coincide | `NaN16MemoryAlgebra.v` | PASS |

## Certification limits

R5 is a completed kernel-verified abstract theorem package. It is **not** a proof of machine-code correctness, physical update atomicity, or a newly solved open problem. The executable Python regressions independently support the finite checks but do not substitute for proofs.

## Remaining open obligations

1. Connect bit-list words to numeric `rev8`/`rev16` operations.
2. Prove refinement of the actual NaN/0S implementation to the Coq store model.
3. Prove higher-order incidence and simultaneous state transitions, including the effects of shared memory.
4. Distinguish abstract mathematical safety from concurrency primitives and physical atomicity.

These Coq sources contain no intentionally introduced `Axiom` or `Admitted`. Mathematical certification does not imply correctness of any unverified C, assembly, OS or hardware implementation.
