# TCC → NaN16 backend: implementation checklist

Scope: what `nan16-gen.c` (code generator) and `nan16-link.c` (linker/output)
must provide, derived from `tccgen.c`, `tccelf.c`, `libtcc.c`, `tcc.h`,
`configure`, `Makefile` and by comparison with `x86_64-gen.c`,
`riscv64-gen.c`, `c67-gen.c`.

Tree: `/data/data/com.termux/files/home/nan0s_work/third_party/tinycc`.
The requested `5cef7f3` is **not** an object in this repo
(`git cat-file -t 5cef7f3` fails). Baseline used here: `71422cd`
("test: list tcc_nan16_enc in --list"). While this document was being written
the tree advanced to `11b3371`; `git diff 71422cd..11b3371` touches **only**
`nan16-enc.*`, `tests/` and `tools/`, so every line number below for
`tccgen.c` / `tccelf.c` / `tcc.h` / `libtcc.c` / `configure` / `Makefile` is
still exact at HEAD. `nan16-enc.*` is in flux and is therefore cited by symbol
name, not line. A work-in-progress `nan16-gen.c` / `nan16-link.c` also appeared
in the worktree during writing — see §8.

Verification method (not just reading): a throwaway copy of the tree was given
a stub `nan16-gen.c`/`nan16-link.c`, a `TCC_TARGET_NAN16` branch in `tcc.h` /
`libtcc.c` / `config.h`, and built with `gcc -DTCC_TARGET_NAN16 -DONE_SOURCE`.
Each symbol below was then ablated one at a time and the build re-run; the
"required" list is the set whose removal produces
`ld.lld: error: undefined symbol: …`. A stubbed-but-logging backend was used
to obtain the exact call trace in §3.

---

## 0. Ground rules that drive the design

* TCC is ELF-shaped, not merely "ELF-output". `Section`, `ElfSym`, the symtab,
  and relocation records are the compiler's **internal IR**:
  `tccelf_new()` creates `.text/.data/.rodata/.bss/.symtab` unconditionally
  (`tccelf.c:60-128`), and `put_extern_sym2()` writes into `symtab_section`
  (`tccgen.c:517-585`). Therefore `TCC_TARGET_NAN16` must **not** try to
  replace ELF; it replaces only the *file writer* and the runtime-library
  policy. `nan16-link.c` is `relocate()` + `nan16_output_file()`, not a
  second object format.
* `PTR_SIZE 4` selects ELF32 (`tcc.h:397-411`), `LONG_SIZE 4`
  (`tcc.h:416-420`), `__ILP32__`/`unsigned int size_t`
  (`tccpp.c:3617-3618` + `include/tccdefs.h:20-30`). This matches
  `nan16-abi.h` pointer/long/size_t = 4.
* `tccgen.c` keeps `ind` as a byte offset and requires
  `ind == cur_text_section->data_offset` at entry and exit of the function:
  set at `tccgen.c:8810`, stored back at `tccgen.c:8859`.

---

## 1. Symbols `nan16-gen.c` must provide

### 1.1 Inside `#ifdef TARGET_DEFS_ONLY`

Only preprocessor definitions, plus (optionally) forward declarations of
target-only helpers, exactly as `x86_64-gen.c:112-113` declares
`gen_struct_copy`. `tcc.h` includes the file with `TARGET_DEFS_ONLY` defined
and then `#undef`s it (`tcc.h:366,393`); the declarations in
`tcc.h:1631-1658` are **not** visible during that pass.

* macros: §2.
* `ST_FUNC int gfunc_sret(CType *, int, CType *, int *, int *);` — already
  declared in `tcc.h:1638`, so a re-declaration is optional.
* `ST_FUNC void gen_struct_copy(int size);` — **only** if
  `TCC_TARGET_NATIVE_STRUCT_COPY` is defined (`tccgen.c:3827-3833`).

### 1.2 Full build (after `#define USING_GLOBALS` + `#include "tcc.h"`)

All definitions below are mandatory. Signatures are from `tcc.h:1631-1658`;
"call sites" are the places in `tccgen.c` that force the symbol to exist.

| # | symbol | exact signature | call sites / notes |
|---|--------|-----------------|--------------------|
| 1 | `target_machine_defs` | `ST_DATA const char * const target_machine_defs;` | `tccpp.c:3588` `putdefs()`; NUL-separated `NAME` / `NAME value` list, e.g. `"__nan16\0__nan16__\0"` |
| 2 | `reg_classes` | `ST_DATA const int reg_classes[NB_REGS];` | `tccgen.c:284,1477,1501,1520-1523,1928-1936,6494-6500` |
| 3 | `gsym_addr` | `ST_FUNC void gsym_addr(int t, int a);` | `tccgen.c:176,7142,7152,7418,7532,7548,7585` |
| 4 | `load` | `ST_FUNC void load(int r, SValue *sv);` | `tccgen.c:1587,1954,1963,1971,1981,1991,2101,3944` |
| 5 | `store` | `ST_FUNC void store(int r, SValue *v);` | `tccgen.c:1438,1448,3954,3959,3962` |
| 6 | `gfunc_sret` | `ST_FUNC int gfunc_sret(CType *vt, int variadic, CType *ret, int *ret_align, int *regsize);` | `tccgen.c:6403,7014`; return #regs, `0` = memory, `<0` = "target handles it" (riscv64 only) |
| 7 | `gfunc_call` | `ST_FUNC void gfunc_call(int nb_args);` | `tccgen.c:1611,1705,2137,3237,3265,3849,5734,6483,7200,7820` |
| 8 | `gfunc_prolog` | `ST_FUNC void gfunc_prolog(Sym *func_sym);` | `tccgen.c:8844` |
| 9 | `gfunc_epilog` | `ST_FUNC void gfunc_epilog(void);` | `tccgen.c:8852` |
| 10 | `gen_fill_nops` | `ST_FUNC void gen_fill_nops(int);` | `tccgen.c:8814` (only for `__attribute__((aligned))` on a function) |
| 11 | `gjmp` | `ST_FUNC int gjmp(int t);` | `tccgen.c:6814,6842,6876,7159,7234,7237,7398,7477,7490,7498,7522,7570,7572,7649` |
| 12 | `gjmp_addr` | `ST_FUNC void gjmp_addr(int a);` | `tccgen.c:7417,7526,7531,7652` |
| 13 | `gjmp_cond` | `ST_FUNC int gjmp_cond(int op, int t);` | `tccgen.c:1093` (in `gjmp2`) |
| 14 | `gjmp_append` | `ST_FUNC int gjmp_append(int n, int t);` | `tccgen.c:1075` |
| 15 | `gen_opi` | `ST_FUNC void gen_opi(int op);` | `tccgen.c:2506` — all non-`long long`/non-`PTR_SIZE==8` binops |
| 16 | `gen_opf` | `ST_FUNC void gen_opf(int op);` | `tccgen.c:2655` |
| 17 | `gen_cvt_ftoi` | `ST_FUNC void gen_cvt_ftoi(int t);` | `tccgen.c:3269` |
| 18 | `gen_cvt_itof` | `ST_FUNC void gen_cvt_itof(int t);` | `tccgen.c:3241` |
| 19 | `gen_cvt_ftof` | `ST_FUNC void gen_cvt_ftof(int t);` | `tccgen.c:3415` |
| 20 | `ggoto` | `ST_FUNC void ggoto(void);` | `tccgen.c:7631` (`goto *expr`) |
| 21 | `gen_vla_sp_save` | `ST_FUNC void gen_vla_sp_save(int addr);` | `tccgen.c:8702,8714` |
| 22 | `gen_vla_sp_restore` | `ST_FUNC void gen_vla_sp_restore(int addr);` | `tccgen.c:7258` |
| 23 | `gen_vla_alloc` | `ST_FUNC void gen_vla_alloc(CType *type, int align);` | `tccgen.c:8708` |

