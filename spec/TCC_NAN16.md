# TCC -> NaN16: self-hosting and the verified compiler chain

Status: P0.7, **tcc1 and tcc2 reached** (byte-identical fixpoint), and the
**raw-source tcc1 self-build (C1b) is reached**: the self-hosted compiler reads
raw `libtcc.c` and its headers from an N16PACK1 guest VFS and emits a
replacement compiler R that compiles `test.c` to 42. SQLite 3.54.1 is vendored
and runs as a raw NaN16 cartridge. TCC source is
vendored at `third_party/tinycc` (upstream
`5cef7f3f85b0fbbd4663fd3518ba097d7fe3d738`, imported tree
`dcb896d1c7ae2e64114c55c93f5223f92280bbdf`; see
`third_party/tinycc/VENDOR`).

The ABI contract is in `third_party/tinycc/nan16-abi.h` and the host-side
word encoder in `nan16-enc.c/.h`.  `tools/tcc_nan16_enc.sh` builds the
encoder and executes raw-word and `.nan` programs in `nan_cli`.

**tcc0 works.**  `third_party/tinycc/nan16-gen.c` and `nan16-link.c` implement
the mandatory TCC generator/linker surface.  `tools/tcc_nan16_smoke.sh`
builds TCC with `TCC_TARGET_NAN16`, compiles 40 C programs and runs each
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
- `?:` with comparison-valued arms, including a saved and later merged
  `VT_CMP` (32-bit and 64-bit `>`/`>=`/`==`/`!=`)
- constant-address lvalues: `*(volatile T *)ADDR` dereferences instead of
  returning `ADDR`
- bit-field runs whose declared container is not naturally aligned (the
  SQLite `sqlite3InitInfo` layout)

Coverage: byte-addressed C pointers (locals/params `SP*4+ci`/`FP*4+ci`,
data `section_word*4+offset`), size-aware LDB/STB/LD/ST and byte-composed
16-bit loads/stores, stack arguments, callee-saved frame pointer, 24-bit
absolute far branches (`0x38`), 32-bit `MOVI`/`MOVHI`+`CALLR` direct calls,
dynamic per-function frames, `.rodata`, `.data.ro`, `.data`, `.bss`,
`.rel.data`, and a 7-word entry prelude that sets the guest stack
(`0x300000` words), loads `main` as a 32-bit address, calls it with
`CALLR`, stores the result at 0x100 and halts.

## Self-host harness (tcc1 and tcc2)

`tools/tcc_nan16_selfhost.sh` preprocesses `libtcc.c`, links it with the
minimal NaN16 libc (`third_party/nan16-libc`) and a driver into a ~2.53 MB
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

Result: self1 compiles the TCC sources with the self-hosted libtcc to a
byte-identical self2 (2,031,584 bytes), and self2 compiles `test.c` to 42.
The softfloat runtime supplies IEEE binary64 add/sub/mul/div, comparison and
conversion helpers, plus `__divdi3`, `__udivdi3`, `__moddi3`, `__umoddi3`,
`__ashldi3`, `__ashrdi3` and `__lshrdi3`.

### tcc2 fixpoint

The first tcc2 attempt compiles preprocessed sources (`libc.i`, `libtcc.i`,
`driver.i`) with self1, extracts `self2`, runs it on `test.c`, and compares
`self1` with `self2`.  Preprocessed input keeps the guest from needing the
host sysroot; raw-source compilation with a VFS include path is a later gate.

The selfcompile driver writes progress markers at guest byte `0x03F00000`
(1=VFS setup, 2=tcc_new, 3..5=adding libc/libtcc/driver, 6=runtime compiled,
7..9=finished), so a budget-limited run identifies the active source.  The
marker is deliberately outside the `0x03000000` output-copy buffer; at
`0x03100300` the final marker write corrupted four bytes of the copied
cartridge.  A checkpoint taken when the size word at `0x02FFFFF0` becomes
nonzero can still be mid-copy; wait for marker 9 before extracting.

