; libcx.nas - extra C library pieces (strftime, tmpfile/tmpnam, wide strings).

.equ SF_OUT   61620
.equ SF_MAX   61621
.equ SF_USED  61622
.equ SF_TM    61623
.equ SF_FMT   61624
.equ SF_OVF   61625
.equ SF_VAL   61626
.equ SF_DIG   61627
.equ SF_CNT   61628
.equ SF_PTR   61629

; sf_put: r1=char
cx_sf_put:
LD r2,r0,#SF_USED
LD r3,r0,#SF_MAX
ADDI r4,r3,-1
CMP r2,r4
JMP[GE] @cx_sfp_ovf
LD r4,r0,#SF_OUT
ADD r4,r4,r2
STB r1,r4,0
ADD r2,r2,r13
ST r2,r0,#SF_USED
RET
cx_sfp_ovf:
MOVI r1,1
ST r1,r0,#SF_OVF
RET

; sf_num: r1=value r2=digits (zero padded)
cx_sf_num:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#SF_VAL
ST r2,r0,#SF_DIG
MOVI r5,1
ADD r6,r2,r0
ADDI r6,r6,-1
cx_sfn_p:
CMP r6,r0
JMP[EQ] @cx_sfn_go
MOVI r7,10
MUL r5,r5,r7
ADDI r6,r6,-1
JMP @cx_sfn_p
cx_sfn_go:
LD r2,r0,#SF_DIG
ST r2,r0,#SF_CNT
cx_sfn_l:
LD r2,r0,#SF_CNT
CMP r2,r0
JMP[EQ] @cx_sfn_d
LD r1,r0,#SF_VAL
DIV r3,r1,r5
MOD r1,r1,r5
ST r1,r0,#SF_VAL
ADDI r1,r3,48
CALL @cx_sf_put
MOVI r7,10
DIV r5,r5,r7
LD r2,r0,#SF_CNT
ADDI r2,r2,-1
ST r2,r0,#SF_CNT
JMP @cx_sfn_l
cx_sfn_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; sf_nth: r1=base byte ptr, r2=n -> r1=ptr to nth NUL-terminated string
cx_sf_nth:
CMP r2,r0
JMP[EQ] @cx_sfnth_d
cx_sfnth_l:
LDB r3,r1,0
ADD r1,r1,r13
CMP r3,r0
JMP[NE] @cx_sfnth_l
ADDI r2,r2,-1
JMP @cx_sf_nth
cx_sfnth_d:
RET

