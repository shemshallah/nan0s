; ncc M2 gate: control flow, functions, parameters, recursion.
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
.str "int fib(int n) {\n  if (n < 2) return n;\n  return fib(n - 1) + fib(n - 2);\n}\nint fact(int n) {\n  int r = 1;\n  while (n > 1) { r = r * n; n = n - 1; }\n  return r;\n}\nint sum_to(int n) {\n  int s = 0;\n  for (int i = 1; i <= n; i = i + 1) s += i;\n  return s;\n}\nint main(void) {\n  print_int(fib(10)); putchar(10);\n  print_int(fact(5)); putchar(10);\n  print_int(sum_to(10)); putchar(10);\n  int i = 0, s = 0;\n  while (i < 10) { i++; if (i == 5) continue; if (i == 8) break; s += i; }\n  print_int(s); putchar(10);\n  int j = 0;\n  do { j += 2; } while (j < 7);\n  print_int(j); putchar(10);\n  return fib(10);\n}\n"
