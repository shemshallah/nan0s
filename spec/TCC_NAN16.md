# TCC -> NaN16: self-hosting and the verified compiler chain

Status: P0.7, **tcc1 reached**. TCC source is vendored at
`third_party/tinycc` (upstream `5cef7f3f85b0fbbd4663fd3518ba097d7fe3d738`,
imported tree `dcb896d1c7ae2e64114c55c93f5223f92280bbdf`; see
`third_party/tinycc/VENDOR`).

The ABI contract is in `third_party/tinycc/nan16-abi.h` and the host-side
word encoder in `nan16-enc.c/.h`.  `tools/tcc_nan16_enc.sh` builds the
encoder and executes raw-word and `.nan` programs in `nan_cli`.

**tcc0 works.**  `third_party/tinycc/nan16-gen.c` and `nan16-link.c` implement
the mandatory TCC generator/linker surface.  `tools/tcc_nan16_smoke.sh`
builds TCC with `TCC_TARGET_NAN16`, compiles 37 C programs and runs each
flat cartridge directly in `nan_cli`.  Passing:

- `return 42`; `add(20,22)`; a `for` loop (sum 0..9 = 45)
- local/global arrays; recursion (`fact(5)` = 120); `switch`
- local pointers (`&x`, `*p`); string literals and `char` loads
- local and global structs
- function pointers (`int (*f)(int,int)=add; f(20,22)` -> 42)
- 64-bit pairs: `long long` add with arguments/return, recursive
  `fact(5)`=120, global 5e9 arithmetic, `(1<<40)>>32`=256
- struct-by-value arguments (`struct S {int a,b;}` passed to `sum`) and
  struct returns through the hidden pointer
- 64-bit division/modulo (`5e9/1e9`, negative and unsigned) and variable
  shifts, via a C runtime injected into every link
- comparisons as values and signed compares (`a == -5`, `a < 0`, `!x`)
- stack varargs with `int`, `long long` and `double`
- 8-byte IEEE-754 binary64 `double`: globals/locals/arrays/structs,
  arguments and returns, struct returns, function pointers, varargs,
  comparisons (NaN-aware), int/long long/float conversions, and
  add/sub/mul/div through a binary64 softfloat runtime
- `long double` is 8-byte and aliases `double` (`TCC_USING_DOUBLE_FOR_LDOUBLE`)

Coverage: byte-addressed C pointers (locals/params `SP*4+ci`/`FP*4+ci`,
data `section_word*4+offset`), size-aware LDB/STB/LD/ST and byte-composed
16-bit loads/stores, stack arguments, callee-saved frame pointer, 24-bit
absolute far branches (`0x38`), 32-bit `MOVI`/`MOVHI`+`CALLR` direct calls,
dynamic per-function frames, `.rodata`, `.data.ro`, `.data`, `.bss`,
`.rel.data`, and a 7-word entry prelude that sets the guest stack
(`0x300000` words), loads `main` as a 32-bit address, calls it with
`CALLR`, stores the result at 0x100 and halts.

## Self-host harness (tcc1)

`tools/tcc_nan16_selfhost.sh` preprocesses `libtcc.c`, links it with the
minimal NaN16 libc (`third_party/nan16-libc`) and a driver into a ~1.88 MB
cartridge (`self1`).  The libc supplies a heap, strings, `printf`, `strtod`,
math helpers, setjmp/system stubs and a flat in-memory VFS.  The driver
registers `test.c`, calls `tcc_new`/`tcc_add_file`/`tcc_output_file`, reads
`out.bin` from the VFS, stores the size at byte `0x02FFFFF0` and copies the
cartridge to byte `0x03000000`.

With `--run` the gate executes self1, extracts the inner cartridge, runs it,
and requires the inner `main` to return 42 at word `0x100`.  It passes in
about 20 seconds.

The earlier trap was a 16-bit branch-target truncation: libtcc functions
extend past word 65535, and `0x0A` branch immediates silently wrapped.  The
backend now emits 24-bit `0x38` absolute far jumps for every branch (target
split across the d/a/imm fields), patches three bytes, and the linker's
entry-prelude shift also handles 24 bits.  Direct calls remain 32-bit
`MOVI`/`MOVHI` + `0x2C CALLR`.  A text-only audit of self1 finds 9,000 far
jumps, 5,781 with targets above 64k words, a maximum target of 207,850, and
zero 16-bit branch instructions.

Other fixes required for tcc1:

- `MAX_ALIGN` is 16, so the built-in `__uint128__ ... aligned(16)` predef
  parses.
- Variable-shift count masking uses a scratch register holding 31; the NaN16
  ALU has no immediate AND.
- 16-bit loads/stores are composed from bytes (with signed extension); a
  full-word access pulled in neighbouring array elements.
