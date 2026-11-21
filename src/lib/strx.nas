; strx.nas - extra string/stdlib helpers (raw NaN16).

.equ W_TOKPTR 61670

; nbi_strspn(s,accept)
nbi_strspn:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r8,r1,r0
ADD r10,r1,r0
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

; nbi_memchr(s,c,n)
nbi_memchr:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r7,r1,r0
mch_l:
CMP r8,r0
JMP[EQ] @mch_n
LDB r5,r7,0
CMP r5,r9
JMP[EQ] @mch_y
ADD r7,r7,r13
SUB r8,r8,r13
JMP @mch_l
mch_y:
ADD r1,r7,r0
JMP @mch_p
mch_n:
MOVI r1,0
mch_p:
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_strcoll(a,b) - C locale is strcmp
nbi_strcoll:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r2,r9,r0
CALL @ni_strcmp
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_strxfrm(dst,src,n)
nbi_strxfrm:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r3,r1,r0
CALL @ni_pop
ADD r8,r1,r0
ADD r10,r1,r0
CALL @ni_pop
ADD r7,r1,r0
MOVI r4,0
CMP r3,r0
JMP[EQ] @sxf_len
sxf_c:
ADDI r5,r3,-1
CMP r4,r5
JMP[GE] @sxf_nul
LDB r6,r8,0
CMP r6,r0
JMP[EQ] @sxf_nul
ADD r5,r7,r4
STB r6,r5,0
ADD r4,r4,r13
ADD r8,r8,r13
JMP @sxf_c
sxf_nul:
ADD r5,r7,r4
STB r0,r5,0
sxf_len:
MOVI r4,0
sxf_l2:
ADD r5,r10,r4
LDB r6,r5,0
CMP r6,r0
JMP[EQ] @sxf_d
ADD r4,r4,r13
JMP @sxf_l2
sxf_d:
ADD r1,r4,r0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_strerror(err)
nbi_strerror:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
CMP r1,r0
JMP[LT] @ser_def
MOVI r2,22
CMP r1,r2
JMP[GT] @ser_def
LA r2,@sx_errtab
ADD r2,r2,r1
LD r1,r2,0
SHL r1,r1,2
JMP @ser_p
ser_def:
LA r1,@sx_eunk
SHL r1,r1,2
ser_p:
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_perror(prefix)
nbi_perror:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
CMP r1,r0
JMP[EQ] @per_nopre
CALL @ni_puts
per_nopre:
MOVI r1,58
CALL @ncc_putc
MOVI r1,32
CALL @ncc_putc
LA r1,@sx_e0
SHL r1,r1,2
CALL @ni_puts
MOVI r1,10
CALL @ncc_putc
MOVI r1,0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

sx_errtab:
.word @sx_e0,@sx_e1,@sx_e2,@sx_e3,@sx_e4,@sx_e5,@sx_e6,@sx_e7
.word @sx_e8,@sx_e9,@sx_e10,@sx_e11,@sx_e12,@sx_e13,@sx_e14,@sx_e15
.word @sx_e16,@sx_e17,@sx_e18,@sx_e19,@sx_e20,@sx_e21,@sx_e22
sx_e0:
.str "Success"
sx_e1:
.str "Operation not permitted"
sx_e2:
.str "No such file or directory"
sx_e3:
.str "No such process"
sx_e4:
.str "Interrupted system call"
sx_e5:
.str "Input/output error"
sx_e6:
.str "No such device or address"
sx_e7:
.str "Argument list too long"
sx_e8:
.str "Exec format error"
sx_e9:
.str "Bad file descriptor"
sx_e10:
.str "No child processes"
sx_e11:
.str "Resource temporarily unavailable"
sx_e12:
.str "Cannot allocate memory"
sx_e13:
.str "Permission denied"
sx_e14:
.str "Bad address"
sx_e15:
.str "Block device required"
sx_e16:
.str "Device or resource busy"
sx_e17:
.str "File exists"
sx_e18:
.str "Cross-device link"
sx_e19:
.str "No such device"
sx_e20:
.str "Not a directory"
sx_e21:
.str "Is a directory"
sx_e22:
.str "Invalid argument"
sx_eunk:
.str "Unknown error"

ncc_s_memchr:
.str "memchr"
ncc_s_strcoll:
.str "strcoll"
ncc_s_strxfrm:
.str "strxfrm"
ncc_s_strerror:
.str "strerror"
ncc_s_perror:
.str "perror"
