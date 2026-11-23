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
.str "#include <stdio.h>\n#include <stddef.h>\nstruct S { char c; long long x; };\nlong long addll(long long a, long long b){ return a + b; }\nint main(void){\n  struct S s; s.c = 7; s.x = 0x123456789ABCDEF0LL;\n  printf(\"%d %d %d\\n\", (int)sizeof(struct S), (int)((char *)&s.x-(char *)&s), (int)s.c);\n  printf(\"%llx\\n\", (unsigned long long)s.x);\n  printf(\"%lld\\n\", addll(5000000000LL, -3LL));\n  printf(\"%d %d\\n\", (int)((char*)&s.x - (char*)&s), (int)sizeof(long long));\n  return 0;\n}\n"
