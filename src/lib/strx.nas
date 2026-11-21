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
MOVI r2,0
CMP r1,r2
JMP[EQ] @ser_0
MOVI r2,1
CMP r1,r2
JMP[EQ] @ser_1
MOVI r2,2
CMP r1,r2
JMP[EQ] @ser_2
MOVI r2,3
CMP r1,r2
JMP[EQ] @ser_3
MOVI r2,4
CMP r1,r2
JMP[EQ] @ser_4
MOVI r2,5
CMP r1,r2
JMP[EQ] @ser_5
MOVI r2,6
CMP r1,r2
JMP[EQ] @ser_6
MOVI r2,7
CMP r1,r2
JMP[EQ] @ser_7
MOVI r2,8
CMP r1,r2
JMP[EQ] @ser_8
MOVI r2,9
CMP r1,r2
JMP[EQ] @ser_9
MOVI r2,10
CMP r1,r2
JMP[EQ] @ser_10
MOVI r2,11
CMP r1,r2
JMP[EQ] @ser_11
MOVI r2,12
CMP r1,r2
JMP[EQ] @ser_12
MOVI r2,13
CMP r1,r2
JMP[EQ] @ser_13
MOVI r2,14
CMP r1,r2
JMP[EQ] @ser_14
MOVI r2,15
CMP r1,r2
JMP[EQ] @ser_15
MOVI r2,16
CMP r1,r2
JMP[EQ] @ser_16
MOVI r2,17
CMP r1,r2
JMP[EQ] @ser_17
MOVI r2,18
CMP r1,r2
JMP[EQ] @ser_18
MOVI r2,19
CMP r1,r2
JMP[EQ] @ser_19
MOVI r2,20
CMP r1,r2
JMP[EQ] @ser_20
MOVI r2,21
CMP r1,r2
JMP[EQ] @ser_21
MOVI r2,22
CMP r1,r2
JMP[EQ] @ser_22
JMP @ser_def
ser_0:
LA r1,@sx_e0
SHL r1,r1,2
JMP @ser_p
ser_1:
LA r1,@sx_e1
SHL r1,r1,2
JMP @ser_p
ser_2:
LA r1,@sx_e2
SHL r1,r1,2
JMP @ser_p
ser_3:
LA r1,@sx_e3
SHL r1,r1,2
JMP @ser_p
ser_4:
LA r1,@sx_e4
SHL r1,r1,2
JMP @ser_p
ser_5:
LA r1,@sx_e5
SHL r1,r1,2
JMP @ser_p
ser_6:
LA r1,@sx_e6
SHL r1,r1,2
JMP @ser_p
ser_7:
LA r1,@sx_e7
SHL r1,r1,2
JMP @ser_p
ser_8:
LA r1,@sx_e8
SHL r1,r1,2
JMP @ser_p
ser_9:
LA r1,@sx_e9
SHL r1,r1,2
JMP @ser_p
ser_10:
LA r1,@sx_e10
SHL r1,r1,2
JMP @ser_p
ser_11:
LA r1,@sx_e11
SHL r1,r1,2
JMP @ser_p
ser_12:
LA r1,@sx_e12
SHL r1,r1,2
JMP @ser_p
ser_13:
LA r1,@sx_e13
SHL r1,r1,2
JMP @ser_p
ser_14:
LA r1,@sx_e14
SHL r1,r1,2
JMP @ser_p
ser_15:
LA r1,@sx_e15
SHL r1,r1,2
JMP @ser_p
ser_16:
LA r1,@sx_e16
SHL r1,r1,2
JMP @ser_p
ser_17:
LA r1,@sx_e17
SHL r1,r1,2
JMP @ser_p
ser_18:
LA r1,@sx_e18
SHL r1,r1,2
JMP @ser_p
ser_19:
LA r1,@sx_e19
SHL r1,r1,2
JMP @ser_p
ser_20:
LA r1,@sx_e20
SHL r1,r1,2
JMP @ser_p
ser_21:
LA r1,@sx_e21
SHL r1,r1,2
JMP @ser_p
ser_22:
LA r1,@sx_e22
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

; nbi_strrchr(s,c)
nbi_strrchr:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r7,r1,r0
MOVI r10,0
srr_l:
LDB r1,r7,0
CMP r1,r9
JMP[NE] @srr_nx
ADD r10,r7,r0
srr_nx:
CMP r1,r0
JMP[EQ] @srr_d
ADD r7,r7,r13
JMP @srr_l
srr_d:
ADD r1,r10,r0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_strndup(s,n)
nbi_strndup:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r6,r1,r0
CALL @ni_pop
ST r1,r0,#W_EL_OFF
ST r0,r0,#W_EL_COUNT
snd_l:
LD r2,r0,#W_EL_COUNT
CMP r2,r6
JMP[GE] @snd_c
LD r1,r0,#W_EL_OFF
ADD r1,r1,r2
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @snd_c
ADD r2,r2,r13
ST r2,r0,#W_EL_COUNT
JMP @snd_l
snd_c:
LD r1,r0,#W_EL_COUNT
ADD r1,r1,r13
CALL @ni_malloc
ST r1,r0,#W_EL_ELEM
LD r2,r0,#W_EL_OFF
LD r3,r0,#W_EL_COUNT
CALL @ni_memcpy_raw
LD r1,r0,#W_EL_ELEM
LD r2,r0,#W_EL_COUNT
ADD r1,r1,r2
STB r0,r1,0
LD r1,r0,#W_EL_ELEM
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_stpcpy(dst,src)
nbi_stpcpy:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r7,r1,r0
CALL @ni_pop
ADD r6,r1,r0
spc_l:
LDB r1,r7,0
STB r1,r6,0
CMP r1,r0
JMP[EQ] @spc_d
ADD r7,r7,r13
ADD r6,r6,r13
JMP @spc_l
spc_d:
ADD r1,r6,r0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; nbi_memccpy(dst,src,c,n)
nbi_memccpy:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r10,r1,r0
CALL @ni_pop
ADD r11,r1,r0
mcc_l:
CMP r8,r0
JMP[EQ] @mcc_n
LDB r1,r10,0
STB r1,r11,0
CMP r1,r9
JMP[EQ] @mcc_y
ADD r10,r10,r13
ADD r11,r11,r13
SUB r8,r8,r13
JMP @mcc_l
mcc_y:
ADD r1,r11,r13
JMP @mcc_p
mcc_n:
MOVI r1,0
mcc_p:
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

ncc_s_strrchr:
.str "strrchr"
ncc_s_strndup:
.str "strndup"
ncc_s_stpcpy:
.str "stpcpy"
ncc_s_memccpy:
.str "memccpy"
