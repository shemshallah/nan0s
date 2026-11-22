# ncc: C on NaN16 — parity status

`src/lib/ncc.nas` is a C front end and interpreter written entirely in raw
NaN16. It is usable from the GUI terminal: press `e`, type C lines, then
`.run` (or `.demo` for the built-in example). The compiler, the runtime, and
the editor are guest NaN16 code; there is no host C/Python/JS in the execution
path.

## Port readiness

All tracked C language/library blockers are closed: the explicit
function-returning-function-pointer definitions, nested/mixed brace elision,
packed bit-fields, `wprintf`/`wscanf`, the `getchar`/`getc`/`putc`/`ungetc`
family, and persistent files over ATA are implemented and gated by `M40`-`M46`.
The C89/C99 hosted library name set used by the port is now present: the
last core names (`strtof`/`strtold`, `llabs`, `strncat`, `remquo`, and the
restartable multibyte conversions) are gated by `M61`, and the `<inttypes.h>`,
wide-ctype, `errno`, `assert`, and `fwide` additions are gated by `M62`.
The explicit exclusions are now only C11 `<complex.h>` (and `_Complex`/
`_Imaginary`) and variable-length arrays (`__STDC_NO_VLA__` is defined).
C11 `_Static_assert`, `_Alignof`, `_Alignas`, `_Generic`, `_Noreturn`,
`_Atomic`, `_Thread_local`, compound literals (including inferred-size array
literals), wide string/character literals (`L"..."`/`L'x'`), flexible array
members, `<uchar.h>` (real UTF-8/UTF-16/UTF-32 conversions), the `f`/`s`/`v`
wide-stdio family, a single-threaded `<stdatomic.h>`, a stored-rounding
`<fenv.h>`, and serialized `<threads.h>` are implemented and gated by
`tools/ncc_iso_c.sh`.
The remaining documented limitations are platform or optional-scope items:

- `<stdatomic.h>` operations are plain 32-bit loads/stores (single-threaded;
  `memory_order_*` values are accepted and sequential consistency is trivial);
- `<fenv.h>` stores/returns a rounding mode but arithmetic stays
  round-to-nearest, and floating exceptions are not raised or accumulated;
- `<threads.h>` `thrd_create` runs the start routine synchronously and
  `thrd_join` returns its result; mutexes/condition variables are successful
  no-ops, and `tss_*` uses a small per-process table;
- `_Alignas` beyond the natural type alignment is honored for globals and for
  locals relative to the frame base; nested frames can only be as aligned as
  their frame base;
- wide string literals are pointer-typed (like the existing narrow literals),
  so `sizeof L"..."` is the pointer size; use a `wchar_t` array when the array
  size is needed;
- wide stdio reuses the narrow formatter/scanner; in the ASCII C locale it
  emits/consumes byte cells and does not UTF-8-encode non-ASCII wide output
  (`<uchar.h>` does perform real UTF-8 conversion);
