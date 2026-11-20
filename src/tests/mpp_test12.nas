.org 0
JMP @main
.include "../lib/mpp.nas"
main:
MOVI r13,1
LA r1,@src
CALL @mp_preprocess
SHL r2,r1,2
prt:
LDB r4,r2,0
CMP r4,r0
JMP[EQ] @done
PUTC r4
ADD r2,r2,r13
JMP @prt
done:
MOVI r1,10
PUTC r1
HALT
src:
.str "#define V(...) f(__VA_ARGS__)\n#define W(fmt, ...) g(fmt, ##__VA_ARGS__)\nint a=V(11,22,33,44); int b=V(); int c=W(9); int d=W(1,2,3);\n"