; sf_str: r1=byte ptr
cx_sf_str:
ST r15,r14,0
ADD r14,r14,r13
cx_sfstr_l:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @cx_sfstr_d
ST r1,r0,#SF_PTR
ADD r1,r2,r0
CALL @cx_sf_put
LD r1,r0,#SF_PTR
ADD r1,r1,r13
JMP @cx_sfstr_l
cx_sfstr_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; sf_tmv: r1=byte offset -> r1=int field
cx_sf_tmv:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#SF_TM
ADD r1,r2,r1
MOVI r2,#SZ_32
CALL @ni_loadv
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_strftime:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#SF_TM
CALL @ni_pop
ST r1,r0,#SF_FMT
CALL @ni_pop
ST r1,r0,#SF_MAX
CALL @ni_pop
ST r1,r0,#SF_OUT
ST r0,r0,#SF_USED
ST r0,r0,#SF_OVF
cx_sf_l:
LD r1,r0,#SF_FMT
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @cx_sf_done
ADD r1,r1,r13
ST r1,r0,#SF_FMT
MOVI r3,37
CMP r2,r3
JMP[EQ] @cx_sf_pct
ADD r1,r2,r0
CALL @cx_sf_put
JMP @cx_sf_l
cx_sf_pct:
LD r1,r0,#SF_FMT
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @cx_sf_done
ADD r1,r1,r13
ST r1,r0,#SF_FMT
MOVI r3,89
CMP r2,r3
JMP[EQ] @cx_sf_Y
MOVI r3,121
CMP r2,r3
JMP[EQ] @cx_sf_y
MOVI r3,109
CMP r2,r3
JMP[EQ] @cx_sf_m
MOVI r3,100
CMP r2,r3
JMP[EQ] @cx_sf_d
MOVI r3,101
CMP r2,r3
JMP[EQ] @cx_sf_e
MOVI r3,72
CMP r2,r3
JMP[EQ] @cx_sf_H
MOVI r3,77
CMP r2,r3
JMP[EQ] @cx_sf_M
MOVI r3,83
CMP r2,r3
JMP[EQ] @cx_sf_S
MOVI r3,106
CMP r2,r3
JMP[EQ] @cx_sf_j
MOVI r3,97
CMP r2,r3
JMP[EQ] @cx_sf_a
MOVI r3,65
CMP r2,r3
JMP[EQ] @cx_sf_A
MOVI r3,98
CMP r2,r3
JMP[EQ] @cx_sf_b
MOVI r3,66
CMP r2,r3
JMP[EQ] @cx_sf_B
MOVI r3,112
CMP r2,r3
JMP[EQ] @cx_sf_p
MOVI r3,110
CMP r2,r3
JMP[EQ] @cx_sf_n
MOVI r3,116
CMP r2,r3
JMP[EQ] @cx_sf_t
MOVI r3,37
CMP r2,r3
JMP[EQ] @cx_sf_litpct
MOVI r1,37
CALL @cx_sf_put
ADD r1,r2,r0
CALL @cx_sf_put
JMP @cx_sf_l
cx_sf_litpct:
MOVI r1,37
CALL @cx_sf_put
JMP @cx_sf_l
cx_sf_n:
MOVI r1,10
CALL @cx_sf_put
JMP @cx_sf_l
cx_sf_t:
MOVI r1,9
CALL @cx_sf_put
JMP @cx_sf_l
cx_sf_Y:
MOVI r1,20
CALL @cx_sf_tmv
ADDI r1,r1,1900
MOVI r2,4
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_y:
MOVI r1,20
CALL @cx_sf_tmv
ADDI r1,r1,1900
MOVI r2,100
MOD r1,r1,r2
MOVI r2,2
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_m:
MOVI r1,16
CALL @cx_sf_tmv
ADD r1,r1,r13
MOVI r2,2
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_d:
MOVI r1,12
CALL @cx_sf_tmv
MOVI r2,2
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_e:
MOVI r1,12
CALL @cx_sf_tmv
MOVI r2,10
CMP r1,r2
JMP[GE] @cx_sf_e2
MOVI r1,32
CALL @cx_sf_put
MOVI r1,12
CALL @cx_sf_tmv
MOVI r2,1
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_e2:
MOVI r2,2
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_H:
MOVI r1,8
CALL @cx_sf_tmv
MOVI r2,2
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_M:
MOVI r1,4
CALL @cx_sf_tmv
MOVI r2,2
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_S:
MOVI r1,0
CALL @cx_sf_tmv
MOVI r2,2
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_j:
MOVI r1,28
CALL @cx_sf_tmv
ADD r1,r1,r13
MOVI r2,3
CALL @cx_sf_num
JMP @cx_sf_l
cx_sf_a:
MOVI r1,24
CALL @cx_sf_tmv
SHL r1,r1,2
LA r2,@cx_sf_abday
SHL r2,r2,2
ADD r1,r1,r2
CALL @cx_sf_str
JMP @cx_sf_l
cx_sf_A:
MOVI r1,24
CALL @cx_sf_tmv
ADD r2,r1,r0
LA r1,@cx_sf_day
SHL r1,r1,2
CALL @cx_sf_nth
CALL @cx_sf_str
JMP @cx_sf_l
cx_sf_b:
MOVI r1,16
CALL @cx_sf_tmv
SHL r1,r1,2
LA r2,@cx_sf_abmon
SHL r2,r2,2
ADD r1,r1,r2
CALL @cx_sf_str
JMP @cx_sf_l
cx_sf_B:
MOVI r1,16
CALL @cx_sf_tmv
ADD r2,r1,r0
LA r1,@cx_sf_mon
SHL r1,r1,2
CALL @cx_sf_nth
CALL @cx_sf_str
JMP @cx_sf_l
cx_sf_p:
MOVI r1,8
CALL @cx_sf_tmv
MOVI r2,12
CMP r1,r2
JMP[GE] @cx_sf_pm
LA r1,@cx_sf_am
SHL r1,r1,2
CALL @cx_sf_str
JMP @cx_sf_l
cx_sf_pm:
LA r1,@cx_sf_pmstr
SHL r1,r1,2
CALL @cx_sf_str
JMP @cx_sf_l
cx_sf_done:
LD r1,r0,#SF_OVF
CMP r1,r0
JMP[NE] @cx_sf_zero
LD r2,r0,#SF_USED
LD r1,r0,#SF_OUT
ADD r1,r1,r2
STB r0,r1,0
ADD r2,r2,r0
JMP @cx_sf_ret
cx_sf_zero:
MOVI r2,0
cx_sf_ret:
ADD r1,r2,r0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