### 1.3 Optional / conditionally required

| symbol | signature | when |
|---|---|---|
| `o` | `ST_FUNC void o(unsigned int c);` | **not required**: all uses are inside `#if defined(TCC_TARGET_I386)||defined(TCC_TARGET_X86_64)` (`tccgen.c:922-924,1441-1445`). Declared for non-C67 at `tcc.h:1653-1655`. |
| `gen_vla_result` | `ST_FUNC void gen_vla_result(int addr);` | only `TCC_TARGET_PE && TCC_TARGET_X86_64` (`tcc.h:1700-1702`, `tccgen.c:8712`) |
| `gen_struct_copy` | `ST_FUNC void gen_struct_copy(int size);` | only with `TCC_TARGET_NATIVE_STRUCT_COPY` (`tccgen.c:3827-3833`) |
| `gen_va_start` | `ST_FUNC void gen_va_start(void);` | only if you add a `TCC_TARGET_NAN16` case to `tccgen.c:6071-6145`; see §6.2 |
| `gen_va_arg` | `ST_FUNC void gen_va_arg(CType *t);` | `tccgen.c:6116-6124`, target-gated |
| `gen_clear_cache` | `ST_FUNC void gen_clear_cache(void);` | `tccgen.c:6126-6145`, target-gated |
| `gen_cvt_sxtw` | `ST_FUNC void gen_cvt_sxtw(void);` | `tccgen.c:3495` is inside the x86_64/arm64/riscv64-only `#if` at `3513` |
| `gen_cvt_csti` | `ST_FUNC void gen_cvt_csti(int t);` | `tccgen.c:3515`, same `#if` |
| `gen_increment_tcov` | `ST_FUNC void gen_increment_tcov(SValue *sv);` | only `-ftest-coverage` (`tccdbg.c:2586`) |
| `classify_x86_64_va_arg` | `ST_FUNC int classify_x86_64_va_arg(CType *ty);` | x86_64 only (`tcc.h:1527-1529`) |
| `func_bound_add_epilog` | `ST_DATA int func_bound_add_epilog;` | only if `CONFIG_TCC_BCHECK` stays enabled **and** `gfunc_call` calls `gbound_args()`; cf. `x86_64-gen.c:161-164`, `riscv64-gen.c:85-88`, `tccgen.c:1681,1706,1709` |

### 1.4 Symbols that must **not** be defined

* `gen_opl` — `tccgen.c:2105` defines it as `static` when `PTR_SIZE == 4`
  (dispatch at `tccgen.c:2502-2506`). A target definition is a duplicate.
  It emits calls to `__divdi3/__udivdi3/__moddi3/__umoddi3`
  (`tccgen.c:2118-2130`) → those must exist in the NaN16 runtime.
* `gsym` (`tccgen.c:173`), `gen_negf` (`tccgen.c:2521-2551`), `gen_op`,
  `gen_cast`, `vstore`, `save_reg`, `get_reg`, `gv`, `gv2`, `lexpand`
  (`tccgen.c:2035`) are all tccgen-owned.

### 1.5 Derivation check: the three reference backends

`X` = `x86_64-gen.c`, `R` = `riscv64-gen.c`, `C` = `c67-gen.c`. The
intersection of the three is exactly the mandatory list of §1.2; everything
outside it is target-specific.

