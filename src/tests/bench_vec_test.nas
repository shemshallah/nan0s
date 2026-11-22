; bench_vec_test.nas - packed-i8 MAC throughput, VDP4B vs DP4B.
; Each loop does 1,000,000 iterations.  VDP4B accumulates 16 lanes of
; 4-byte dots (64 MACs/iteration); DP4B does one 4-byte dot (4 MACs).
; Both loops have the same instruction shape, so the comparison isolates
; MACs per dispatched instruction.  TICK is the guest millisecond clock.
.org 0
JMP @main
main:
MOVI r13,1
MOVI r14,0x7000

; ---- VDP4B: 64 MACs/instruction ----
LA r1,0x01010101
VBCAST r1,r1
VBCAST r2,r1
LA r1,0x02020202
VBCAST r3,r1
VZERO r0
TICK r8
LA r10,1000000
vloop:
VDP4B r4,r2,r3
VADD32 r0,r0,r4
SUB r10,r10,r13
CMP r10,r0
JMP[NE] @vloop
TICK r9
SUB r9,r9,r8
MOVI r6,86
PUTC r6
ADD r3,r9,r0
CALL @ph32
VGET r3,r0,0
CALL @ph32
MOVI r6,10
PUTC r6

; ---- DP4B: 4 MACs/instruction ----
LA r1,0x01010101
LA r2,0x02020202
MOVI r5,0
TICK r8
LA r10,1000000
dloop:
DP4B r4,r1,r2
ADD r5,r5,r4
SUB r10,r10,r13
CMP r10,r0
JMP[NE] @dloop
TICK r9
SUB r9,r9,r8
MOVI r6,68
PUTC r6
ST r5,r0,@dsum
ADD r3,r9,r0
CALL @ph32
LD r3,r0,@dsum
CALL @ph32
MOVI r6,10
PUTC r6
HALT

; r3 -> exactly 8 uppercase hex digits + no newline
ph32:
MOVI r9,8
ph1:
SHR r5,r3,28
SHL r3,r3,4
MOVI r6,10
CMP r5,r6
MOVI r7,48
MOVI[GE] r7,55
ADD r7,r7,r5
PUTC r7
SUB r9,r9,r13
CMP r9,r0
JMP[NE] @ph1
RET

dsum:
.word 0