- Whole-`SymAttr` assignments are 2-byte `memcpy`s.  A plain bitfield-struct
  assignment was emitted as a 4-byte bitfield-unit copy starting at
  `Sym.r`, zeroing the symbol's storage class; that made every direct
  function call go to `FP*4+2` instead of the function.  With this fix the
  guest compiler handles `add(20,22)`, recursive `fib(10)` and a
  loops/arrays/structs/switch test (returns 19).
- Address relocations prefer the stored symbol index when its name still
  matches (globals are updated after forward/tentative references), then the
  section/value captured for local literals whose symtab index moved, then
  name lookup.
- VFS file descriptors start at 3, so writes to the first files do not alias
  stdout/stderr (fd 1/2).

Next: tcc1 -> tcc2.  The flat writer, sections, relocations and 24-bit branch
model are in place; the next step is to compile the TCC sources with the
self-hosted libtcc and compare the resulting compiler with self1.  The
softfloat runtime supplies IEEE binary64 add/sub/mul/div, comparison and
conversion helpers, plus `__divdi3`, `__udivdi3`, `__moddi3`, `__umoddi3`,
`__ashldi3`, `__ashrdi3` and `__lshrdi3`.

### tcc2 fixpoint plan

The first tcc2 attempt compiles preprocessed sources (`libc.i`, `libtcc.i`,
`driver.i`) with self1, extracts `self2`, runs it on `test.c`, and compares
`self1` with `self2`.  Preprocessed input keeps the guest from needing the
host sysroot; raw-source compilation with a VFS include path is a later gate.

The selfcompile driver writes progress markers at guest byte `0x03100300`
(1=VFS setup, 2=tcc_new, 3..5=adding libc/libtcc/driver, 6=runtime compiled,
7..9=finished), so a budget-limited run identifies the active source.  It must
also compile `NAN16_RUNTIME_SRC` after the three input files, exactly like
`tcc.c`; otherwise the full TCC source's `__nan16_i2d`/`__nan16_dadd`/division
helpers are unresolved and `tcc_output_file` fails with
`nan16: unresolved address '__nan16_i2d'`.  The guest compiler's `init_assert`
was rewritten with explicit branches: the compound ternary/`&&` form was
miscompiled and fired with `offset=5 > data_offset=6`, a false positive that
aborted the libc.i compile at ~80M steps.

Fixpoint hazards to control before calling a mismatch a compiler bug:

- zero-fill section alignment padding and any `.bss`/reserve area;
- avoid `__DATE__`/`__TIME__` in emitted code, or pin them;
- keep `__FILE__`/`__BASE_FILE__` paths identical between the self1 and self2
  builds; the preprocessed `.i` files bake in the original paths;
- do not let pointer/hash iteration order reach section output (the flat
  writer uses a fixed section order and no symbol table);
- compare after stripping any remaining metadata, and record a canonical
  difference explicitly if one is unavoidable.

For toolchain integrity, build TCC with three independent compilers (ncc,
host tcc0, clang), have each resulting compiler compile the same source, and
compare deterministic outputs.  That is diverse double compilation, separate
from a compiler-correctness proof.

## The milestone

`tcc1` is reached: TCC compiled by TCC on NaN16, compiling `test.c` to a
cartridge that returns 42.  `tcc2` is the next moment: `tcc1` compiles the TCC
sources again to a byte-identical executable.  At that point NaN16 is not "a
VM that runs demos"; it is a self-hosting platform with its own C compiler,
libc, VFS and linker.  The SQLite gate remains deferred until the tcc2
fixpoint is stable.  The verified-chain gate is scoped in its own section
below.

## Port shape

TCC is a small retargetable C compiler. The port reuses:

- `tccgen.c` (parser, types, codegen driver, ABI decisions),
- `tccpp.c` (preprocessor) with a NaN/0S VFS for `#include`,
- `tccelf.c` / `tccrun.c` only where the ELF model is useful; otherwise a flat
  NaN16 cartridge writer and a small relocation pass,
- `libtcc1.c` replaced by a NaN16 runtime that matches the ncc C ABI.

New target files:

| file | purpose |
| --- | --- |
| `nan16-gen.c` | instruction encoding, addressing, prologue/epilogue, calls, varargs, 64-bit pairs, f32/f64 |
| `nan16-link.c` | relocation types and the flat cartridge/executable writer |
| `nan16-asm.c`, `nan16-tok.h` | inline assembler (optional until TCC needs it) |
| `nan16-abi.h` | register/stack/argument/return contract shared with ncc |
| `nan16-vfs.c` | `#include`, source files, model/SQLite files through the VFS |

## ABI contract (must match the ncc runtime)

- `r0 = 0`, `r13 = 1`, `r14 = C stack pointer`, `r15 = link register`.
- Scalar arguments and returns follow the ncc C ABI; the backend must be able
  to call ncc-compiled libc functions and be called by them.
- 64-bit integers are `(lo,hi)` pairs; TCC's `double` and `long double` are
  8-byte IEEE-754 binary64 values moved as two 32-bit words.  The ncc-side
  `double` is still being brought to the same layout (P0.2/P0.4).
