; timeb.nas - time.h / locale.h / signal.h runtime builtins (raw NaN16).
; Included by ncc.nas after its .equ block.

; ---- time ---------------------------------------------------------
nbi_time:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_bare_tick
ADD r2,r1,r0
MOVI r3,1000
DIVU r2,r2,r3
LA r3,1700000000
ADD r2,r2,r3
ST r2,r0,#W_F2V
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nbt_d
LD r2,r0,#W_F2V
MOVI r3,4
CALL @ni_storev
nbt_d:
LD r1,r0,#W_F2V
CALL @ni_push
JMP @nbi_d

nbi_clock:
CALL @ni_bare_tick
CALL @ni_push
JMP @nbi_d

nbi_difftime:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LD r2,r0,#W_F2P
SUB r1,r1,r2
CVTIF r1,r1
CALL @ni_push
JMP @nbi_d

; ni_tm_ld: r1=struct base r2=index -> r1=field
ni_tm_ld:
SHL r2,r2,2
ADD r1,r1,r2
MOVI r2,4
JMP @ni_loadv

nbi_mktime:
CALL @ni_pop
ST r1,r0,#W_F2P
LD r1,r0,#W_F2P
MOVI r2,0
CALL @ni_tm_ld
ST r1,r0,#W_TM0
LD r1,r0,#W_F2P
MOVI r2,1
CALL @ni_tm_ld
ST r1,r0,#W_TM1
LD r1,r0,#W_F2P
MOVI r2,2
CALL @ni_tm_ld
ST r1,r0,#W_TM2
LD r1,r0,#W_F2P
MOVI r2,3
CALL @ni_tm_ld
ST r1,r0,#W_TM3
LD r1,r0,#W_F2P
MOVI r2,4
CALL @ni_tm_ld
ST r1,r0,#W_TM4
LD r1,r0,#W_F2P
MOVI r2,5
CALL @ni_tm_ld
ST r1,r0,#W_TM5
LD r1,r0,#W_TM5
ADDI r1,r1,1900
ST r1,r0,#W_TA
LD r1,r0,#W_TM4
ADD r1,r1,r13
ST r1,r0,#W_TB
LD r1,r0,#W_TM3
ST r1,r0,#W_TC
LD r1,r0,#W_TB
MOVI r2,2
CMP r1,r2
JMP[GT] @mkt_nj
LD r1,r0,#W_TA
SUB r1,r1,r13
ST r1,r0,#W_TA
LD r1,r0,#W_TB
ADDI r1,r1,12
ST r1,r0,#W_TB
mkt_nj:
LD r1,r0,#W_TA
MOVI r2,400
DIVU r1,r1,r2
ST r1,r0,#W_TD
LD r2,r0,#W_TD
MOVI r3,400
MUL r2,r2,r3
LD r1,r0,#W_TA
SUB r1,r1,r2
ST r1,r0,#W_TE
LD r1,r0,#W_TB
MOVI r2,3
SUB r1,r1,r2
MOVI r3,153
MUL r1,r1,r3
ADDI r1,r1,2
MOVI r2,5
DIVU r1,r1,r2
LD r2,r0,#W_TC
ADD r1,r1,r2
SUB r1,r1,r13
ST r1,r0,#W_TF
LD r1,r0,#W_TE
MOVI r2,365
MUL r1,r1,r2
ST r1,r0,#W_TM6
LD r1,r0,#W_TE
MOVI r2,4
DIVU r1,r1,r2
LD r2,r0,#W_TM6
ADD r1,r1,r2
ST r1,r0,#W_TM6
LD r1,r0,#W_TE
MOVI r2,100
DIVU r1,r1,r2
LD r2,r0,#W_TM6
SUB r2,r2,r1
LD r1,r0,#W_TF
ADD r2,r2,r1
ST r2,r0,#W_TM6
LD r1,r0,#W_TD
LA r2,146097
MUL r1,r1,r2
LD r2,r0,#W_TM6
ADD r1,r1,r2
LA r2,719468
SUB r1,r1,r2
ST r1,r0,#W_TM7
LD r1,r0,#W_TM7
LA r2,86400
MUL r1,r1,r2
LD r2,r0,#W_TM2
MOVI r3,3600
MUL r2,r2,r3
ADD r1,r1,r2
LD r2,r0,#W_TM1
MOVI r3,60
MUL r2,r2,r3
ADD r1,r1,r2
LD r2,r0,#W_TM0
ADD r1,r1,r2
ST r1,r0,#W_TM8
LD r1,r0,#W_TM8
CALL @ni_push
JMP @nbi_d