The driver must compile `NAN16_RUNTIME_SRC` after the three input files,
exactly like `tcc.c`; otherwise the full TCC source's
`__nan16_i2d`/`__nan16_dadd`/division helpers are unresolved and
`tcc_output_file` fails with `nan16: unresolved address '__nan16_i2d'`.
The guest compiler's `init_assert` was rewritten with explicit branches after
a compound ternary/`&&` form fired with `offset=5 > data_offset=6`, a false
positive that aborted the libc.i compile at ~80M steps.  The underlying
`?:`/`VT_CMP` bug is fixed now (see the SQLite section); the explicit form is
retained for clearer diagnostics.

The last byte-level fixpoint difference was the guest libc's `strtod`.  It
accumulated integer digits in a 64-bit `mant` without an overflow check, so
`2^64` and `2^96` wrapped to zero, and it built DBL_MAX by 292 successive
multiplications, losing the low bits.  It now keeps 19 significant digits,
tracks the discarded digits for round-to-nearest-even, and applies one
correctly rounded power of ten from a generated table
(`third_party/nan16-libc/src/nan16_pow10.h`).  self1 and tcc0 emit
byte-identical cartridges for a test using DBL_MAX, 2^64 and 2^96.  The
fixpoint run then completes within the 4,000,000,000-step gate budget:
`self1` and `self2` are both 2,031,584 bytes and byte-identical, and self2
compiles `test.c` to a 144-byte cartridge whose `main` returns 42.  The
fixed-point image SHA-256 is
`812c252e4d89b5146c1129e77f58abd01fb95a967159291c63da0dde73451183`
for this tree and the documented build commands; the scratch harness and
`tools/tcc_nan16_tcc2.sh` reproduce the same bytes.  The earlier
1,891,544-byte / `9af0d603...` fixpoint predates the SQLite-driven compiler
corrections and is superseded by this hash.

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

## Raw-source self-build (C1b)

`tools/tcc_nan16_selfbuild.sh` moves the self-build input from host-preprocessed
`.i` blobs to raw source files.  A tcc1 builder reads an N16PACK1 archive from
the guest VFS, compiles raw `libtcc.c` (with its headers), raw `libc.c` and the
generic build driver into a replacement compiler R, then runs R.  R compiles
raw `test.c` to a 42 cartridge; the R output is byte-identical to the tcc0
oracle for that program.  Sizes/hashes from the current tree:

- R (replacement compiler, 1,940,000 bytes) SHA-256
  `2ba83eb61cab39d94f15f5c2f71ce1911f68cb99bab53b95c680841155469d0d`.
- test cartridge 210,360 bytes, `main` returns 42.

The builder itself is still produced by tcc0 from a preprocessed bootstrap
`libtcc.i`; that is the bootstrap stage, not the product.  R and every source
input to it are raw C.  The compiler image contains no host path.

N16PACK1 is the single guest archive format
(`src/tests/tcl_sqlite/PACK_FORMAT.md`, `tools/nan16_suite_pack.py`).  A pack is
a byte stream; `tools/nan16_pack_image.py` packs four bytes per NaN16 payload
word and places it at a checked guest base.  `nan16_vfs_add_pack()` uses the
dynamic VFS table (`NAN16_VFS_INIT_CAP`, optional `NAN16_VFS_MAXFILES`), so a
2,133-file suite is not truncated.  `tools/tcc_nan16_vfs_pack.sh` verifies
every byte of a 256-byte pattern, a non-ASCII blob crossing a payload-word
boundary, and a 2,133-file pack whose last entry is read back; it also checks
the 25.8 MB suite layout and the `printf` `*` width/precision paths.

Memory map for the self-build gate (guest byte addresses):

