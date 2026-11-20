; ncc M3 gate: arrays, pointers, indexing, &/*, sizeof, char strings.
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
.str "int ga[5] = {1,2,3,4,5};\nint sum(int *v, int n) {\n  int s = 0;\n  for (int i = 0; i < n; i++) s += v[i];\n  return s;\n}\nint main(void) {\n  int a[4] = {10,20,30,40};\n  int x = 7;\n  int *p;\n  p = &x;\n  print_int(*p); putchar(10);\n  *p = 9;\n  print_int(x); putchar(10);\n  p = a;\n  print_int(p[2]); putchar(10);\n  p[2] = 99;\n  print_int(a[2]); putchar(10);\n  print_int(sum(a, 4)); putchar(10);\n  print_int(sum(ga, 5)); putchar(10);\n  print_int(sizeof(int)); putchar(10);\n  print_int(sizeof(a)); putchar(32); print_int(sizeof(ga)); putchar(10);\n  char *s = \"hello\";\n  print_int(s[1]); putchar(10);\n  puts(s);\n  print_int(*(p + 3)); putchar(10);\n  int i = 0;\n  while (i < 4) { print_int(a[i]); putchar(32); i++; }\n  putchar(10);\n  return 0;\n}\n"