cx_sf_abday:
.str "Sun\0Mon\0Tue\0Wed\0Thu\0Fri\0Sat\0"
cx_sf_day:
.str "Sunday\0Monday\0Tuesday\0Wednesday\0Thursday\0Friday\0Saturday\0"
cx_sf_abmon:
.str "Jan\0Feb\0Mar\0Apr\0May\0Jun\0Jul\0Aug\0Sep\0Oct\0Nov\0Dec\0"
cx_sf_mon:
.str "January\0February\0March\0April\0May\0June\0July\0August\0September\0October\0November\0December\0"
cx_sf_am:
.str "AM"
cx_sf_pmstr:
.str "PM"

ncc_s_strftime:
.str "strftime"

.equ TMPN_CNT 61630

nbi_tmpnam:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
CMP r1,r0
JMP[NE] @tn_have
LA r1,11021100
tn_have:
ST r1,r0,#SF_OUT
LD r2,r0,#TMPN_CNT
ADD r2,r2,r13
ST r2,r0,#TMPN_CNT
MOVI r3,10000
MOD r2,r2,r3
MOVI r3,47
STB r3,r1,0
ADDI r1,r1,1
MOVI r3,116
STB r3,r1,0
ADDI r1,r1,1
MOVI r3,109
STB r3,r1,0
ADDI r1,r1,1
MOVI r3,112
STB r3,r1,0
ADDI r1,r1,1
MOVI r5,1000
MOVI r6,4
tn_d:
DIV r7,r2,r5
ADDI r7,r7,48
STB r7,r1,0
ADDI r1,r1,1
MOD r2,r2,r5
MOVI r7,10
DIV r5,r5,r7
SUB r6,r6,r13
CMP r6,r0
JMP[NE] @tn_d
MOVI r3,46
STB r3,r1,0
ADDI r1,r1,1
MOVI r3,116
STB r3,r1,0
ADDI r1,r1,1
MOVI r3,109
STB r3,r1,0
ADDI r1,r1,1
MOVI r3,112
STB r3,r1,0
ADDI r1,r1,1
STB r0,r1,0
LD r1,r0,#SF_OUT
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_tmpfile:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,0
CALL @ni_push
CALL @nbi_tmpnam
CALL @ni_pop
CALL @ni_push
LA r1,@cx_wplus
SHL r1,r1,2
CALL @ni_push
CALL @nbi_fopen
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_wcslen:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ0
ST r0,r0,#W_LLQ1
wl_l:
LD r1,r0,#W_LLQ0
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @wl_d
LD r1,r0,#W_LLQ0
ADDI r1,r1,4
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLQ1
ADD r1,r1,r13
ST r1,r0,#W_LLQ1
JMP @wl_l
wl_d:
LD r1,r0,#W_LLQ1
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_wcscmp:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ1
CALL @ni_pop
ST r1,r0,#W_LLQ0
wc_l:
LD r1,r0,#W_LLQ0
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_LLD0
LD r1,r0,#W_LLQ1
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_LLD1
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CMPS r1,r2
JMP[NE] @wc_ne
CMP r1,r0
JMP[EQ] @wc_eq
LD r1,r0,#W_LLQ0
ADDI r1,r1,4
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLQ1
ADDI r1,r1,4
ST r1,r0,#W_LLQ1
JMP @wc_l
wc_eq:
MOVI r1,0
JMP @wc_d
wc_ne:
MOVI r1,1
SUB[LT] r1,r0,r13
wc_d:
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_wcscpy:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ1
CALL @ni_pop
ST r1,r0,#W_LLQ0
ST r1,r0,#W_LLD0
wcp_l:
LD r1,r0,#W_LLQ1
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_LLD1
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLD1
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_LLD1
CMP r1,r0
JMP[EQ] @wcp_d
LD r1,r0,#W_LLQ0
ADDI r1,r1,4
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLQ1
ADDI r1,r1,4
ST r1,r0,#W_LLQ1
JMP @wcp_l
wcp_d:
LD r1,r0,#W_LLD0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_wcscat:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ1
CALL @ni_pop
ST r1,r0,#W_LLQ0
ST r1,r0,#W_LLD0
wca_find:
LD r1,r0,#W_LLQ0
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @wca_copy
LD r1,r0,#W_LLQ0
ADDI r1,r1,4
ST r1,r0,#W_LLQ0
JMP @wca_find
wca_copy:
LD r1,r0,#W_LLQ1
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_LLD1
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLD1
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_LLD1
CMP r1,r0
JMP[EQ] @wca_d
LD r1,r0,#W_LLQ0
ADDI r1,r1,4
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLQ1
ADDI r1,r1,4
ST r1,r0,#W_LLQ1
JMP @wca_copy
wca_d:
LD r1,r0,#W_LLD0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