; ni_localtime_core: r1=seconds -> r1=static struct tm pointer
ni_localtime_core:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TA
LA r2,86400
DIVU r1,r1,r2
ST r1,r0,#W_TB
LD r2,r0,#W_TB
LA r3,86400
MUL r2,r2,r3
LD r1,r0,#W_TA
SUB r1,r1,r2
ST r1,r0,#W_TC
LD r1,r0,#W_TC
MOVI r2,3600
DIVU r1,r1,r2
ST r1,r0,#W_TM2
LD r2,r0,#W_TM2
MOVI r3,3600
MUL r2,r2,r3
LD r1,r0,#W_TC
SUB r1,r1,r2
ST r1,r0,#W_TC
LD r1,r0,#W_TC
MOVI r2,60
DIVU r1,r1,r2
ST r1,r0,#W_TM1
LD r2,r0,#W_TM1
MOVI r3,60
MUL r2,r2,r3
LD r1,r0,#W_TC
SUB r1,r1,r2
ST r1,r0,#W_TM0
LD r1,r0,#W_TB
LA r2,719468
ADD r1,r1,r2
ST r1,r0,#W_TD
LA r2,146097
DIVU r1,r1,r2
ST r1,r0,#W_TE
LD r2,r0,#W_TE
LA r3,146097
MUL r2,r2,r3
LD r1,r0,#W_TD
SUB r1,r1,r2
ST r1,r0,#W_TF
LD r1,r0,#W_TF
MOVI r2,1460
DIVU r1,r1,r2
ST r1,r0,#W_TM3
LD r1,r0,#W_TF
MOVI r2,36524
DIVU r1,r1,r2
ST r1,r0,#W_TM4
LD r1,r0,#W_TF
LA r2,146096
DIVU r1,r1,r2
ST r1,r0,#W_TM5
LD r1,r0,#W_TF
LD r2,r0,#W_TM3
SUB r1,r1,r2
LD r2,r0,#W_TM4
ADD r1,r1,r2
LD r2,r0,#W_TM5
SUB r1,r1,r2
MOVI r2,365
DIVU r1,r1,r2
ST r1,r0,#W_TM3
LD r2,r0,#W_TE
MOVI r3,400
MUL r2,r2,r3
ADD r1,r1,r2
ST r1,r0,#W_TM4
LD r1,r0,#W_TM3
MOVI r2,365
MUL r1,r1,r2
LD r2,r0,#W_TM3
MOVI r3,4
DIVU r2,r2,r3
ADD r1,r1,r2
LD r2,r0,#W_TM3
MOVI r3,100
DIVU r2,r2,r3
SUB r1,r1,r2
LD r2,r0,#W_TF
SUB r2,r2,r1
ST r2,r0,#W_TM5
LD r1,r0,#W_TM5
MOVI r2,5
MUL r1,r1,r2
ADDI r1,r1,2
MOVI r2,153
DIVU r1,r1,r2
ST r1,r0,#W_TM6
LD r2,r0,#W_TM6
MOVI r3,153
MUL r2,r2,r3
ADDI r2,r2,2
MOVI r3,5
DIVU r2,r2,r3
LD r1,r0,#W_TM5
SUB r1,r1,r2
ADDI r1,r1,1
ST r1,r0,#W_TM7
LD r1,r0,#W_TM6
MOVI r2,10
CMP r1,r2
JMP[GE] @nlc_m2
ADDI r1,r1,3
JMP @nlc_m3
nlc_m2:
MOVI r2,9
SUB r1,r1,r2
nlc_m3:
ST r1,r0,#W_TM8
LD r1,r0,#W_TM8
MOVI r2,2
CMP r1,r2
JMP[GT] @nlc_yn
LD r1,r0,#W_TM4
ADD r1,r1,r13
ST r1,r0,#W_TM4
nlc_yn:
; yday = cumulative_days[mon] + mday - 1 (+ leap day after February)
LD r1,r0,#W_TM8
SUB r1,r1,r13
LA r2,@asc_mdays
ADD r2,r2,r1
LD r1,r2,0
LD r3,r0,#W_TM7
ADD r1,r1,r3
SUB r1,r1,r13
LD r2,r0,#W_TM4
MOVI r3,4
MODU r4,r2,r3
CMP r4,r0
JMP[NE] @nlc_noleap
MOVI r3,100
MODU r4,r2,r3
CMP r4,r0
JMP[NE] @nlc_leap
MOVI r3,400
MODU r4,r2,r3
CMP r4,r0
JMP[NE] @nlc_noleap
nlc_leap:
LD r2,r0,#W_TM8
MOVI r3,2
CMP r2,r3
JMP[LE] @nlc_noleap
ADD r1,r1,r13
nlc_noleap:
ST r1,r0,#W_TM5
LD r1,r0,#W_TB
ADDI r1,r1,4
MOVI r2,7
MODU r1,r1,r2
ST r1,r0,#W_TA
LA r1,11020000
LD r2,r0,#W_TM0
MOVI r3,4
CALL @ni_storev
LA r1,11020004
LD r2,r0,#W_TM1
MOVI r3,4
CALL @ni_storev
LA r1,11020008
LD r2,r0,#W_TM2
MOVI r3,4
CALL @ni_storev
LA r1,11020012
LD r2,r0,#W_TM7
MOVI r3,4
CALL @ni_storev
LA r1,11020016
LD r2,r0,#W_TM8
SUB r2,r2,r13
MOVI r3,4
CALL @ni_storev
LA r1,11020020
LD r2,r0,#W_TM4
LA r3,1900
SUB r2,r2,r3
MOVI r3,4
CALL @ni_storev
LA r1,11020024
LD r2,r0,#W_TA
MOVI r3,4
CALL @ni_storev
LA r1,11020028
LD r2,r0,#W_TM5
MOVI r3,4
CALL @ni_storev
LA r1,11020032
MOVI r2,0
MOVI r3,4
CALL @ni_storev
LA r1,11020000
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_localtime:
CALL @ni_pop
CMP r1,r0
JMP[NE] @nbl_ptr
CALL @ni_bare_tick
MOVI r2,1000
DIVU r1,r1,r2
LA r2,1700000000
ADD r1,r1,r2
JMP @nbl_go
nbl_ptr:
MOVI r2,4
CALL @ni_loadv
nbl_go:
CALL @ni_localtime_core
CALL @ni_push
JMP @nbi_d
nbi_gmtime:
JMP @nbi_localtime

