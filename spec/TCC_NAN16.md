# TCC -> NaN16: self-hosting and the verified compiler chain

Status: P0.7, started. TCC source is vendored at
`third_party/tinycc` commit `5cef7f3f85b0fbbd4663fd3518ba097d7fe3d738`.

The ABI contract is in `third_party/tinycc/nan16-abi.h` and the host-side
word encoder in `nan16-enc.c/.h`.  `tools/tcc_nan16_enc.sh` builds the
encoder and executes raw-word and `.nan` programs in `nan_cli`.

**tcc0 works.**  `third_party/tinycc/nan16-gen.c` and `nan16-link.c` implement
the mandatory TCC generator/linker surface.  `tools/tcc_nan16_smoke.sh`
builds TCC with `TCC_TARGET_NAN16`, compiles 13 C programs and runs each
flat cartridge directly in `nan_cli`.  Passing:

- `return 42`; `add(20,22)`; a `for` loop (sum 0..9 = 45)
- local/global arrays; recursion (`fact(5)` = 120); `switch`
- local pointers (`&x`, `*p`); string literals and `char` loads
- local and global structs
- function pointers (`int (*f)(int,int)=add; f(20,22)` -> 42)
- 64-bit pairs: `long long` add with arguments/return, recursive
  `fact(5)`=120, global 5e9 arithmetic, `(1<<40)>>32`=256
- struct-by-value arguments (`struct S {int a,b;}` passed to `sum`)

Coverage: byte-addressed C pointers (locals/params `SP*4+ci`/`FP*4+ci`,
data `section_word*4+offset`), size-aware LDB/STB/LD/ST, stack arguments,
callee-saved frame pointer, absolute jump/call relocations, `.rodata`,
`.data.ro`, `.data`, `.bss`, `.rel.data`, and the 4-word entry prelude
(`MOVI r14,0x8000; CALL main; ST r1,r0,0x100; HALT`).

Open before tcc1: 64-bit division/modulo (generic `gen_opl` calls
`__divdi3/__moddi3`, which are not provided yet), struct **returns**
(currently crash; `func_vc` hidden-pointer handling is missing), varargs,
`double`, external libc/libtcc1, and the VFS.

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
- 64-bit integers are `(lo,hi)` pairs; `double` becomes IEEE-754 binary64 (the
  current ncc ABI is still 32-bit for `double` and pointers; the 64-bit ABI
  work in P0.2/P0.4 is a dependency).
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