| range | use |
| --- | --- |
| 0x00000000 | flat compiler image |
| 0x00800000 | compiler image floor / stack grows down from 0x00c00000 |
| 0x00c00000-0x00ffffff | reserved for the x86_64 S1 trap/kernel frame |
| 0x01000000 | low N16PACK1 base (self-build and SQLite packs) |
| 0x03000000 | output copy 0 (8 MiB) |
| 0x03800000 | output copy 1 (8 MiB) |
| 0x03e00000 | diagnostics |
| 0x03f00000 | progress word |
| 0x04000000 | heap (128 MiB in the self-build gate) |

The pack tool rejects a base below the stack top, a guest span that crosses
the next region, or an encoded host image over its budget.  The 25.8 MB Tcl
suite pack spans 0x01000000..0x0289c700, so it remains below the output copy;
its encoded host image is 51,613,184 bytes plus 32 MiB of word padding.

**SQLite-on-R status:** R compiles the vendored 3.54.1 amalgamation,
`nan16_vfs.c` and the SQL probe from the same raw VFS and emits a
6,727,720-byte cartridge that is **byte-identical to the tcc0-built oracle**.
The probe finishes in 8,789,447 steps with sum=6, count=3, max="two" and the
expected magic words.  The earlier hang was a linker-state leak, not a
SQLite or data-layout defect: `nan16_relocs`/`nan16_addr_relocs`/jump fixups
are file-scope arrays, and a process that compiles job 0 and job 1 in sequence
(the generic build driver) applied job 0's relocations to job 1's text at the
same byte offsets.  `tcc_new()` now resets the NaN16 linker state; the
regression is `tools/tcc_nan16_multijob.sh` (job a returns 0, job b returns 42;
disabling the reset makes job b return 1).  Removing the stale patches makes
R's SQLite output identical to tcc0's.

## The milestone

`tcc1` and `tcc2` are reached.  `tcc1` is TCC compiled by TCC on NaN16; it
compiles `test.c` to a cartridge that returns 42.  `tcc2` is self1 compiling
the TCC sources again to a byte-identical 2,031,584-byte self2, which also
compiles `test.c` to 42.  NaN16 is now a self-hosting platform with its own C
compiler, libc, VFS and linker.  The fixpoint completes within the
gate budget.  The raw-source tcc1 rebuild R also compiles SQLite 3.54.1 +
the NaN16 VFS + probe from the guest VFS to the byte-identical tcc0
cartridge (sum=6,count=3,max="two").  The verified-chain gate remains scoped
in its own section below.

## Guest console capture

The guest libc publishes its captured console buffers at a fixed guest
control block so any terminal client can retrieve them without host symbols:

| guest byte | contents |
| --- | --- |
| `0x03EFF000` | stdout buffer pointer (word payload) |
| `0x03EFF004` | stdout length in bytes |
| `0x03EFF008` | stderr buffer pointer |
| `0x03EFF00C` | stderr length |

`nan_cli` exposes this as `--guest-stdout FILE` and `--guest-stderr FILE`.
`tools/nan16_console_gate.sh` verifies `printf`/`fprintf` output exactly; it
uses the portable C core only as an oracle and accepts an x86_64 runner via
`NAN16_CONSOLE_RUNNER`.

## Guest time

The runner publishes monotonic time at guest byte `0x03EFF010`:

| guest byte | contents |
| --- | --- |
| `0x03EFF010` | milliseconds since boot |
| `0x03EFF014` | executed steps, low 32 bits |
| `0x03EFF018` | executed steps, high 32 bits |

The libc implements `gettimeofday`, `time`, `clock`, `clock_gettime` and
`nanosleep` from this block. `gmtime`/`localtime` convert to UTC (locale and
timezone files are not ported yet). `tools/nan16_time_gate.sh` checks time
advance, a 10 ms sleep, and exact UTC values for 0 and 1700000000. The x86_64
S1 kernel must publish the same block from its timer IRQ.

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
| `nan16-vfs.c` | `#include`, source files, model files through the VFS |
| `third_party/sqlite/nan16_vfs.c` | SQLite base VFS and `sqlite3_os_init/os_end`; named in-memory files |

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
3. **tcc2 (reached)**: `tcc1` compiles the TCC sources again to a
   byte-identical `self2` (2,031,584 bytes).  The gate runs `self2` on
   `test.c` (inner `main` returns 42) and checks `self1 == self2`.
