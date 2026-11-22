;
; ncc object-like replacement-text macro gate.  Covers type/storage macros,
; expression macros, recursive object macros, self/mutual reference, later
; definitions, #undef/redefine, object+function composition, # and ##,
; empty replacement, multi-line continuations, no expansion in literals or
; comments, and #if/defined after text macro expansion.
.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r1,@c_src
CALL @ncc_compile
CALL @ncc_run
HALT
c_src:
.str "#define PRIVATE static\n#define API\n#define UINT unsigned int\n#define ONE 1\n#define TWO (ONE+ONE)\n#define FOUR (TWO*TWO)\n#define EMPTY\n#define SELF SELF\n#define ALPHA BETA\n#define BETA ALPHA\n#define GREETING \"PRIVATE ONE\"\n#define N 7\n#undef N\n#define N 9\n#define SQ(x) ((x)*(x))\n#define STR(x) #x\n#define CAT(a,b) a##b\n#define WRAP(x) SQ(x)\n#define MULTI(a,b) \\\n  ((a) + \\\n   (b))\n#define LONG_EXPR (10 + \\\n                   20)\n#define WITHCOMMENT 3 /* N ONE */ + 4\nPRIVATE int LATE = 42;\nPRIVATE API UINT g1 = FOUR;\nPRIVATE int SELF = 5;\nPRIVATE int ALPHA = 6;\nint EMPTY CAT(my,var) = 3;\nint before = LATE;\n#define LATE 99\nint after = LATE;\n#undef LATE\n#define TEMP 77\n#undef TEMP\nint TEMP = 8;\nint temp_use = TEMP;\nint main(void) {\n  char *s = GREETING;\n  char c = 'N'; /* N ONE must stay a comment */\n  char *q = \"ONE N PRIVATE\";\n  print_int(g1); putchar(10);\n  print_int(SELF); putchar(10);\n  print_int(ALPHA); putchar(10);\n  print_int(myvar); putchar(10);\n  print_int(N); putchar(10);\n  print_int(SQ(N)); putchar(10);\n  print_int(WRAP(2+3)); putchar(10);\n  print_int(MULTI(2,3)); putchar(10);\n  print_int(ONE); putchar(10);\n  print_int(LONG_EXPR); putchar(10);\n  print_int(WITHCOMMENT); putchar(10);\n  print_int(before); putchar(10);\n  print_int(after); putchar(10);\n  print_int(TEMP); putchar(10);\n  print_int(temp_use); putchar(10);\n  puts(STR(hi there));\n  puts(s);\n  puts(q);\n  putchar(c); putchar(10);\n#if N == 9\n  puts(\"if-ok\");\n#else\n  puts(\"if-bad\");\n#endif\n#if defined(N) && defined(PRIVATE) && !defined(MISSING)\n  puts(\"def-ok\");\n#else\n  puts(\"def-bad\");\n#endif\n  return 0;\n}\n"