; ---- asctime / ctime ---------------------------------------------
; asc_out: append r1 to the buffer at W_TB
asc_out:
LD r2,r0,#W_TB
STB r1,r2,0
ADD r2,r2,r13
ST r2,r0,#W_TB
RET

; asc_str3b: r1=byte ptr, copy three characters
asc_str3b:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TA
MOVI r2,3
as3_l:
LD r1,r0,#W_TA
LDB r1,r1,0
ST r2,r0,#W_TC
CALL @asc_out
LD r1,r0,#W_TA
ADD r1,r1,r13
ST r1,r0,#W_TA
LD r2,r0,#W_TC
SUB r2,r2,r13
CMP r2,r0
JMP[NE] @as3_l
SUB r14,r14,r13
LD r15,r14,0
RET

; asc_num2z: zero-padded two digits
asc_num2z:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TA
MOVI r2,10
DIVU r1,r1,r2
ADDI r1,r1,48
CALL @asc_out
LD r1,r0,#W_TA
MOVI r2,10
MODU r1,r1,r2
ADDI r1,r1,48
CALL @asc_out
SUB r14,r14,r13
LD r15,r14,0
RET

; asc_num2s: two digits, tens is a space when zero
asc_num2s:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TA
MOVI r2,10
DIVU r1,r1,r2
CMP r1,r0
JMP[NE] @an2s_d
MOVI r1,32
JMP @an2s_p
an2s_d:
ADDI r1,r1,48
an2s_p:
CALL @asc_out
LD r1,r0,#W_TA
MOVI r2,10
MODU r1,r1,r2
ADDI r1,r1,48
CALL @asc_out
SUB r14,r14,r13
LD r15,r14,0
RET