4. **SQLite (reached)**: host `tcc0` cross-compiles the vendored 3.54.1
   amalgamation with `SQLITE_OS_OTHER=1` and `third_party/sqlite/nan16_vfs.c`
   into a raw NaN16 cartridge.  `tools/tcc_sqlite.sh` runs a 96-result suite
   (schema, binds, aggregates, index, join, update/delete, transaction
   rollback/commit, type round-trips, close/reopen) plus a 256-result 500-row
   stress database (multi-page btrees, overflow blobs, `GROUP BY`, `VACUUM`,
   reopen).  Every result word matches the native build, and a
   `SQLITE_DEBUG` build with all SQLite assertions enabled also matches and
   finishes.  The current path is `tcc0`; compiling the 9.2 MB amalgamation
   with the guest `tcc2` is a separate, much larger budget gate.

## SQLite bring-up (compiler corrections)

The SQLite port was also the best compiler test in the tree: a 9.2 MB C
program with varargs, 64-bit integers, floating point, large frames, unions,
bit-fields and heavy preprocessing.  Six real defects were found and fixed in
the compiler/libc, not worked around in SQLite:

- **Unaligned bit-field containers.**  NaN16 memory is word-addressed.
  TCC's generic bit-field path may use the declared `unsigned` container even
  when a bit-field run starts at a non-natural byte offset (SQLite's
  `newTnum`/`iDb`/`busy`/bit-fields layout starts one at byte 6).  The backend
  truncated the address to the containing word and applied the mask at bit 0,
  so `db->init.orphanTrigger = 0` cleared `iDb` (and nearly cleared `busy`).
  `check_fields()` now applies the same natural-alignment rule already used by
  the ARM targets: bit-fields on NaN16 use a naturally aligned byte/short/int
  container or the byte-wise fallback.
- **`VT_CMP` lifetime.**  The backend kept one global pending comparison.
  `?:` saves a comparison, generates the other arm (replacing the globals),
  then restores the saved value; its operands were lost and the branch tested
  stale flags from the wrong comparison.  `SValue.cmp_r` now carries the
  register pair and signedness (`a | b<<4 | signed<<8`), and `gjmp_cond`/
  `load` re-emit the `CMP` when the value is finally consumed.  This fixed
  `eq ? (a > b) : (a >= b)` (wrong for `a == b`) and SQLite's
  `checkTreePage()` false `Rowid ... out of order` reports.  The raw database
  image was byte-identical to native all along.
- **Constant-address lvalues.**  The non-symbol `VT_CONST` load path
  materialised the address but skipped the dereference, so
  `*(volatile T *)ADDR` read the address.  The `VT_LVAL` case now emits the
  size-aware load.
- **Member offsets through saved lvalues.**  `gaddrof()` on a `VT_LLOCAL`
  base converted it to `VT_LOCAL|VT_LVAL`, which made the backend treat the
  member offset in `c.i` as a stack-slot index.  It now materialises the
  saved pointer in a register.  Field addresses in registers clear `c.i`;
  genuine register-lvalue displacements are still honoured.
- **Allocator alignment.**  The free-list header was 12 bytes, so payloads
  were only 4-byte aligned; SQLite's `EIGHT_BYTE_ALIGNMENT` assertion fired.
  The header is padded to 16 bytes.  The temporary bump allocator used during
  bring-up was removed.
- **Headers/diagnostics.**  `stdint.h` gained the C99 `INT*_C`/`UINT*_C`
  macros, `assert.h` honours `NDEBUG`, and `NAN16_ASSERT_DIAG` reports a
  failing SQLite assertion (expression/file/line) through fixed guest memory
  for the debug gate.  `NAN16_MAP=1` emits a word-address symbol map from the
  linker for VM watchpoint work.

