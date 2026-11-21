# Pre-SQLite gap closure

This round runs five parallel workstreams against `main` at `f24ca88`.
Each works in a separate git worktree/branch; integration merges one branch at
a time and re-runs `tools/presqlite_gate.sh`.

| # | Gap | Before | Worktree / branch | Gate |
| - | --- | --- | --- | --- |
| 0 | Real allocator (S0) | closed | `6f5534e`, `2d47f9e` | `ncc_alloc` |
| 1 | Object-like replacement-text macros | numeric-only | `presql_wt/macros`, `presql/macros` | `ncc_macro_text` |
| 2 | Real `#include` (quoted + system) | skipped | `presql_wt/include`, `presql/include` | `ncc_include` |
| 3 | Correctly rounded float32 libm | ~1 ulp off for most inputs | `presql_wt/libm`, `presql/libm` | `ncc_libm_exact` |
| 4 | ISO C language/library gaps | C11/wide-stdio exclusions | `presql_wt/iso`, `presql/iso` | `ncc_iso_c` |
| 5 | c-testsuite / GCC torture | no suite in tree | `presql_wt/ctest`, `presql/ctest` | `ncc_ctests` |

Already closed before this round:

- S0 boundary-tag free-list allocator, coalescing, 10,000-op gate.
- `& | ^` lowering and nested-subscript base-type fix.
- a1k0n donut first frame byte-identical to clang (x^9/x^11 sine terms).
- C89/C99 limits/stdint/float/stdio/locale/signal/math/wchar macros and
  fixed-width typedefs (`headers.nas`).
- Full `#if`/`#elif` integer/character/`defined`/ternary evaluator
  (`ppexpr.nas`).

Coordination notes live in `~/presql_coord/`. Integration order is macros,
include, libm, iso, ctest; each merge must keep `presqlite_gate` green.