- the C locale is the only locale (the ISO C minimum);
- x86 BIOS boot media: qemu-system-i386 is installed. `tools/qgate.sh` passes
  the floppy fallback, and `tools/qgate_gui.sh` passes the full GUI by
  attaching the image as the primary IDE master: the kernel's ATA loader
  reads `ceil(LMAX/64)` sectors from LBA 17 into guest memory, so the whole
  0.67 MB image loads even though the real-mode floppy staging is only
  512 KiB. A floppy-only machine still gets the 512 KiB fallback; the full
  image must be attached as (or dd'ed to) the primary master.
- the POSIX-free machine-interface table is implemented in
  `src/lib/bare.nas`; console, block, and NPAF-backed filesystem adapters are
  wired (see `spec/BARE_METAL_INTERFACES.md`);
- the library now covers the standard C names plus the POSIX interval timer
  interface; the remaining POSIX extensions are outside the subset.

None of these blocks the Python port; the Py-M1 subset now runs in-guest
(`spec/PYTHON_PORT.md`).


## What NaN16 is (and is not)

NaN16 is the **guest ISA / VM**, not a 16-bit target. Every machine word is
64 bits wide:

```
far NaN head (16) | payload (32) | near NaN head (16)
```

Each head is one of four legal NaN encodings, so the two ends carry a 4-bit
**class nibble**: 16 Boolean functions / 16 predicate masks. The "16" is that
nibble, not 16-bit words.

The C runtime uses the 32-bit payload as the value and a byte-addressed memory
model on top of the 64-bit words (four C bytes per word). It is ILP32:
`char` 1, `short` 2, `int`/`long`/pointers 4, `long long` 8 (two words),
`float`/`double` 4 (32-bit IEEE bits in the payload). Pointers are 32-bit byte
addresses into the C globals/stack/heap; function pointers are 32-bit entry
addresses. Structs use the normal alignment/padding rules (`long long` is
4-aligned here). The C ABI is **internal**: arguments and results travel on the
IR evaluation stack, `long long` is a low/high pair, and struct/union returns
are heap copies. There is no external ELF/COFF ABI to match.

## What kind of parity

- **Compile/runtime parity** for the documented C subset: every feature and
  library gate compares stdout exactly (`M1`-`M62`).
- **Differential torture parity**: `tools/ncc_torture.sh` compiles the same C
  source with clang and ncc; the saved clang output is the expected file.
  The current case covers integer promotions, signed division/remainder, shifts,
  bitwise `&`/`|`/`^` (including compound assignment), pointer arithmetic,
  multidimensional arrays and nested subscripts whose index expression itself
  contains a subscript (`lp[j][ls[j]-1]`; the base type is saved across the
  index parse), struct/union layout, function pointers, recursion, varargs,
  `for(;;)`, `switch`, `goto`, `setjmp`/`longjmp`, strings and `long long`.
- **Visual parity** for the classic a1k0n donut:
  `tools/ncc_donut_exact.sh` runs the ported source and checks the first frame
  byte-for-byte against a saved frame. The saved frame is also byte-identical
  to a host clang build of the same float-trig algorithm (1761/1761 cells);
  the x^9 and x^11 sine terms close the four luminance-boundary differences
  left by the old degree-7 polynomial.
- **Self-hosting**: `tools/mkproof.sh` proves nasm0 reproduces the ncc words.
- **Not** ABI parity with an external object format, full ISO C, or
  performance parity. There is no optimizer; `volatile` is effectively
  always-accessed.

## What ran, and what still diverges

Run in this tree: `M1`-`M62`, `ncc_alloc`, `ncc_heap`, `ncc_headers`,
`ncc_include`, `ncc_iso_c`, the GUI gates, `py_m1`, `ncc_torture`,
`ncc_donut_exact`, `mkproof`, `qgate`, `xmemgate`, and
`qgate_gui` (x86 + ATA IDE loader). Not yet run: Csmith, the GCC torture
tests, or the c-testsuite as a whole. Known divergences: the preprocessor is
line-based; `#if`/`#elif` evaluate the full integer/character constant
operator set, `defined()`, macro values, parentheses, and `?:`; object-like
macros carry arbitrary replacement text (types, storage classes,
expressions, declarations, empty bodies) and are expanded recursively with
the C blue-paint rule; `#include "..."`/`<...>` are expanded from the NPAF
path store (relative to the including file, then `/`), standard headers are
accepted as empty placeholders because `src/lib/headers.nas` installs the
C89/C99 limits, stdint, float, stdio, locale, signal, math, and wchar
constants plus the `int8_t`..`uint64_t` typedefs; function-like macro
definitions in headers are not seen by the pre-expansion macro pass; `double`
is 32-bit storage; the in-guest `sin`/`cos` are float32 and
not correctly rounded for every input, although the a1k0n donut first frame is
now byte-identical to clang's double-trig build; C11 `<complex.h>` and VLAs
are excluded; the wide `f`/`s`/`v` stdio families and the C11 atomic/fenv/
threads/uchar interfaces are present in the single-threaded form documented
above; a floppy-only x86 boot falls
back to the first 512 KiB (the full GUI needs the image as an IDE primary
master, which the kernel ATA loader reads).

## Memory model

C memory is byte-addressed on top of the 32-bit NaN word:

| type | size | alignment |
| --- | ---: | ---: |
| `char`, `signed char`, `unsigned char` | 1 | 1 |
| `short`, `unsigned short` | 2 | 2 |
| `int`, `unsigned int` | 4 | 4 |
| `long`, `unsigned long` | 4 | 4 |
| `long long`, `unsigned long long` | 8 | 4 |
| pointers | 4 | 4 |
| `float`, `double` (storage only) | 4 | 4 |

Four C bytes live in each NaN word, little-endian. `sizeof`, pointer scaling,
`char`/`short` loads and stores, sign extension, and unsigned division/shift
all use those byte sizes. C frames, globals, string literals, and the heap use
dedicated byte regions (see the `C_*` constants in `ncc.nas`), so a C pointer
is an ordinary 32-bit byte address.

Integer promotions are applied to operands narrower than `int`; the usual
arithmetic conversions pick the common type. `char` is signed by default.

## Language subset

Implemented:

- declarations, initializers, assignment and compound assignment
- all C89 integer/pointer operators with correct precedence, including
  `++`/`--`, unary `&`/`*`/`!`/`~`, shifts, comparisons, logical
  short-circuit, ternary, casts, `sizeof`
- `if`/`else`, `while`, `for`, `do`/`while`, `break`, `continue`
- functions, prototypes, parameters, recursion, `return`
- function pointers: `RET (*name)(params)` at global or block scope,
  typedefs, parameters (explicit and typedef), typedef'd returns, arrays,
  function-designator values, assignment, indirect calls through variables,
  array elements, struct members, and `(*fp)(...)`, comparison
- global and local arrays, multidimensions, pointer arithmetic/indexing,
  including `[]` size inference from brace initializers
- `char`/`short`/`int`/`long`, signed and unsigned, `sizeof` in bytes
- 64-bit `long long`/`unsigned long long`: two-word stack representation,
  literals (including values above 2^32 in decimal/hex/octal), add/sub/mul/
  div/mod (signed and unsigned), shifts, bitwise operators, comparisons,
  compound assignment, `++`/`--`, arrays, structs/unions, globals, function
  parameters/returns (including mixed int/LL and indirect calls), `va_arg`,
  `%lld/%llu/%llx/%llo` in printf and scanf, and LL<->float casts
- `float`/`double` (32-bit IEEE storage), float literals, arithmetic,
  comparisons, casts, and built-in `sin`/`cos`
- `printf` with `%d %i %u %x %X %c %s %p %f %e %E %g %G %%`, flags
  `-`/`0`/`#`, field width, and precision (including `%.2f`, `%.3s`,
  zero-padded `%08.2f`, `%.6g`, and `%#g`)
- `sprintf`/`snprintf` (including truncation and `snprintf`'s would-be length)
- `%e`/`%E` (normalization, precision, width, sign)
- variadic functions: `va_list`, `va_start`, `va_arg`, `va_end`
- string and character literals with escapes (`\n`, `\t`, `\xNN`, octal)
- `char` arrays with string-literal initializers, including unsized
  `char s[] = "..."`
- `struct`/`union` with `.` and `->`, arrays of structs, alignment/padding
- struct/union assignment as a byte copy of the object
- struct/union pass-by-value and return-by-value (including nested
  expressions; returned objects are heap copies)
- aggregate brace initializers for structs, unions, and arrays, including
  nested struct/array members and partial brace elision (unions initialise
  the first member)
- C99 designated initializers: `.member =`, `[index] =`, `[index].member =`,
  and nested braced designators (`.s = {.b = 2}`)
- C11 `_Static_assert` (file scope, block scope, and inside struct/union
  member lists), `_Alignof`, `_Alignas` (globals and locals; the effective
  alignment is the maximum of the type alignment and the requested value),
  `_Generic` (only the selected association is compiled; the controlling
  expression is typed but not evaluated), `_Noreturn`, `_Atomic` as a
  qualifier or `_Atomic(type)`, and `_Thread_local` (static storage in this
  single-threaded runtime)
- compound literals `(type){...}` for scalars, structs/unions, and arrays,
  including brace designators and inferred-size arrays (`(int[]){1,2,3}`);
  nested compound literals are supported
- wide string and character literals (`L"..."`, `L'x'`) as 32-bit arrays;
  `wchar_t` arrays can be initialised from a wide string literal
- flexible array members (`int a[];` as the last struct member); `sizeof`
  excludes the flexible member and element access uses the allocated tail
- bit-fields (named, anonymous, signed/unsigned, comma declarators,
  initializers); the layout is implementation-defined and non-packed: each
  named field occupies its declared type's storage, and values are masked /
  sign-extended on access
- `enum` constants in expressions and `case` labels
- `typedef`
- `switch`/`case`/`default` with fallthrough, `goto`/labels
- block scope with shadowing (locals and typedefs; labels stay function-wide)
- casts, including pointer target casts and `sizeof(int *)`

Not implemented (honest list):

- brace elision is supported across arrays of flat aggregates
  (`struct S a[2] = {1,2,3,4};`), nested aggregates
  (`struct T{struct S s; int z;} t = {1,2,3};`), mixed braced/unbraced
  subobjects, and aggregate expressions (`t = {other, 5}`)
- the explicit function-returning-function-pointer declarator is parsed for
  prototypes and for definitions with any parameters
  (`int (*f(int k))(int,int){...}`)
- bit-fields pack into 32-bit storage units (`unsigned a:3; unsigned b:5;`
  share one word, matching GCC for `int`-based fields), with zero-width fields
  starting a new unit. `char`/`short` bit-fields also use 32-bit units rather
  than GCC's 1/2-byte units; layout is implementation-defined and the field
  access rules follow C
- `const` is enforced for scalar objects, globals, and function parameters
  (assignment/compound assignment/`++`/`--` are rejected). `volatile` accesses
  are always emitted because there is no optimiser; `register` is ignored as a
  hint, which C permits
- `#include "..."` and `#include <...>` are expanded from NPAF; quoted names
  are searched relative to the including file's directory, then `/`, while
  `<...>` first matches the built-in standard-header table (whose bodies are
  empty because the libc and standard types are built in) and otherwise falls
  back to NPAF
- variable-length arrays are not implemented; `__STDC_NO_VLA__` is 1
- `_Complex`/`_Imaginary` and `<complex.h>` are not implemented
- the standard library is a practical subset. Sorting/searching
  (`qsort`/`bsearch`, including guest and builtin callbacks), non-local jumps
  (`setjmp`/`longjmp`), `strftime`, `tmpnam`/`tmpfile`, and the wide-string
  helpers `wcslen`/`wcscmp`/`wcscpy`/`wcscat`, plus `strspn`/`strcspn`/
  `strpbrk`/`strtok`/`memchr`/`strcoll`/`strxfrm`/`strtol`/`strtoul`/
  `strtoll`/`strtoull`/`strchr`/`strrchr`/`strndup`/`stpcpy`/`memccpy`,
  `atol`/`atoll`, the remaining ctype predicates (`isalnum`, `iscntrl`,
  `isgraph`, `isprint`, `ispunct`, `isxdigit`), wide-string helpers
  (`wcschr`/`wcsrchr`/`wcsncmp`/`wcsncpy`/`wcsncat`/`wcsspn`/`wcscspn`/
  `wcspbrk`/`wcsstr`/`wcstok`/`wmem*`/`wcscoll`/`wcsxfrm`, wide numeric
  conversions (`wcstol`/`wcstoul`/`wcstoll`/`wcstoull`/`wcstod`/`wcstof`/
  `wcstold`), multibyte conversion
  (`btowc`/`wctob`/`mblen`/`mbtowc`/`wctomb`/`mbstowcs`/`wcstombs`),
  plus `strerror`/`perror`
  and `getenv`/`system` stubs are implemented. `wprintf` now supports
  flags, width, precision, `%d`/`%i`/`%u`/`%o`/`%x`/`%X`/`%c`/`%s`/`%ls`/`%p`/
  `%%` and literal wide text; `wscanf` translates the wide format to narrow
  scanf syntax and widens `%ls` destinations. The C locale is the only locale,
  which is the minimum required by ISO C; `setlocale` returns `"C"` and
  `localeconv` reports the C conventions
- C11 library additions: `<uchar.h>` (`char16_t`, `char32_t`, `mbrtoc16`,
  `c16rtomb`, `mbrtoc32`, `c32rtomb`) performs real UTF-8 conversion with
  UTF-16 surrogate state in the 32-bit `mbstate_t`; the `f`/`s`/`v` wide-stdio
  family (`fwprintf`, `fwscanf`, `swprintf`, `swscanf`, `vfwprintf`,
  `vfwscanf`, `vswprintf`, `vswscanf`) converts the wide format to the ASCII
  narrow form and reuses the narrow formatter/scanner (the scanner keeps the
  existing `%ls` destination widening); `<stdatomic.h>` provides the atomic
  typedefs, memory-order constants, `atomic_flag`, load/store/exchange/CAS/
  fetch-op/flag/fence/is_lock_free and the `_explicit` spellings over 32-bit
  objects; `<fenv.h>` provides `fenv_t`/`fexcept_t`, the `FE_*` constants and
  get/set/hold/update entry points (rounding is stored but arithmetic stays
  round-to-nearest); `<threads.h>` provides `thrd_t`/`mtx_t`/`cnd_t`/`tss_t`/
  `once_flag`, synchronous `thrd_create`/`thrd_join`, successful mutex and
  condition no-ops, a small TSS table, and working `call_once`. `_Complex` and
  VLAs remain excluded (`__STDC_NO_VLA__` is 1)
- signal handlers are installed and delivered by `raise`; `alarm()` and
  `setitimer`/`getitimer` perform asynchronous `SIGALRM` delivery at
  IR-instruction boundaries (ITIMER_REAL, with interval reload)
- the path filesystem is RAM-backed by default. When an ATA primary-master
  disk is attached, NPAF snapshots to LBA 2048 after each write/delete and
  reloads the snapshot at startup; without a disk it still resets on reboot.
  The POSIX-free machine interface remains planned; see
  `spec/BARE_METAL_INTERFACES.md`
- x86 BIOS boot images remain capped at 1.44 MB (Android/NaN0S images are
  arbitrary size). This is a boot-media limit, not a C language gap

## Preprocessor subset

A text pass (`src/lib/mpp.nas`) runs before the lexer when the source
contains any `#define`. It removes directive lines and rewrites the
remaining text; `tools/ncc_macro_text.sh` gates the object-macro path.

- `#define NAME replacement-text` (object-like): types, storage classes,
  expressions, declarations, and empty replacements, including
  backslash-newline continuations. Replacement text is tokenized and
  rescanned recursively; a macro is disabled while its own replacement is
  being expanded, so self-reference and mutual recursion terminate without
  looping. Later definitions take effect only after their line, and
  `#undef`/redefinition work in source order.
- `#define NAME(params) body` (function-like): parameters, nesting, `#`
  stringification, `##` pasting, `__VA_ARGS__`, GNU `, ##__VA_ARGS__`, and
  zero-argument macros. Object-like and function-like macros compose in
  either direction.
- Replacement text is not expanded inside string literals, character
  constants, line comments, or block comments.
- `#undef NAME`
- `#ifdef`, `#ifndef`, `#if`, `#elif`, `#else`, `#endif`; `defined(NAME)`
  and macro values inside `#if`/`#elif` are resolved by the text pass, then
  the lexer-side evaluator handles the full integer constant-expression
  operator set. A small conditional stack suppresses definitions in
  obvious inactive regions (`#if 0`, `#ifdef` of an undefined name);
  elaborate `#if` expressions are conservatively treated as active while
  the lexer still selects the correct branch.
- `#include "path"` searches the including file's directory, then `/`;
  `#include <name>` first accepts a built-in standard header (empty body), then
  searches NPAF at `/name` and in the including directory
- includes nest up to 16 levels, with a recursion guard that rejects a file
  that is already active; a missing include is `!C0090@<line>`, a depth
  overflow `!C0091`, and a recursive include `!C0092`
- conditional nesting up to 16 levels; inactive branches are skipped without
  tokenizing, including `#include` directives in dead branches
- line numbers are per file: an included file starts at line 1 and the
  including file's line count resumes after the directive

## Runtime library

Built-in functions (no headers needed):

```
printf(fmt, ...)   %d %i %u %o %x %X %c %s %p %f %e %E %g %G %%
                   flags '-' (left), '0' (zero pad), '#' (keep zeros),
                   '+'/' ', width/precision including '*' and '.*';
                   %x/%X digits; %ls for wide strings
vprintf/vfprintf/vsprintf/vsnprintf  va_list-based formatters
vscanf/vfscanf/vsscanf                va_list-based scanners
putchar(c)         getchar()          getc(f)        putc(c,f)
ungetc(c,f)        clearerr(f)       setvbuf(...)   fgetpos/fsetpos
freopen(p,m,f)     print_int(v)
puts(s)            print_str(s)
malloc(n)          calloc(n,size)     realloc(p,n)   free(p)
atexit(f)          _Exit(n)           abort()        setbuf(f,b)
atol(s)            atoll(s)           div/ldiv/lldiv
strtof(s,e)        strtold(s,e)       llabs(x)       strncat(d,s,n)
remquo(x,y,q)      mbsinit(p)         mbrlen(s,n,p)  mbrtowc(w,s,n,p)
wcrtomb(s,w,p)     mbsrtowcs(d,s,n,p) wcsrtombs(d,s,n,p)
imaxabs/imaxdiv    strtoimax/strtoumax  wcstoimax/wcstoumax
iswalnum..iswxdigit towlower/towupper   wctype/iswctype/wctrans/towctrans
errno/EDOM/ERANGE/EILSEQ  assert(e)     fwide(stream,mode)
setitimer/getitimer (ITIMER_REAL)
sin(x)             cos(x)
sqrt(x)            fabs(x)           pow(x,y)
exp(x)             log(x)            log10(x)
tanh(x)            tan(x)
floor(x)           ceil(x)           fmod(x,y)
fmin(x,y)          fmax(x,y)
exp2(x)            log2(x)          log1p(x)       expm1(x)
hypot(x,y)         cbrt(x)          sinh(x)        cosh(x)
asinh(x)           acosh(x)         atanh(x)       trunc(x)
round(x)           rint(x)          nearbyint(x)   copysign(x,y)
nan(s)             fdim(x,y)        fma(x,y,z)     modf(x,p)
ldexp(x,n)         scalbn(x,n)      remainder(x,y) atan(x)
frexp(x,p)         nextafter(x,y)   erf(x)         erfc(x)
tgamma(x)          lgamma(x)        signgam        iface_version()
atan2(y,x)         asin(x)          acos(x)
strchr(s,c)        strstr(s,t)       strdup(s)
isdigit(c)         isalpha(c)        isspace(c)
isupper(c)         islower(c)        toupper(c)       tolower(c)
rand()             srand(seed)       labs(x)          memmove(d,s,n)
strlen(s)          strcmp(a,b)        strncmp(a,b,n)
strcpy(d,s)        strncpy(d,s,n)      strcat(d,s)
memcpy(d,s,n)      memset(d,c,n)       memcmp(a,b,n)
atoi(s)            abs(n)             exit(code)
```

`malloc` is an S0 boundary-tag free-list allocator over
`C_HEAP..heap_ceiling`: 4-byte alignment, a header/footer word per block,
`next`/`prev` in the free payload, minimum 4 words, and coalescing with the
previous and next physical blocks on `free`. The heap starts with a 256 KiB
tail and grows on demand (`ni_heap_grow`) by extending toward the stack
guard, merging the new tail with a free block that already ends at the old
limit. `ncc_run` resets it. `realloc` always moves: it allocates, copies
`min(old,new)` bytes and frees the old block, so shrinking cannot leave a
stray split.

The ceiling is not a compile-time constant. At `ncc_run`, `ncc_mem_setup`
queries CPUID leaf `0x4E4D00FF` (0 = word mask, 1 = word count, 2 = flags
`0x4E160001`, 3 = payload bytes) and derives:

```text
payload_bytes = mem_words * 4
stack_size    = clamp(payload_bytes / 16, 1 MiB, 8 MiB)
C stack       = [payload_bytes - stack_size, payload_bytes)
C heap        = [8.1 MB, payload_bytes - stack_size)
```

The default portable VM is 32M words = 128 MiB payload, giving a 111.9 MB
heap and an 8 MiB C stack; a 16M-word VM falls back to the historical 15 MB
stack guard and a 6.9 MB heap. The word count is rounded to a power of two
and capped at 2^28 words (1 GiB payload), the flat-memory limit in
`spec/NANVM_SPEC.md`.

`tools/ncc_alloc.sh` runs 10,000 random malloc/free/realloc operations on a
128 MiB-payload VM and checks 4-byte alignment, overlap among live blocks,
full-pattern preservation across realloc, leak-free reuse (including a
single 100,000,000-byte allocation, then the same allocation again after
`free`), `calloc` zeroing/overflow and `realloc(NULL,n)`.
`tools/ncc_heap.sh` runs one C program on 16, 64, 128 and 512 MiB VMs: the
100 MB allocation fails cleanly on the small machines and succeeds, with
edge bytes intact and pointer reuse, on the large ones.

The C runtime buffers stay below the heap: IR at 4 MB, expression stack at
5.6 MB, interpreter stack at 6.4 MB, compiler tables at 7-8 MB. The C heap
begins at 8.1 MB. The host core allocates guest words on demand
(`mmap(MAP_NORESERVE)` on Linux/Android, `calloc` elsewhere), so a 256 MiB
word array does not commit resident memory until the guest touches it.

## Diagnostics and undefined behaviour

Compile errors print `!C<code>@<line>[<kind>:<value>:<hash>]` and halt the
compiler. There is no recovery and no multi-error reporting.

Defined behaviour: every operation on the integer/pointer subset above.
Undefined (not checked): out-of-bounds indexing, use of uninitialised
locals, signed overflow, invalid pointer arithmetic, division/modulo by zero
(the NaN16 `DIV`/`MOD` behaviour applies), and `realloc` of a non-malloc
pointer. There is no `-fsanitize` mode yet.

## Path filesystem and multi-file C

The runtime includes NPAF (`src/lib/nfs2.nas`), a path-addressed store with
64 entries and paths up to 31 bytes. The GUI terminal commands are:

```
ls                 list live paths and sizes
pwd                print /
cat PATH           print a file
cc PATH            compile and run a file (expands #include "PATH")
run PATH           alias for cc
write PATH         open the C editor and save to PATH with .save
edit PATH          load PATH into the editor
rm PATH            remove a file
mkdir PATH         create a directory entry
```

The C editor adds `.save` to write the buffer back to the current path.
`#include` is handled by the compiler itself (nested, guarded, relative paths);
the GUI `cc` command pre-flattens quoted includes from the store before
compiling, and `#include <stdio.h>` is accepted as an empty standard header
because the libc is built in.

The classic C donut is shipped as `/donut.c` (original sampling) and
`/donut_fast.c` (coarser sampling); `cc /donut_fast.c` renders a torus in the
terminal. Captures: `docs/donut_parity.png` (clang reference beside ncc on
NaN16) and `docs/donut_nan0s.png` (the torus in the GUI terminal).

## Gates

```
tools/ncc_lex.sh    lexer, 98 tokens exact
tools/ncc_m1.sh     expressions/variables/builtins, 11 lines exact
tools/ncc_m2.sh     control flow/functions/recursion, 5 lines exact
tools/ncc_m3.sh     pointers/arrays/strings/sizeof/casts, 12 lines exact
tools/ncc_m4.sh     byte types, structs/unions/enums/typedef/switch/goto, 11 lines
tools/ncc_m5.sh     preprocessor subset, 1 line
tools/ncc_m6.sh     libc + loop/operator extras, 10 lines
tools/ncc_m7.sh     block scope, aggregate initializers, struct assignment
tools/ncc_m8.sh     float literals/arithmetic/casts and sin/cos
tools/ncc_m9.sh     function pointers: globals/locals/assignment/indirect calls
tools/ncc_m10.sh    printf %f, precision, float width/flags
tools/ncc_m11.sh    struct/union pass-by-value and return-by-value
tools/ncc_m12.sh    user variadic functions (int/char/float/struct)
tools/ncc_m13.sh    nested aggregate initializers and brace elision
tools/ncc_m14.sh    bit-fields (masked values, signed, anonymous, initializers)
tools/ncc_m15.sh    math built-ins (sqrt/pow/exp/log/floor/ceil/fmod/...)
tools/ncc_m16.sh    string/ctype/stdlib built-ins
tools/ncc_m17.sh    sprintf/snprintf into guest buffers
tools/ncc_m18.sh    printf %e/%E
tools/ncc_m19.sh    _Bool/bool, inline/restrict
tools/ncc_m20.sh    function-like + variadic macros, #/##, nesting, #undef
tools/ncc_macro_text.sh  object replacement-text macros: types/storage,
                    nesting, blue paint, #undef/redefine, #if/defined
tools/ncc_m21.sh    printf %g/%G, # flag, float exponent literals
tools/ncc_m22.sh    time/locale/signal, struct tm/lconv, atof/strtod, limits
tools/ncc_m23.sh    stdio FILE streams over the path filesystem
tools/ncc_m24.sh    scanf/fscanf/sscanf conversions and widths
tools/ncc_m25.sh    64-bit long long: literals, arithmetic, casts, printf/scanf,
                    structs/arrays, varargs, function pointers, LL<->float
tools/ncc_m26.sh    qsort/bsearch callbacks (int, long long, strings),
                    setjmp/longjmp and deep-frame unwinding
tools/ncc_m27.sh    strftime, tmpnam/tmpfile, wide-string helpers
tools/ncc_m28.sh    const enforcement (locals/globals/params) and const pointers
tools/ncc_m29.sh    signal handlers delivered by raise()
tools/ncc_m30.sh    explicit function-returning-function-pointer prototypes/defs
tools/ncc_m40.sh    FP-returning definitions with parameters
tools/ncc_m41.sh    nested/mixed brace elision
tools/ncc_m42.sh    wprintf flags/width/precision
tools/ncc_m43.sh    wscanf (console input, %ls widening)
tools/ncc_m44.sh    packed bit-fields, sizeof, neighbors, arrays
tools/ncc_m45.sh    getchar/getc/putc/ungetc/clearerr/setvbuf
tools/ncc_m46.sh    persistent files over ATA (two boots, same disk)
tools/ncc_m47.sh    vprintf/vfprintf/vsprintf/vsnprintf, * width/precision
tools/ncc_m48.sh    wide-string and multibyte helpers
tools/ncc_m49.sh    additional math wrappers
tools/ncc_m50.sh    atan/atan2/asin/acos
tools/ncc_m51.sh    atexit ordering, exit(), _Exit()
tools/ncc_m52.sh    vscanf/vfscanf/vsscanf
tools/ncc_m53.sh    fgetpos/fsetpos/freopen
tools/ncc_m54.sh    frexp/nextafter
tools/ncc_m55.sh    wcstol/wcstoul/wcstoll/wcstoull/wcstod
tools/ncc_m56.sh    wcscoll/wcsxfrm
tools/ncc_m57.sh    erf/erfc
tools/ncc_m58.sh    tgamma/lgamma/signgam, interface version
tools/ncc_m59.sh    div/ldiv/lldiv aggregate returns
tools/ncc_m60.sh    setitimer/getitimer (SIGALRM delivery)
tools/ncc_m61.sh    strtof/strtold, llabs, strncat, remquo, restartable mbs
tools/ncc_m62.sh    inttypes, wide ctype, errno, assert, fwide
tools/ncc_alloc.sh  S0 free-list heap: 10,000 malloc/free/realloc operations
tools/ncc_headers.sh limits/stdint/float/stdio/locale/signal/math macros and fixed-width typedefs
tools/ncc_include.sh #include: quoted/nested/guarded headers, std headers, diagnostics
tools/ncc_heap.sh   one image on 16/64/128/512 MiB VMs (100 MB heap and reuse)
tools/ncc_iso_c.sh  C11 language (_Static_assert/_Alignof/_Alignas/_Generic/
                    _Noreturn/_Atomic/_Thread_local, compound/wide literals),
                    <uchar.h>, f/s/v wide stdio, <stdatomic.h>, <fenv.h>,
                    <threads.h>
tools/xmemgate.sh   native x86 E820 sizing and the 100 MB C heap
tools/ncc_ppexpr.sh #if/#elif arithmetic/bitwise/logical/defined/ternary expressions
tools/ncc_torture.sh differential C torture case (clang vs ncc)
tools/ncc_donut_exact.sh a1k0n donut first-frame parity
tools/qgate_gui.sh  x86 GUI + kernel ATA guest loader
tools/py_m1.sh      Python-subset interpreter (Py-M1) on NaN16
tools/bare_fs.sh    NPAF-backed bare fs_open/read/write/seek/close/rename/remove
tools/ncc_m31.sh    alarm()/SIGALRM asynchronous delivery
tools/ncc_m32.sh    C99 designated initializers (.member, [index], nested)
tools/ncc_m33.sh    brace elision across arrays of flat aggregates
tools/ncc_m34.sh    strspn/strcspn/strpbrk/strtok, getenv/system
tools/ncc_m35.sh    memchr/strcoll/strxfrm/strerror/perror
tools/ncc_m36.sh    [] array size inference from brace lists
tools/ncc_m37.sh    wprintf subset
tools/ncc_m38.sh    strtol/strtoul/strtoll/strtoull
tools/ncc_m39.sh    strchr/strrchr/strndup/stpcpy/memccpy
tools/ncc_donut.sh  original C donut (one frame) in raw NaN16
tools/nfs2.sh       path-addressed RAM filesystem API
tools/ncc_gui.sh    boot image, open terminal, .demo runs C in the vbuf
tools/ncc_editor.sh boot image, type a C program, .run compiles and runs it
tools/ncc_fs.sh     boot image, cc /useinc.c: path source + #include
tools/ncc_donut_gui.sh  boot image, cc /donut_fast.c: torus in the terminal
tools/mkproof.sh src/lib/ncc.nas   in-guest nasm0 reproduces every word
```

The GUI editor commands are `.run` (compile and run the buffer), `.demo`
(run the embedded example), `.clear`, and `.quit`. The first `e` puts the
focused terminal in C-entry mode; each Enter appends a line, so a program can
be typed one line at a time.
