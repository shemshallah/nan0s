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
.str "#define N 10\n#define M 3\n#define Q 0\n#include <stdio.h>\n#undef Q\n#ifdef Q\nint bad = 1;\n#else\nint y = 2;\n#endif\n#ifndef Q\nint z = 3;\n#endif\n#if 0\nint worse = 9;\n#endif\n#if 1\nint good = 4;\n#endif\n#if defined(N)\nint ok = 5;\n#endif\nint main(void){ printf(\"%d %d %d %d %d\\n\", y, z, good, ok, N*M); return 0; }\n"