The SQLite build uses `SQLITE_OS_OTHER=1`, `SQLITE_THREADSAFE=0`,
`SQLITE_TEMP_STORE=3`, `SQLITE_OMIT_WAL`, and the in-memory VFS.  No SQLite
field sizes, page sizes or allocator layouts are patched; the vendored
`sqlite3.c` hashes match upstream (see `third_party/sqlite/VENDOR`).

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

- `tools/tcc_nan16_smoke.sh`: tcc0 compiles and runs 40 C programs. Passing.
- `tools/tcc_nan16_selfhost.sh --run`: tcc0 builds self1; self1 compiles
  `test.c`, emits an inner cartridge, and the inner returns 42. Passing and
  wired into `presqlite_gate`.
- `tools/tcc_nan16_rawcc.sh`: tcc1 preprocesses and compiles raw `libc.c`
  plus a program with guest-VFS `/usr/include` headers, links a
  210,512-byte inner cartridge, and verifies its `main` returns 42. Passing.
- `tools/tcc_nan16_vfs_pack.sh`: verifies the N16PACK1 payload-word encoding
  byte-for-byte (including a non-ASCII blob crossing a word boundary), the
  dynamic VFS with a 2,133-file pack whose last entry is readable, the
  25.8 MB suite layout, and libc `printf` `*` width/precision. Passing.
- `tools/tcc_nan16_selfbuild.sh`: tcc1 compiles raw `libtcc.c` + raw `libc.c`
  + the build driver from the guest VFS into R (1,940,000 bytes, SHA-256
  `2ba83eb61cab39d94f15f5c2f71ce1911f68cb99bab53b95c680841155469d0d`);
  R compiles raw `test.c` to 42 and compiles SQLite 3.54.1 + the VFS + probe
  to a 6,727,720-byte cartridge byte-identical to tcc0, running with
  sum=6,count=3,max="two". Passing.
- `tools/tcc_nan16_multijob.sh`: two independent TCCState jobs in one guest
  process; job a -> 0, job b -> 42.  This is the linker relocation-state
  reset regression (disabling the reset makes job b return 1). Passing.
- `tools/tcc_nan16_tcc2.sh`: self1 compiles the TCC sources to a
  byte-identical self2 (2,031,584 bytes); self2 also compiles `test.c` to a
  144-byte cartridge whose `main` returns 42.  Passing within the 8.0B-step cumulative
  budget, resumable in slices.  SHA-256
  `812c252e4d89b5146c1129e77f58abd01fb95a967159291c63da0dde73451183`.
- `tools/tcc_sqlite.sh`: vendored SQLite 3.54.1 plus the NaN16 in-memory VFS;
  suite, 500-row stress database, and `SQLITE_DEBUG` assertion build all
  match native bit-for-bit.  Passing (standalone; the pre-SQLite battery stays
  the 122-gate regression set).
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
4. [x] tcc2: self1 compiles the TCC sources to a byte-identical 2,031,584-byte
   self2; self2 compiles `test.c` to 42.
5. [x] SQLite 3.54.1: vendored, cross-compiled by tcc0, and exercised by
   `tcc_sqlite` (suite/stress/assert builds match native).
6. [x] C1b/C2: tcc1 builds R from raw `libtcc.c`; R compiles raw `test.c` to
   42 and compiles SQLite 3.54.1 + the VFS + probe to a byte-identical
   oracle cartridge (sum=6, count=3, max="two").  The multi-job linker-state
   reset is covered by `tools/tcc_nan16_multijob.sh`.
7. [ ] Broaden the guest-compiler/program corpus (printf, libm, struct-heavy
   and varargs programs) beyond add/fib/loops/structs/switch and the
   double-constant test.
8. [ ] ncc <-> TCC bidirectional call test and the 8-byte `double` ABI audit.
9. [ ] Verified chain: opcode-lowering lemmas plus small UTM traces; scope the
   compiler-correctness statement honestly.