| symbol | X | R | C | note |
|---|---|---|---|---|
| `target_machine_defs`, `reg_classes` | ✓ | ✓ | ✓ | `ST_DATA` (`x86_64-gen.c:121,127`; `riscv64-gen.c:47,63`; `c67-gen.c:119,123`) |
| `load`, `store` | ✓ | ✓ | ✓ | `x86_64-gen.c:374,577`; `riscv64-gen.c:251,408`; `c67-gen.c:1551,1713` |
| `gfunc_sret` | ✓ | ✓ | ✓ | `x86_64-gen.c:1194`; `riscv64-gen.c:885`; `c67-gen.c:1873` |
| `gfunc_call`, `gfunc_prolog`, `gfunc_epilog` | ✓ | ✓ | ✓ | `x86_64-gen.c:1220,1425,1577`; `riscv64-gen.c:587,807,921`; `c67-gen.c:1880,1949,2023` |
| `gsym_addr` | ✓ | ✓ | ✓ | `x86_64-gen.c:233`; `riscv64-gen.c:156`; `c67-gen.c:209` |
| `gen_fill_nops` | ✓ | ✓ | ✓ | `x86_64-gen.c:1605`; `riscv64-gen.c:968`; `c67-gen.c:2039` |
| `gjmp`, `gjmp_addr`, `gjmp_cond`, `gjmp_append` | ✓ | ✓ | ✓ | `x86_64-gen.c:1612,1618,1644,1630`; `riscv64-gen.c:979,988,1004,1025`; `c67-gen.c:2050,2064,2081,2108` |
| `gen_opi`, `gen_opf`, `gen_cvt_{itof,ftoi,ftof}` | ✓ | ✓ | ✓ | `x86_64-gen.c:1671,1804,2013,2118,2055`; `riscv64-gen.c:1170,1180,1304,1330,1356`; `c67-gen.c:2132,2290,2422,2450,2474` |
| `ggoto` | ✓ | ✓ | ✓ | `x86_64-gen.c:2186`; `riscv64-gen.c:1430`; `c67-gen.c:2519` |
| `gen_vla_sp_save`, `gen_vla_sp_restore`, `gen_vla_alloc` | ✓ | ✓ | ✓ | `x86_64-gen.c:2193,2199,2212`; `riscv64-gen.c:1436,1447,1458`; `c67-gen.c:2526,2531,2536` |
| `o` | ✓ | ✓ | — | `x86_64-gen.c:184`; `riscv64-gen.c:117`; excluded for C67 by `tcc.h:1653-1655` |
| `gen_opl` | ✓ | — | — | R has `PTR_SIZE 8`; C relies on the `PTR_SIZE==4` generic (`tccgen.c:2105`); X defines its own `x86_64-gen.c:1796` |
| `gen_cvt_sxtw`, `gen_cvt_csti` | ✓ | ✓ | — | `x86_64-gen.c:2154,2163`; `riscv64-gen.c:1298,1277` |
| `gen_increment_tcov` | ✓ | ✓ | — | `x86_64-gen.c:2177`; `riscv64-gen.c:1404` |
| `gen_struct_copy` | ✓ | — | — | `x86_64-gen.c:2244` + decl at `112` (needs `TCC_TARGET_NATIVE_STRUCT_COPY`) |
| `gen_va_start` / `gen_va_arg` / `gen_clear_cache` | — | start+cache | — | `riscv64-gen.c:962,1489`; called only from `tccgen.c:6071-6145` target cases |
| `arch_transfer_ret_regs` | — | ✓ | — | `riscv64-gen.c:906`; only for `gfunc_sret < 0` |
| `classify_x86_64_va_arg` | ✓ | — | — | `x86_64-gen.c:1177` |
| `func_bound_add_epilog` | ✓ | ✓ | — | `x86_64-gen.c:161-164`; `riscv64-gen.c:85-88`; C67 `#undef CONFIG_TCC_BCHECK` (`c67-gen.c:112`) |
| `g`, `gen_le16`, `gen_le32`, `gen_le64` | ✓ | — | — | assembler only (`x86_64-gen.c:172-206`) |

---

## 2. Required macros in `TARGET_DEFS_ONLY`

| macro | value for NaN16 | consumed at / assumption made by tccgen |
|---|---|---|
| `NB_REGS` | 16 (ISA field is 4 bits; `nan16_p()` packs `d`,`a` in 4 bits) | `tccgen.c:1476,1500,1520-1523`; array bound at `tcc.h:1632`; `tccgen.c:6499-6500` |
| `RC_INT` | `0x0001` | generic int class, `tccgen.c:288-291`, `1928` |
| `RC_FLOAT` | `0x0002` | generic float class, `tccgen.c:290-301`. Must exist even if `gen_opf` only raises `tcc_error`; `float`/`double` types still parse. No `RC_F(n)` subclasses are needed if all 16 registers are integer — this avoids the `1<<31` overflow a `1<<(18+n)` scheme hits at n=13. |
| `RC_R(n)` | `1 << (2+n)` | per-register subclass; **must be strictly ordered "general → precise"** because `gv2` compares classes numerically (`tccgen.c:2004-2031`) |
| `RC_IRET` | `RC_R(1)` (conventional) | **not load-bearing**: `RC_RET` uses `reg_classes[REG_IRET]`, not this macro (`tccgen.c:282-285`). It is only read by `RC2_TYPE` (`tccgen.c:309-312`), and only when `RC_IRE2` is also defined. Define it for symmetry with the other backends. |
| `RC_IRE2` | `RC_R(2)` (conventional) | defining it enables the `RC2_TYPE` branch `if (rc == RC_IRET) return RC_IRE2;` (`tccgen.c:309-312`); if omitted, the second word falls back to `RC_INT` (`tccgen.c:317-319`). Either is workable; defining it is clearer. |
| `RC_FRET` | `RC_R(1)` (conventional) | only read by `RC2_TYPE` (`tccgen.c:313-316`) and by `RC_TYPE`'s x86_64-only branch (`tccgen.c:292-296`). Not needed by tccgen for NaN16. |
| `REG_IRET` | `1` | `tccgen.c:242, 6504` |
| `REG_IRE2` | `2` | `tccgen.c:259` (mandatory at `PTR_SIZE==4`) |
| `REG_FRET` | `1` | `tccgen.c:250` — **compiled unconditionally**, must be defined even if you never support `float` |
| `REG_FRE2` | omit | x86_64-only (`tccgen.c:263-264`, `313-316`) |
| `PTR_SIZE` | `4` | `tcc.h:397-420`, `tccgen.c:235,1447,1967,3555`, `tccpp.c:3617` |
| `LDOUBLE_SIZE` | `8` (or `16`) | `tccgen.c:3561-3563`; also `tccgen.c:8011-8070` host↔guest conversion |
| `LDOUBLE_ALIGN` | `8` | same |
| `MAX_ALIGN` | `8` | `tccgen.c:4114` (`__attribute__((aligned))` with no argument) |
| `CHAR_IS_UNSIGNED` | define (per `nan16-abi.h`) | `libtcc.c:892-894` sets `s->char_is_unsigned`; nothing else reads it |
| `PROMOTE_RET` | **do not define** | if undefined, tccgen rewrites a `char/short` return to `VT_INT` at the call site (`tccgen.c:6537-6544`, same at `5739-5745`), i.e. it trusts the callee to have extended. Your `load()` of a `char` via LDB already yields a 32-bit value, so this is the correct choice. Defining it instead sets `VT_MUSTCAST` (`tccgen.c:3277-3300`) and requires exact extension semantics. |
| `INVERT_FUNC_PARAMS` | cosmetic only | **never read by tccgen** (grep: only `arm-gen.c:103`, `c67-gen.c:96`, `i386-gen.c:62`, `il-gen.c:58`). It is a comment-style marker for the backend's own arg order. |
| `FUNC_STRUCT_PARAM_AS_PTR` | cosmetic only | same (`c67-gen.c:100,1982`, `i386-gen.c:706`) |
| `CONFIG_TCC_ASM` | **omit for v1** | defining it pulls in `tccasm.c:23-1525`, which then needs `g`/`gen_le16`/`gen_le32` (`tccasm.c:589,626,628`), `NB_ASM_REGS` (`tccasm.c:1333`) and `asm_opcode()`/`asm_parse_regvar()` (`tcc.h:1762-1765`). Without it, `tccasm.c` compiles empty and `tcc.h:700` `ASMOperand` disappears. |
| `TCC_TARGET_NATIVE_STRUCT_COPY` | omit for v1 | otherwise struct assignment calls `memmove` (`tccgen.c:3838-3849`) — that symbol must exist in the NaN16 runtime. |
| `TCC_TARGET_NAN16` | must be `#define`d by the build system | consumed at `tcc.h:163-165,366-392`, `libtcc.c:32-58`, `configure:646` |

