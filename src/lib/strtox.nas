; strtox.nas - strtol/strtoul/strtoll/strtoull (raw NaN16).

.equ W_SX_S     0xF06A4
.equ W_SX_ORIG  0xF06A5
.equ W_SX_ENDP  0xF06A6
.equ W_SX_ENDVAL 0xF06A7
.equ W_SX_BASE  0xF06A8
.equ W_SX_SIGN  0xF06A9
.equ W_SX_DIGITS 0xF06AA

; sx_parse: uses W_SX_S/W_SX_BASE/W_SX_SIGN; sets W_LLD0/1, W_SX_ENDVAL
sx_parse:
ST r15,r14,0
ADD r14,r14,r13
LD r5,r0,#W_SX_S
ST r0,r0,#W_SX_DIGITS
sx_ws:
LDB r1,r5,0
MOVI r3,9
CMP r1,r3
JMP[LT] @sx_wsd
MOVI r3,13
CMP r1,r3
JMP[LE] @sx_wsn
MOVI r3,32
CMP r1,r3
JMP[NE] @sx_wsd
sx_wsn:
ADD r5,r5,r13
JMP @sx_ws
sx_wsd:
LDB r1,r5,0
MOVI r3,45
CMP r1,r3
JMP[NE] @sx_plus
MOVI r3,1
ST r3,r0,#W_SX_SIGN
ADD r5,r5,r13
JMP @sx_sign_d
sx_plus:
MOVI r3,43
CMP r1,r3
JMP[NE] @sx_sign_d
ADD r5,r5,r13
sx_sign_d:
LD r6,r0,#W_SX_BASE
CMP r6,r0
JMP[NE] @sx_b16
LDB r1,r5,0
MOVI r3,48
CMP r1,r3
JMP[NE] @sx_b10
ADDI r3,r5,1
LDB r1,r3,0
MOVI r3,120
CMP r1,r3
JMP[EQ] @sx_b16p
MOVI r3,88
CMP r1,r3
JMP[EQ] @sx_b16p
MOVI r6,8
JMP @sx_loop
sx_b16p:
MOVI r6,16
ADDI r5,r5,2
JMP @sx_loop
sx_b10:
MOVI r6,10
JMP @sx_loop
sx_b16:
MOVI r3,16
CMP r6,r3
JMP[NE] @sx_loop
LDB r1,r5,0
MOVI r3,48
CMP r1,r3
JMP[NE] @sx_loop
ADDI r3,r5,1
LDB r1,r3,0
MOVI r3,120
CMP r1,r3
JMP[EQ] @sx_skip0x
MOVI r3,88
CMP r1,r3
JMP[NE] @sx_loop
sx_skip0x:
ADDI r5,r5,2
sx_loop:
ST r0,r0,#W_LLD0
ST r0,r0,#W_LLD1
sx_l:
LDB r1,r5,0
MOVI r2,255
MOVI r3,48
CMP r1,r3
JMP[LT] @sx_alpha
MOVI r3,57
CMP r1,r3
JMP[GT] @sx_alpha
MOVI r3,48
SUB r2,r1,r3
JMP @sx_dchk
sx_alpha:
MOVI r3,97
CMP r1,r3
JMP[LT] @sx_upper
MOVI r3,122
CMP r1,r3
JMP[GT] @sx_upper
MOVI r3,87
SUB r2,r1,r3
JMP @sx_dchk
sx_upper:
MOVI r3,65
CMP r1,r3
JMP[LT] @sx_done
MOVI r3,90
CMP r1,r3
JMP[GT] @sx_done
MOVI r3,55
SUB r2,r1,r3
sx_dchk:
MOVI r3,255
CMP r2,r3
JMP[EQ] @sx_done
CMP r2,r6
JMP[GE] @sx_done
; pair = pair*base + digit
ST r2,r0,#W_EL_OFF
LD r4,r0,#W_LLD0
LD r7,r0,#W_LLD1
MUL r8,r4,r6
MULHU r9,r4,r6
MUL r10,r7,r6
ADD r9,r9,r10
LD r10,r0,#W_EL_OFF
ADD r8,r8,r10
MOVI r11,0
CMP r8,r10
JMP[GE] @sx_nc
MOVI r11,1
sx_nc:
ADD r9,r9,r11
ST r8,r0,#W_LLD0
ST r9,r0,#W_LLD1
LD r1,r0,#W_SX_DIGITS
ADD r1,r1,r13
ST r1,r0,#W_SX_DIGITS
ADD r5,r5,r13
JMP @sx_l
sx_done:
LD r1,r0,#W_SX_DIGITS
CMP r1,r0
JMP[NE] @sx_have
LD r1,r0,#W_SX_ORIG
ST r1,r0,#W_SX_ENDVAL
JMP @sx_sign
sx_have:
ST r5,r0,#W_SX_ENDVAL
sx_sign:
LD r1,r0,#W_SX_SIGN
CMP r1,r0
JMP[EQ] @sx_d
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CALL @ll_neg_pair
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
sx_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; helpers to run a conversion and push a 32/64-bit result
sx_setup:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_SX_BASE
CALL @ni_pop
ST r1,r0,#W_SX_ENDP
CALL @ni_pop
ST r1,r0,#W_SX_S
ST r1,r0,#W_SX_ORIG
ST r0,r0,#W_SX_SIGN
CALL @sx_parse
LD r1,r0,#W_SX_ENDP
CMP r1,r0
JMP[EQ] @sxs_d
LD r2,r0,#W_SX_ENDVAL
MOVI r3,#SZ_32
CALL @ni_storev
sxs_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_strtol:
ST r15,r14,0
ADD r14,r14,r13
CALL @sx_setup
LD r1,r0,#W_LLD0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

nbi_strtoul:
ST r15,r14,0
ADD r14,r14,r13
CALL @sx_setup
LD r1,r0,#W_LLD0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

nbi_strtoll:
ST r15,r14,0
ADD r14,r14,r13
CALL @sx_setup
LD r1,r0,#W_LLD0
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

nbi_strtoull:
ST r15,r14,0
ADD r14,r14,r13
CALL @sx_setup
LD r1,r0,#W_LLD0
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

ncc_s_strtol:
.str "strtol"
ncc_s_strtoul:
.str "strtoul"
ncc_s_strtoll:
.str "strtoll"
ncc_s_strtoull:
.str "strtoull"
