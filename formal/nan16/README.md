# NaN16 mirror formalization — Coq R1

This self-contained Coq source formalizes the 256-by-256 mirrored lattice as an involution on ordered pairs. It defines the canonical orientation, proves every cell has a canonical representative, and gives a duplicate-free enumeration of the strict upper triangle.

Intended theorems:

- `mirror_involutive`: applying the mirror twice is the identity.
- `mirror_fixed_iff_diagonal`: only diagonal cells are fixed.
- `project_idempotent` and `project_mirror`: normalization is stable and identifies mirror partners.
- `upper_pairs_sound`, `upper_pairs_complete`, `upper_pairs_nodup`: every unordered pair of distinct indices occurs exactly once in the upper-triangle enumeration.
- `nan16_mirror_counts`: 256 fixed diagonal cells, 32,640 strict mirror pairs, 32,896 canonical cells, and 65,536 ordered addresses.
- `flat_addr_injective`: no distinct valid 8-bit coordinate pairs collide under `256*a+b`.

## Verification

The source intentionally contains no `Admitted`, explicit axioms, or incomplete proofs. It has **not yet been kernel-checked** because the current execution environment has no `coqc`/`rocq` binary. Until a compiler passes, all proof obligations in this file should be marked **pending formal verification**, not certified.

For Coq 8.18+ (or a compatible Rocq release), run:

```sh
coqc -q NaN16Mirror.v
```

The combinatorial count and enumerator uniqueness can also be checked independently with `python3 check_counts.py`, which is a diagnostic check **not** a substitute for the Coq kernel.

## Scope

This is a new, independent foundation based on the known NaN16 lattice specification, **not** an assertion that an earlier, unavailable Coq checkpoint was recovered. It does not conflate mirror-pair addresses with the larger triangle/tetrahedron conceptual geometry. The connection to `rev8` and bit-level palindromic 16-bit encodings remains a separate proof task.