Two additional switches normally `#undef`ed by a minimal target, cf.
`c67-gen.c:111-112`:

```c
#undef CONFIG_TCC_BCHECK    /* else tccelf.c:1597 tcc_add_bcheck + bcheck.o,
                               and gfunc_call must call gbound_args()
                               (tccgen.c:1681) + define func_bound_add_epilog */
#undef CONFIG_TCC_BACKTRACE /* else -bt pulls bt-exe.o/bt-log.o
                               (tccelf.c:1852-1860) */
```

### 2.1 What tccgen assumes about `reg_classes`

* `get_reg(rc)` returns the **first** index with `reg_classes[r] & rc`
  (`tccgen.c:1494-1512`), and on exhaustion spills the **bottom-most**
  stack value whose `r`/`r2` matches (`tccgen.c:1514-1528` →
  `save_reg` → `save_reg_upstack` → `store` at `tccgen.c:1438/1448`).
* Hence the return register must be the **first** register in the array that
  carries its `RC_R(n)` bit, and no earlier entry may share that bit.
* `RC_RET(t) = reg_classes[R_RET(t)] & ~(RC_FLOAT|RC_INT)`
  (`tccgen.c:282-285`): the return register's class entry must keep exactly
  one `RC_R(n)` bit after stripping `RC_INT|RC_FLOAT`.
* Reserved registers get `reg_classes[0|13|14|15] = 0` (r0 constant 0,
  r13 constant 1, r14 sp, r15 link — `nan16-abi.h:32-35`), so the allocator
  never picks them. Note `nb_args`/`regsize` paths also iterate `0..NB_REGS-1`
  (`tccgen.c:6499`).
* Putting `RC_INT` on the return register is optional: with
  `reg_classes[REG_IRET] = RC_R(1)` only, it is never allocated for ordinary
  expressions and `return` degenerates to `load(REG_IRET, …)` with no spill.

---

## 3. Minimum call sequence for `int main(void){return 42;}`

Verified by the instrumented stub backend (§0). Actual trace:

```
[gfunc_prolog] main loc=0
[load] r=1 sv->r=30 type=03 c=42        ← VT_CONST, VT_INT, 42
[gfunc_epilog] loc=0
```

Exact path with citations:

1. `tccgen_compile()` → `decl(VT_CONST)` → `gen_function(sym)`
   (`tccgen.c:8803`).
2. `ind = cur_text_section->data_offset` (`tccgen.c:8810`); optional
   `gen_fill_nops` if the symbol has an `aligned` attribute
   (`tccgen.c:8811-8815`).
3. `funcname/func_ind/func_vt/func_var/func_old` set
   (`tccgen.c:8817-8821`).
4. `put_extern_sym(sym, cur_text_section, ind, 0)` (`tccgen.c:8824`) —
   allocates the `ElfSym` via `put_elf_sym` (`tccgen.c:573`,
   `tccelf.c:442`). **NaN16 needs no change here.**
5. `gfunc_prolog(sym)` (`tccgen.c:8844`). At entry `loc == 0`, `ind` is the
   function start, `func_vt` = `int`, `func_var == 0`. Your prolog must:
   save the caller frame, set `loc` negative for locals (tccgen allocates
   downwards, `tccgen.c:1562,8702`), publish parameters with
   `gfunc_set_param(sym, offset, byref)` (`tccgen.c:8777-8786`).
6. `block(0)` (`tccgen.c:8847`) → `statement()` sees `TOK_RETURN`
   (`tccgen.c:7454`): `gexpr()` parses `42` and pushes `VT_CONST`
   (`vpushi`, `tccgen.c:952-955`); `gen_assign_cast` (`tccgen.c:7459`) is a
   no-op for `int` → `int`.
7. `leave_scope(root_scope)` (`tccgen.c:7471`) — no-op here.
8. `gfunc_return(&func_vt)` (`tccgen.c:7473`, body `tccgen.c:7009-7073`):
   non-struct → `gv(RC_RET(func_type->t))` (`tccgen.c:7069`).
   `RC_RET` = `RC_R(1)`.
