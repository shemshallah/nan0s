; vscanf.nas - vscanf/vfscanf/vsscanf (raw NaN16).
; Materialises the destination pointers from the va_list on the eval stack,
; then delegates to the normal scanf core.

.equ W_VS_FMT  61900
.equ W_VS_AP   61901
.equ W_VS_FP   61902
.equ W_VS_WORDS 61903
.equ W_VS_SUP  61904
.equ W_VS_TMP  61905

; vs_push_ptr: copy one pointer word from the va_list to the eval stack
vs_push_ptr:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_VS_AP
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_VS_TMP
CALL @ni_push
LD r2,r0,#W_VS_WORDS
ADD r2,r2,r13
ST r2,r0,#W_VS_WORDS
LD r2,r0,#W_VS_AP
ADDI r2,r2,4
ST r2,r0,#W_VS_AP
SUB r14,r14,r13
LD r15,r14,0
RET

; vs_build: push format and destination pointers; set W_CALLWORDS/R_T1
vs_build:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_VS_FMT
CALL @ni_push
MOVI r1,1
ST r1,r0,#W_VS_WORDS
LD r1,r0,#W_VS_FMT
ST r1,r0,#W_VS_FP
vs_l:
LD r1,r0,#W_VS_FP
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @vs_done
MOVI r3,37
CMP r2,r3
JMP[EQ] @vs_pct
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
JMP @vs_l
vs_pct:
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
ST r0,r0,#W_VS_SUP
vs_flags:
LD r1,r0,#W_VS_FP
LDB r2,r1,0
MOVI r3,42
CMP r2,r3
JMP[NE] @vs_width
MOVI r3,1
ST r3,r0,#W_VS_SUP
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
JMP @vs_flags
vs_width:
MOVI r3,48
CMP r2,r3
JMP[LT] @vs_len
MOVI r3,58
CMP r2,r3
JMP[GE] @vs_len
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
JMP @vs_width
vs_len:
MOVI r3,104
CMP r2,r3
JMP[EQ] @vs_len_one
MOVI r3,108
CMP r2,r3
JMP[EQ] @vs_len_one
MOVI r3,76
CMP r2,r3
JMP[EQ] @vs_len_one
MOVI r3,106
CMP r2,r3
JMP[EQ] @vs_len_one
MOVI r3,122
CMP r2,r3
JMP[EQ] @vs_len_one
MOVI r3,116
CMP r2,r3
JMP[EQ] @vs_len_one
JMP @vs_conv
vs_len_one:
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
LD r1,r0,#W_VS_FP
LDB r2,r1,0
JMP @vs_len
vs_conv:
MOVI r3,37
CMP r2,r3
JMP[EQ] @vs_adv
MOVI r3,91
CMP r2,r3
JMP[EQ] @vs_scan
LD r2,r0,#W_VS_SUP
CMP r2,r0
JMP[NE] @vs_adv
CALL @vs_push_ptr
JMP @vs_adv
vs_scan:
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
LD r1,r0,#W_VS_FP
LDB r2,r1,0
MOVI r3,94
CMP r2,r3
JMP[NE] @vs_scan_l
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
vs_scan_l:
LD r1,r0,#W_VS_FP
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @vs_scan_end
MOVI r3,93
CMP r2,r3
JMP[EQ] @vs_scan_end
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
JMP @vs_scan_l
vs_scan_end:
LD r2,r0,#W_VS_SUP
CMP r2,r0
JMP[NE] @vs_adv
CALL @vs_push_ptr
vs_adv:
LD r1,r0,#W_VS_FP
ADDI r1,r1,1
ST r1,r0,#W_VS_FP
JMP @vs_l
vs_done:
LD r1,r0,#W_VS_WORDS
ST r1,r0,#W_CALLWORDS
ST r1,r0,#R_T1
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_vscanf:
CALL @ni_pop
ST r1,r0,#W_VS_AP
CALL @ni_pop
ST r1,r0,#W_VS_FMT
CALL @vs_build
JMP @nbi_scanf

nbi_vfscanf:
CALL @ni_pop
ST r1,r0,#W_VS_AP
CALL @ni_pop
ST r1,r0,#W_VS_FMT
CALL @ni_pop
ST r1,r0,#W_VS_TMP
LD r1,r0,#W_VS_TMP
CALL @ni_push
CALL @vs_build
LD r1,r0,#W_VS_WORDS
ADD r1,r1,r13
ST r1,r0,#W_CALLWORDS
ST r1,r0,#R_T1
JMP @nbi_fscanf

nbi_vsscanf:
CALL @ni_pop
ST r1,r0,#W_VS_AP
CALL @ni_pop
ST r1,r0,#W_VS_FMT
CALL @ni_pop
ST r1,r0,#W_VS_TMP
LD r1,r0,#W_VS_TMP
CALL @ni_push
CALL @vs_build
LD r1,r0,#W_VS_WORDS
ADD r1,r1,r13
ST r1,r0,#W_CALLWORDS
ST r1,r0,#R_T1
JMP @nbi_sscanf

ncc_s_vscanf:
.str "vscanf"
ncc_s_vfscanf:
.str "vfscanf"
ncc_s_vsscanf:
.str "vsscanf"
