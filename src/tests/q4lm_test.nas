; q4lm_test.nas - Q4 language-model inference skeleton.
; 64-token vocabulary, 64-wide embedding, one Q4 64x64 transition matrix.
; For each step: y = W * emb[token] (VDP4B4 Q4 GEMV), next = argmax(y).
; Weights and embeddings are deterministic synthetic values (LCG); the
; point is the exact inference path, not model quality.
;
; Weight layout is blocked for VDP4B4: [k=0..7][g=0..3][lane=0..15],
; each vector 64 bytes, so W byte = 0x20000 + k*64 + g*512.
; Embeddings: 64 tokens x 64 bytes at 0x24000.  Logits: 0x28000.
.org 0
JMP @main
main:
MOVI r13,1
MOVI r14,0x7000

; ---- W: 512 words, synthetic Q4 ----
MOVI r1,1
LA r2,1664525
LA r3,1013904223
LA r5,0x8000
MOVI r4,512
CALL @fill
; ---- EMB: 1024 words, 64 x 64 bytes ----
LA r5,0x9000
MOVI r4,1024
CALL @fill

; ---- 32 autoregressive steps ----
MOVI r12,0
MOVI r11,0
ST r11,r0,@pos
tokloop:
SHL r2,r12,6
LA r3,0x24000
ADD r2,r2,r3
LA r1,0x20000
LA r3,0x28000
CALL @q4gemv
; argmax over 64 signed logits
LA r9,0xA000
LD r4,r9,0
MOVI r5,0
ADDI r9,r9,1
MOVI r8,1
am:
LD r7,r9,0
CMPS r7,r4
JMP[LE] @amn
ADD r4,r7,r0
ADD r5,r8,r0
amn:
ADDI r9,r9,1
ADDI r8,r8,1
MOVI r7,64
CMP r8,r7
JMP[LT] @am
; append and continue
LD r10,r0,@pos
LA r9,0xA100
ADD r9,r9,r10
ST r5,r9,0
ADD r12,r5,r0
ADDI r10,r10,1
ST r10,r0,@pos
MOVI r7,32
CMP r10,r7
JMP[LT] @tokloop

; ---- print the generated token string ----
LA r9,0xA100
MOVI r8,0
pr:
LD r1,r9,0
LA r2,@alpha
SHL r2,r2,2
ADD r2,r2,r1
LDB r3,r2,0
PUTC r3
ADDI r9,r9,1
ADDI r8,r8,1
MOVI r7,32
CMP r8,r7
JMP[LT] @pr
MOVI r3,10
PUTC r3
LA r1,@s_pass
CALL @puts
HALT

; ---- LCG fill: r1=state r2=mul r3=inc r4=count r5=dest ----
fill:
MUL r1,r1,r2
ADD r1,r1,r3
ST r1,r5,0
ADDI r5,r5,1
SUB r4,r4,r13
CMP r4,r0
JMP[NE] @fill
RET

; ---- Q4 GEMV: r1=W byte, r2=act byte, r3=out byte ----
q4gemv:
VZERO r0
VZERO r1
VZERO r2
VZERO r3
SHR r6,r2,2          ; LD uses word addresses; VLOAD uses byte addresses
ADD r7,r1,r0
MOVI r8,8
qk:
LD r9,r6,0
LD r10,r6,1
ADDI r6,r6,2
VBCAST r4,r9
VBCAST r5,r10
ADD r11,r7,r0
VLOAD r6,r11
VDP4B4 r7,r6,r4
VADD32 r0,r0,r7
ADDI r11,r11,512
VLOAD r6,r11
VDP4B4 r7,r6,r4
VADD32 r1,r1,r7
ADDI r11,r11,512
VLOAD r6,r11
VDP4B4 r7,r6,r4
VADD32 r2,r2,r7
ADDI r11,r11,512
VLOAD r6,r11
VDP4B4 r7,r6,r4
VADD32 r3,r3,r7
ADDI r7,r7,64
SUB r8,r8,r13
CMP r8,r0
JMP[NE] @qk
VSTORE r0,r3
ADDI r3,r3,64
VSTORE r1,r3
ADDI r3,r3,64
VSTORE r2,r3
ADDI r3,r3,64
VSTORE r3,r3
RET

puts:
SHL r1,r1,2
pl:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @pd
PUTC r2
ADDI r1,r1,1
JMP @pl
pd:
RET

alpha:
.str "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!?"
pos:
.word 0
s_pass:
.str "Q4LM PASS\n"
