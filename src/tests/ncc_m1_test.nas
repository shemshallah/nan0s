; ncc M1 gate: expressions, globals, locals, assignment, print builtins.
; Compiler + IR interpreter are raw NaN16 (src/lib/ncc.nas).
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
.str "int g;\nint h = 7;\nint main(void) {\n  int a = 3;\n  int b;\n  char c = 'A';\n  g = a + h;\n  b = g * 2 - 5;\n  putchar(c); putchar(10);\n  print_int(g); putchar(32); print_int(b); putchar(10);\n  a += 4; b = a;\n  print_int(a); putchar(32); print_int(b); putchar(10);\n  print_int(a > b ? 100 : 200); putchar(10);\n  print_int((a == 7) && (b == 7)); putchar(10);\n  print_int(!a); putchar(10);\n  print_int(~0); putchar(10);\n  print_int(1 << 5); putchar(10);\n  print_int(100 / 7); putchar(32); print_int(100 % 7); putchar(10);\n  print_hex(0xDEADBEEF); putchar(10);\n  puts(\"hello\");\n  return 0;\n}\n"
