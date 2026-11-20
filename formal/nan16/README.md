# NaN16 mirror formalization — Coq R1

This self-contained Coq source formalizes the 256-by-256 mirrored lattice as an involution on ordered pairs. It defines the canonical orientation, proves every cell has a canonical representative, and gives a duplicate-free enumeration of the strict upper triangle.

Intended theorems:

- `mirror_involutive`: applying the mirror twice is the identity.
- `mirror_fixed_iff_diagonal`: only diagonal cells are fixed.
- `project_idempotent` and `project_mirror`: normalization is stable and identifies mirror partners.
- `upper_pairs_sound`, `upper_pairs_complete`, `upper_pairs_nodup`: every unordered pair of distinct indices occurs exactly once in the upper-triangle enumeration.
- `nan16_mirror_counts`: 256 fixed diagonal cells, 32,640 strict mirror pairs, 32,896 canonical cells, and 65,536 ordered addresses.
- `flat_addr_injective`: no distinct valid 8-bit coordinate pairs collide under `256*a+b`.
- `physical_mirror_swap`: reversing a 16-bit encoded word swaps its two 8-bit coordinates.
- `physical_encoding_injective`: the encoding of two fixed-width bytes is injective.
- `physical_fixed_iff_diagonal`: 16-bit reversal fixes the physical address exactly when its coordinate bytes coincide.

## Verification

The source intentionally contains no `Admitted`, explicit axioms, or incomplete proofs. It has **not yet been kernel-checked** because the current execution environment has no `coqc`/`rocq` binary. Until a compiler passes, all proof obligations in this file should be marked **pending formal verification**, not certified.

For Coq 8.18+ (or a compatible Rocq release), run:

```sh
coqc -q NaN16Mirror.v
coqc -q NaN16Bits.v
```

The combinatorial count, enumerator uniqueness, and numeric bit-reversal semantics can also be checked independently with `python3 check_counts.py` and `python3 check_bit_reverse.py`. These are diagnostic checks **not** substitutes for the Coq kernel.

## Scope

This is a new, independent foundation based on the known NaN16 lattice specification, **not** an assertion that an earlier, unavailable Coq checkpoint was recovered. It does not conflate mirror-pair addresses with the larger triangle/tetrahedron conceptual geometry. The Boolean-list bit-reversal proof now covers the physical high-byte/low-byte encoding; a kernel-checked bridge to the integer arithmetic `rev8` function is a separate future refinement.