asc_num4:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TA
MOVI r2,1000
DIVU r1,r1,r2
ADDI r1,r1,48
CALL @asc_out
LD r1,r0,#W_TA
MOVI r2,100
DIVU r1,r1,r2
MOVI r2,10
MODU r1,r1,r2
ADDI r1,r1,48
CALL @asc_out
LD r1,r0,#W_TA
MOVI r2,10
DIVU r1,r1,r2
MOVI r2,10
MODU r1,r1,r2
ADDI r1,r1,48
CALL @asc_out
LD r1,r0,#W_TA
MOVI r2,10
MODU r1,r1,r2
ADDI r1,r1,48
CALL @asc_out
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_asctime_core: r1=struct tm ptr -> r1=static buffer
ni_asctime_core:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_F2P
LD r1,r0,#W_F2P
MOVI r2,0
CALL @ni_tm_ld
ST r1,r0,#W_TM0
LD r1,r0,#W_F2P
MOVI r2,1
CALL @ni_tm_ld
ST r1,r0,#W_TM1
LD r1,r0,#W_F2P
MOVI r2,2
CALL @ni_tm_ld
ST r1,r0,#W_TM2
LD r1,r0,#W_F2P
MOVI r2,3
CALL @ni_tm_ld
ST r1,r0,#W_TM3
LD r1,r0,#W_F2P
MOVI r2,4
CALL @ni_tm_ld
ST r1,r0,#W_TM4
LD r1,r0,#W_F2P
MOVI r2,5
CALL @ni_tm_ld
ST r1,r0,#W_TM5
LD r1,r0,#W_F2P
MOVI r2,6
CALL @ni_tm_ld
ST r1,r0,#W_TM6
LA r1,11020100
ST r1,r0,#W_TB
LA r1,@asc_days
SHL r1,r1,2
LD r2,r0,#W_TM6
MOVI r3,3
MUL r2,r2,r3
ADD r1,r1,r2
CALL @asc_str3b
MOVI r1,32
CALL @asc_out
LA r1,@asc_months
SHL r1,r1,2
LD r2,r0,#W_TM4
MOVI r3,3
MUL r2,r2,r3
ADD r1,r1,r2
CALL @asc_str3b
MOVI r1,32
CALL @asc_out
LD r1,r0,#W_TM3
CALL @asc_num2s
MOVI r1,32
CALL @asc_out
LD r1,r0,#W_TM2
CALL @asc_num2z
MOVI r1,58
CALL @asc_out
LD r1,r0,#W_TM1
CALL @asc_num2z
MOVI r1,58
CALL @asc_out
LD r1,r0,#W_TM0
CALL @asc_num2z
MOVI r1,32
CALL @asc_out
LD r1,r0,#W_TM5
ADDI r1,r1,1900
CALL @asc_num4
MOVI r1,10
CALL @asc_out
MOVI r1,0
CALL @asc_out
LA r1,11020100
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_asctime:
CALL @ni_pop
CALL @ni_asctime_core
CALL @ni_push
JMP @nbi_d

