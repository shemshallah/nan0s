; scanf.nas - scanf/fscanf/sscanf (raw NaN16).
; Conversions: d i u o x X f e g s c and %%; whitespace, literals,
; '*' suppression and field widths.  Streams use the stdio FILE layer.
.equ CSBUF    11020600
.equ CSBUFSZ  128
.equ CS_FMT   61560
.equ CS_ARG   61561
.equ CS_CNT   61562
.equ CS_MODE  61563
.equ CS_SRC   61564
.equ CS_PBF   61565
.equ CS_PBC   61566
.equ CS_W     61567
.equ CS_SUP   61568
.equ CS_TMP   61569
.equ CS_SGN   61570
.equ CS_DST   61571
.equ CS_BASE  61572
.equ CS_DIG   61573
.equ CS_I     61574
.equ CS_ENT   61575
.equ CS_FBUF  11020700

; cs_getc -> r1=char or -1
cs_getc:
LD r1,r0,#CS_PBF
CMP r1,r0
JMP[EQ] @csg_src
ST r0,r0,#CS_PBF
LD r1,r0,#CS_PBC
RET
csg_src:
LD r1,r0,#CS_MODE
CMP r1,r0
JMP[NE] @csg_stream
LD r1,r0,#CS_SRC
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @csg_eof
ADD r1,r1,r13
ST r1,r0,#CS_SRC
ADD r1,r2,r0
RET
csg_stream:
LD r1,r0,#CS_SRC
MOVI r2,4
CMP r1,r2
JMP[LT] @csg_key
CALL @st_entry
CMP r1,r0
JMP[EQ] @csg_eof
CALL @st_getc
RET
csg_key:
KEYQ r1
CMP r1,r0
JMP[EQ] @csg_eof
RET
csg_eof:
LA r1,0xFFFFFFFF
RET

; cs_ungetc: r1=char
cs_ungetc:
ST r1,r0,#CS_PBC
MOVI r1,1
ST r1,r0,#CS_PBF
RET

; cs_isspace: r1=char -> r1=1/0
cs_isspace:
MOVI r2,32
CMP r1,r2
JMP[EQ] @css_y
MOVI r2,9
CMP r1,r2
JMP[EQ] @css_y
MOVI r2,10
CMP r1,r2
JMP[EQ] @css_y
MOVI r2,13
CMP r1,r2
JMP[EQ] @css_y
MOVI r1,0
RET
css_y:
MOVI r1,1
RET

; cs_skipws
cs_skipws:
ST r15,r14,0
ADD r14,r14,r13
csw_l:
CALL @cs_getc
CMPS r1,r0
JMP[LT] @csw_d
ST r1,r0,#CS_TMP
CALL @cs_isspace
CMP r1,r0
JMP[NE] @csw_l
LD r1,r0,#CS_TMP
CALL @cs_ungetc
csw_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; cs_digit: r1=char r2=base -> r1=value or -1
cs_digit:
MOVI r3,48
CMP r1,r3
JMP[LT] @csd_alpha
MOVI r3,57
CMP r1,r3
JMP[GT] @csd_alpha
ADDI r1,r1,-48
JMP @csd_chk
csd_alpha:
MOVI r3,97
CMP r1,r3
JMP[LT] @csd_upper
MOVI r3,102
CMP r1,r3
JMP[GT] @csd_upper
ADDI r1,r1,-87
JMP @csd_chk
csd_upper:
MOVI r3,65
CMP r1,r3
JMP[LT] @csd_bad
MOVI r3,70
CMP r1,r3
JMP[GT] @csd_bad
ADDI r1,r1,-55
JMP @csd_chk
csd_bad:
LA r1,0xFFFFFFFF
RET
csd_chk:
CMP r1,r2
JMP[LT] @csd_ok
LA r1,0xFFFFFFFF
csd_ok:
RET

