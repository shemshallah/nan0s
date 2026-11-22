; xlate_x86_test.nas - NaN-native translator -> x86 -> EXECN.
; Block A: MOVI/ADD/MOVI/SUB must leave r1=80.
; Block B: CMP 10,3 + JMP[GT] 0x1100 must take the branch.
; Block C: CMP 3,10 + JMP[GT] 0x1200 must fall through to MOVI r1,77.
.org 0
JMP @main
.include "../translate/block.nas"

.org 0x1000
main:
MOVI r13,1
MOVI r14,0x7000

; ---- block A: ALU chain ----
LA r1,@srcA
MOVI r2,4
LA r3,0x10000
LA r4,@afterA
CALL @xt_block_x86
CMP r1,r0
JMP[EQ] @fail
CODELEN r1
LA r2,0x10000
EXECN r2
afterA:
MOVI r5,80
CMP r1,r5
JMP[NE] @fail

; ---- block D: memory + shifts + MOVHI/ADDI ----
LA r1,@srcD
MOVI r2,16
LA r3,0x10000
LA r4,@afterD
CALL @xt_block_x86
CMP r1,r0
JMP[EQ] @fail
CODELEN r1
LA r2,0x10000
EXECN r2
afterD:
MOVI r5,0x5678
CMP r2,r5
JMP[NE] @fail
CMP r3,r5
JMP[NE] @fail
MOVI r5,0x5679
CMP r7,r5
JMP[NE] @fail
MOVI r5,0x78
CMP r8,r5
JMP[NE] @fail
MOVI r5,0x7978
CMP r9,r5
JMP[NE] @fail
LA r5,0x00010003
CMP r10,r5
JMP[NE] @fail

; ---- block B: conditional branch taken ----
LA r1,@srcB
MOVI r2,5
LA r3,0x10000
LA r4,@afterB
CALL @xt_block_x86
CMP r1,r0
JMP[EQ] @fail
CODELEN r1
LA r2,0x10000
EXECN r2
afterB:
HALT

.org 0x1100
takenB:
MOVI r5,10
CMP r1,r5
JMP[NE] @fail
MOVI r6,3
CMP r2,r6
JMP[NE] @fail

; ---- block C: conditional branch not taken ----
LA r1,@srcC
MOVI r2,4
LA r3,0x10000
LA r4,@afterC
CALL @xt_block_x86
CMP r1,r0
JMP[EQ] @fail
CODELEN r1
LA r2,0x10000
EXECN r2
JMP @fail

.org 0x1200
notTakenC:
JMP @fail

.org 0x1400
takenE:
LA r5,0xFFFFFFFF
CMP r1,r5
JMP[NE] @fail
MOVI r5,1
CMP r2,r5
JMP[NE] @fail
JMP @pass

fail:
LA r1,@s_fail
CALL @puts
HALT
pass:
LA r1,@s_pass
CALL @puts
HALT
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

srcA:
.raw FFF8_0110002A_F8FF      ; MOVI r1,42
.raw FFF8_03110001_F8FF      ; ADD r1,r1,r1
.raw FFF8_01200004_F8FF      ; MOVI r2,4
.raw FFF8_04110002_F8FF      ; SUB r1,r1,r2

srcB:
.raw FFF8_0110000A_F8FF      ; MOVI r1,10
.raw FFF8_01200003_F8FF      ; MOVI r2,3
.raw FFF8_07010002_F8FF      ; CMP r1,r2
.raw 7FF1_0A001100_F1FF      ; JMP[GT] 0x1100
.raw FFF8_01100063_F8FF      ; MOVI r1,99 (must not run)

srcD:
.raw FFF8_01103000_F8FF      ; MOVI r1,0x3000
.raw FFF8_01205678_F8FF      ; MOVI r2,0x5678
.raw FFF8_09210000_F8FF      ; ST r2,r1,0
.raw FFF8_08310000_F8FF      ; LD r3,r1,0
.raw FFF8_07030002_F8FF      ; CMP r3,r2
.raw FFF8_29430001_F8FF      ; ADDI r4,r3,1
.raw FFF8_05540004_F8FF      ; SHL r5,r4,4
.raw FFF8_06650002_F8FF      ; SHR r6,r5,2
.raw FFF8_06760002_F8FF      ; SHR r7,r6,2
.raw FFF8_01B0C000_F8FF      ; MOVI r11,0xC000 (byte address of word 0x3000)
.raw FFF8_2A8B0000_F8FF      ; LDB r8,r11,0
.raw FFF8_2B4B0001_F8FF      ; STB r4,r11,1
.raw FFF8_08910000_F8FF      ; LD r9,r1,0
.raw FFF8_01A00002_F8FF      ; MOVI r10,2
.raw FFF8_02A00001_F8FF      ; MOVHI r10,1
.raw FFF8_29AA0001_F8FF      ; ADDI r10,r10,1

srcC:
.raw FFF8_01100003_F8FF      ; MOVI r1,3
.raw FFF8_0120000A_F8FF      ; MOVI r2,10
.raw FFF8_07010002_F8FF      ; CMP r1,r2
.raw 7FF1_0A001200_F1FF      ; JMP[GT] 0x1200 (not taken)
.raw FFF8_0110004D_F8FF      ; MOVI r1,77 (fallthrough)
afterC:
MOVI r5,77
CMP r1,r5
JMP[NE] @fail
; ---- block E: signed CMPS + JMP[LT] taken ----
LA r1,@srcE
MOVI r2,6
LA r3,0x10000
LA r4,@afterE
CALL @xt_block_x86
CMP r1,r0
JMP[EQ] @fail
CODELEN r1
LA r2,0x10000
EXECN r2
afterE:
JMP @fail

srcE:
.raw FFF8_0110FFFF_F8FF      ; MOVI r1,0xFFFF
.raw FFF8_0210FFFF_F8FF      ; MOVHI r1,0xFFFF -> 0xFFFFFFFF (-1)
.raw FFF8_01200001_F8FF      ; MOVI r2,1
.raw FFF8_28010002_F8FF      ; CMPS r1,r2
.raw 7FF1_0A001400_F87F      ; JMP[LT] 0x1400 (n=2)
.raw FFF8_01100063_F8FF      ; MOVI r1,99 (must not run)

s_pass:
.str "XLATE PASS\n"
s_fail:
.str "XLATE FAIL\n"
