; s1_guest_test.nas - flat-cartridge acceptance for the x86_64 NaN16 S1.
; Exercises: r0=0/r13=1 reset, MOVI/MOVHI/LA, ADD/SUB/MUL/ADDI, SHL/SHR,
; CMP+branch, LD/ST, LDB/STB byte addressing, CALL/RET, CALLR, JMPR,
; BCOPY, BFILL, PUTC and HALT.  Prints exactly one line on COM1.
.org 0
JMP @main
main:
MOVI r13,1
CMP r0,r0
JMP[NE] @fail

; 7+5=12, 12-5=7, 7*5=35, +1=36
MOVI r1,7
MOVI r2,5
ADD r3,r1,r2
MOVI r4,12
CMP r3,r4
JMP[NE] @fail
SUB r3,r4,r2
MOVI r5,7
CMP r3,r5
JMP[NE] @fail
MUL r3,r1,r2
MOVI r4,35
CMP r3,r4
JMP[NE] @fail
ADDI r3,r3,1
MOVI r4,36
CMP r3,r4
JMP[NE] @fail

; MOVHI and LA produce the same 32-bit constant
MOVI r1,0x1234
MOVHI r1,0xABCD
LA r2,0xABCD1234
CMP r1,r2
JMP[NE] @fail

; shifts: (0xABCD1234 << 4) >> 4 returns the lower 28 bits
SHL r3,r1,4
SHR r3,r3,4
LA r4,0xBCD1234
CMP r3,r4
JMP[NE] @fail

; byte store/load at byte address 0x800 = word 0x200 lane 0
MOVI r1,0x800
MOVI r2,0x5A
STB r2,r1,0
LDB r3,r1,0
CMP r3,r2
JMP[NE] @fail

; CALL/RET
MOVI r1,10
CALL @add5
MOVI r2,15
CMP r1,r2
JMP[NE] @fail

; CALLR/RET
LA r6,@add5
MOVI r1,20
CALLR r6
MOVI r2,25
CMP r1,r2
JMP[NE] @fail

; JMPR skips the failure path
LA r6,@after_jmpr
JMPR r6
JMP @fail
after_jmpr:

; BCOPY four words 0x300..0x303 -> 0x310..0x313
MOVI r1,0x300
MOVI r2,0x111
ST r2,r1,0
ADDI r1,r1,1
MOVI r2,0x222
ST r2,r1,0
ADDI r1,r1,1
MOVI r2,0x333
ST r2,r1,0
ADDI r1,r1,1
MOVI r2,0x444
ST r2,r1,0
MOVI r1,0x300
MOVI r3,0x310
MOVI r2,4
BCOPY r3,r1,r2
LD r4,r3,0
MOVI r5,0x111
CMP r4,r5
JMP[NE] @fail
ADDI r3,r3,1
LD r4,r3,0
MOVI r5,0x222
CMP r4,r5
JMP[NE] @fail

; BFILL two words at 0x320 with payload 0x99
MOVI r1,0x99
MOVI r3,0x320
MOVI r2,2
BFILL r3,r1,r2
LD r4,r3,0
CMP r4,r1
JMP[NE] @fail
ADDI r3,r3,1
LD r4,r3,0
CMP r4,r1
JMP[NE] @fail

; string on COM1 (bytes, not words)
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
JMP[EQ] @fail_done
PUTC r2
ADD r1,r1,r13
JMP @print_fail_loop
fail_done:
MOVI r1,1
HALT

add5:
ADDI r1,r1,5
RET

msg:
.str "S1GUEST PASS\n"
bad:
.str "S1GUEST FAIL\n"