; cs_uint: r2=base -> r1=1/0, value in CS_TMP
cs_uint:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#CS_BASE
ST r0,r0,#CS_TMP
ST r0,r0,#CS_DIG
csu_l:
CALL @cs_getc
CMPS r1,r0
JMP[LT] @csu_d
ST r1,r0,#CS_DST
LD r2,r0,#CS_BASE
CALL @cs_digit
CMPS r1,r0
JMP[LT] @csu_nod
ST r1,r0,#CS_PBC
LD r1,r0,#CS_TMP
LD r2,r0,#CS_BASE
MUL r1,r1,r2
LD r2,r0,#CS_PBC
ADD r1,r1,r2
ST r1,r0,#CS_TMP
MOVI r1,1
ST r1,r0,#CS_DIG
JMP @csu_l
csu_nod:
LD r1,r0,#CS_DST
CALL @cs_ungetc
csu_d:
LD r1,r0,#CS_DIG
SUB r14,r14,r13
LD r15,r14,0
RET

; cs_float -> r1=1/0, float bits in CS_TMP
cs_float:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#CSBUF
ST r1,r0,#CS_DST
ST r0,r0,#CS_DIG
ST r0,r0,#CS_I
csf_l:
LD r1,r0,#CS_DIG
MOVI r2,#CSBUFSZ
SUB r2,r2,r13
CMP r1,r2
JMP[GE] @csf_conv
CALL @cs_getc
CMPS r1,r0
JMP[LT] @csf_conv
ST r1,r0,#CS_PBC
MOVI r2,48
CMP r1,r2
JMP[LT] @csf_sign
MOVI r2,57
CMP r1,r2
JMP[LE] @csf_take
csf_sign:
LD r1,r0,#CS_PBC
MOVI r2,46
CMP r1,r2
JMP[EQ] @csf_take
MOVI r2,101
CMP r1,r2
JMP[EQ] @csf_take
MOVI r2,69
CMP r1,r2
JMP[EQ] @csf_take
MOVI r2,43
CMP r1,r2
JMP[EQ] @csf_pm
MOVI r2,45
CMP r1,r2
JMP[NE] @csf_stop
csf_pm:
LD r1,r0,#CS_DIG
CMP r1,r0
JMP[EQ] @csf_take
LD r1,r0,#CS_DST
ADDI r1,r1,-1
LDB r1,r1,0
MOVI r2,101
CMP r1,r2
JMP[EQ] @csf_take
MOVI r2,69
CMP r1,r2
JMP[NE] @csf_stop
csf_take:
LD r1,r0,#CS_DST
LD r2,r0,#CS_PBC
STB r2,r1,0
ADD r1,r1,r13
ST r1,r0,#CS_DST
LD r1,r0,#CS_DIG
ADD r1,r1,r13
ST r1,r0,#CS_DIG
LD r1,r0,#CS_PBC
MOVI r2,48
CMP r1,r2
JMP[LT] @csf_l
MOVI r2,57
CMP r1,r2
JMP[GT] @csf_l
MOVI r1,1
ST r1,r0,#CS_I
JMP @csf_l
csf_stop:
LD r1,r0,#CS_PBC
CALL @cs_ungetc
csf_conv:
LD r1,r0,#CS_DST
STB r0,r1,0
LD r1,r0,#CS_I
CMP r1,r0
JMP[EQ] @csf_bad
LA r1,#CSBUF
CALL @ni_strtod_core
ST r1,r0,#CS_TMP
MOVI r1,1
JMP @csf_d
csf_bad:
MOVI r1,0
csf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; cs_store: value in CS_TMP, requires !CS_SUP
cs_store:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#CS_SUP
CMP r1,r0
JMP[NE] @csst_ok
LD r1,r0,#CS_ARG
CALL @ni_arg
ST r1,r0,#CS_DST
LD r2,r0,#CS_TMP
MOVI r3,4
CALL @ni_storev
LD r1,r0,#CS_ARG
ADD r1,r1,r13
ST r1,r0,#CS_ARG
csst_ok:
MOVI r1,1
SUB r14,r14,r13
LD r15,r14,0
RET

