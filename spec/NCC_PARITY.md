# ncc: C on NaN16 — parity status

`src/lib/ncc.nas` is a C front end and interpreter written entirely in raw
NaN16. It is usable from the GUI terminal: press `e`, type C lines, then
`.run` (or `.demo` for the built-in example). The compiler, the runtime, and
the editor are guest NaN16 code; there is no host C/Python/JS in the execution
path.

## Memory model

C memory is byte-addressed on top of the 32-bit NaN word:

| type | size | alignment |
| --- | ---: | ---: |
| `char`, `signed char`, `unsigned char` | 1 | 1 |
| `short`, `unsigned short` | 2 | 2 |
| `int`, `unsigned int` | 4 | 4 |
| `long`, `unsigned long` | 4 | 4 |
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
- global and local arrays, multidimensions, pointer arithmetic/indexing
- `char`/`short`/`int`/`long`, signed and unsigned, `sizeof` in bytes
- string and character literals with escapes (`\n`, `\t`, `\xNN`, octal)
- sized `char` arrays with string-literal initializers
- `struct`/`union` with `.` and `->`, arrays of structs, alignment/padding
- struct/union assignment as a byte copy of the object
- aggregate brace initializers for structs and unions (flat member lists;
  unions initialise the first member)
- `enum` constants in expressions and `case` labels
- `typedef`
- `switch`/`case`/`default` with fallthrough, `goto`/labels
- block scope with shadowing (locals and typedefs; labels stay function-wide)
- casts, including pointer target casts and `sizeof(int *)`

Not implemented (honest list):

- function-like macros, `#`/`##`, recursive macro expansion
- `#include "file"` (directive lines are skipped; libc is built in)
- struct/union pass-by-value, return-by-value, comparison
- nested aggregate initializers, brace initializers for array members inside
  a struct or union, and unsized `char s[] = "..."` (declare a size)
- bit-fields, `const`/`volatile` semantics, `register` semantics
- user variadic functions; `printf` is a built-in variadic function
- floating-point printing (`%f`); float arithmetic exists in the IR but is
  not exposed through `printf`
- `printf` precision (`%.3s`, `%.2d`)
- `cc FILE`: there is no path-based filesystem API in the raw NaN16 runtime,
  so source entry is the terminal editor (a NaNFS block reader could be wired
  later)

## Preprocessor subset

Lexer-integrated, line based:

- `#define NAME integer` (object-like, integer replacement)
- `#undef NAME`
- `#ifdef`, `#ifndef`, `#if 0|1|defined(NAME)`, `#elif`, `#else`, `#endif`
- `#include` is skipped
- nesting up to 16 levels; inactive branches are skipped without tokenizing

## Runtime library

Built-in functions (no headers needed):

```
printf(fmt, ...)   %d %i %u %x %X %c %s %p %%
                   flags '-' (left) and '0' (zero pad), decimal field width
                   (%05d, %-6s, %04x); %x/%X significant digits
putchar(c)         print_int(v)      puts(s)        print_str(s)
malloc(n)          calloc(n,size)     realloc(p,n)   free(p)
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
tools/ncc_gui.sh    boot image, open terminal, .demo runs C in the vbuf
tools/ncc_editor.sh boot image, type a C program, .run compiles and runs it
tools/mkproof.sh src/lib/ncc.nas   in-guest nasm0 reproduces every word
```

The GUI editor commands are `.run` (compile and run the buffer), `.demo`
(run the embedded example), `.clear`, and `.quit`. The first `e` puts the
focused terminal in C-entry mode; each Enter appends a line, so a program can
be typed one line at a time.
