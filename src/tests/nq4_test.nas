; nq4_test.nas - exact packed Q4_0/Q8_0 dequant, dot and GEMV (F6).
;
; Q4_0 block A: scale 0.5, only q[0]=1 and q[16]=-1; all others 0.
;   dequant q0=0.5 (0x3F000000), q16=-0.5 (0xBF000000).
;   acts[0]=1, acts[16]=2 -> dot = 0.5 + (-1.0) = -0.5 (0xBF000000).
; Q4_0 block B: scale 1.0, q[31]=7 -> with acts[31]=4 dot = 28.0
;   (0x41E00000).
; Q8_0 block A: scale 0.25, q[0]=3, q[31]=-2 -> dot
;   0.75 + (-2.0) = -1.25 (0xBFA00000).
; Q8_0 block B: scale 1.0, q[0]=-128 -> dot = -128.0 (0xC3000000).
; GEMV over the two blocks emits the same two values per format.
.org 0
JMP @main
.include "../lib/nq4.nas"

main:
MOVI r13,1
MOVI r14,0x7000

; dequant lanes
MOVI r1,49
CALL @mark
LA r1,@q4a
MOVI r2,0
CALL @nq4_dequant
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LA r1,@q4a
MOVI r2,16
CALL @nq4_dequant
LA r2,0xBF000000
CMP r1,r2
JMP[NE] @fail
LA r1,@q4a
MOVI r2,15
CALL @nq4_dequant
CMP r1,r0
JMP[NE] @fail
LA r1,@q4a
MOVI r2,31
CALL @nq4_dequant
CMP r1,r0
JMP[NE] @fail
LA r1,@q8a
MOVI r2,0
CALL @nq8_dequant
LA r2,0x3F400000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8a
MOVI r2,31
CALL @nq8_dequant
LA r2,0xBF000000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8b
MOVI r2,0
CALL @nq8_dequant
LA r2,0xC3000000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8b
MOVI r2,31
CALL @nq8_dequant
CMP r1,r0
JMP[NE] @fail

; 32-element dots
MOVI r1,50
CALL @mark
LA r1,@q4a
LA r2,@acts
CALL @nq4_dot32
LA r5,@dotdbg
ST r1,r5,0
LA r2,0xBF000000
CMP r1,r2
JMP[NE] @fail
LA r1,@q4b
LA r2,@acts
CALL @nq4_dot32
LA r5,@dotdbg
ST r1,r5,1
LA r2,0x41E00000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8a
LA r2,@acts
CALL @nq8_dot32
LA r5,@dotdbg
ST r1,r5,2
LA r2,0xBFA00000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8b
LA r2,@acts
CALL @nq8_dot32
LA r5,@dotdbg
ST r1,r5,3
LA r2,0xC3000000
CMP r1,r2
JMP[NE] @fail

; 2-row GEMV
MOVI r1,51
CALL @mark
LA r1,@q4a
MOVI r2,2
LA r3,@acts
LA r4,@out
CALL @nq4_gemv
CMP r1,r0
JMP[NE] @fail
LA r5,@out
LD r1,r5,0
LA r2,0xBF000000
CMP r1,r2
JMP[NE] @fail
LD r1,r5,1
LA r2,0x41E00000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8a
MOVI r2,2
LA r3,@acts
LA r4,@out
CALL @nq8_gemv
CMP r1,r0
JMP[NE] @fail
LA r5,@out
LD r1,r5,0
LA r2,0xBFA00000
CMP r1,r2
JMP[NE] @fail
LD r1,r5,1
LA r2,0xC3000000
CMP r1,r2
JMP[NE] @fail

MOVI r1,79
PUTC r1
HALT

fail:
LA r2,@stage
LD r1,r2,0
PUTC r1
MOVI r1,70
PUTC r1
HALT

mark:
LA r2,@stage
ST r1,r2,0
RET

.org 0x9000
q4a:
.word 0x3F000000, 0x88888879, 0x88888888, 0x88888888, 0x88888888
q4b:
.word 0x3F800000, 0x88888888, 0x88888888, 0x88888888, 0xF8888888
q8a:
.word 0x3E800000, 0x00000003, 0,0,0,0,0,0, 0xFE000000
q8b:
.word 0x3F800000, 0x00000080, 0,0,0,0,0,0, 0
acts:
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x40000000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x40800000
out:
.word 0,0
stage:
.word 0
dotdbg:
.word 0,0,0,0