; cs_dispatch: r1=conversion char -> r1=1/0
cs_dispatch:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,100
CMP r1,r2
JMP[EQ] @csdi10
MOVI r2,105
CMP r1,r2
JMP[EQ] @csdi10
MOVI r2,117
CMP r1,r2
JMP[EQ] @csdi10
MOVI r2,111
CMP r1,r2
JMP[EQ] @csdi8
MOVI r2,120
CMP r1,r2
JMP[EQ] @csdi16
MOVI r2,88
CMP r1,r2
JMP[EQ] @csdi16
MOVI r2,102
CMP r1,r2
JMP[EQ] @csdf
MOVI r2,101
CMP r1,r2
JMP[EQ] @csdf
MOVI r2,103
CMP r1,r2
JMP[EQ] @csdf
MOVI r2,115
CMP r1,r2
JMP[EQ] @csds
MOVI r2,99
CMP r1,r2
JMP[EQ] @csdc
JMP @csd_fail
csdi10:
CALL @cs_skipws
MOVI r2,10
JMP @csdi
csdi8:
CALL @cs_skipws
MOVI r2,8
JMP @csdi
csdi16:
CALL @cs_skipws
MOVI r2,16
csdi:
ST r2,r0,#CS_BASE
ST r0,r0,#CS_SGN
CALL @cs_getc
CMPS r1,r0
JMP[LT] @csd_fail
MOVI r3,45
CMP r1,r3
JMP[NE] @csdi_plus
MOVI r3,1
ST r3,r0,#CS_SGN
CALL @cs_getc
JMP @csdi_go
csdi_plus:
MOVI r3,43
CMP r1,r3
JMP[NE] @csdi_go
CALL @cs_getc
csdi_go:
CALL @cs_ungetc
LD r2,r0,#CS_BASE
CALL @cs_uint
CMP r1,r0
JMP[EQ] @csd_fail
LD r1,r0,#CS_SGN
CMP r1,r0
JMP[EQ] @csdi_store
LD r1,r0,#CS_TMP
SUB r1,r0,r1
ST r1,r0,#CS_TMP
csdi_store:
CALL @cs_store
JMP @csd_d
csdf:
CALL @cs_skipws
CALL @cs_float
CMP r1,r0
JMP[EQ] @csd_fail
CALL @cs_store
JMP @csd_d
csds:
CALL @cs_skipws
LD r1,r0,#CS_SUP
CMP r1,r0
JMP[NE] @csds_buf
LD r1,r0,#CS_ARG
CALL @ni_arg
ST r1,r0,#CS_DST
LD r1,r0,#CS_ARG
ADD r1,r1,r13
ST r1,r0,#CS_ARG
JMP @csds_go
csds_buf:
LA r1,#CSBUF
ST r1,r0,#CS_DST
csds_go:
ST r0,r0,#CS_DIG
csds_l:
CALL @cs_getc
CMPS r1,r0
JMP[LT] @csds_d
ST r1,r0,#CS_PBC
CALL @cs_isspace
CMP r1,r0
JMP[NE] @csds_e
LD r1,r0,#CS_W
CMP r1,r0
JMP[EQ] @csds_st
LD r2,r0,#CS_DIG
CMP r2,r1
JMP[GE] @csds_e
csds_st:
LD r1,r0,#CS_DST
LD r2,r0,#CS_PBC
STB r2,r1,0
ADD r1,r1,r13
ST r1,r0,#CS_DST
LD r1,r0,#CS_DIG
ADD r1,r1,r13
ST r1,r0,#CS_DIG
JMP @csds_l
csds_e:
LD r1,r0,#CS_PBC
CALL @cs_ungetc
csds_d:
LD r1,r0,#CS_DST
STB r0,r1,0
LD r1,r0,#CS_DIG
CMP r1,r0
JMP[EQ] @csd_fail
MOVI r1,1
JMP @csd_d
csdc:
LD r1,r0,#CS_SUP
CMP r1,r0
JMP[NE] @csdc_buf
LD r1,r0,#CS_ARG
CALL @ni_arg
ST r1,r0,#CS_DST
LD r1,r0,#CS_ARG
ADD r1,r1,r13
ST r1,r0,#CS_ARG
JMP @csdc_go
csdc_buf:
LA r1,#CSBUF
ST r1,r0,#CS_DST
csdc_go:
LD r1,r0,#CS_W
CMP r1,r0
JMP[NE] @csdc_w
MOVI r1,1
ST r1,r0,#CS_W
csdc_w:
ST r0,r0,#CS_DIG
csdc_l:
LD r1,r0,#CS_DIG
LD r2,r0,#CS_W
CMP r1,r2
JMP[GE] @csdc_ok
CALL @cs_getc
CMPS r1,r0
JMP[LT] @csdc_chk
LD r2,r0,#CS_DST
STB r1,r2,0
ADD r2,r2,r13
ST r2,r0,#CS_DST
LD r1,r0,#CS_DIG
ADD r1,r1,r13
ST r1,r0,#CS_DIG
JMP @csdc_l
csdc_chk:
LD r1,r0,#CS_DIG
CMP r1,r0
JMP[EQ] @csd_fail
csdc_ok:
MOVI r1,1
JMP @csd_d
csd_fail:
MOVI r1,0
csd_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; cs_run: r1=format ptr r2=first destination arg index
cs_run:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#CS_FMT
ST r2,r0,#CS_ARG
ST r0,r0,#CS_CNT
ST r0,r0,#CS_PBF
csr_l:
LD r1,r0,#CS_FMT
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @csr_done
ST r2,r0,#CS_TMP
CALL @cs_isspace
CMP r1,r0
JMP[NE] @csr_ws
LD r1,r0,#CS_TMP
MOVI r2,37
CMP r1,r2
JMP[EQ] @csr_pct
; literal
CALL @cs_getc
CMPS r1,r0
JMP[LT] @csr_done
LD r2,r0,#CS_TMP
CMP r1,r2
JMP[NE] @csr_litbad
LD r1,r0,#CS_FMT
ADD r1,r1,r13
ST r1,r0,#CS_FMT
JMP @csr_l
csr_litbad:
CALL @cs_ungetc
JMP @csr_done
csr_ws:
CALL @cs_skipws
LD r1,r0,#CS_FMT
ADD r1,r1,r13
ST r1,r0,#CS_FMT
JMP @csr_l
csr_pct:
LD r1,r0,#CS_FMT
ADD r1,r1,r13
ST r1,r0,#CS_FMT
LDB r2,r1,0
MOVI r3,37
CMP r2,r3
JMP[NE] @csr_pct2
CALL @cs_getc
MOVI r3,37
CMP r1,r3
JMP[NE] @csr_done
LD r1,r0,#CS_FMT
ADD r1,r1,r13
ST r1,r0,#CS_FMT
JMP @csr_l
csr_pct2:
ST r0,r0,#CS_SUP
MOVI r3,42
CMP r2,r3
JMP[NE] @csr_width
MOVI r3,1
ST r3,r0,#CS_SUP
LD r1,r0,#CS_FMT
ADD r1,r1,r13
ST r1,r0,#CS_FMT
LDB r2,r1,0
csr_width:
ST r0,r0,#CS_W
csr_wl:
LD r1,r0,#CS_FMT
LDB r2,r1,0
MOVI r3,48
CMP r2,r3
JMP[LT] @csr_conv
MOVI r3,57
CMP r2,r3
JMP[GT] @csr_conv
ADDI r2,r2,-48
LD r3,r0,#CS_W
MOVI r4,10
MUL r3,r3,r4
ADD r3,r3,r2
ST r3,r0,#CS_W
LD r1,r0,#CS_FMT
ADD r1,r1,r13
ST r1,r0,#CS_FMT
JMP @csr_wl
csr_conv:
LD r1,r0,#CS_FMT
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @csr_done
ST r2,r0,#CS_TMP
LD r1,r0,#CS_FMT
ADD r1,r1,r13
ST r1,r0,#CS_FMT
LD r1,r0,#CS_TMP
CALL @cs_dispatch
CMP r1,r0
JMP[EQ] @csr_done
LD r1,r0,#CS_SUP
CMP r1,r0
JMP[NE] @csr_l
LD r1,r0,#CS_CNT
ADD r1,r1,r13
ST r1,r0,#CS_CNT
JMP @csr_l
csr_done:
LD r1,r0,#CS_CNT
SUB r14,r14,r13
LD r15,r14,0
RET

