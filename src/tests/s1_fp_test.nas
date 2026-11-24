; s1_fp_test.nas - scalar FP/NaN16 opcode smoke for the x86_64 S1.
.org 0
JMP @main
main:
MOVI r13,1

; 1.5 + 2.25 = 3.75 -> CVTFI 3
LA r1,0x3FC00000
LA r2,0x40100000
FADD r3,r1,r2
CVTFI r4,r3
MOVI r5,3
CMP r4,r5
JMP[NE] @fail

; 1.5 * 2.0 = 3.0 -> CVTFI 3
LA r2,0x40000000
FMUL r3,r1,r2
CVTFI r4,r3
CMP r4,r5
JMP[NE] @fail

; sqrt(9.0) = 3.0 -> CVTFI 3
LA r1,0x41100000
FSQRT r3,r1
CVTFI r4,r3
CMP r4,r5
JMP[NE] @fail

; FEXP(0) = 1 -> CVTFI 1
MOVI r1,0
FEXP r3,r1
CVTFI r4,r3
MOVI r5,1
CMP r4,r5
JMP[NE] @fail

; FLOG(1) = 0 -> CVTFI 0
LA r1,0x3F800000
FLOG r3,r1
CVTFI r4,r3
CMP r4,r0
JMP[NE] @fail

; FTANH(0) = 0 -> CVTFI 0
MOVI r1,0
FTANH r3,r1
CVTFI r4,r3
CMP r4,r0
JMP[NE] @fail

; FCMP 1.5 < 2.25 -> LT predicate
LA r1,0x3FC00000
LA r2,0x40100000
FCMP r1,r2
JMP[LT] @cmp_ok
JMP @fail
cmp_ok:

LA r1,@msg
SHL r1,r1,2
print_loop:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @done
PUTC r2
ADD r1,r1,r13
JMP @print_loop
done:
MOVI r1,0
HALT

fail:
LA r1,@bad
SHL r1,r1,2
print_fail_loop:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @faildone
PUTC r2
ADD r1,r1,r13
JMP @print_fail_loop
faildone:
MOVI r1,1
HALT

msg:
.str "FP PASS\n"
bad:
.str "FP FAIL\n"
