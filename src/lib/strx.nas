; strx.nas - extra string/stdlib helpers (raw NaN16).

.equ W_TOKPTR 61670

; nbi_strspn(s,accept)
nbi_strspn:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
MOVI r9,0
sps_l:
LDB r1,r7,0
CMP r1,r0
JMP[EQ] @sps_d
ADD r2,r8,r0
sps_s:
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @sps_d
CMP r3,r1
JMP[EQ] @sps_m
ADD r2,r2,r13
JMP @sps_s
sps_m:
ADD r7,r7,r13
ADD r9,r9,r13
JMP @sps_l
sps_d:
ADD r1,r9,r0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_strcspn(s,reject)
nbi_strcspn:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
MOVI r9,0
scs_l:
LDB r1,r7,0
CMP r1,r0
JMP[EQ] @scs_d
ADD r2,r8,r0
scs_s:
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @scs_m
CMP r3,r1
JMP[EQ] @scs_d
ADD r2,r2,r13
JMP @scs_s
scs_m:
ADD r7,r7,r13
ADD r9,r9,r13
JMP @scs_l
scs_d:
ADD r1,r9,r0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_strpbrk(s,accept)
nbi_strpbrk:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
spb_l:
LDB r1,r7,0
CMP r1,r0
JMP[EQ] @spb_n
ADD r2,r8,r0
spb_s:
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @spb_nx
CMP r3,r1
JMP[EQ] @spb_y
ADD r2,r2,r13
JMP @spb_s
spb_nx:
ADD r7,r7,r13
JMP @spb_l
spb_y:
ADD r1,r7,r0
JMP @spb_p
spb_n:
MOVI r1,0
spb_p:
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_strtok(s,delim)
nbi_strtok:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
CMP r1,r0
JMP[NE] @stk_have
LD r1,r0,#W_TOKPTR
stk_have:
CMP r1,r0
JMP[EQ] @stk_none
ADD r7,r1,r0
stk_skip:
LDB r1,r7,0
CMP r1,r0
JMP[EQ] @stk_none
ADD r2,r8,r0
stk_ss:
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @stk_start
CMP r3,r1
JMP[EQ] @stk_skipn
ADD r2,r2,r13
JMP @stk_ss
stk_skipn:
ADD r7,r7,r13
JMP @stk_skip
stk_start:
ADD r9,r7,r0
stk_adv:
LDB r1,r7,0
CMP r1,r0
JMP[EQ] @stk_end
ADD r2,r8,r0
stk_as:
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @stk_anext
CMP r3,r1
JMP[EQ] @stk_cut
ADD r2,r2,r13
JMP @stk_as
stk_anext:
ADD r7,r7,r13
JMP @stk_adv
stk_cut:
STB r0,r7,0
ADD r1,r7,r13
ST r1,r0,#W_TOKPTR
ADD r1,r9,r0
JMP @stk_p
stk_end:
ST r0,r0,#W_TOKPTR
ADD r1,r9,r0
JMP @stk_p
stk_none:
ST r0,r0,#W_TOKPTR
MOVI r1,0
stk_p:
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

nbi_getenv:
CALL @ni_pop
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_system:
CALL @ni_pop
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

ncc_s_strspn:
.str "strspn"
ncc_s_strcspn:
.str "strcspn"
ncc_s_strpbrk:
.str "strpbrk"
ncc_s_strtok:
.str "strtok"
ncc_s_getenv:
.str "getenv"
ncc_s_system:
.str "system"
