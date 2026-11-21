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
The remaining documented limitations are platform or optional-scope items:

- the C locale is the only locale (the ISO C minimum);
- x86 BIOS boot media is capped at 1.44 MB by the floppy format;
- the POSIX-free machine-interface table is implemented in
  `src/lib/bare.nas`; console and block adapters are wired, filesystem slots
  are still adapter stubs (see `spec/BARE_METAL_INTERFACES.md`);
- the library is the practical subset documented below (`tgamma`/`lgamma`,
  `div`/`ldiv` struct returns, and some POSIX extensions are still outside
  it).

None of these blocks the Python port; they are deployment or optional-library
work.

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
- `#include <...>` system headers are skipped; the libc and standard types are
  built in
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
- signal handlers are installed and delivered by `raise`; `alarm()` performs
  asynchronous `SIGALRM` delivery at IR-instruction boundaries. POSIX timers
  (`setitimer`) are not implemented
- the path filesystem is RAM-backed by default. When an ATA primary-master
  disk is attached, NPAF snapshots to LBA 2048 after each write/delete and
  reloads the snapshot at startup; without a disk it still resets on reboot.
  The POSIX-free machine interface remains planned; see
  `spec/BARE_METAL_INTERFACES.md`
- x86 BIOS boot images remain capped at 1.44 MB (Android/NaN0S images are
  arbitrary size). This is a boot-media limit, not a C language gap

## Preprocessor subset

Lexer-integrated, line based:

- `#define NAME integer` (object-like, integer replacement)
- `#undef NAME`
- `#ifdef`, `#ifndef`, `#if 0|1|defined(NAME)`, `#elif`, `#else`, `#endif`
- `#include "path"` is expanded from the runtime path filesystem (nested
  includes up to 8 levels); `#include <...>` is skipped
- nesting up to 16 levels; inactive branches are skipped without tokenizing

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
atol(s)            atoll(s)
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

`malloc` uses a 4-byte size header in the C heap and 4-byte alignment.
`realloc` copies `min(old,new)` bytes. `free` is a no-op (bump allocator).

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
`#include "path"` is flattened recursively from the same store before the
compiler runs; `#include <stdio.h>` remains a no-op because the libc is
built in.

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
