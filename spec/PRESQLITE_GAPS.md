# Pre-SQLite gap closure

This round runs five parallel workstreams against `main` at `f24ca88`.
Each works in a separate git worktree/branch; integration merges one branch at
a time and re-runs `tools/presqlite_gate.sh`.

| # | Gap | Before | Worktree / branch | Gate |
| - | --- | --- | --- | --- |
| 0 | Real allocator (S0) | closed | `6f5534e`, `2d47f9e` | `ncc_alloc` |
| 1 | Object-like replacement-text macros | **closed**; nested/blue-paint function+object macros | merged `ebd0b20` | `ncc_macro_text` |
| 2 | Real `#include` (quoted + system) | **closed**; NPAF relative/nested/guarded + standard placeholders | merged `f2262ad` | `ncc_include` |
| 3 | Correctly rounded float32 libm | **closed for \|x\| <= 65536**; 0/20,981 bit mismatches; larger args use coarse fallback | merged `5c153a6` | `ncc_libm_exact` |
| 4 | ISO C language/library gaps | **closed**; C11 language, uchar, wide stdio, atomic/fenv/threads | merged `dcdd823` | `ncc_iso_c` |
| 5 | c-testsuite / GCC torture | **52/56 pass, 4 documented skips**; GCC torture still out of tree | merged `122ca35` | `ncc_ctests` |

Already closed before this round:

- S0 boundary-tag free-list allocator, coalescing, 10,000-op gate.
- `& | ^` lowering and nested-subscript base-type fix.
- a1k0n donut first frame byte-identical to clang (x^9/x^11 sine terms).
- C89/C99 limits/stdint/float/stdio/locale/signal/math/wchar macros and
  fixed-width typedefs (`headers.nas`).
- Full `#if`/`#elif` integer/character/`defined`/ternary evaluator
  (`ppexpr.nas`).
- Correctly rounded float32 `sin`/`cos` for `|x| <= 65536`, exact
  `sqrt/fabs/floor/ceil/trunc/round`, and exact `fmod` for the gated range,
  using an in-guest double-float path (`ncc_libm_exact`, 20,981 comparisons).
- Object-like replacement-text macros with the C blue-paint rule, plus real
  quoted/system `#include` resolution (`ncc_macro_text`, `ncc_include`).
- The C heap is no longer a fixed arena: it starts at 256 KiB and grows on
  demand to the runtime stack guard.  The VM word count is runtime-sized
  (default 32M words = 128 MiB payload), discovered by the guest through
  CPUID 0x4E4D00FF, so the same image yields a 111.9 MB heap on the default
  VM and 6.9 MB on a 16M-word VM.  `ncc_alloc` allocates 100,000,000 bytes;
  `ncc_heap` checks 16/64/128/512 MiB VMs.

Coordination notes live in `~/presql_coord/`. Macros, include, libm, ISO C
and the c-testsuite baseline are merged; `tools/presqlite_gate.sh` is the
aggregate gate. Remaining: GCC torture, Csmith, and the SQLite workload.