nbi_ctime:
CALL @ni_pop
CMP r1,r0
JMP[NE] @nct_have
TICK r1
MOVI r2,1000
DIVU r1,r1,r2
LA r2,1700000000
ADD r1,r1,r2
JMP @nct_go
nct_have:
MOVI r2,4
CALL @ni_loadv
nct_go:
CALL @ni_localtime_core
CALL @ni_asctime_core
CALL @ni_push
JMP @nbi_d

; ---- locale -------------------------------------------------------
nbi_setlocale:
CALL @ni_pop
CALL @ni_pop
LA r1,11020200
MOVI r2,67
STB r2,r1,0
MOVI r2,0
STB r2,r1,1
CALL @ni_push
JMP @nbi_d

nbi_localeconv:
LA r1,11020256
ST r1,r0,#W_TA
; zero the 56-byte structure
MOVI r2,0
MOVI r3,14
MOVI r2,0
nlcv_z:
LA r4,11020256
ADD r4,r4,r2
STB r0,r4,0
ADD r2,r2,r13
MOVI r3,56
CMP r2,r3
JMP[LT] @nlcv_z
LA r1,11020204
MOVI r2,46
STB r2,r1,0
MOVI r2,0
STB r2,r1,1
LA r1,11020256
LA r2,11020204
MOVI r3,4
CALL @ni_storev
LA r1,11020256
CALL @ni_push
JMP @nbi_d

; ---- signal -------------------------------------------------------
nbi_signal:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
MOVI r2,31
CMP r1,r2
JMP[LE] @nsig_ok
MOVI r1,31
nsig_ok:
SHL r2,r1,2
LA r3,11020300
ADD r3,r3,r2
LD r4,r3,0
LD r5,r0,#W_TA
ST r5,r3,0
ADD r1,r4,r0
CALL @ni_push
JMP @nbi_d

nbi_alarm:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ1
; old seconds = W_ALARM / 100000
LD r1,r0,#W_ALARM
LA r2,100000
DIV r1,r1,r2
ST r1,r0,#W_LLQ0
; new steps = sec * 100000
LD r1,r0,#W_LLQ1
LA r2,100000
MUL r1,r1,r2
ST r1,r0,#W_ALARM
LD r1,r0,#W_LLQ0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