9. `gv()` (`tccgen.c:1851`): `r_ok` false because `vtop->r == VT_CONST`
   (`tccgen.c:1927-1928`) → `r = get_reg(RC_R(1))` (`tccgen.c:1941`,
   `1494`) → **`load(r, vtop)`** (`tccgen.c:1991`). Arg:
   `sv->r == VT_CONST (0x30)`, `sv->type.t == VT_INT (3)`, `sv->c.i == 42`.
   **No `save_reg`/`store` occurs** — the return register is free.
10. `vtop--` at `tccgen.c:7071`.
11. `gsym(rsym)` (`tccgen.c:8848`): `rsym == 0`, and `gsym()` is a no-op for
    `t == 0` (`tccgen.c:173-178`), so **no `gsym_addr`**.
12. `gjmp` is **not** emitted: the `return` is the last statement of a
    top-level block, guarded by `if (tok != '}' || local_scope != 1)`
    (`tccgen.c:7476-7477`).
13. `gfunc_epilog()` (`tccgen.c:8852`) — must emit the return sequence
    (`nan16_ret()`), restore the frame, and leave `ind` at the end of code.
14. `elfsym(sym)->st_size = ind - func_ind` (`tccgen.c:8858`);
    `cur_text_section->data_offset = ind` (`tccgen.c:8859`).

Backend output for this program (with `nan16-enc.h` primitives):
`prolog` → `nan16_movi32(p, REG_IRET, 42)` (or `nan16_movi` when
`0 <= 42 <= 0xffff`) → `nan16_ret(p)`.

Emitter plumbing: `nan16-enc.c` writes into its own `Nan16Prog`, while the
backend must append to `cur_text_section` and keep `ind` in sync
(`tccgen.c:8810,8859`). Pick one:
* (a) keep a `Nan16Prog` next to `ind`, and copy its words into
  `section_ptr_add(cur_text_section, 8 * p.n)` at `gfunc_epilog`; or
* (b) write a 20-line local `emit(uint32_t payload, int pred)` that does
  `section_realloc`/`write64le` (the pattern of `riscv64-gen.c:117-126`),
  reusing only `nan16_p()` for payload construction.
Option (b) is simpler because `gjmp`/`gsym_addr` patch already-emitted words
by index (`nan16_patch_imm16`, `nan16-enc.h`) and therefore need random access
to the section buffer, not to a private array.

`save_reg`/`store` only enter the picture when the return register (or any
class register) is already busy: `get_reg` (`tccgen.c:1525`) →
`save_reg` (`tccgen.c:1406-1409`) → `save_reg_upstack`
(`tccgen.c:1413-1466`) → `store()` twice for a two-word value
(`tccgen.c:1438,1448`). Any non-trivial expression with more live values than
registers will hit this.

`gfunc_call` contract (for the next step, calling code): consume all
`nb_args` values **and** the function-symbol slot, i.e. finish with
`vtop -= nb_args + 1` (cf. `riscv64-gen.c:792`) so tccgen can write the
return value at `vsetc(&ret.type, ret.r, …)` (`tccgen.c:6504`).

---

## 4. Linker / output surface: `nan16-link.c` + the two tccelf.c hooks

### 4.1 Correction to the premise

`reloc`, `put_extern_sym`, `put_extern_sym2` are **not** in `tccelf.c`:

* `put_extern_sym2` — `tccgen.c:517-585`
* `put_extern_sym` — `tccgen.c:587-592`
* `greloca` / `greloc` — `tccgen.c:595-628`
* `elfsym` — `tccgen.c:463`

They operate on `symtab_section`/`Section` and need **no NaN16 branch**. The
only NaN16-relevant input is `R_DATA_PTR`, used at `tccgen.c:8192,8206,8679`
and `tccdbg.c:540` (with `R_DATA_32`), and `R_DATA_32DW`
(`tcc.h:1927-1930`).

### 4.2 Symbols `nan16-link.c` must define

`TARGET_DEFS_ONLY` part (mirrors `riscv64-link.c:1-18`):

| macro | use |
|---|---|
| `EM_TCC_TARGET` | `tccelf.c:2740` (ELF header), `3310`, `3874` (object/dll type checks) — any private value is fine for a cartridge |
| `R_DATA_32` | `tccdbg.c:540` — must be a number `relocate()` accepts |
| `R_DATA_PTR` | `tccgen.c:8192,8206,8679`, `tccdbg.c:540` — **mandatory** |
| `R_JMP_SLOT`, `R_GLOB_DAT`, `R_COPY`, `R_RELATIVE` | `tccelf.c:1336,1386,1530,1534,2048-2055,2135` (dynamic path only; may be private numbers) |
| `R_NUM` | defined by every link.c, currently unused in this tree |
| `ELF_START_ADDR`, `ELF_PAGE_SIZE` | `tccelf.c:1934,2446-2459` |
| `PCRELATIVE_DLLPLT`, `RELOCATE_DLLPLT` | `tccelf.c:1460` and `tccelf.c:3144` respectively — both only on the dynamic path; `0` is correct here |

Full build — all five are **link-time required** (ablation-verified, because
`tccelf.c` references them unconditionally in the non-PE/non-MACHO build):

| symbol | signature | NaN16 stub |
|---|---|---|
| `relocate` | `ST_FUNC void relocate(TCCState *s1, ElfW_Rel *rel, int type, unsigned char *ptr, addr_t addr, addr_t val);` (decl `tcc.h:1628`, call `tccelf.c:1171`) | **must be real** — see §4.4 |
| `code_reloc` | `ST_FUNC int code_reloc(int reloc_type);` (`tcc.h:1609`, call `tccelf.c:1520`) | `return -1;` (never reaches the GOT path) |
| `gotplt_entry_type` | `ST_FUNC int gotplt_entry_type(int reloc_type);` (`tcc.h:1610`, call `tccelf.c:1440`) | `return NO_GOTPLT_ENTRY;` (`tcc.h:1613-1618`) |
| `create_plt_entry` | `ST_FUNC unsigned create_plt_entry(TCCState *s1, unsigned got_offset, struct sym_attr *attr);` (`tcc.h:1621`, call `tccelf.c:1402`) | `return 0;` |
| `relocate_plt` | `ST_FUNC void relocate_plt(TCCState *s1);` (`tcc.h:1622`, call `tccelf.c:3145`) | empty |

