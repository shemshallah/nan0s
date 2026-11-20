.org 0
JMP @main
.include "../lib/mpp.nas"
main:
MOVI r13,1
LA r1,@src
SHL r1,r1,2
CALL @mp_has_func
ADDI r1,r1,48
PUTC r1
MOVI r1,10
PUTC r1
LA r1,@src
CALL @mp_preprocess
ST r1,r0,@outp
LA r2,@src
CMP r1,r2
JMP[EQ] @same
MOVI r1,88
PUTC r1
JMP @show
same:
MOVI r1,83
PUTC r1
show:
MOVI r1,58
PUTC r1
LD r1,r0,@outp
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
outp:
.word 0
src:
.str "#define ADD(a,b) ((a)+(b))\nint main(void){ return 0; }\n"