- Structs by value, varargs and alignment must match the same ABI, not a
  TCC-private variant.
- ncc <-> TCC interop is a separate later gate.  Do not link ncc-compiled and
  TCC-compiled objects until the ncc `double` layout is 8 bytes and the
  bidirectional `printf`/call test passes; build the guest libc with tcc0 in
  the meantime.
- The C stack and heap are NaN16 guest memory; no host C stack is used in the
  product path.

## Bootstrap

1. **tcc0**: host build of TCC with `TCC_TARGET_NAN16`; it emits NaN16
   cartridges and links against the NaN16 runtime.
2. **tcc1 (reached)**: `tcc0` compiles the TCC sources on the VM, and the
   resulting self1 cartridge compiles `test.c` to a working cartridge.
   `tcc_nan16_selfhost --run` checks this end to end.
3. **tcc2 (next)**: `tcc1` compiles the TCC sources again. The gate requires a
   fixpoint: `tcc1` and `tcc2` byte-identical, or a documented canonical
   difference with a semantic equivalence check.
4. **SQLite (deferred)**: `tcc2` compiles `sqlite3.c` (amalgamation), links the
   shell, and runs a query suite. This exercises the preprocessor, varargs,
   64-bit integers, file I/O, allocator, libc and the linker at real scale.

## Verified chain (scope)

A trace check proves that a particular run of a particular binary is
consistent with the UTM semantics and the lowering relation.  It does **not**
by itself prove that the binary implements the C source: that requires
compiler correctness (CompCert-scale work) or translation validation for each
compile.  A full TCC self-compile on a Binary TM is also far too many steps to
check as a single Coq trace, so end-to-end traces are only practical for tiny
programs.

The scalable structure is:

1. Prove each NaN16 opcode/block lowering to Binary TM once, as a finite set
   of lemmas; any program then inherits the result compositionally.
2. Keep the Minsky UTM and Coq trace checker for small end-to-end witnesses
   and regression traces.
3. For toolchain integrity, use diverse double compilation: build TCC with
   ncc, host tcc0 and clang, compile the same source with each resulting
   compiler, and compare deterministic outputs.  This is the Wheeler-style
   defense against trusting-trust, separate from compiler correctness.
4. Scope the claim honestly as "binary execution is verified" plus a
   translation-validation/compiler-correctness obligation.  Do not claim that
   a trace checker alone proves "the C code you compiled is the code that ran".

The existing NaN16/TM substrate is the bridge: `formal/nan16` has the
bit-mirror, signed, memory and memory-algebra lemmas, and `tools/tm_gate.sh`
runs the same TM guest natively and nested inside the NaN16 interpreter and
requires byte-identical tape results.  The missing pieces are the per-opcode/
block lowering relation to Binary TM, the Minsky UTM trace checker, and the
compiler-correctness/translation-validation bridge.  Those remain explicit
gates, not assumptions.

## Acceptance gates

- `tools/tcc_nan16_smoke.sh`: tcc0 compiles and runs 37 C programs. Passing.
- `tools/tcc_nan16_selfhost.sh --run`: tcc0 builds self1; self1 compiles
  `test.c`, emits an inner cartridge, and the inner returns 42. Passing and
  wired into `presqlite_gate`.
- tcc2 mode (next): self1 compiles the TCC sources and the resulting self2 is
  compared with self1 (byte-identical fixpoint, or a documented canonical
  difference plus semantic checks).
- `tools/tcc_sqlite.sh` (deferred): SQLite amalgamation + query suite.
- `tools/tcc_verified.sh` (planned): finite opcode-lowering lemmas, UTM trace
  checks for small witnesses, and a scoped compiler-correctness or
  translation-validation statement.

## Dependencies / ordering

TCC cannot precede the ABI and memory work:

1. ISO C parity (P0.1-P0.3), including 64-bit `double`/`long long` and
   eventually 64-bit pointers.
2. x86-64/paging/64-bit memory (P0.4): model files, SQLite databases, large
   allocations.
3. SMP/isolation (P0.5-P0.6) for a usable hosted compiler/server.
4. TCC backend + runtime (this track).
5. C++17 (P1) for llama.cpp; TCC itself and SQLite are C and do not wait for
   C++.

## Immediate next steps

1. [x] ABI contract + host encoder + `main(){return 42;}` smoke test.
2. [x] Flat cartridge writer, 24-bit branches, 32-bit direct calls, sections,
   relocations and the entry prelude.
3. [x] tcc1: self1 compiles `test.c`; the inner cartridge returns 42.
4. [ ] tcc2: embed the TCC sources in a compile driver, have self1 produce
   self2, run self2, and compare self1/self2.
5. [ ] Enlarge the self-host corpus (fib/loops/structs/printf) before the full
   TCC source.
6. [ ] ncc <-> TCC bidirectional call test and the 8-byte `double` ABI audit.
7. [ ] Verified chain: opcode-lowering lemmas plus small UTM traces; scope the
   compiler-correctness statement honestly.
