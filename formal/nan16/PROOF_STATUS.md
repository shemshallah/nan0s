# NaN16 Coq claim ledger

Updated 2026-11-22. Coq 8.18.0 on GitHub Actions.

## Kernel-certified R3 foundation

All of these modules passed `coqc -q` in [run 45048813377](https://github.com/shemshallah/nan0s/actions/runs/45048813377) at commit `fa494f67487404b73f61112fdd21559181ab1841`.

| Claim | Source | Kernel result |
| --- | --- | --- |
| Mirror involution and canonical projection | `NaN16Mirror.v` | PASS |
| Unique enumeration of strict canonical pairs | `NaN16Mirror.v` | PASS |
| 65,536 physical cells; 256 fixed; 32,640 mirror pairs; 32,896 representatives | `NaN16Mirror.v` | PASS |
| Injective 256 x 256 flat addressing | `NaN16Mirror.v` | PASS |
| Bit reversal swaps the physical coordinate representation | `NaN16Bits.v` | PASS |
| Physical bit encoding injective; fixed iff diagonal | `NaN16Bits.v` | PASS |
| Unique S+/S- representation of every off-diagonal address | `NaN16Signed.v` | PASS |
| Signed orientation and mirror channel algebra | `NaN16Signed.v` | PASS |

All three original Python exhaustive regressions passed in the same run. These are independent checks, not substitutions for kernel proofs.

## R4 candidate (pending new CI)

`NaN16Memory.v` adds a functional-update memory model and proofs that the two signed addresses of any strict canonical pair cannot overwrite each other, that unrelated addresses retain their values, and that orientation decoding returns the canonical pair. `check_memory.py` exhaustively checks all 32,640 strict pairs.

The new memory theorem package is **not kernel-certified** until the new CI run passes.

The abstract memory model does not prove correctness of any C, assembly, OS, firmware, or hardware implementation.

## Remaining open obligations

1. Connect bit-list words to numeric `rev8` and `rev16` address operations.
2. Prove refinement of the actual NaN/0S machine memory implementation to this abstract store model.
3. Specify and certify higher-order triangle/tetrahedron incidence and state transitions.
4. Benchmark and certify any concurrent/training dynamics separately.

No `Axiom` or `Admitted` statements are introduced in this theorem package.