Everything else on the ELF path may stay as-is and simply never be called by
`nan16_output_file`.

### 4.3 The two hooks that must be added in `tccelf.c`

1. **`tcc_output_file` dispatch** — `tccelf.c:3223-3237`. Insert before the
   final `#else`:
   ```c
   #elif defined(TCC_TARGET_NAN16)
       return nan16_output_file(s, filename);
   ```
   Declare `ST_FUNC int nan16_output_file(TCCState *s1, const char *filename);`
   next to `tcc_output_file` (e.g. after `tcc.h:1596-1604`).
   Note `TCC_OUTPUT_OBJ` returns early through `elf_output_obj`
   (`tccelf.c:3228-3229`, function at `3203`); either accept ELF `.o` or
   remap `-c` to the cartridge too.
2. **`tcc_add_runtime`** — `tccelf.c:1827-1885` is `#ifndef TCC_TARGET_PE` and
   hard-codes `tcc_add_bcheck`, `bcheck.o`, `bt-*.o`, `-lpthread`, `-lc`,
   `libtcc1.a`, `tccelf_add_crtend`. Give NaN16 its own definition:
   ```c
   #ifdef TCC_TARGET_NAN16
   ST_FUNC void tcc_add_runtime(TCCState *s1)
   {
       s1->filetype = 0;
       tcc_add_pragma_libs(s1);
       /* optionally: tcc_add_support(s1, "nan16-libc.a");  */
   }
   #else
   ... existing body ...
   #endif
   ```
   (Wrap the existing body, do not duplicate the symbol.)

Related, and *only* needed because they are referenced outside
`TCC_TARGET_UNIX`:
* `tccelf_add_crtbegin` / `tccelf_add_crtend` are defined only under
  `#ifdef TCC_TARGET_UNIX` (`tccelf.c:1764-1823`) but called from
  `libtcc.c:1010-1011` and `tccelf.c:1882`. Do **not** define
  `TCC_TARGET_UNIX` for NaN16 (`tcc.h:231-235`); instead add the branch in
  `tcc_set_output_type` (§5.2) and the replacement `tcc_add_runtime` above.

### 4.4 Minimal `nan16_output_file`

Reuse the ELF IR; only four calls are needed before writing bytes:

```c
resolve_common_syms(s1);                     /* tccelf.c:1975: .common -> .bss */
                                             /* assign sh_addr yourself, as layout_sections()
                                                does at tccelf.c:2413-2564 (a flat layout:
                                                .text=0, then .rodata, .data, .bss aligned) */
relocate_syms(s1, s1->symtab, 0);            /* tccelf.c:1084: st_value += section->sh_addr */
relocate_sections(s1);                       /* tccelf.c:1198 -> your relocate() */
/* then: copy .text / .rodata / .data data, append .bss as zeros, write file */
```

`relocate()` for NaN16:

* `ptr = s->data + rel->r_offset`; `val = sym->st_value (+ r_addend)`
  (`tccelf.c:1152-1171` documents the exact ABI of the call).
* Emit exactly three reloc numbers:
  * `R_NAN16_WORD` — 16-bit payload field of a `CALL`/`JMP` word.
    `nan16_emit_word()` stores each instruction as one little-endian
    `uint64_t`, and `nan16_p(op,d,a,imm)` builds the payload as
    `op<<24 | d<<20 | a<<16 | imm`, i.e. the imm is the **low 16 bits of the
    low 32-bit word**. Patch with `write16le(ptr + 2, val / 8)` — divide by 8
    because `ind`/`st_value` are byte offsets while `nan16_jmp`/`nan16_call`
    take a **word index** (`uint16_t target` in `nan16-enc.h`).
  * `R_NAN16_ABS32` — a full 32-bit constant produced by `nan16_movi32()`
    (`MOVI` + `MOVHI`) → `write32le(ptr, val)`.
  * `R_DATA_PTR` (reuse the name) for pointer-sized data words.
* Add addend: `PTR_SIZE == 4` selects `SHT_REL` (`tcc.h:404-410`), so
  `put_elf_reloca` rejects non-zero addends (`tccelf.c:815-816`); always
  encode addends in the emitted word instead.

Hard limits to enforce at relocation time: imm16 → target word index
`< 0x10000`, i.e. cartridge `<= 64Ki words = 512 KiB`; a 32-bit
`LD/ST` base must be materialized with `MOVI`/`MOVHI`, since `nan16_ld` /
`nan16_st` take only a 16-bit offset (`uint16_t imm` in `nan16-enc.h`).

### 4.5 What can be stubbed for a flat cartridge

| item | disposition |
|---|---|
| `relocate` | **real** (§4.4) |
| `code_reloc`, `gotplt_entry_type`, `create_plt_entry`, `relocate_plt` | stubs (§4.2) |
| `build_got_entries` (`tccelf.c:1422`) | never called by `nan16_output_file`; leave compiled |
| `tcc_load_object_file` (`tccelf.c:3289`), `tcc_load_archive` (3685), `tcc_load_dll` (3857), `tcc_load_ldscript` (4183) | keep; unreachable unless such a file is passed. `tcc_add_binary`/`tcc_object_type` (`libtcc.c:1065-1160`, `tccelf.c:3268`) still sniffs ELF magic for every input — harmless for `.c`-only input |
| `tcc_add_crt` (`libtcc.c:1290-1296`) | compiled only under `TCC_TARGET_UNIX`; do not define it |
| `tcc_add_support` (`libtcc.c:1282-1288`) | usable if you ship `nan16-libc.a`; otherwise not called |
| `-run` | impossible: `TCC_IS_NATIVE` is only set for matching hosts (`tcc.h:189-202`) and `tccrun.c` is `#ifdef TCC_IS_NATIVE` (`tccrun.c:24,215,1587`) |
| `TCC_EH_FRAME` | disable (§5.1) — `tccdbg.c:820-1000` has no `#else` for unknown targets |

---

## 5. Exact places needing a `TCC_TARGET_NAN16` branch

### 5.1 `tcc.h`

