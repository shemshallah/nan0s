# TCC -> NaN16: self-hosting and the verified compiler chain

Status: P0.7, started. TCC source is vendored at
`third_party/tinycc` commit `5cef7f3f85b0fbbd4663fd3518ba097d7fe3d738`.

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
data `section_word*4+offset`), size-aware LDB/STB/LD/ST, stack arguments,
callee-saved frame pointer, 32-bit `CALLR` call/address relocations,
dynamic per-function frames, `.rodata`, `.data.ro`, `.data`, `.bss`,
`.rel.data`, and a 7-word entry prelude that sets the guest stack
(`0x300000` words), loads `main` as a 32-bit address, calls it with
`CALLR`, stores the result at 0x100 and halts.

## Self-host harness

`tools/tcc_nan16_selfhost.sh` preprocesses `libtcc.c`, links it with the
minimal NaN16 libc (`third_party/nan16-libc`) and a driver into a ~1.8 MB
cartridge.  The libc supplies a heap, strings, `printf`, `strtod`, math
helpers, setjmp/system stubs and a flat in-memory VFS, so the driver can
register `test.c` and retrieve `out.bin`.  The cartridge builds, but the
generated libtcc still traps in its first calls (a bad call/return after
~7k steps); its `tcc_new`/`tcc_mallocz` call and function-symbol/frame
layout is not yet correct, so `tcc_add_file`/`tcc_output_file` do not
produce a program.  Fixing that layout is the next tcc1 step.

Open before tcc1: fix the generated libtcc call/symbol/frame layout (the
self-host driver currently traps in its first calls), finish the VFS and
headers, and run tcc1 -> tcc2.  The softfloat runtime supplies IEEE binary64
add/sub/mul/div, comparison and conversion helpers.  The same runtime also
supplies `__divdi3`, `__udivdi3`, `__moddi3`, `__umoddi3`, `__ashldi3`,
`__ashrdi3` and `__lshrdi3`.

## The milestone

`tcc2` is the moment: TCC compiled by TCC on NaN16, compiling TCC again to a
byte-identical executable. At that point NaN16 is not "a VM that runs demos";
it is a self-hosting platform with its own C compiler, libc, VFS and linker.
The second gate is SQLite: the amalgamation compiles under `tcc2` and answers
queries. The third gate is the verified chain: the NaN16 binary is lowered to a
Binary TM, run on the Minsky UTM, and the trace is checked in Coq.

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
- The C stack and heap are NaN16 guest memory; no host C stack is used in the
  product path.

## Bootstrap

1. **tcc0**: host build of TCC with `TCC_TARGET_NAN16`; it emits NaN16
   cartridges and links against the NaN16 runtime.
2. **tcc1**: `tcc0` compiles the TCC sources on the VM. This is the first
   self-hosted compiler.
3. **tcc2**: `tcc1` compiles the TCC sources again. The gate requires a
   fixpoint: `tcc1` and `tcc2` byte-identical, or a documented canonical
   difference with a semantic equivalence check.
4. **SQLite**: `tcc2` compiles `sqlite3.c` (amalgamation), links the shell, and
   runs a query suite. This exercises the preprocessor, varargs, 64-bit
   integers, file I/O, allocator, libc and the linker at real scale.

## Verified chain

The existing NaN16/TM substrate is the bridge:

1. TCC emits a NaN16 binary (word stream + entry point).
2. The LLM -> Binary TM compiler lowers each NaN16 instruction/block to Binary
   TM transitions, preserving the architectural state.
3. The Minsky UTM executes the Binary TM; the run trace is recorded.
4. Coq checks the trace against the UTM semantics and the compiler-lowering
   relation.
5. The compiler-correctness statement ties TCC's source semantics to the
   executed Binary TM, so "the C code you compiled is the code that ran" is a
   checked artifact, not a claim.

This requires a formal NaN16 semantics, a proved lowering to Binary TM, and a
Coq-checked UTM. Those become explicit gates, not assumptions.

## Acceptance gates

- `tools/tcc_build.sh`: vendor build + NaN16 target smoke test.
- `tools/tcc_selfhost.sh`: tcc1 -> tcc2 fixpoint.
- `tools/tcc_sqlite.sh`: SQLite amalgamation + query suite.
- `tools/tcc_verified.sh`: binary -> Binary TM -> UTM -> Coq trace check.
- All of the above stay in `presqlite_gate`.

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
   [ ] Wire `TCC_TARGET_NAN16` into `tcc.h`/`configure` and implement
   `nan16-gen.c` against the encoder and ABI header.
2. Define `nan16-abi.h` from the ncc calling convention and write a
   bidirectional call test (TCC code calls ncc `printf`; ncc calls TCC code).
3. Implement the flat cartridge writer and relocations for `MOVI/MOVHI`,
   branches and data.
4. Bring up `tcc0` on a small C subset, then TCC's own sources.
