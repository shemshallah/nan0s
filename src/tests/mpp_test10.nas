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
.str "#define ADD(a,b) ((a)+(b))\n#define TWICE(x) ADD(x,x)\n#define STR(x) #x\n#define CAT(a,b) a##b\n#define NOP() 7\nint a=TWICE(3); char*s=STR(hi there); int CAT(fo,o)=NOP();\n"