| line | change |
|---|---|
| `163-165` | add `&& \` / `!defined(TCC_TARGET_NAN16)` to the "no target chosen" test, otherwise the host default is selected |
| `366-392` | add `#elif defined(TCC_TARGET_NAN16)` → `# include "nan16-gen.c"` + `# include "nan16-link.c"` (this is the `TARGET_DEFS_ONLY` pass) |
| `1846` | add `\|\| defined TCC_TARGET_NAN16` to the `TCC_EH_FRAME` exclusion list (same reason as `TCC_TARGET_C67`, which is excluded because `tccdbg.c` has no CFI emitter for it) |
| `302-317` | optional: `#elif defined TCC_TARGET_NAN16` → `#define CONFIG_TCC_ELFINTERP "-"`; the fallback is `/lib/ld-linux.so.2`, harmless but wrong |
| `1602`, `1608`, `1620`, `1628` | **no change**: the declarations of `tcc_add_runtime`, `code_reloc`/`gotplt_entry_type`, `NEED_BUILD_GOT`, `relocate` are all `#ifndef TCC_TARGET_PE` / `#if !defined TCC_TARGET_MACHO …`, which is true for NaN16 |
| `1631-1658` | **no change**: generic gen.c API declarations |

### 5.2 `libtcc.c`

| line | change |
|---|---|
| `32-58` | add `#elif defined(TCC_TARGET_NAN16)` → `#include "nan16-gen.c"` / `#include "nan16-link.c"` in the `ONE_SOURCE` chain (without it the second, full-build inclusion never happens) |
| `996-1012` | add `#elif defined(TCC_TARGET_NAN16)` before the final `#else`; the `#else` calls `tccelf_add_crtbegin` (`1011`) and splits `CONFIG_TCC_CRTPREFIX` (`1009`), both absent for NaN16. NaN16 branch = do nothing (or add only its own lib path) |
| `1775-1789` | add `#elif defined TCC_TARGET_NAN16` → `"nan16"` to `dumpmachine_str` |
| `892-894` | no change; driven by `CHAR_IS_UNSIGNED` |
| `987-991` | decide: `TCC_OUTPUT_OBJ` currently forces `TCC_OUTPUT_FORMAT_ELF`; if `-c` must emit a cartridge, add a branch here |

### 5.3 `tcc.c` (driver, cosmetic but expected)

| line | change |
|---|---|
| `177-195` | add `#elif defined TCC_TARGET_NAN16` → `"NaN16"` in the `-v` banner |
| `227-232` | `print_search_dirs` prints crt/elfinterp only under `TCC_TARGET_UNIX`; no change needed |
| `251-276` | `default_outputfile`: `.o` for `-c`, `a.out` otherwise; add an extension (e.g. `.n16`) if desired |

### 5.4 `configure`

| line | change |
|---|---|
| `351-353` | add `nan16) cpu="nan16" ;;` to the `case "$cpu"` (before the `*)` "Unsupported CPU" at `354-356`) |
| `481` | `case $cpu in x86_64\|arm64\|riscv64)` selects `/usr/lib64` — NaN16 must **not** be added (no libc) |
| `646-647` | add `\|\| TCC_TARGET_NAN16` to the generated `config.h` guard `#if !(TCC_TARGET_I386 \|\| … \|\| TCC_TARGET_C67)`. **Without this, `config.h` force-defines the host target and the NaN16 build silently compiles the host backend** (observed during verification) |
| `660-663` | add `CONFIG_nan16=yes) print_num TCC_TARGET_NAN16 1 ;;` next to the other `CONFIG_*` cases |
| `300-356` | no other target lists exist (no `--cpu` whitelist beyond this `case`) |

### 5.5 `Makefile`

| line | change |
|---|---|
| `119-120` | add `DEF-nan16 = -DTCC_TARGET_NAN16` (after `DEF-riscv64`) |
| `136-137` | add `nan16` to `TCC_X` |
| `141` | `LIBTCC1_X = $(filter-out c67,$(TCC_X))` → also filter `nan16` unless a `nan16-libtcc1.a` is built |
| `219` | add `nan16_FILES = $(CORE_FILES) nan16-gen.c nan16-link.c` — plus `nan16-enc.c nan16-enc.h nan16-abi.h` **only if** `nan16-gen.c` `#include`s them (the ONE_SOURCE build must list every file the include chain pulls in, because `$(X)%.o : %.c $(LIBTCC_INC)` uses `$($T_FILES)`) |
| `254-257` | `tccdefs_.h` rule is target-independent; no change |
| `293-300` | `%-tcc: … CROSS_TARGET=$*` and `$(CROSS_TARGET)-tcc$(EXESUF)` need no change once `DEF-nan16` and `nan16_FILES` exist |

---

## 6. Known conflicts / decisions to settle before coding

### 6.1 `double` is 8 bytes in this TCC, unconditionally

`type_size()` hard-codes `VT_DOUBLE`/`VT_LLONG` to size 8 and align 8 except
for i386/ARM EABI (`tccgen.c:3564-3571`). `nan16-abi.h:52` says
`NAN16_SIZEOF_DOUBLE 4` and `nan16-abi.h:58` says `NAN16_ALIGN_DOUBLE 4`.
**These cannot both be true**, but the conflict is already resolved in
product direction: `spec/ABI64_DOUBLE_PLAN.md` moves ncc to `double` = 8 bytes
/ align 8, which is exactly what TCC emits. So set
`NAN16_SIZEOF_DOUBLE 8` / `NAN16_ALIGN_DOUBLE 8` in `nan16-abi.h` and do not
try to make TCC's `double` 4 bytes (it would require patching
`type_size()` itself). `long double` must be 8 (or 16) because
`LDOUBLE_SIZE` feeds `type_size` (`tccgen.c:3561-3563`) and the constant
writer (`tccgen.c:8011-8069`): with any other value the "unknown" branch
(`tccgen.c:8064-8067`) copies nothing, leaving `long double` initialisers
uninitialised.

### 6.2 Varargs

