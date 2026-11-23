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
.str "#include <stdio.h>\n#include <stddef.h>\n#include <stdint.h>\nstruct A { char c; double d; };\nstruct B { char c; void *p; };\nstruct C { char c; long long x; };\nint main(void){\n  printf(\"%d %d %d %d %d %d %d %d\\n\", (int)sizeof(char), (int)sizeof(short), (int)sizeof(int), (int)sizeof(long), (int)sizeof(long long), (int)sizeof(float), (int)sizeof(double), (int)sizeof(long double));\n  printf(\"%d %d %d %d %d\\n\", (int)sizeof(void*), (int)sizeof(size_t), (int)sizeof(ptrdiff_t), (int)sizeof(intptr_t), (int)sizeof(intmax_t));\n  printf(\"%d %d %d %d %d %d %d %d %d\\n\", (int)_Alignof(char), (int)_Alignof(short), (int)_Alignof(int), (int)_Alignof(long), (int)_Alignof(long long), (int)_Alignof(float), (int)_Alignof(double), (int)_Alignof(long double), (int)_Alignof(void*));\n  printf(\"%d %d %d %d %d %d\\n\", (int)sizeof(struct A), (int)_Alignof(struct A), (int)sizeof(struct B), (int)_Alignof(struct B), (int)sizeof(struct C), (int)_Alignof(struct C));\n  return 0;\n}\n"
