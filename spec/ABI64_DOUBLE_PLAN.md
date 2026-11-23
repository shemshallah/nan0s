# ABI64: `double` = 8 bytes / align 8 in ncc

Status: implementation plan. The investigation was read-only; no ncc source
file was modified. This plan is the only file written by this task.

Baseline used for line numbers: `3eee07d` ("ncc: 64-bit long long ABI
runtime gate"). That commit added `ncc_abi_ll`, so the tree currently has
**77** compiler-family gates, not 76. The task's "76" is the pre-`ncc_abi_ll`
baseline. After phase 5 this plan adds `ncc_abi_double`, making it 78.
`py_m1` is a separate compiler-adjacent gate and must also stay green.

---

## 0. Executive summary

1. `double` and `float` are currently the **same kind** (`TY_FLOAT`) and the
   same size/alignment (4/4). There is no `TY_DOUBLE` kind.
2. There is no 64-bit C load/store path. `ni_loadv`/`ni_storev` only implement
   1, 2 and 4-byte accesses. `long long` has a private pair path
   (`I_LLOAD`/`I_LLSTORE` + `ni_store64`); `double` has none.
3. Phase 1 (type table size/align + struct layout) can be made green with
   **only** a type-table edit and two test-side edits (one expected file and
   one test source), because every existing double operation stays one word
   and keeps using the low-addressed word. It is deliberately a layout-only phase: `sizeof`/`_Alignof`/struct
   offsets change, but the value representation does not.
4. Phase 2 (real 8-byte load/store as two words) **cannot** be split into
   "load/store only". Every consumer of a `double` value must switch at the
   same time: assignment, casts, arithmetic, comparisons, conditions,
   arguments, returns, varargs, `printf`, and builtin returns. This is the
   main risk callout in this document.
5. Phase 3's practical implementation for this VM is the existing f32
   double-float idiom (`nix_dadd`/`nix_dsub`/`nix_dmul`, extended with
   `nix_ddiv`). It gives ~48 significant bits, **not** IEEE-754 binary64.
   True binary64 requires a separate softfloat phase; size/alignment alone
   does not make `double` C-conformant.
6. `long double` is not a separate type in ncc. `pts_double`
   (`src/lib/ncc.nas:4602-4607`) sets `W_TFLOAT=2`, and `pts_choose`
   (`src/lib/ncc.nas:4662-4667`) maps both `double` and `long double` to
   `T_DOUBLE` (id 11). Type entry **12 is `_Bool`**, not `long double`
   (`src/lib/ncc.nas:309-312`, `2113-2120`). Therefore this change also makes
   `sizeof(long double) == 8` unless a new type id is introduced.

---

## 1. Investigation results

### 1.1 Type table entries 10/11 and 12

`src/lib/ncc.nas:2143-2157`:

```
; 10 float, 11 double (32-bit payload representation)
10 -> TY_FLOAT, size 4, align 4, signed 1, base 0
11 -> TY_FLOAT, size 4, align 4, signed 1, base 0
```

- Type kinds are at `src/lib/ncc.nas:275-285`: `TY_VOID=0`, `TY_INT=1`,
  `TY_FLOAT=2`, `TY_PTR=3`, `TY_ARRAY=4`, `TY_STRUCT=5`, `TY_UNION=6`,
  `TY_FUNC=7`, `TY_ENUM=8`, `TY_BOOL=9`, `TY_LL=10`. There is no
  `TY_DOUBLE`.
- Built-in ids are at `src/lib/ncc.nas:298-312`: `T_FLOAT=10`,
  `T_DOUBLE=11`, **`T_BOOL=12`**, `T_LONGLONG=13`, `T_ULONGLONG=14`.
- Entry 12 is initialized as `_Bool` with kind `TY_BOOL`, size/align 1
  (`src/lib/ncc.nas:2113-2120`). It is not `long double`.
- Entry 13/14 (`long long`) is already 8/8 after commit `92ad61c`
  (`src/lib/ncc.nas:2158-2172`). That commit is the exact template for a
  pure layout change: two type-table words plus expected-file updates.
- `ty_size`/`ty_align`/`ty_kind` are generic table readers
  (`src/lib/ncc.nas:2196-2213`). Struct layout uses `ty_size` and `ty_align`
  (`src/lib/ncc.nas:5200-5325`), so changing the double entry automatically
  changes member offsets, struct size and struct alignment.
- `px_align_up` (`src/lib/ncc.nas:13197-13207`) already handles any positive
  alignment (it divides/multiplies), so align 8 needs no change.
- Local/global allocation uses `ty_size`/`ty_align` at
  `src/lib/ncc.nas:14408-14413` (function pointers), `14817-14829`
  (locals), `16356-16368` (globals), `16786-16790` and `16890-16900`
  (function parameters), and `7878-7897` (builtin globals). All are generic.

### 1.2 How values are loaded/stored and how float codegen is selected

Load/store size codes are at `src/lib/ncc.nas:314-319`:

```
SZ_8S=0 SZ_8U=1 SZ_16S=2 SZ_16U=3 SZ_32=4
```

There is **no SZ_64**. `ty_store_code` (`src/lib/ncc.nas:2515-2551`) maps
size 1 and 2 to the narrow codes and everything else (including size 8) to
`SZ_32`. `ni_loadv` (`src/lib/ncc.nas:17179-17231`) and `ni_storev`
(`src/lib/ncc.nas:17233-17266`) implement only 1/2/4-byte accesses; any
code other than 0-3 falls through to the 32-bit path.

The one existing 64-bit C value is `long long`, handled specially:

- `px_emit_load` (`src/lib/ncc.nas:9357-9424`) checks `TY_LL` and emits
  `I_LLOAD`; otherwise it uses `ty_store_code` + `I_LOAD`.
- `px_emit_store` (`src/lib/ncc.nas:9426-9517`) checks `TY_LL` and emits
  `I_LLSTORE`; otherwise `I_STORE`/`I_STORE_K` or `I_BITSTORE`.
- `px_discard` (`src/lib/ncc.nas:9339-9355`) pops two words for `TY_LL`.
- `ni_store64` exists at `src/lib/ll.nas:868-889`; `ll_load` at
  `src/lib/ll.nas:666-700` pops an address and pushes the pair.
- IR dispatch is `src/lib/ncc.nas:22868-23078`; the LL handlers are at
  `src/lib/ncc.nas:23080-23207`.
- `ni_call` copies `long long` arguments with `ncl_copy_ll`
  (`src/lib/ncc.nas:22659-22677`) and returns them via `I_RET 2`
  (`px_ret_emit`, `src/lib/ncc.nas:16157-16175`; `ni_ret`,
  `src/lib/ncc.nas:22752-22802`).

Float values are one 32-bit payload word. `TY_FLOAT` selects native NaN16
`FADD/FSUB/FMUL/FDIV/FSQRT/FCMP/CVTIF/CVTFI` paths:

- Binary operators: `p_binop` (`src/lib/ncc.nas:11427-11920`), float branch
  `pb_float` at `src/lib/ncc.nas:11745-11838`; LL branch `pb_ll` at
  `11852`. `ty_common` (`src/lib/ncc.nas:2437-2513`) returns `T_FLOAT`
  when either operand kind is `TY_FLOAT`.
- Unary minus: `pu_minus` (`src/lib/ncc.nas:10915-10941`) emits `I_FNEG`.
- `!`: `pu_lnot` (`src/lib/ncc.nas:10944-10960`).
- Loads/stores and casts are selected by `ty_store_code`.
- Native float ops are implemented in the interpreter at
  `src/lib/ncc.nas:23669-23770` (`nil_fadd` … `nil_fne`), and via `I_CAST`
  codes 5 (`CVTIF`) and 6 (`CVTFI`) at `src/lib/ncc.nas:23591-23650`.
  Note: adding `SZ_64=5` would collide with the existing `itof` cast code 5.
  Use a non-conflicting code (this plan uses `SZ_64=7`).

Other directly relevant `TY_FLOAT` checks:

| Site | Line | Purpose |
| --- | ---: | --- |
| `ty_common` | 2454, 2459 | usual arithmetic type |
| `px_cast_stack` | 9578, 9609, 9637 | source-float check, float-to-LL, LL-to-float |
| `pu_minus` | 10921 | unary minus |
| `pb_scalar` | 11536 | binary operator dispatch |
| `pb_float` | 11747, 11759 | LL-to-float widening |
| `pp_flit` | 9770 | unsuffixed float literal is `T_FLOAT` |

### 1.3 Arguments, returns, varargs, printf and the libm helpers

- IR values live on a word-indexed evaluation stack. `I_CALL` packs
  `argc` in the low 16 bits and **total argument words** in the high 16 bits
  (`src/lib/ncc.nas:10022-10050`); `ni_call` stores the word count in
  `W_CALLWORDS` (`src/lib/ncc.nas:22525-22533`).
- `pp_args_l` counts 2 words only for `TY_LL` (`src/lib/ncc.nas:10002-10017`);
  the function-pointer path does the same at `src/lib/ncc.nas:10708-10723`.
- `ni_call` copies each declared parameter from the evaluation stack to the
  callee frame using `SY_ARG` offsets/types (`src/lib/ncc.nas:22612-22699`).
  `ncl_copy_ll` is the 2-word special case.
- Variadic arguments are copied into a fixed 64-byte area at `fp+16`
  (`src/lib/ncc.nas:22700-22734`). Its current word count is
  `W_CALLWORDS - W_VARNP`, which is only correct when every fixed parameter is
  one word. It also copies one word per loop index, not one word per argument
  word. This is a latent bug for `long long` varargs after a fixed `long long`
  parameter; doubles make it visible.
- `va_arg` is `I_VAARG`. `pva_emit` (`src/lib/ncc.nas:10197-10207`) passes
  operand 8 only for `TY_LL`; everything else gets 4. `nil_vaarg`
  (`src/lib/ncc.nas:23168-23207`) loads two 32-bit words when the operand is
  8 and advances the pointer by 8, preserving pair order.
- `printf` is a variadic builtin (`B_PRINTF`, registered at
  `src/lib/ncc.nas:5970-5977`). `ni_printf` (`src/lib/ncc.nas:18062-19540`)
  walks arguments by **word index** `W_PF_IDX` through `ni_arg`
  (`src/lib/ncc.nas:17361-17369`). `%f` reads one word and calls
  `ni_fcalc` (`src/lib/ncc.nas:19013`); `%e`/`%g` read one word and call
  `ni_ecalc` (`src/lib/ncc.nas:18610`). The float branches increment the
  argument index by 1 at `src/lib/ncc.nas:18587-18590` (`%e`),
  `18784-18787` (`%g`) and `18961-18964` (`%f`). `npf_done`
  (`src/lib/ncc.nas:19531-19535`) pops `W_CALLWORDS` words.
- `sprintf`/`snprintf` reuse `ni_printf` with a word offset
  (`W_PF_OFF=1/2`) at `src/lib/ncc.nas:22434-22479`.
- Only five builtins are registered as returning `T_DOUBLE`:
  `difftime` (`6860-6865`), `atof` (`6933-6938`), `strtod` (`6940-6945`),
  `strtold` (`7684-7689`), `remquo` (`7705-7710`). All implementations
  currently push exactly one word: `nbi_difftime` (`src/lib/timeb.nas:31-39`),
  `nbi_atof`/`nbi_strtod` (`src/lib/timeb.nas:891-905`),
  `nbi_remquo` (`src/lib/mbs.nas:338-364`). `wcstod`/`wcstold` are currently
  registered as `T_FLOAT` (`src/lib/ncc.nas:7570-7590`) even though their C
  type is `double`.
- The libm software double-float helpers are `nix_dadd`
  (`src/lib/ncc.nas:17439-17452`), `nix_dsub` (`17455-17459`) and
  `nix_dmul` (`17462-17489`). They take two f32 words `(hi,lo)` and return a
  normalized pair. `nix_rsubc` (`17492`) and the sin/cos kernels build on
  them. There is no `nix_ddiv` and no double comparison helper.
- Unsuffixed floating literals are `T_FLOAT` (`pp_flit`,
  `src/lib/ncc.nas:9766-9773`). `scan_float`/`scan_exp`
  (`src/lib/ncc.nas:3258-3320`) produce binary32 bits only.

### 1.4 What this means

The type table is the easy part. The hard constraint is that a `double`
value is currently **one word everywhere above the memory layer**: on the IR
stack, in `ni_arg`, in the `%f` index, in the call word count, in the return
path, and in every arithmetic operator. Changing only size/align makes the
object larger but leaves the value one word. Changing the memory access to
8 bytes while leaving any of those consumers one-word corrupts the stack or
misindexes `printf`.

---

## 2. Representation decision

Two viable layouts exist. They have different consequences and should be
chosen explicitly before phase 2.

### Strategy A (recommended for this task): f32 pair, `hi` first

```
double object in memory, increasing byte address:
  word 0 (offset 0): hi  -- binary32 approximation of the value
  word 1 (offset 4): lo  -- binary32 correction, value ~= hi + lo

IR stack pair, bottom to top:  hi, lo
LL pair, for contrast:         lo, hi
```

Properties:

- `lo == 0` for every value that came from an existing binary32 literal,
  `strtod` result, or binary32 builtin. Therefore phase 2 can reproduce the
  old f32 results exactly by operating on `hi`.
- `printf("%f", d)` can read `hi` at the same word index it reads today, and
  `scanf("%f", &d)` can keep writing four bytes at offset 0. This is why the
  existing `ncc_m10`/`m24`/`m61` tests can stay byte-identical during the
  transition.
- `nix_dadd`/`nix_dsub`/`nix_dmul` already use `(hi,lo)` in registers, so
  phase 3 is a direct mapping.
- It is **not** IEEE-754 binary64: exponent range is binary32 and precision is
  ~48 bits. `union { double d; unsigned u[2]; }` sees `(hi,lo)`, not the
  binary64 bit pattern. Document this as the ncc internal ABI.
- This conflicts with `spec/TCC_NAN16.md:46-47`, which says the shared ncc/TCC
  ABI makes `double` IEEE-754 binary64. Either revise that contract for the
  first stage or choose Strategy B.

### Strategy B (C-conformant): IEEE binary64 words, low first

```
word 0 (offset 0): low 32 bits of the binary64 bit pattern
word 1 (offset 4): high 32 bits of the binary64 bit pattern
```

Properties:

- Correct little-endian IEEE-754 binary64 object representation and correct
  `union`/`memcpy` behavior.
- Requires a binary64 encode/decode shim in phase 2 (f32 operation on decode,
  encode result), or a full softfloat implementation in phase 3. That is a
  much larger change: exponent/mantissa packing, rounding, subnormals, inf,
  NaN, comparisons, `%f` with up to 17 digits, `strtod`.
- Phase 2 cannot be green with only "load/store pairs"; the codegen change is
  the ABI change.

**Recommendation:** use Strategy A for phases 1-5, and treat true binary64 as
phase 6. This is the only route that satisfies "all compiler gates green at
each step" without a flag day. If true binary64 is a hard acceptance
criterion, choose Strategy B and expect phase 2/3 to be a softfloat project,
not a small ABI patch.

### `long double` policy

Option L1 (recommended): leave `long double` aliased to `double`. It becomes
8/8. Update the ABI expected accordingly. This preserves the C requirement
`sizeof(long double) >= sizeof(double)`.

Option L2 (only if `long double` must stay 4 bytes): add a new type id 15
`T_LDOUBLE` with size 4/align 4, and change `pts_choose`
(`src/lib/ncc.nas:4649-4667`) to select it when `W_TLONG=1` and
`W_TFLOAT=2`. This violates the C rank/precision rule and buys nothing for
the current tests. It is not recommended.

Do **not** use type id 12 for `long double`; id 12 is `_Bool`.

---

## 3. Phased implementation

Each phase is a commit boundary. "Green" means the full compiler-family
battery plus `py_m1`. Sub-steps inside phase 2 are not individually green;
they are listed so the change can be reviewed.

### Phase 0 — baseline

Run and save:

```sh
sh tools/gate_targeted.sh --full
sh tools/presqlite_gate.sh --list | grep -c '^ncc_'
```

Expected: 77 compiler gates (15 named + 62 `ncc_m*`) plus `py_m1`. Record the
current `ncc_abi_sizes` output.

---

### Phase 1 — type size/align and struct layout only (green)

**Goal:** `sizeof(double)==8`, `_Alignof(double)==8`, struct layout uses 8,
while every double value remains a single 32-bit word in codegen. No load,
store, arithmetic, call, vararg or printf change.

This is intentionally a "layout-only lie": a double object is 8 bytes, but
only the low-addressed word is written/read. That is safe for the current
corpus because all double values are binary32-exact and the high-addressed
word is never examined.

**Changes:**

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:2143-2157` | Comment: double is 8/8 layout. Entry 11: `size=8`, `align=8`, **keep kind `TY_FLOAT`**. Entry 10 stays 4/4 `TY_FLOAT`. |
| `src/lib/ncc.nas:2151-2156` | `MOVI r3,8` and `MOVI r4,8` for id 11; leave `MOVI r2,#TY_FLOAT`. |
| `src/tests/ncc_abi_sizes.expected:1-4` | Update the four lines (see §4). |
| `src/tests/ncc_iso_lang_test.nas:11` | `_Static_assert(_Alignof(double)==4, ...)` -> `==8`. The expected file does not change because this assertion prints nothing. |
| `spec/NCC_PARITY.md:80,171,205` | Update the prose/table when the phase lands. Not a gate, but the spec currently says double is 4/4. |
| `spec/MASTER_TASKLIST.md:21-29` | Mark the double size/alignment portion in progress, not the arithmetic portion. |

**Why this is green:** With kind still `TY_FLOAT`:

- `ty_store_code` (`2515-2551`) returns `SZ_32` for size 8, so
  `px_emit_load`/`px_emit_store` keep emitting `I_LOAD 4`/`I_STORE 4`.
- `ty_common` returns `T_FLOAT` for any float-kind operand, so `p_binop`
  stays on `pb_float`; all arithmetic is one-word f32.
- `px_discard` (`9339-9355`) sees `TY_FLOAT`, not `TY_LL`, and pops one word.
- `px_cast_stack` (`9551-9648`) sees the same kind for float and double and
  the same `SZ_32` code, so it emits no conversion.
- `ni_call` (`22525`) sees `TY_FLOAT`, not `TY_LL`, and copies one word;
  parameter offsets are 8-aligned but the values are one word.
- `px_ret_emit` (`16157`) sees `TY_FLOAT`, not `TY_LL`, and emits one-word
  `I_RET`.
- `pva_emit` (`10197-10207`) sees `TY_FLOAT`, not `TY_LL`, and advances 4.
- `pp_flit` (`9766-9773`) stays `T_FLOAT`, so literals do not change.
- `ncc_add_global` (`7859-7903`) allocates 8 bytes but stores one word at
  offset 0; the second word is zero in the image or irrelevant.
- `p_struct_spec` (`5200-5325`) lays out members with align 8 automatically.

**Expected gate results:** 77/77 + `py_m1` green, with only the ABI expected
file and the `ncc_iso_lang` test source changed. This should be a low-risk
commit analogous to `92ad61c`.

**Tests to run:**

```sh
sh tools/ncc_abi_sizes.sh
sh tools/ncc_iso_c.sh          # lang/uchar/wstdio/c11lib
sh tools/ncc_headers.sh
sh tools/ncc_m10.sh            # representative %f gate
sh tools/py_m1.sh
NO_CACHE=1 sh tools/gate_targeted.sh src/lib/ncc.nas \
  src/tests/ncc_abi_sizes.expected src/tests/ncc_iso_lang_test.nas
```

**Risk:** This phase is only green because kind and store code are unchanged.
If you also set the kind to a new `TY_DOUBLE` or make `ty_store_code` return a
64-bit code here, every double arithmetic/call/printf path breaks and phase 1
is no longer a small commit. Mixed `double`/`long long` expressions are not
exercised by the current corpus and remain semantically wrong until phase 2
(`ty_common` checks `TY_LL` before `TY_FLOAT` today).

---

### Phase 2 — two-word `double` representation and ABI plumbing (green as one atomic commit)

**Goal:** a `double` is a two-word pair everywhere, memory loads/stores move
8 bytes, and all non-arithmetic consumers understand the pair. Arithmetic in
this phase still operates on `hi` and writes `lo=0`, so numerical results and
all expected stdout remain identical to phase 1. The pair order is `(hi,lo)`
under Strategy A; if the task literally requires `(lo,hi)` (LL order), that
is Strategy B and the caveats in §2 apply.

This phase is large but mechanical. It must land as one commit; splitting it
at "load/store only" leaves the IR stack inconsistent.

#### 2.1 Type identity

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:285` | Add `.equ TY_DOUBLE 11` (next to `TY_LL 10`). |
| `src/lib/ncc.nas:2151-2156` | Entry 11 kind becomes `TY_DOUBLE`, size 8, align 8. Entry 10 stays `TY_FLOAT` 4/4. |
| `src/lib/ncc.nas:2437-2513` | `ty_common`: check `TY_DOUBLE` first and return `T_DOUBLE` if either operand is double; then existing `TY_FLOAT`, then `TY_LL`, then integer. This also fixes double-vs-LL precedence. |
| `src/lib/ncc.nas:315-319` | Add `.equ SZ_64 7` (do **not** use 5; `I_CAST` code 5 is `itof`, code 6 is `ftoi`). |
| `src/lib/ncc.nas:2515-2551` | `ty_store_code`: size 8 -> `SZ_64`. Every caller must special-case double before using the code; `ni_loadv`/`ni_storev` must never receive 7. |

#### 2.2 IR opcodes and runtime helpers

Add opcodes after `I_BITSTORE` (`src/lib/ncc.nas:244`). Suggested numbering
(81 is free):

```
I_DLOAD   81   pop addr, push hi,lo
I_DSTORE  82   operand=keep; stack addr,hi,lo
I_DNEG    83   pop pair, push (-hi,-lo) or (-hi,0) in phase 2
I_DBOOL   84   pop pair, push i32 (0/1)
I_DADD    85   pop two pairs, push pair
I_DSUB    86
I_DMUL    87
I_DDIV    88
I_DLT     89
I_DGT     90
I_DLE     91
I_DGE     92
I_DEQ     93
I_DNE     94
I_F2D     95   operand=depth; replace one word with (value,0)
I_I2D     96   operand=depth
I_LL2D    97   operand=depth of LL high; replace pair with (value,0)
I_D2F     98   operand=depth of double high; replace pair with hi (or hi+lo in phase 3)
I_D2I     99   operand=depth of double high
I_D2LL   100   operand=depth of double high
```

The depth convention follows `ll_ext`/`ll_trunc`
(`src/lib/ll.nas:559-625`): a depth is a word offset from the top of the
evaluation stack. The one-word-to-pair ops insert a word and shift higher
words up; the pair-to-one-word ops drop a word and shift higher words down.
This lets `p_binop` convert the right operand at depth 0 and the left at
depth 2 without reordering the stack.

Runtime implementation:

- Add `ni_load64` next to `ni_store64` (`src/lib/ll.nas:868-889`), returning
  `r1=word0`, `r2=word1`. `I_DLOAD` calls it and pushes word0 then word1.
- `I_DSTORE` calls `ni_store64(addr, word0, word1)`; if `keep`, pushes the
  pair back.
- Phase 2 arithmetic handlers pop two pairs and do `FADD/FSUB/FMUL/FDIV` on
  the `hi` words, then push `(result, 0)`. This is the compatibility shim
  that keeps every expected numeric output byte-identical.
- `I_DNEG` flips the sign bit of `hi` and pushes 0.
- `I_DBOOL` pushes 1 if either word is nonzero (or `hi != 0` in phase 2).
- `I_DLT`..`I_DNE` do `FCMP` on the `hi` words.
- `I_F2D`: pop float, push `(value, 0)`.
- `I_I2D`: pop integer, `CVTIF`, push `(value, 0)`.
- `I_LL2D`: pop LL pair (`lo,hi`), call `ll_pair_to_f`
  (`src/lib/ll.nas:997-1042`), push `(value, 0)`.
- `I_D2F`: pop pair, push `hi`.
- `I_D2I`: pop pair, `CVTFI hi`.
- `I_D2LL`: pop pair, `ll_from_f` (`src/lib/ll.nas:894-956`) on `hi`, push
  LL pair.

Add the dispatch comparisons in `ncc_ir_loop` before `JMP @nil_bad`
(`src/lib/ncc.nas:22868-23078`) and the handlers next to the LL handlers
(`src/lib/ncc.nas:23080-23207`). Add scratch words after `W_LM_SG`
(`src/lib/ncc.nas:857`) or in the free 61148+ range (e.g. `W_DB0`,
`W_DB1`, `W_FIXEDWORDS`, `W_BUILTIN_RETTYPE`, `W_BUILTIN_RETKIND`).

#### 2.3 Loads, stores, casts, discards

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:9339-9355` | `px_discard`: `TY_LL` **or `TY_DOUBLE`** -> two `I_POP`s. |
| `src/lib/ncc.nas:9357-9424` | `px_emit_load`: after the `TY_LL` check, if kind `TY_DOUBLE` emit `I_DLOAD` and return. |
| `src/lib/ncc.nas:9426-9517` | `px_emit_store`: after the `TY_LL` check, if kind `TY_DOUBLE` emit `I_DSTORE` with the keep operand and return. |
| `src/lib/ncc.nas:9551-9648` | `px_cast_stack`: add the double conversion matrix listed below. Keep the existing float/LL paths intact. |
| `src/lib/ncc.nas:9547-9549` | `px_cast_code` (currently unused) should not be used for double; either delete or document that it returns `SZ_64`. |
| `src/lib/ncc.nas:9519-9545` | `px_promote`: double size 8 returns itself already; no change. |

`px_cast_stack` matrix:

| source | target | emit |
| --- | --- | --- |
| double | double | none |
| float | double | `I_F2D` depth 0 |
| int/enum/bool | double | `I_I2D` depth 0 |
| long long | double | `I_LL2D` depth 0 |
| double | float | `I_D2F` depth 1 |
| double | int | `I_D2I` depth 1 |
| double | long long | `I_D2LL` depth 1 |
| double | `_Bool` | `I_DBOOL` (optional; C comparison-to-zero) |
| float/int/LL | float/int/LL | existing code unchanged |

The depth 1 for double-to-X is because a pair is `(hi,lo)` with `hi` at
depth 1 and `lo` at depth 0.

#### 2.4 Binary operators, assignments, conditions, inc/dec

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:11535` | `pb_scalar`: if either operand kind is `TY_DOUBLE`, branch to a new `pb_double` before the `TY_FLOAT`/`TY_LL` checks. |
| new `pb_double` after `pb_scalar` | Save op/left type/right type; pop the three compiler locals; emit the right conversion at depth 0; emit the left conversion at depth 2; select `I_DADD/DSUB/DMUL/DDIV` or `I_DLT..DNE`. Set `W_ETYPE=T_DOUBLE` for arithmetic and `T_INT` for comparisons. `BIN_MOD`, shifts and bitwise ops on double -> error 69. |
| `src/lib/ncc.nas:12263-12327` | `p_land`: after each `p_emit_rv`, call `px_cond_bool` before `I_JZ`. |
| `src/lib/ncc.nas:12329-12393` | `p_lor`: after each `p_emit_rv`, call `px_cond_bool` before `I_JNZ`. |
| `src/lib/ncc.nas:12395-12467` | `p_cond`: call `px_cond_bool` after the condition `p_emit_rv`; when merging branch types, if either is `TY_DOUBLE` set `W_ETYPE=T_DOUBLE`. |
| `src/lib/ncc.nas:12529-12652` | `p_assign`: no structural change. `px_cast_stack` and `px_emit_store` now handle double; compound assignment uses `pb_double` and `I_DSTORE keep`. Verify the parser-stack offsets (-1/-2/-3) are unchanged: they are compiler temporaries, not the runtime value stack. |
| `src/lib/ncc.nas:10915-10941` | `pu_minus`: `TY_DOUBLE` -> `I_DNEG`; keep `TY_FLOAT` -> `I_FNEG` and `TY_LL` -> `I_LLNEG`. |
| `src/lib/ncc.nas:10944-10960` | `pu_lnot`: `TY_DOUBLE` -> `I_DBOOL`, then `I_LNOT`; set `W_ETYPE=T_INT`. |
| `src/lib/ncc.nas:10570-10855` | `pxf_loop` (postfix `++`/`--`): add a double branch. Load pair, push `(1.0,0)`, `I_DADD`/`I_DSUB`, `I_DSTORE keep`, then recover the old value by subtracting/adding 1.0. Set `W_ETYPE=T_DOUBLE`. |
| `src/lib/ncc.nas:11346-11420` | `pu_incdec` (prefix): same double branch. |
| `src/lib/ncc.nas:15729-15786` | `p_if`: call `px_cond_bool` after `p_emit_rv` before `I_JZ`. |
| `src/lib/ncc.nas:15788-15844` | `p_while`: same. |
| `src/lib/ncc.nas:15846-15972` | `p_for`: same for the condition; replace the hardcoded `I_POP` for the post expression at `15912-15915` with `px_discard`. |
| `src/lib/ncc.nas:15974-16024` | `p_do`: same for the condition. |
| new `px_cond_bool` near `px_discard` | If `W_ETYPE` kind is `TY_DOUBLE`, emit `I_DBOOL` and set `W_ETYPE=T_INT`; if `TY_LL`, optionally emit `I_LLBOOL`; otherwise no-op. This is required for `if(c)` in `py_m1`. |

`p_cond` currently types every non-pointer ternary as `T_INT`
(`src/lib/ncc.nas:12445-12446`). Add double before that fallback.

#### 2.5 Calls, returns, arguments, varargs

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:10002-10017` | `pp_args_l`: count 2 words for `TY_DOUBLE` as well as `TY_LL`. |
| `src/lib/ncc.nas:10708-10723` | `pxf_call_args`: same. |
| `src/lib/ncc.nas:16198-16245` | `px_arg_cast`: add default argument promotions for variadic calls (see 2.6). Declared double parameters already go through `px_cast_stack`. |
| `src/lib/ncc.nas:22612-22657` | `ncl_copy`: add a `TY_DOUBLE` branch before the one-word copy. |
| new `ncl_copy_dbl` after `ncl_copy_ll` (`22659-22677`) | Source = `R_SP - W_CALLWORDS + W_SRCOFF`; load word0/word1; dest = new `fp + param offset`; call `ni_store64`; `W_SRCOFF += 2`; advance the param index. |
| `src/lib/ncc.nas:22700-22734` | `ncl_varstore`: replace the count/offset logic with fixed-word logic (see below). |
| `src/lib/ncc.nas:22752-22802` | `ni_ret`: no change. Operand 2 already copies any two-word pair preserving stack order. |
| `src/lib/ncc.nas:16157-16175` | `px_ret_emit`: emit `I_RET 2` for `TY_DOUBLE` as well as `TY_LL`. |
| `src/lib/ncc.nas:16177-16195` | `px_ret_zero`: push two zeros for `TY_DOUBLE`. |
| `src/lib/ncc.nas:16105-16153` | `p_return`: the void-expression `I_POP` at `16132-16134` should become `px_discard` so a discarded double pair is fully removed. |
| `src/lib/ncc.nas:17039-17080` | `p_const_eval`: if the constant expression type is double, pop two words. `_Static_assert` requires an integer constant, so this is defensive. |

Varargs fix (needed in phase 2 because a double vararg is now 2 words):

```
after the declared-parameter copy loop, W_SRCOFF == fixed parameter words
W_VARCNT = W_CALLWORDS - W_SRCOFF          ; vararg words, not arg count
for j = 0 .. W_VARCNT-1 (cap 16):
    src = R_SP - W_CALLWORDS + W_SRCOFF + j
    dst = new_fp + 16 + 4*j
    ni_storev(dst, src_word, SZ_32)
```

This also fixes the existing `long long`-after-fixed-`long long` varargs
bug. The 64-byte area holds 16 words (8 doubles); keep the existing cap and
document it. Increasing it would require moving `W_LOCALB` from 80 to 144
(`src/lib/ncc.nas:16788`, `14448`) and is not needed for the current corpus.

#### 2.6 Default argument promotions (must be in phase 2)

This is nominally a phase-4 item, but it must land with the pair switch. If
`%f` starts consuming 2 words while float literals still push 1 word, the
argument index desynchronizes; if float literals are promoted while `%f`
still consumes 1 word, the same. Both changes are one atomic unit.

In `px_arg_cast` (`src/lib/ncc.nas:16198-16245`):

1. Detect a variadic call:
   - user function: `SY_OFF != 0` and `W_ARGIDX >= SY_NP`;
   - user function pointer: same from the type table if a marker exists;
   - builtin with `SY_NP == 0xFFFF` (`printf`, `sprintf`, `snprintf`,
     `scanf`, `fscanf`, `sscanf`): promote all arguments. This is safe
     because the format/destination/pointer arguments are pointers.
2. Apply promotions:
   - `TY_FLOAT` -> `T_DOUBLE` (`I_F2D`);
   - integer kind with size < 4 -> `T_INT`/`T_UINT` (reuse `px_promote`,
     `src/lib/ncc.nas:9519-9545`);
   - `TY_DOUBLE`, `TY_LL`, pointers, structs, arrays -> unchanged.
3. Set `W_ETYPE` to the promoted type, then continue with the existing
   declared-parameter cast (if any).

`printf("%f", 1.5)` then pushes a double pair; `printf("%f", d)` already
pushes a pair; `printf("%d", 1)` stays one word.

#### 2.7 printf word indexing (must be in phase 2)

Change the three floating branches to consume two words:

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:18587-18590` (`%e`) | `W_PF_IDX += 2` |
| `src/lib/ncc.nas:18784-18787` (`%g`) | `W_PF_IDX += 2` |
| `src/lib/ncc.nas:18961-18964` (`%f`) | `W_PF_IDX += 2` |

Keep the actual formatting on the `hi` word (`ni_arg` returns word 0 of the
pair). `npf_done` already pops `W_CALLWORDS`, so no change there. `%d`, `%u`,
`%x`, `%c`, `%s`, `%p` stay +1; `%lld` stays two +1 reads
(`src/lib/ncc.nas:18409-18418`); `*` width/precision stays +1
(`18137-18145`, `18187-18195`). `sprintf`/`snprintf` inherit this through
`ni_printf`.

#### 2.8 Builtin returns

Only five builtins return `T_DOUBLE` (list in §1.3). Convert centrally at
`nbi_d` (`src/lib/ncc.nas:22519-22523`) rather than editing each handler:

1. At the builtin call site (`src/lib/ncc.nas:22554-22556`), load
   `SY_TYPE` into `W_BUILTIN_RETTYPE` before `SY_AUX` overwrites `r1`.
2. At `ni_builtin` entry (`src/lib/ncc.nas:20207-20211`), resolve that type
   with `ty_kind`, store `W_BUILTIN_RETKIND`, and clear `W_BUILTIN_RETTYPE`
   so a stale double type cannot leak into a later callback dispatch.
3. At `nbi_d`, if the kind is `TY_DOUBLE`, pop the one-word result and push
   `(value, 0)`.
4. Set `W_BUILTIN_RETTYPE=0` at the other `ni_builtin` callers
   (`src/lib/ncc.nas:21350`, `src/lib/libcx.nas:632`, `src/lib/qsort.nas:37`)
   or accept that a double-returning comparator is invalid.

Keep the individual handlers one-word until phase 3. The wrapper is the
single conversion point; do not convert both in the handler and at `nbi_d`.

Affected handlers: `nbi_difftime` (`src/lib/timeb.nas:31-39`),
`nbi_atof`/`nbi_strtod` (`src/lib/timeb.nas:891-905`), `nbi_remquo`
(`src/lib/mbs.nas:338-364`), and `nbi_strtold` (jumps to `nbi_strtod`).
`nbi_wcstod` (`src/lib/wcsto.nas:132-158`) is registered `T_FLOAT`; it is
promoted on assignment in phase 2 and can be re-registered as `T_DOUBLE` in
phase 4.

#### 2.9 Globals and frame alignment

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:7859-7903` | `ncc_add_global`: when the type kind is `TY_DOUBLE`, after storing the one-word value at offset 0, store 0 at offset+4. Use `W_AGSYM.SY_AUX` (set at `7888`) to find the base. This guarantees `lo=0` for `M_PI`, `HUGE_VAL`, `DBL_*` globals, etc. |
| `src/lib/ncc.nas:1811-1822` | `ncc_mem_setup`: round the heap ceiling / `C_STACK` to 8 instead of 4 (`SHR 3` / `SHL 3`). |
| `src/lib/ncc.nas:17018-17022` | `p_func`: round the frame size to 8 instead of 4. `W_LOCALB` starts at 80, which is 8-aligned. |
| `src/lib/ncc.nas:1748-1750` | `W_LOCALB`/`W_FRAMEB` initialization: no change (16 is 8-aligned). |

This guarantees `_Alignof(double)` for frame locals and makes the varargs
area 8-aligned when the first vararg is a double.

**Why phase 2 is green:** every double operation still produces the same
`hi` word as phase 1, and `lo` is always zero. All existing tests use
binary32-exact values, so `%f`/`%e`/`%g` output is unchanged.

**Tests:** all 77 compiler gates + `py_m1` + `ncc_abi_ll` (the varargs fix
touches LL paths). Then `sh tools/gate_targeted.sh --full`.

**Risk:** This phase cannot be green if split at load/store. The following
must change in the same commit: `px_discard`, `px_emit_load`,
`px_emit_store`, `px_cast_stack`, `pb_double`, `px_cond_bool`,
`px_ret_emit`, `px_ret_zero`, `pp_args_l`, `pxf_call_args`, `px_arg_cast`,
`ni_call`/`ncl_copy`, `ncl_varstore`, `pva_emit`, `nbi_d`, and the `%f/%e/%g`
index increments.

---

### Phase 3 — conversions and double arithmetic (green with f32-compatible results)

**Goal:** use the `lo` word for real double-float arithmetic and add the
complete conversion matrix. Keep `hi` bit-identical to the old binary32
result for add/sub/mul so the existing expected files stay valid.

#### 3.1 Arithmetic

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:17439-17452` | `nix_dadd` already correct for `(hi,lo)`; call it from `I_DADD`. |
| `src/lib/ncc.nas:17455-17459` | `nix_dsub` already correct; call it from `I_DSUB`. |
| `src/lib/ncc.nas:17462-17489` | `nix_dmul` already correct; call it from `I_DMUL`. |
| new after `nix_dmul` | `nix_ddiv`: `q = FDIV(a.hi,b.hi)`; `p = nix_dmul(q,b)`; `r = nix_dsub(a,p)`; `q2 = FDIV(r.hi,b.hi)`; return `nix_dadd(q,q2)`. Special-case `b==0`, inf and NaN to return the plain f32 quotient so IEEE edge behavior is unchanged. |
| new helper | `nix_dcmp`: compare `hi`; if equal, compare `lo`; map to `I_DLT..DNE` predicates. Handle NaN (unordered) explicitly. |
| `src/lib/ncc.nas:23669-23770` | `nil_f*` stays untouched; new `nil_d*` handlers call the `nix_*` helpers. |

Semantics:

- `I_DADD`/`I_DSUB`/`I_DMUL`/`I_DDIV` pop two pairs, call `nix_*`, push the
  normalized result pair.
- `I_DNEG` flips both sign bits (or calls a `nix_dneg`).
- `I_DBOOL` tests both words.
- `I_DLT..I_DNE` use `nix_dcmp`.
- `BIN_MOD`/shift/bitwise on double remain errors.

#### 3.2 Conversions

| Conversion | Phase 3 implementation |
| --- | --- |
| float -> double (`I_F2D`) | exact: `(x, 0)` |
| int -> double (`I_I2D`) | `hi = CVTIF(x)`, `lo = CVTIF(x - hi)` if desired; `(hi,0)` is sufficient for the corpus |
| LL -> double (`I_LL2D`) | `hi = ll_pair_to_f`, `(hi,0)`; a correction term requires an integer-to-f32 remainder path and can be deferred |
| double -> float (`I_D2F`) | `FADD hi,lo` then push (correctly rounded f32), or push `hi` to guarantee old results; choose `FADD` only after reviewing the 1-ulp cases |
| double -> int (`I_D2I`) | `CVTFI (hi+lo)` or `CVTFI hi`; keep `hi` for bit-identical old behavior |
| double -> LL (`I_D2LL`) | `ll_from_f` on `hi` (or `hi+lo`) |
| `_Bool` | `I_DBOOL` |

For the first phase-3 commit, keep `I_D2F`/`I_D2I`/`I_D2LL` on `hi` to
guarantee expected-output stability. Then switch them to `FADD hi,lo` as a
separate reviewed step if precision matters.

#### 3.3 Literals (optional, not needed for gates)

`pp_flit` (`src/lib/ncc.nas:9766-9773`) and `scan_float`
(`src/lib/ncc.nas:3258-3320`) currently produce binary32 bits. Converting
unsuffixed literals to double pairs would be more C-correct, but it would
break the 52 builtins registered as returning/taking `T_FLOAT` unless
their parameter types are also fixed. Keep literals `T_FLOAT` in this plan
and rely on `px_arg_cast`/`px_cast_stack` to widen them. This is a documented
deviation, not a regression.

#### 3.4 Header constants (deferred correctness)

`src/lib/headers.nas:376-467` still reports `DBL_MANT_DIG=24`,
`DBL_MAX_EXP=128`, `DBL_MIN=0x00800000`, etc. With Strategy A these are
f32-range values stored in an 8-byte slot. Changing the numeric constants
without a binary64 implementation would be misleading. Leave the gate output
unchanged and document the gap; phase 6 can fix them.

**Why phase 3 is expected to be green:** for binary32-exact inputs,
`nix_dadd`/`nix_dsub` are designed to produce `hi` equal to the old
`FADD`/`FSUB` result. `nix_dmul` is the Dekker/TwoProduct construction
intended to do the same for multiplication; verify both with
`ncc_libm_exact` and the float tests. If a
1-ulp difference appears, keep `I_DMUL` on the phase-2 `FMUL` shim until that
case is reviewed. If `I_DDIV` is enabled with correction, review the one-ulp
cases first; the corpus has no non-exact `double` division (the `7.5/2.5`
case in `ncc_m8` is `float`, not `double`).

**Tests:** `ncc_m8`, `ncc_m10`, `ncc_m12`, `ncc_m18`, `ncc_m21`, `ncc_m22`,
`ncc_m24`, `ncc_m25`, `ncc_m49`, `ncc_m54`, `ncc_m55`, `ncc_m61`,
`ncc_libm_exact`, `ncc_torture`, `py_m1`, then full battery.

**Risk:** `nix_ddiv`/`nix_dsqrt`/`FADD hi,lo` can change the last printed
digit. Keep the first phase-3 commit on the compatibility shim
(`hi` for conversion/formatting, no division correction) and enable
correction only with an explicit expected-file review.

---

### Phase 4 — varargs and printf completion

**Goal:** finish the double paths that are not needed for the current corpus
but are needed for a coherent ABI.

| File:lines | Change |
| --- | --- |
| `src/lib/ncc.nas:22700-22734` | If not already done in phase 2, switch `ncl_varstore` to fixed-word counting and copy complete pairs. |
| `src/lib/ncc.nas:10197-10207` | `pva_emit`: pass 8 for `TY_DOUBLE` as well as `TY_LL`. |
| `src/lib/ncc.nas:23168-23207` | `nil_vaarg` already handles operand 8 as a two-word pair and advances 8. Verify it preserves `(hi,lo)` order; no change if it does. |
| `src/lib/ncc.nas:18062-19540` | `ni_printf`: keep the phase-2 `+2` index. Optionally add a `W_PF_DBL` flag to format `hi+lo` instead of `hi`; do not change expected output until reviewed. Raise the 9-digit precision cap only with a decimal algorithm that handles 17 digits. |
| `src/lib/ncc.nas:22434-22479` | `sprintf`/`snprintf`: inherits `ni_printf`; no separate word-count change. |
| `src/lib/scanf.nas:359-375` (`cs_store`) | `%lf` should store a full pair: parse `l` into `CS_LEN`, and for floating conversions with the double flag write `(value,0)` with `ni_store64`; leave `%f` as a 4-byte store for `float*`. |
| `src/lib/scanf.nas:476-481` (`csdf`) | Branch on the double flag. |
| `src/lib/scanf.nas:685-712` (`csr_lenl`) | Preserve the existing length-modifier parse; use it for the `%lf` decision. |
| `src/lib/ncc.nas:7570-7590` | Re-register `wcstod` and `wcstold` as `T_DOUBLE` (keep `wcstof` as `T_FLOAT`). `nbi_wcstod` pushes one word; the `nbi_d` wrapper converts. |
| `src/lib/timeb.nas:31-39` | `nbi_difftime` remains one word; wrapper converts. |
| `src/lib/timeb.nas:891-905` | `nbi_atof`/`nbi_strtod` remain one word; wrapper converts. |
| `src/lib/mbs.nas:338-364` | `nbi_remquo` remains one word; wrapper converts. |
| `src/lib/ncc.nas:7859-7903` | Verify `ncc_add_global` zeroes the `lo` word for every double global. |

**Compatibility detail for `ncc_m24`:** the test calls
`sscanf("...3.5","%f",&f)` with `double f`. In Strategy A, `%f` writes the
4-byte binary32 value at offset 0 and the already-zero `lo` stays zero, so
`printf("%f",f)` reads the same value. This is technically `%f` with a
`double*` (UB in C); phase 4 should either keep the compatibility behavior or
change the test to `%lf` with the same expected output. Do not make `%f`
write 8 bytes unconditionally; that would overwrite adjacent `float`
objects.

**Why phase 4 is green:** the default output path still formats `hi`, and
the new `%lf`/`wcstod` paths are not exercised by the existing expected
outputs (or produce identical text).

**Tests:** `ncc_m10`, `ncc_m12`, `ncc_m18`, `ncc_m21`, `ncc_m22`, `ncc_m24`,
`ncc_m25`, `ncc_m55`, `ncc_m61`, `ncc_iso_c`, `ncc_headers`, `ncc_torture`,
`py_m1`, full battery.

**Risk:** `printf("%f", double)` with a non-zero `lo` still prints only the
binary32 approximation. That is deliberate for gate preservation; true
binary64 formatting is phase 6.

---

### Phase 5 — ABI audit gate, expected files, docs

**Goal:** make the new ABI executable and visible.

#### 5.1 New gate

Model it on the `ncc_abi_ll` gate added in `3eee07d`
(`tools/ncc_abi_ll.sh`, `src/tests/ncc_abi_ll_test.nas`,
`src/tests/ncc_abi_ll.expected`).

New files:

- `tools/ncc_abi_double.sh`
- `src/tests/ncc_abi_double_test.nas`
- `src/tests/ncc_abi_double.expected`

Suggested guest C source:

```c
#include <stdio.h>
#include <stdarg.h>

struct D { char c; double d; };
double addd(double a, double b){ return a + b; }
double pick(int n, ...){
  va_list ap; va_start(ap, n);
  double d = va_arg(ap, double);
  va_end(ap);
  return d;
}
int main(void){
  struct D s; s.c = 7; s.d = 1.5;
  double a[3];
  printf("%d %d %d\n", (int)sizeof(struct D),
         (int)((char *)&s.d - (char *)&s), (int)_Alignof(struct D));
  printf("%.2f\n", addd(5.5, 2.25));
  printf("%.2f\n", pick(1, 2.5));
  printf("%d %d %d\n", (int)sizeof(a), (int)_Alignof(double),
         (int)((char *)&a[1] - (char *)&a[0]));
  return 0;
}
```

Expected:

```
16 8 8
7.75
2.50
24 8 8
```

Do not use `offsetof`: the `ncc_abi_ll` commit documents that it currently
fails to compile. Pointer subtraction is deliberate.

Optional representation lock (Strategy A only):

```c
union U { double d; unsigned u[2]; } x;
x.d = 1.5;
printf("%08x %08x\n", x.u[0], x.u[1]);
```

Expected `3fc00000 00000000`. Under Strategy B it would be
`00000000 3ff80000`. Add this line only if the layout is intended to be
frozen.

#### 5.2 Gate registration

| File:lines | Change |
| --- | --- |
| `tools/gate_targeted.sh:34` | Add `ncc_abi_double` to `COMPILER`. |
| `tools/presqlite_gate.sh:26` | Add `ncc_abi_double` to `--list`. |
| `tools/presqlite_gate.sh:139` | Add `ncc_abi_double` to the batch. |
| `src/tests/ncc_abi_sizes.expected:1-4` | Final values from §4 (already updated in phase 1). |
| `spec/NCC_PARITY.md:80,171,205` | Double is 8/8; state whether it is Strategy A (f32 pair) or B (binary64). |
| `spec/TCC_NAN16.md:46-47` | Replace "current ncc ABI is still 32-bit for double" with the new representation. |
| `spec/MASTER_TASKLIST.md:21-29` | Check off size/alignment, leave arithmetic/binary64 open if Strategy A. |

#### 5.3 Gate count

Current at `3eee07d`: 77 compiler gates. Add `ncc_abi_double`: 78. If the
task's acceptance script hardcodes 76, update the count in the task text or
the runner; do not silently claim 76. `py_m1` remains an additional gate.

**Tests:** `sh tools/ncc_abi_double.sh`, then
`sh tools/gate_targeted.sh --full`; confirm 78/78 + `py_m1`.

---

### Phase 6 (optional, required for true binary64)

Only if C-conformant `double` is required:

1. Choose Strategy B (IEEE words, low first) or keep Strategy A and accept
   that it is not binary64.
2. Implement binary64 encode/decode and softfloat add/sub/mul/div/sqrt/
   compare using the existing 64-bit integer primitives
   (`ll_op`, `MULHU`, `DIVU`, `SHL/SHR`) in `src/lib/ll.nas` style.
3. Rewrite `I_D*` arithmetic/conversions to use the softfloat layer; keep the
   pair ABI unchanged.
4. Update `printf` `%f/%e/%g` to 17 significant digits and correct rounding;
   update `strtod`/`scanf`; update `float.h` DBL constants.
5. Regenerate the affected expected files only after a differential review
   against clang. This is a new ABI/behavior gate, not a phase-1 follow-up.

---

## 4. Expected sizeof / _Alignof / struct results

Assumes Option L1 (long double aliases double). Current -> new:

```
sizeof:  char 1  short 2  int 4  long 4  llong 8  float 4  double 4 -> 8  ldouble 4 -> 8
align:   char 1  short 2  int 4  long 4  llong 8  float 4  double 4 -> 8  ldouble 4 -> 8
ptr/size_t/ptrdiff_t/intptr_t/intmax_t: 4 4 4 4 8   (unchanged)
```

`src/tests/ncc_abi_sizes.expected` old:

```
1 2 4 4 8 4 4 4
4 4 4 4 8
1 2 4 4 8 4 4 4 4
8 4 8 4 16 8
```

New:

```
1 2 4 4 8 4 8 8
4 4 4 4 8
1 2 4 4 8 4 8 8 4
16 8 8 4 16 8
```

Line 4 decoded:

| struct | size | align | member offset |
| --- | ---: | ---: | --- |
| `struct A { char c; double d; }` | 16 | 8 | `d` at 8 |
| `struct B { char c; void *p; }` | 8 | 4 | `p` at 4 |
| `struct C { char c; long long x; }` | 16 | 8 | `x` at 8 |

Other expected layout results for the new gate:

```
struct { double a, b; }          size 16 align 8
struct { char c; double d; char e; } size 24 align 8 (offsets 0,8,16)
union  { char c; double d; }     size 8  align 8
double a[3]                      size 24 align 8, stride 8
```

If Option L2 is chosen (long double stays 4), the two ABI lines become:

```
1 2 4 4 8 4 8 4
1 2 4 4 8 4 8 4 4
```

with the same struct line.

`src/tests/ncc_iso_lang.expected` does not change; only the compile-time
`_Static_assert` in `src/tests/ncc_iso_lang_test.nas:11` changes from 4 to 8.

---

## 5. Gate/test matrix

| Gate | Why it matters | Phase | Expected |
| --- | --- | --- | --- |
| `ncc_abi_sizes` | sizeof/align/struct audit | 1 | new 4 lines above |
| `ncc_abi_ll` | two-word LL ABI/varargs | 2 | unchanged; varargs fix must not regress it |
| `ncc_iso_c` (`lang`) | `_Alignof(double)` static assert | 1 | source edit; expected unchanged |
| `ncc_headers` | `float.h`/`stdint` constants, `FLT` union | 1/2 | unchanged |
| `ncc_m8` | float arithmetic, sin/cos casts | 2/3 | unchanged |
| `ncc_m10` | `%f`, width/precision | 2 | unchanged; promotions + `%f` +2 |
| `ncc_m12` | `va_arg(ap,double)`, varargs | 2/4 | unchanged |
| `ncc_m18` | `%e` | 2 | unchanged |
| `ncc_m21` | `%g` | 2 | unchanged |
| `ncc_m22` | `atof`/`strtod`/`difftime` double | 2 | unchanged |
| `ncc_m24` | `sscanf("%f", &double)` | 2/4 | unchanged; `%f` writes hi, lo stays 0 |
| `ncc_m25` | `float` + LL varargs | 2 | unchanged; fixed-word varargs must hold |
| `ncc_m49` | libm double-returning behavior via `%f` | 2 | unchanged |
| `ncc_m54` | bit-level float helpers | 1/2 | unchanged |
| `ncc_m55` | `wcstod` into double | 2/4 | unchanged |
| `ncc_m61` | `strtold`, `remquo`, `%f` | 2/4 | unchanged |
| `ncc_libm_exact` | bit-exact f32 sin/cos/fmod | 2/3 | must remain bit-exact |
| `ncc_torture` | integer/pointer/struct/varargs | 2 | unchanged |
| `ncc_ctests` | 56 C cases, no double | 1/2 | unchanged |
| `py_m1` | double params/returns/arrays/`if(c)`/`%g` | 2/3 | unchanged |
| `ncc_abi_double` | new double ABI gate | 5 | new expected above |

---

## 6. Risk register / where a phase cannot be green without codegen

1. **Phase 1 is only green as a layout-only phase.** Keep type 11 kind
   `TY_FLOAT` and `ty_store_code` returning `SZ_32` at that point. Setting
   `TY_DOUBLE` or a 64-bit store code in phase 1 breaks every double
   arithmetic, call, vararg and `printf` path. The green phase-1 change is
   two type-table words plus expected files.
2. **Phase 2 cannot be split at "load/store".** A two-word value on the IR
   stack requires simultaneous updates to `px_discard`, `px_emit_load`,
   `px_emit_store`, `px_cast_stack`, `pb_double`, `px_cond_bool`,
   `px_ret_emit`, `px_ret_zero`, `pp_args_l`, `pxf_call_args`,
   `px_arg_cast`, `ni_call`/`ncl_copy`, `ncl_varstore`, `pva_emit`,
   `nbi_d`, and the `%f/%e/%g` index. There is no useful smaller green
   commit.
3. **`printf` and default promotions are coupled.** `%f` must consume two
   words exactly when a float argument is promoted to a double pair. Changing
   either alone breaks `ncc_m10`/`m18`/`m21` (literals) or
   `ncc_m22`/`m24`/`m61` (double variables).
4. **Varargs fixed-word bug.** `ncl_varstore` currently uses
   `W_CALLWORDS - W_VARNP`, which subtracts a parameter *count* from a word
   count. It works for the current tests only because every fixed parameter is
   one word. A double pair (or an LL fixed parameter) exposes it. Fix it in
   phase 2, not phase 4.
5. **Builtin parameter types are absent.** Builtins are registered with
   `SY_ARG=0` (`ncc_add_builtin`, `src/lib/ncc.nas:8535-8566`), so fixed
   double arguments to `remquo`, `pow`, `fmod`, etc. are not converted. Current
   tests pass float literals to those functions, so gates stay green, but a
   call like `remquo(d1,d2,&q)` with double variables will pop one word where
   two were pushed. Fix by adding an argument-type vector for builtins or by
   special-casing the math family before claiming ABI completeness.
6. **Builtin return wrapper assumption.** The `nbi_d` conversion assumes
   every `T_DOUBLE` builtin leaves exactly one word. Audit
   `atof`, `strtod`, `strtold`, `difftime`, `remquo` (and `wcstod`/
   `wcstold` if re-registered) before enabling it. Do not also convert inside
   the handler.
7. **`long double` is not type 12.** Type 12 is `_Bool`. `long double` aliases
   `double` through `W_TFLOAT=2`. The ABI audit will show `sizeof(long double)
   == 8` unless a new type id is added. Option L2 (keep 4) requires parser
   work and violates C rank.
8. **True binary64 is not achieved by Strategy A.** f32 pair is ~48-bit with
   binary32 exponent range. `DBL_MANT_DIG`, `DBL_MAX`, `strtod` precision and
   `printf` >9 digits remain inconsistent. If binary64 is an acceptance
   criterion, choose Strategy B and phase 2/3 become a softfloat project.
9. **Layout migration is an ABI break.** Strategy A stores `(hi,lo)`;
   Strategy B stores binary64 `(low32,high32)`. Moving from A to B later
   changes every double object and any union/memcpy observation. Decide once.
10. **Frame/heap alignment.** `ncc_mem_setup` rounds `C_STACK` to 4 and
    `p_func` rounds frame size to 4 (`src/lib/ncc.nas:1811-1822`,
    `17018-17022`). A double local at an 8-aligned offset is only truly
    8-aligned if the frame base is 8-aligned. Change both to 8. `ni_malloc`
    (`src/lib/ncc.nas:19724-19850`) still returns a 4-aligned payload; heap
    doubles and LLs can be 4-mod-8. This is a pre-existing LL issue too.
    Fixing the allocator is a separate, riskier change (header/free/realloc
    assumptions).
11. **Global `lo` word.** `ncc_add_global` writes only 4 bytes. Zero offset+4
    for double globals; otherwise a reused globals region can leave a stale
    correction. Uninitialized locals are C UB, but globals should not depend
    on image zeroing.
12. **Unsuffixed literals stay `float`.** `pp_flit` is `T_FLOAT`. Converting
    literals to double pairs would be more C-correct but would break the 52
    builtins registered as `T_FLOAT` and all `%f` tests. Keep the
    conversion at assignment/argument boundaries.
13. **`SZ_64` code collision.** Code 5 is `itof`, code 6 is `ftoi` in
    `nil_cast` (`src/lib/ncc.nas:23591-23650`). Use 7 (or a dedicated
    non-`I_CAST` code). Never pass `SZ_64` to `ni_loadv`/`ni_storev`; they
    treat unknown codes as 32-bit.
14. **`offsetof` is currently broken.** The new ABI gate must use pointer
    subtraction, as `ncc_abi_ll` does.
15. **Gate count drift.** The task says 76; the tree at `3eee07d` has 77
    because `ncc_abi_ll` was added. After phase 5 it is 78. Update the count
    deliberately, and still run `py_m1`.

---

## 7. Commit sequence / rollback points

1. `ncc: double 8-byte type layout` — phase 1. Only
   `src/lib/ncc.nas`, `src/tests/ncc_abi_sizes.expected`,
   `src/tests/ncc_iso_lang_test.nas`, plus spec prose. Rollback: restore the
   two type-table words and two expected lines.
2. `ncc: two-word double representation and ABI plumbing` — phase 2. Large,
   atomic. Rollback: revert the whole commit; do not keep a partial pair
   representation.
3. `ncc: double conversions and double-float arithmetic` — phase 3. Rollback:
   switch `I_DADD/DSUB/DMUL/DDIV` and the conversion ops back to the phase-2
   f32 shim; the pair ABI remains.
4. `ncc: double varargs and printf` — phase 4. Rollback: `%f` stays on `hi`
   and varargs stay one-word only if phase 2's pair plumbing is also
   reverted; do not mix.
5. `ncc: double ABI audit gate` — phase 5. Rollback: remove the new gate and
   restore the gate lists; the ABI behavior stays.

At each boundary:

```sh
NO_CACHE=1 sh tools/gate_targeted.sh --full
```

The full battery is mandatory for this work: it changes the C ABI, the
value representation, varargs, struct layout and `printf`.