`include/tccdefs.h:246-249` falls through to the generic
`typedef char *__builtin_va_list` +
`#define __builtin_va_start(ap,last) (ap = ((char*)&(last)) + ((sizeof(last)+3)&~3))`
because NaN16 defines none of `__x86_64__`/`__arm__`/`__aarch64__`/`__riscv`.
That requires the callee to lay **declared parameters contiguously and
ascending** starting at `NAN16_VARARGS_OFFSET` (fp+16, `nan16-abi.h:60-61`),
which is compatible with the frame layout in `nan16-abi.h:38-43`. With that
layout **no `gen_va_start` is needed** and no `tccgen.c` edit is needed. If
instead you want the fixed 64-byte varargs area with a register save area, you
must add `TCC_TARGET_NAN16` cases to `tcctok.h:179-188`,
`include/tccdefs.h`, and `tccgen.c:6071-6145`, and implement
`gen_va_start`/`gen_va_arg`.

### 6.3 Runtime symbols the generated code will reference

* `memmove` — struct assignment unless `TCC_TARGET_NATIVE_STRUCT_COPY`
  (`tccgen.c:3838-3849`).
* `__divdi3`, `__udivdi3`, `__moddi3`, `__umoddi3` — `long long` division
  via `gen_opl` (`tccgen.c:2118-2130`).
* `memcpy/memmove/memset/memcmp/strlen/strcpy/strncpy/strcmp/strncmp/strcat/strncat/strchr/strrchr/strdup`
  as `__BOTH(…)` builtins (`include/tccdefs.h:279-306`) if you enable the
  predefs header (default `CONFIG_TCC_PREDEFS`); otherwise declare them
  yourself in a NaN16 `libc` header set.
* `_start` / entry stub: `tcc.c` passes no `-e` for a cartridge; the loader
  entry must be generated (either a small `.s` in the cartridge or an
  emitted stub calling `main`).

### 6.4 Output constraints recap

* Word index space 16 bits → whole cartridge `<= 512 KiB`; branch/call
  relocation must fail loudly beyond that.
* No PIC/GOT/PLT/dynamic linker: keep `s1->static_link` semantics irrelevant
  by never calling `build_got_entries`.
* `TCC_OUTPUT_MEMORY` (`-run`) is unreachable; reject it explicitly.

---

## 7. Ordered implementation checklist

1. `tcc.h:163-165`, `366-392`, `1846`; `libtcc.c:32-58`, `996-1012`,
   `1775-1789`; `configure:351-353,646-647,660-663`; `Makefile:119-120,
   136-137,141,219`.
2. `nan16-gen.c` `TARGET_DEFS_ONLY`: macros of §2 (`#undef CONFIG_TCC_BCHECK`
   / `CONFIG_TCC_BACKTRACE`), `reg_classes[]` with r0/r13/r14/r15 = 0.
3. `nan16-gen.c` full build: `target_machine_defs`, then the 23 symbols of
   §1.2. Start with `load/store` (const + local + reg + symbol cases) and
   `gjmp*`; stub `gen_opf`/`gen_cvt_*` with `tcc_error("float unsupported")`
   until FP is needed.
4. Verify §3 acceptance: `int main(void){return 42;}` produces exactly one
   `MOVI/MOVHI` into `REG_IRET` and one `RET`.
5. `nan16-link.c`: §4.2 macros + stubs, then `relocate()` (§4.4) and
   `nan16_output_file()`; hook `tcc_output_file` (`tccelf.c:3223`) and
   replace `tcc_add_runtime` (`tccelf.c:1827`).
6. Add the runtime (memmove + divdi3 family + entry stub) as
   `nan16-libc.a` fed by `tcc_add_support` in your `tcc_add_runtime`.
7. Re-run the ablation build (`-DTCC_TARGET_NAN16 -DONE_SOURCE`) to confirm
   no symbol from §1/§4 is missing, then diff the emitted words against the
   VM's `nan16-enc` self-test expectations (`nan16-enc-selftest.c`).

---

## 8. State of the in-tree work-in-progress (observed, not part of the API)

At the time of writing, untracked `nan16-gen.c` (defs-only macros, no
full-build section) and `nan16-link.c` (defs-only macros, no full build)
exist in the worktree, and `tcc.h`/`libtcc.c` already carry the two branches
of §5.1/§5.2. Against that file set:

1. **No per-register subclass bit.** `RC_RET(t)` is
   `reg_classes[R_RET(t)] & ~(RC_FLOAT|RC_INT)` (`tccgen.c:282-285`) and must
   be non-zero. With only `RC_INT`/`RC_FLOAT` available (the file defines no
   `RC_R(n)` and no `reg_classes[]` yet), the mask strips to `0`; `get_reg(0)`
   then matches nothing (`reg_classes[r] & 0` is false, `tccgen.c:1500-1512`)
   and returns `-1`, which is passed straight to `load()`
   (`tccgen.c:1941,1991`). Add `RC_R(n) = 1 << (2+n)` and give the return
   register its own bit in `reg_classes[]` (§2.1). The `RC_IRET == RC_INT`
   aliasing itself is harmless — those macros are not load-bearing (§2).
2. **`LDOUBLE_SIZE 4` / `LDOUBLE_ALIGN 4` is not representable.** `long
   double` initialisers are copied by `write_ldouble`, which has arms only for
   `8`, `16`, x86-extended and "same as host" (`tccgen.c:8044-8068`); size 4
   falls into the no-op `#else` (`tccgen.c:8064-8067`) and writes nothing.
   Use 8 (or 16) — see §6.1.
3. `NB_REGS 12` covers r0..r11. r0 is the hard-wired zero, so once
   `reg_classes[]` exists it must be `reg_classes[0] = 0`, otherwise
   `get_reg(RC_INT)` can hand out r0 and every store into it is lost.
4. `MAX_ALIGN 8` with `LDOUBLE_ALIGN 4` is self-contradictory for
   `__attribute__((aligned))` (`tccgen.c:4114`).
5. Both files still need the full-build symbol sets of §1.2 and §4.2; without
   them the link fails at `load`, `store`, `gfunc_*`, `gjmp*`, `relocate`,
   … (the exact list is the ablation result quoted in §1/§4).
