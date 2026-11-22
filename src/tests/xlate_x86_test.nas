; xlate_x86_test.nas - NaN-native block translator -> packed x86 -> EXECN.
; The block is MOVI r1,42; ADD r1,r1,r1; MOVI r2,4; SUB r1,r1,r2,
; so the native x86 result must be r1=80.  Emitted bytes: 4*? -> exact 71.
.org 0
JMP @main
.include "../translate/block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,4
LA r3,0x10000
LA r4,@after
CALL @xt_block_x86
MOVI r5,71
CMP r1,r5
JMP[NE] @fail
CODELEN r1
LA r2,0x10000
EXECN r2
after:
MOVI r5,80
CMP r1,r5
JMP[NE] @fail
LA r1,@s_pass
CALL @puts
HALT
fail:
LA r1,@s_fail
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
src:
.word 0x0110002A      ; MOVI r1,42
.word 0x03110001      ; ADD r1,r1,r1
.word 0x01200004      ; MOVI r2,4
.word 0x04110002      ; SUB r1,r1,r2
s_pass:
.str "XLATE PASS\n"
s_fail:
.str "XLATE FAIL\n"