nbi_raise:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ0
SHL r2,r1,2
LA r3,11020300
ADD r3,r3,r2
LD r4,r3,0
CMP r4,r0
JMP[EQ] @nrs_d
CMP r4,r13
JMP[EQ] @nrs_d
ADD r1,r4,r0
LD r2,r0,#W_LLQ0
CALL @nbi_call1
nrs_d:
MOVI r1,0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; ---- atof / strtod ------------------------------------------------
; ni_strtod_core: r1=string -> r1=float bits, r2=end ptr
ni_strtod_core:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_F2P
; skip leading white space
nsc_ws:
LD r1,r0,#W_F2P
LDB r2,r1,0
MOVI r3,32
CMP r2,r3
JMP[EQ] @nsc_wsa
MOVI r3,9
CMP r2,r3
JMP[NE] @nsc_sign
nsc_wsa:
ADD r1,r1,r13
ST r1,r0,#W_F2P
JMP @nsc_ws
nsc_sign:
MOVI r1,1
ST r1,r0,#W_TA
LD r1,r0,#W_F2P
LDB r2,r1,0
MOVI r3,45
CMP r2,r3
JMP[NE] @nsc_plus
LA r3,0xFFFFFFFF
ST r3,r0,#W_TA
ADD r1,r1,r13
ST r1,r0,#W_F2P
JMP @nsc_int
nsc_plus:
MOVI r3,43
CMP r2,r3
JMP[NE] @nsc_int
ADD r1,r1,r13
ST r1,r0,#W_F2P
nsc_int:
ST r0,r0,#W_TM0
MOVI r1,1
ST r1,r0,#W_TM1
nsc_il:
LD r1,r0,#W_F2P
LDB r1,r1,0
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[EQ] @nsc_dot
ST r1,r0,#W_TB
LD r1,r0,#W_TM0
MOVI r2,10
MUL r1,r1,r2
LD r2,r0,#W_TB
ADD r1,r1,r2
ST r1,r0,#W_TM0
LD r1,r0,#W_F2P
ADD r1,r1,r13
ST r1,r0,#W_F2P
JMP @nsc_il
nsc_dot:
LD r1,r0,#W_F2P
LDB r2,r1,0
MOVI r3,46
CMP r2,r3
JMP[NE] @nsc_exp
ADD r1,r1,r13
ST r1,r0,#W_F2P
nsc_fl:
LD r1,r0,#W_F2P
LDB r1,r1,0
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[EQ] @nsc_exp
ST r1,r0,#W_TB
LD r1,r0,#W_TM0
MOVI r2,10
MUL r1,r1,r2
LD r2,r0,#W_TB
ADD r1,r1,r2
ST r1,r0,#W_TM0
LD r1,r0,#W_TM1
MOVI r2,10
MUL r1,r1,r2
ST r1,r0,#W_TM1
LD r1,r0,#W_F2P
ADD r1,r1,r13
ST r1,r0,#W_F2P
JMP @nsc_fl
nsc_exp:
; save end pointer for the mantissa
LD r1,r0,#W_F2P
ST r1,r0,#W_TM2
LD r1,r0,#W_F2P
LDB r2,r1,0
MOVI r3,101
CMP r2,r3
JMP[EQ] @nsc_e
MOVI r3,69
CMP r2,r3
JMP[NE] @nsc_build
nsc_e:
ADD r1,r1,r13
ST r1,r0,#W_F2P
MOVI r3,1
ST r3,r0,#W_TC
LD r1,r0,#W_F2P
LDB r2,r1,0
MOVI r3,45
CMP r2,r3
JMP[NE] @nsc_ep
LA r3,0xFFFFFFFF
ST r3,r0,#W_TC
ADD r1,r1,r13
ST r1,r0,#W_F2P
JMP @nsc_ed
nsc_ep:
MOVI r3,43
CMP r2,r3
JMP[NE] @nsc_ed
ADD r1,r1,r13
ST r1,r0,#W_F2P
nsc_ed:
ST r0,r0,#W_TD
nsc_el:
LD r1,r0,#W_F2P
LDB r1,r1,0
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[EQ] @nsc_edone
ST r1,r0,#W_TB
LD r1,r0,#W_TD
MOVI r2,10
MUL r1,r1,r2
LD r2,r0,#W_TB
ADD r1,r1,r2
ST r1,r0,#W_TD
LD r1,r0,#W_F2P
ADD r1,r1,r13
ST r1,r0,#W_F2P
JMP @nsc_el
nsc_edone:
LD r1,r0,#W_TM2
ST r1,r0,#W_F2P
JMP @nsc_build2
nsc_build:
ST r0,r0,#W_TD
nsc_build2:
; value = mantissa * 10^(exp - fraction digits)
LD r1,r0,#W_TM0
CVTIF r1,r1
LA r2,0x41200000
LD r3,r0,#W_TM1
; divide by 10 for each fraction digit
nsc_fd:
MOVI r4,1
CMP r3,r4
JMP[LE] @nsc_fd2
FDIV r1,r1,r2
MOVI r4,10
DIVU r3,r3,r4
JMP @nsc_fd
nsc_fd2:
LD r3,r0,#W_TD
LD r4,r0,#W_TC
CMPS r4,r0
JMP[LT] @nsc_powd
nsc_powm:
CMP r3,r0
JMP[EQ] @nsc_done
FMUL r1,r1,r2
SUB r3,r3,r13
JMP @nsc_powm
nsc_powd:
CMP r3,r0
JMP[EQ] @nsc_done
FDIV r1,r1,r2
SUB r3,r3,r13
JMP @nsc_powd
nsc_done:
LD r2,r0,#W_TA
CMPS r2,r0
JMP[GE] @nsc_ret
LA r2,0x80000000
ADD r1,r1,r2
nsc_ret:
LD r2,r0,#W_F2P
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_atof:
CALL @ni_pop
CALL @ni_strtod_core
CALL @ni_push
JMP @nbi_d

