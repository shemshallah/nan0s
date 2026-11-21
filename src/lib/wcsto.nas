; wcsto.nas - wide string to number conversions (ASCII subset).

.equ W_WCS_BUF 11040000

; w2_copy_narrow: r1=wide r2=dst r3=max -> r1=bytes copied
w2_copy_narrow:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_W2F
ST r2,r0,#W_W2H
ST r3,r0,#W_W2I
ST r0,r0,#W_W2J
wcn_l:
LD r1,r0,#W_W2J
LD r2,r0,#W_W2I
ADDI r2,r2,-1
CMP r1,r2
JMP[GE] @wcn_d
LD r1,r0,#W_W2F
CALL @w2_load
ST r1,r0,#W_W2G
CMP r1,r0
JMP[EQ] @wcn_d
LD r2,r0,#W_W2H
LD r3,r0,#W_W2J
ADD r2,r2,r3
LD r1,r0,#W_W2G
MOVI r3,255
BOOL.8 r1,r1,r3
STB r1,r2,0
LD r1,r0,#W_W2F
ADDI r1,r1,4
ST r1,r0,#W_W2F
LD r1,r0,#W_W2J
ADD r1,r1,r13
ST r1,r0,#W_W2J
JMP @wcn_l
wcn_d:
LD r2,r0,#W_W2H
LD r3,r0,#W_W2J
ADD r2,r2,r3
STB r0,r2,0
LD r1,r0,#W_W2J
SUB r14,r14,r13
LD r15,r14,0
RET

; w2_parse_int: parse W_W2A using W_W2C base; maps *W_W2E
w2_parse_int:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_W2A
LA r2,#W_WCS_BUF
MOVI r3,250
CALL @w2_copy_narrow
LA r1,#W_WCS_BUF
ST r1,r0,#W_SX_S
ST r1,r0,#W_SX_ORIG
ST r0,r0,#W_SX_SIGN
ST r1,r0,#W_SX_ENDP
LD r1,r0,#W_W2C
ST r1,r0,#W_SX_BASE
CALL @sx_parse
LD r1,r0,#W_W2E
CMP r1,r0
JMP[EQ] @wpi_d
LD r2,r0,#W_SX_ENDVAL
LA r3,#W_WCS_BUF
SUB r2,r2,r3
SHL r2,r2,2
LD r3,r0,#W_W2A
ADD r2,r3,r2
MOVI r3,#SZ_32
CALL @ni_storev
wpi_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_wcstol:
CALL @ni_pop
ST r1,r0,#W_W2C
CALL @ni_pop
ST r1,r0,#W_W2E
CALL @ni_pop
ST r1,r0,#W_W2A
CALL @w2_parse_int
LD r1,r0,#W_LLD0
CALL @ni_push
JMP @nbi_d

nbi_wcstoul:
CALL @ni_pop
ST r1,r0,#W_W2C
CALL @ni_pop
ST r1,r0,#W_W2E
CALL @ni_pop
ST r1,r0,#W_W2A
CALL @w2_parse_int
LD r1,r0,#W_LLD0
CALL @ni_push
JMP @nbi_d

nbi_wcstoll:
CALL @ni_pop
ST r1,r0,#W_W2C
CALL @ni_pop
ST r1,r0,#W_W2E
CALL @ni_pop
ST r1,r0,#W_W2A
CALL @w2_parse_int
LD r1,r0,#W_LLD0
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
JMP @nbi_d

nbi_wcstoull:
CALL @ni_pop
ST r1,r0,#W_W2C
CALL @ni_pop
ST r1,r0,#W_W2E
CALL @ni_pop
ST r1,r0,#W_W2A
CALL @w2_parse_int
LD r1,r0,#W_LLD0
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
JMP @nbi_d

nbi_wcstod:
CALL @ni_pop
ST r1,r0,#W_W2E
CALL @ni_pop
ST r1,r0,#W_W2A
LD r1,r0,#W_W2A
LA r2,#W_WCS_BUF
MOVI r3,250
CALL @w2_copy_narrow
LA r1,#W_WCS_BUF
CALL @ni_strtod_core
ST r1,r0,#W_F2V
ST r2,r0,#W_W2H
LD r1,r0,#W_W2E
CMP r1,r0
JMP[EQ] @wcd_p
LD r2,r0,#W_W2H
LA r3,#W_WCS_BUF
SUB r2,r2,r3
SHL r2,r2,2
LD r3,r0,#W_W2A
ADD r2,r3,r2
MOVI r3,#SZ_32
CALL @ni_storev
wcd_p:
LD r1,r0,#W_F2V
CALL @ni_push
JMP @nbi_d

nbi_wcstof:
JMP @nbi_wcstod
nbi_wcstold:
JMP @nbi_wcstod

ncc_s_wcstol:
.str "wcstol"
ncc_s_wcstoul:
.str "wcstoul"
ncc_s_wcstoll:
.str "wcstoll"
ncc_s_wcstoull:
.str "wcstoull"
ncc_s_wcstod:
.str "wcstod"
ncc_s_wcstof:
.str "wcstof"
ncc_s_wcstold:
.str "wcstold"

nbi_wcscoll:
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
wcol_l:
ADD r1,r7,r0
CALL @w2_load
ADD r9,r1,r0
ADD r1,r8,r0
CALL @w2_load
ADD r10,r1,r0
CMP r9,r10
JMP[NE] @wcol_diff
CMP r9,r0
JMP[EQ] @wcol_z
ADDI r7,r7,4
ADDI r8,r8,4
JMP @wcol_l
wcol_diff:
CMPS r9,r10
JMP[LT] @wcol_neg
MOVI r1,1
CALL @ni_push
JMP @nbi_d
wcol_neg:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d
wcol_z:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_wcsxfrm:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
ST r0,r0,#W_W2D
wxf_l:
ADD r1,r8,r0
CALL @w2_load
CMP r1,r0
JMP[EQ] @wxf_nul
LD r2,r0,#W_W2D
CMP r9,r0
JMP[EQ] @wxf_skip
CMP r2,r9
JMP[GE] @wxf_skip
ST r1,r0,#W_W2E
SHL r3,r2,2
ADD r3,r7,r3
ADD r1,r3,r0
LD r2,r0,#W_W2E
CALL @w2_store
wxf_skip:
LD r1,r0,#W_W2D
ADD r1,r1,r13
ST r1,r0,#W_W2D
ADDI r8,r8,4
JMP @wxf_l
wxf_nul:
LD r2,r0,#W_W2D
CMP r9,r0
JMP[EQ] @wxf_d
CMP r2,r9
JMP[GE] @wxf_d
SHL r3,r2,2
ADD r3,r7,r3
ADD r1,r3,r0
MOVI r2,0
CALL @w2_store
wxf_d:
LD r1,r0,#W_W2D
CALL @ni_push
JMP @nbi_d

ncc_s_wcscoll:
.str "wcscoll"
ncc_s_wcsxfrm:
.str "wcsxfrm"
