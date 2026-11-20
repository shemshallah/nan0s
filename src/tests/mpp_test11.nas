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
.str "#define F(x) ((x)+1)\n#undef F\n#define G(a,b) ((a)+(b))\n#define H(a,b) \\\n ((a)+(b))\nint a=F(1); int x=G(1 /* , */, 2); int y=H(3,4);\n"