; cs_finish: r1=count -> clean args and push count
cs_finish:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#CS_TMP
LD r2,r0,#R_T1
LD r3,r0,#R_SP
SUB r3,r3,r2
ST r3,r0,#R_SP
LD r1,r0,#CS_TMP
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_sscanf:
MOVI r1,0
ST r1,r0,#CS_MODE
ST r0,r0,#CS_PBF
LD r1,r0,#R_T1
ST r1,r0,#W_PF_ARGC
ST r0,r0,#W_PF_OFF
MOVI r1,0
CALL @ni_arg
ST r1,r0,#CS_SRC
MOVI r1,1
CALL @ni_arg
ST r1,r0,#CS_FMT
LD r1,r0,#CS_FMT
MOVI r2,2
CALL @cs_run
CALL @cs_finish
JMP @nbi_d

nbi_fscanf:
ST r0,r0,#CS_PBF
LD r1,r0,#R_T1
ST r1,r0,#W_PF_ARGC
ST r0,r0,#W_PF_OFF
MOVI r1,0
CALL @ni_arg
ST r1,r0,#CS_SRC
MOVI r1,1
CALL @ni_arg
ST r1,r0,#CS_FMT
; read the remaining stream bytes into CSFBUF, then reuse the string scanner
LD r1,r0,#CS_SRC
CALL @st_entry
CMP r1,r0
JMP[EQ] @csf_eof
ST r1,r0,#CS_ENT
LD r2,r1,5
LD r3,r1,3
CMP r2,r3
JMP[GE] @csf_empty
SUB r3,r3,r2
MOVI r4,8191
CMP r3,r4
JMP[LE] @csf_cap
MOVI r3,8191
csf_cap:
ST r3,r0,#CS_TMP
LD r4,r1,2
ADD r4,r4,r2
LA r5,#CS_FBUF
LD r6,r0,#CS_TMP
csf_cp:
CMP r6,r0
JMP[EQ] @csf_nul
LDB r7,r4,0
STB r7,r5,0
ADD r4,r4,r13
ADD r5,r5,r13
SUB r6,r6,r13
JMP @csf_cp
csf_nul:
STB r0,r5,0
JMP @csf_scan
csf_empty:
LA r5,#CS_FBUF
STB r0,r5,0
csf_scan:
ST r0,r0,#CS_MODE
LA r1,#CS_FBUF
ST r1,r0,#CS_SRC
LD r1,r0,#CS_FMT
MOVI r2,2
CALL @cs_run
ST r1,r0,#CS_TMP
; advance the stream by the bytes consumed
LD r2,r0,#CS_SRC
LA r3,#CS_FBUF
SUB r2,r2,r3
LD r1,r0,#CS_ENT
LD r3,r1,5
ADD r3,r3,r2
LD r4,r1,3
CMP r3,r4
JMP[LE] @csf_pos
ADD r3,r4,r0
csf_pos:
ST r3,r1,5
LD r1,r0,#CS_TMP
CALL @cs_finish
JMP @nbi_d
csf_eof:
MOVI r1,0
CALL @cs_finish
JMP @nbi_d

nbi_scanf:
MOVI r1,1
ST r1,r0,#CS_MODE
MOVI r1,1
ST r1,r0,#CS_SRC
ST r0,r0,#CS_PBF
LD r1,r0,#R_T1
ST r1,r0,#W_PF_ARGC
ST r0,r0,#W_PF_OFF
MOVI r1,0
CALL @ni_arg
ST r1,r0,#CS_FMT
LD r1,r0,#CS_FMT
MOVI r2,1
CALL @cs_run
CALL @cs_finish
JMP @nbi_d