nbi_strtod:
CALL @ni_pop
ST r1,r0,#W_TE
CALL @ni_pop
CALL @ni_strtod_core
ST r1,r0,#W_F2V
ST r2,r0,#W_TM3
LD r1,r0,#W_F2V
CALL @ni_push
LD r1,r0,#W_TE
CMP r1,r0
JMP[EQ] @nst_nop
LD r2,r0,#W_TM3
MOVI r3,4
CALL @ni_storev
nst_nop:
JMP @nbi_d

asc_mdays:
.word 0,31,59,90,120,151,181,212,243,273,304,334
asc_days:
.str "SunMonTueWedThuFriSat"
asc_months:
.str "JanFebMarAprMayJunJulAugSepOctNovDec"

; ---- POSIX interval timers (ITIMER_REAL) --------------------------
; itimerval layout: {tv_sec,tv_usec} interval, {tv_sec,tv_usec} value.
nbi_setitimer:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
CALL @ni_pop
CMP r1,r0
JMP[NE] @sit_f
; old values
LD r1,r0,#W_TA
CMP r1,r0
JMP[EQ] @sit_new
CALL @iti_store
sit_new:
LD r1,r0,#W_TB
CMP r1,r0
JMP[EQ] @sit_ok
; value: sec*100000 + usec/10
LD r1,r0,#W_TB
ADDI r1,r1,8
MOVI r2,#SZ_32
CALL @ni_loadv
LA r2,100000
MUL r1,r1,r2
ST r1,r0,#W_TM0
LD r1,r0,#W_TB
ADDI r1,r1,12
MOVI r2,#SZ_32
CALL @ni_loadv
MOVI r2,10
DIVU r1,r1,r2
LD r2,r0,#W_TM0
ADD r1,r1,r2
ST r1,r0,#W_ALARM
; interval
LD r1,r0,#W_TB
MOVI r2,#SZ_32
CALL @ni_loadv
LA r2,100000
MUL r1,r1,r2
ST r1,r0,#W_TM0
LD r1,r0,#W_TB
ADDI r1,r1,4
MOVI r2,#SZ_32
CALL @ni_loadv
MOVI r2,10
DIVU r1,r1,r2
LD r2,r0,#W_TM0
ADD r1,r1,r2
ST r1,r0,#W_IT_INTERVAL
sit_ok:
MOVI r1,0
JMP @sit_p
sit_f:
LA r1,0xFFFFFFFF
sit_p:
CALL @ni_push
JMP @nbi_d

; iti_store: r1=itimerval pointer -> write interval and remaining time
iti_store:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TC
; interval
LD r5,r0,#W_IT_INTERVAL
LA r2,100000
DIVU r6,r5,r2
MUL r7,r6,r2
SUB r7,r5,r7
MOVI r8,10
MUL r7,r7,r8
LD r1,r0,#W_TC
ADD r2,r6,r0
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_TC
ADDI r1,r1,4
ADD r2,r7,r0
MOVI r3,#SZ_32
CALL @ni_storev
; remaining
LD r5,r0,#W_ALARM
LA r2,100000
DIVU r6,r5,r2
MUL r7,r6,r2
SUB r7,r5,r7
MOVI r8,10
MUL r7,r7,r8
LD r1,r0,#W_TC
ADDI r1,r1,8
ADD r2,r6,r0
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_TC
ADDI r1,r1,12
ADD r2,r7,r0
MOVI r3,#SZ_32
CALL @ni_storev
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_getitimer:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
CMP r1,r0
JMP[NE] @git_f
LD r1,r0,#W_TA
CMP r1,r0
JMP[EQ] @git_ok
CALL @iti_store
git_ok:
MOVI r1,0
JMP @git_p
git_f:
LA r1,0xFFFFFFFF
git_p:
CALL @ni_push
JMP @nbi_d

ncc_s_setitimer:
.str "setitimer"
ncc_s_getitimer:
.str "getitimer"