cx_wplus:
.str "w+"
ncc_s_tmpnam:
.str "tmpnam"
ncc_s_tmpfile:
.str "tmpfile"
ncc_s_wcslen:
.str "wcslen"
ncc_s_wcscmp:
.str "wcscmp"
ncc_s_wcscpy:
.str "wcscpy"
ncc_s_wcscat:
.str "wcscat"

; nbi_call1: r1=function pointer, r2=one argument -> r1=result
nbi_call1:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_CMPFP
ST r2,r0,#W_CMPA
LD r4,r0,#R_FP
ST r4,r0,#W_CMPOLD
LD r5,r0,#R_SP
LD r6,r0,#W_CMPA
ST r6,r5,0
ADD r5,r5,r13
ST r5,r0,#R_SP
LD r1,r0,#W_CMPFP
CALL @sym_entry
LD r2,r1,#SY_KIND
MOVI r3,#SK_BUILTIN
CMP r2,r3
JMP[NE] @cc1_func
LD r1,r1,#SY_AUX
MOVI r2,1
CALL @ni_builtin
CALL @ni_pop
SUB r14,r14,r13
LD r15,r14,0
RET
cc1_func:
LD r6,r0,#W_CMPFP
MOVI r7,1
SHL r7,r7,16
BOOL.14 r6,r6,r7
ST r6,r0,#R_T0
CALL @ni_call
LD r4,r0,#W_CMPOLD
ST r4,r0,#W_IRYSTOP
CALL @ncc_ir_loop
ST r0,r0,#W_IRYSTOP
CALL @ni_pop
SUB r14,r14,r13
LD r15,r14,0
RET

ncc_s_c_SIGALRM:
.str "SIGALRM"
ncc_s_alarm:
.str "alarm"
