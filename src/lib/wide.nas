; wide.nas - wide stdio: wprintf with flags/width/precision, wscanf stub.

.equ W_WPF_FMT   61680
.equ W_WPF_OFF   61681
.equ W_WPF_CNT   61682
.equ W_WPF_IDX   61683
.equ W_WPF_LONG  61684
.equ W_WPF_TMP   61685
.equ W_WPF_CASE  61686
.equ W_WPF_OFF2  61687
.equ W_WPF_FLAGS 61730
.equ W_WPF_WIDTH 61731
.equ W_WPF_PREC  61732
.equ W_WPF_VAL   61733
.equ W_WPF_SIGN  61734
.equ W_WPF_PTR   61735
.equ W_WPF_N     61736
.equ W_WPF_TOTAL 61737
.equ W_WPF_PAD   61738
.equ W_WPF_ZERO  61739
.equ W_WPF_PBUF  61740
.equ W_WPF_PLEN  61741
.equ W_WPF_BASE  61742
.equ W_WPF_UPPER 61743
.equ W_WPF_CNT2  61744
.equ W_WPF_HASPREC 61745
.equ W_WPF_PN    61746
.equ W_WPF_PC    61747
.equ W_WPF_EP    61748
.equ W_WPF_EN    61749
.equ W_WPF_BUF   61010
.equ W_WSC_FMT   61760
.equ W_WSC_POS   61761
.equ W_WSC_NPOS  61762
.equ W_WSC_ARGIDX 61763
.equ W_WSC_NW    61764
.equ W_WSC_LEN   61765
.equ W_WSC_SUP   61766
.equ W_WSC_CH    61767
.equ W_WSC_TMP   61768
.equ W_WSC_I     61769
.equ W_WSC_NFMT  2600000
.equ W_WSC_TEMPB 2601000
.equ W_WSC_TAB   2500000
.equ W_WSC_C2    61781
.equ W_WSC_IN    61754
.equ W_WSC_SRC   61755
.equ W_WSC_STREAM 61756
.equ W_WSC_START 61757
.equ W_WSC_CNT   61758
.equ W_WSC_ARG0  61836
.equ W_WSC_RUNN  61837
.equ W_WIDE_OUT  61750
.equ W_WIDE_BUF  61751
.equ W_WIDE_LIM  61752
.equ W_WIDE_POS  61753

; ------------------------------------------------------------------ helpers

; wpf_next: read the next 32-bit wide character; r1 = char
wpf_next:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_WPF_OFF
LD r1,r0,#W_WPF_FMT
ADD r1,r1,r2
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_WPF_TMP
LD r2,r0,#W_WPF_OFF
ADDI r2,r2,4
ST r2,r0,#W_WPF_OFF
LD r1,r0,#W_WPF_TMP
SUB r14,r14,r13
LD r15,r14,0
RET

; wpf_put: r1=wide char; output its low byte
wpf_put:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,255
BOOL.8 r1,r1,r2
CALL @ncc_putc
LD r1,r0,#W_WPF_CNT
ADD r1,r1,r13
ST r1,r0,#W_WPF_CNT
SUB r14,r14,r13
LD r15,r14,0
RET

; wpf_pad: r1=count r2=char
wpf_pad:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_WPF_PN
ST r2,r0,#W_WPF_PC
wpp_l:
LD r1,r0,#W_WPF_PN
CMP r1,r0
JMP[EQ] @wpp_d
LD r1,r0,#W_WPF_PC
CALL @wpf_put
LD r2,r0,#W_WPF_PN
SUB r2,r2,r13
ST r2,r0,#W_WPF_PN
JMP @wpp_l
wpp_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; wpf_zeros: r1=count zero digits
wpf_zeros:
MOVI r2,48
JMP @wpf_pad

; wpf_udigits: r1=value r2=base r3=uppercase
; returns r1=start pointer (most significant digit), r2=length
wpf_udigits:
ST r15,r14,0
ADD r14,r14,r13
LA r4,#W_WPF_BUF+120
MOVI r5,0
CMP r1,r0
JMP[NE] @wud_l
ADDI r4,r4,-1
MOVI r6,48
STB r6,r4,0
MOVI r5,1
JMP @wud_d
wud_l:
CMP r1,r0
JMP[EQ] @wud_trim
DIVU r6,r1,r2
MUL r8,r6,r2
SUB r8,r1,r8
MOVI r9,10
CMP r8,r9
JMP[LT] @wud_num
MOVI r9,1
CMP r3,r9
JMP[EQ] @wud_up
ADDI r8,r8,87
JMP @wud_st
wud_up:
ADDI r8,r8,55
JMP @wud_st
wud_num:
ADDI r8,r8,48
wud_st:
ADDI r4,r4,-1
STB r8,r4,0
ADD r5,r5,r13
ADD r1,r6,r0
JMP @wud_l
wud_trim:
CMP r5,r0
JMP[NE] @wud_d
ADDI r4,r4,-1
MOVI r6,48
STB r6,r4,0
MOVI r5,1
wud_d:
ADD r1,r4,r0
ADD r2,r5,r0
SUB r14,r14,r13
LD r15,r14,0
RET

; wpf_emit: r1=start r2=len -> output bytes
wpf_emit:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_WPF_EP
ST r2,r0,#W_WPF_EN
wpe_l:
LD r1,r0,#W_WPF_EN
CMP r1,r0
JMP[EQ] @wpe_d
LD r2,r0,#W_WPF_EP
LDB r1,r2,0
CALL @wpf_put
LD r2,r0,#W_WPF_EP
ADD r2,r2,r13
ST r2,r0,#W_WPF_EP
LD r2,r0,#W_WPF_EN
SUB r2,r2,r13
ST r2,r0,#W_WPF_EN
JMP @wpe_l
wpe_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; wpf_prefix: r1=sign char (0 none) r2=base r3=uppercase r4=value
; builds the sign/alternate prefix in W_WPF_PBUF; W_WPF_PLEN = length
wpf_prefix:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
ST r5,r14,4
ADDI r14,r14,5
ST r0,r0,#W_WPF_PLEN
LA r5,#W_WPF_PBUF
ADDI r2,r14,-5
LD r6,r2,0
CMP r6,r0
JMP[EQ] @wpx_alt
STB r6,r5,0
ADD r5,r5,r13
MOVI r6,1
ST r6,r0,#W_WPF_PLEN
wpx_alt:
ADDI r2,r14,-5
LD r6,r2,4
CMP r6,r0
JMP[EQ] @wpx_d
ADDI r2,r14,-5
LD r6,r2,1
MOVI r7,16
CMP r6,r7
JMP[NE] @wpx_oct
ADDI r2,r14,-5
LD r7,r2,3
CMP r7,r0
JMP[EQ] @wpx_d
MOVI r6,48
STB r6,r5,0
ADD r5,r5,r13
ADDI r2,r14,-5
LD r6,r2,2
CMP r6,r0
JMP[EQ] @wpx_x
MOVI r6,88
JMP @wpx_xx
wpx_x:
MOVI r6,120
wpx_xx:
STB r6,r5,0
ADD r5,r5,r13
LD r6,r0,#W_WPF_PLEN
ADD r6,r6,r13
ADD r6,r6,r13
ST r6,r0,#W_WPF_PLEN
JMP @wpx_d
wpx_oct:
MOVI r7,8
CMP r6,r7
JMP[NE] @wpx_d
ADDI r2,r14,-5
LD r7,r2,3
CMP r7,r0
JMP[EQ] @wpx_oct_z
LD r2,r0,#W_WPF_PTR
LDB r2,r2,0
MOVI r7,48
CMP r2,r7
JMP[EQ] @wpx_d
wpx_oct_z:
MOVI r6,48
STB r6,r5,0
LD r6,r0,#W_WPF_PLEN
ADD r6,r6,r13
ST r6,r0,#W_WPF_PLEN
wpx_d:
ADDI r14,r14,-6
LD r15,r14,0
RET

; wpf_num: r1=magnitude r2=base r3=uppercase r4=sign char r5=alt flag
wpf_num:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
ST r5,r14,4
ADDI r14,r14,5
ADDI r2,r14,-5
LD r1,r2,0
ADDI r2,r14,-4
LD r2,r2,0
ADDI r3,r14,-3
LD r3,r3,0
CALL @wpf_udigits
ST r1,r0,#W_WPF_PTR
ST r2,r0,#W_WPF_N
; digits after precision: W_WPF_ZERO = padding zeros, W_WPF_N = emitted digits
ST r0,r0,#W_WPF_ZERO
LD r1,r0,#W_WPF_PREC
CMP r1,r0
JMP[LT] @wnum_noprec
ADDI r2,r14,-5
LD r2,r2,0
CMP r2,r0
JMP[NE] @wnum_padd
LD r1,r0,#W_WPF_PREC
CMP r1,r0
JMP[NE] @wnum_padd
ST r0,r0,#W_WPF_N
JMP @wnum_noprec
wnum_padd:
LD r1,r0,#W_WPF_PREC
LD r2,r0,#W_WPF_N
CMP r1,r2
JMP[LE] @wnum_noprec
SUB r1,r1,r2
ST r1,r0,#W_WPF_ZERO
wnum_noprec:
; prefix
ADDI r1,r14,-2
LD r1,r1,0
ADDI r2,r14,-4
LD r2,r2,0
ADDI r3,r14,-3
LD r3,r3,0
ADDI r4,r14,-5
LD r4,r4,0
ADDI r5,r14,-1
LD r5,r5,0
CALL @wpf_prefix
; total = plen + zero + digits
LD r1,r0,#W_WPF_PLEN
LD r2,r0,#W_WPF_ZERO
ADD r1,r1,r2
LD r2,r0,#W_WPF_N
ADD r1,r1,r2
ST r1,r0,#W_WPF_TOTAL
; pad
LD r2,r0,#W_WPF_WIDTH
CMP r2,r1
JMP[LE] @wnum_nopad
SUB r2,r2,r1
JMP @wnum_havepad
wnum_nopad:
MOVI r2,0
wnum_havepad:
ST r2,r0,#W_WPF_PAD
; left?
LD r3,r0,#W_WPF_FLAGS
MOVI r4,1
BOOL.8 r3,r3,r4
CMP r3,r0
JMP[EQ] @wnum_right
LA r1,#W_WPF_PBUF
LD r2,r0,#W_WPF_PLEN
CALL @wpf_emit
LD r1,r0,#W_WPF_ZERO
CALL @wpf_zeros
LD r1,r0,#W_WPF_PTR
LD r2,r0,#W_WPF_N
CALL @wpf_emit
LD r1,r0,#W_WPF_PAD
MOVI r2,32
CALL @wpf_pad
JMP @wnum_d
wnum_right:
LD r3,r0,#W_WPF_FLAGS
MOVI r4,2
BOOL.8 r3,r3,r4
CMP r3,r0
JMP[EQ] @wnum_space
LD r3,r0,#W_WPF_HASPREC
CMP r3,r0
JMP[NE] @wnum_space
LA r1,#W_WPF_PBUF
LD r2,r0,#W_WPF_PLEN
CALL @wpf_emit
LD r1,r0,#W_WPF_PAD
MOVI r2,48
CALL @wpf_pad
LD r1,r0,#W_WPF_ZERO
CALL @wpf_zeros
LD r1,r0,#W_WPF_PTR
LD r2,r0,#W_WPF_N
CALL @wpf_emit
JMP @wnum_d
wnum_space:
LD r1,r0,#W_WPF_PAD
MOVI r2,32
CALL @wpf_pad
LA r1,#W_WPF_PBUF
LD r2,r0,#W_WPF_PLEN
CALL @wpf_emit
LD r1,r0,#W_WPF_ZERO
CALL @wpf_zeros
LD r1,r0,#W_WPF_PTR
LD r2,r0,#W_WPF_N
CALL @wpf_emit
wnum_d:
ADDI r14,r14,-6
LD r15,r14,0
RET

; wpf_int: r1=signed flag r2=base r3=uppercase r4=alt flag
wpf_int:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
ADDI r14,r14,4
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
ST r0,r0,#W_WPF_SIGN
ADDI r2,r14,-4
LD r2,r2,0
CMP r2,r0
JMP[NE] @wi_unsigned
CMPS r1,r0
JMP[GE] @wi_pos
MOVI r2,45
ST r2,r0,#W_WPF_SIGN
SUB r1,r0,r1
JMP @wi_go
wi_pos:
LD r2,r0,#W_WPF_FLAGS
MOVI r3,4
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @wi_spc
MOVI r2,43
ST r2,r0,#W_WPF_SIGN
JMP @wi_go
wi_spc:
LD r2,r0,#W_WPF_FLAGS
MOVI r3,8
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @wi_go
MOVI r2,32
ST r2,r0,#W_WPF_SIGN
JMP @wi_go
wi_unsigned:
ST r0,r0,#W_WPF_SIGN
wi_go:
ADDI r2,r14,-4
LD r2,r2,1
ADDI r3,r14,-4
LD r3,r3,2
LD r4,r0,#W_WPF_SIGN
ADDI r5,r14,-4
LD r5,r5,3
CALL @wpf_num
ADDI r14,r14,-5
LD r15,r14,0
RET

; wpf_str: r1=wide flag
wpf_str:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ADDI r14,r14,1
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
ST r1,r0,#W_WPF_PTR
ST r0,r0,#W_WPF_CNT2
ADDI r3,r14,-1
LD r3,r3,0
CMP r3,r0
JMP[EQ] @ws_narrow
ws_wide_l:
LD r2,r0,#W_WPF_CNT2
LD r3,r0,#W_WPF_HASPREC
CMP r3,r0
JMP[EQ] @ws_wide_n
LD r3,r0,#W_WPF_PREC
CMP r2,r3
JMP[GE] @ws_have
ws_wide_n:
LD r1,r0,#W_WPF_PTR
SHL r2,r2,2
ADD r1,r1,r2
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @ws_have
LD r2,r0,#W_WPF_CNT2
ADD r2,r2,r13
ST r2,r0,#W_WPF_CNT2
JMP @ws_wide_l
ws_narrow:
LD r2,r0,#W_WPF_CNT2
LD r3,r0,#W_WPF_HASPREC
CMP r3,r0
JMP[EQ] @ws_narrow_n
LD r3,r0,#W_WPF_PREC
CMP r2,r3
JMP[GE] @ws_have
ws_narrow_n:
LD r1,r0,#W_WPF_PTR
ADD r1,r1,r2
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @ws_have
ADD r2,r2,r13
ST r2,r0,#W_WPF_CNT2
JMP @ws_narrow
ws_have:
LD r2,r0,#W_WPF_CNT2
ST r2,r0,#W_WPF_N
LD r1,r0,#W_WPF_WIDTH
CMP r1,r2
JMP[LE] @ws_nopad
SUB r1,r1,r2
JMP @ws_pad
ws_nopad:
MOVI r1,0
ws_pad:
ST r1,r0,#W_WPF_PAD
LD r2,r0,#W_WPF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @ws_put
LD r1,r0,#W_WPF_PAD
MOVI r2,32
CALL @wpf_pad
ws_put:
ADDI r1,r14,-1
LD r1,r1,0
CMP r1,r0
JMP[NE] @ws_put_wide
LD r1,r0,#W_WPF_PTR
LD r2,r0,#W_WPF_N
CALL @wpf_emit
JMP @ws_after
ws_put_wide:
ST r0,r0,#W_WPF_TMP
ws_pw_l:
LD r1,r0,#W_WPF_TMP
LD r2,r0,#W_WPF_N
CMP r1,r2
JMP[GE] @ws_after
LD r3,r0,#W_WPF_PTR
SHL r1,r1,2
ADD r1,r3,r1
MOVI r2,#SZ_32
CALL @ni_loadv
CALL @wpf_put
LD r1,r0,#W_WPF_TMP
ADD r1,r1,r13
ST r1,r0,#W_WPF_TMP
JMP @ws_pw_l
ws_after:
LD r2,r0,#W_WPF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @ws_d
LD r1,r0,#W_WPF_PAD
MOVI r2,32
CALL @wpf_pad
ws_d:
ADDI r14,r14,-2
LD r15,r14,0
RET

nbi_wprintf:
ST r0,r0,#W_PF_OFF
wprintf_body:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,0
CALL @ni_arg
ST r1,r0,#W_WPF_FMT
ST r0,r0,#W_WPF_OFF
ST r0,r0,#W_WPF_CNT
MOVI r1,1
ST r1,r0,#W_WPF_IDX
wpf_l:
CALL @wpf_next
CMP r1,r0
JMP[EQ] @wpf_done
MOVI r2,37
CMP r1,r2
JMP[EQ] @wpf_pct
CALL @wpf_put
JMP @wpf_l
wpf_pct:
ST r0,r0,#W_WPF_FLAGS
ST r0,r0,#W_WPF_WIDTH
ST r0,r0,#W_WPF_PREC
ST r0,r0,#W_WPF_HASPREC
ST r0,r0,#W_WPF_LONG
wpf_flags:
CALL @wpf_next
MOVI r2,45
CMP r1,r2
JMP[NE] @wpf_f0
LD r2,r0,#W_WPF_FLAGS
MOVI r3,1
BOOL.14 r2,r2,r3
ST r2,r0,#W_WPF_FLAGS
JMP @wpf_flags
wpf_f0:
MOVI r2,48
CMP r1,r2
JMP[NE] @wpf_fp
LD r2,r0,#W_WPF_FLAGS
MOVI r3,2
BOOL.14 r2,r2,r3
ST r2,r0,#W_WPF_FLAGS
JMP @wpf_flags
wpf_fp:
MOVI r2,43
CMP r1,r2
JMP[NE] @wpf_fs
LD r2,r0,#W_WPF_FLAGS
MOVI r3,4
BOOL.14 r2,r2,r3
ST r2,r0,#W_WPF_FLAGS
JMP @wpf_flags
wpf_fs:
MOVI r2,32
CMP r1,r2
JMP[NE] @wpf_fh
LD r2,r0,#W_WPF_FLAGS
MOVI r3,8
BOOL.14 r2,r2,r3
ST r2,r0,#W_WPF_FLAGS
JMP @wpf_flags
wpf_fh:
MOVI r2,35
CMP r1,r2
JMP[NE] @wpf_width
LD r2,r0,#W_WPF_FLAGS
MOVI r3,16
BOOL.14 r2,r2,r3
ST r2,r0,#W_WPF_FLAGS
JMP @wpf_flags
wpf_width:
MOVI r2,48
CMP r1,r2
JMP[LT] @wpf_wstar
MOVI r2,58
CMP r1,r2
JMP[GE] @wpf_wstar
LD r2,r0,#W_WPF_WIDTH
MOVI r3,10
MUL r2,r2,r3
ADDI r1,r1,-48
ADD r2,r2,r1
ST r2,r0,#W_WPF_WIDTH
JMP @wpf_width_next
wpf_width_next:
CALL @wpf_next
JMP @wpf_width
wpf_wstar:
MOVI r2,42
CMP r1,r2
JMP[NE] @wpf_prec
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
CMPS r1,r0
JMP[GE] @wpf_wpos
SUB r1,r0,r1
ST r1,r0,#W_WPF_WIDTH
LD r2,r0,#W_WPF_FLAGS
MOVI r3,1
BOOL.14 r2,r2,r3
ST r2,r0,#W_WPF_FLAGS
JMP @wpf_prec_next
wpf_wpos:
ST r1,r0,#W_WPF_WIDTH
JMP @wpf_prec_next
wpf_prec:
MOVI r2,46
CMP r1,r2
JMP[NE] @wpf_conv
MOVI r2,1
ST r2,r0,#W_WPF_HASPREC
ST r0,r0,#W_WPF_PREC
CALL @wpf_next
MOVI r2,42
CMP r1,r2
JMP[NE] @wpf_pdig
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
CMPS r1,r0
JMP[GE] @wpf_ppos
MOVI r1,0
ST r0,r0,#W_WPF_HASPREC
wpf_ppos:
ST r1,r0,#W_WPF_PREC
CALL @wpf_next
JMP @wpf_conv
wpf_pdig:
MOVI r2,48
CMP r1,r2
JMP[LT] @wpf_conv
MOVI r2,58
CMP r1,r2
JMP[GE] @wpf_conv
LD r2,r0,#W_WPF_PREC
MOVI r3,10
MUL r2,r2,r3
ADDI r1,r1,-48
ADD r2,r2,r1
ST r2,r0,#W_WPF_PREC
CALL @wpf_next
JMP @wpf_pdig
wpf_prec_next:
CALL @wpf_next
wpf_conv:
MOVI r2,108
CMP r1,r2
JMP[NE] @wpf_disp
CALL @wpf_next
MOVI r2,115
CMP r1,r2
JMP[NE] @wpf_disp
MOVI r1,1
ST r1,r0,#W_WPF_LONG
MOVI r1,115
JMP @wpf_disp
wpf_disp:
MOVI r2,100
CMP r1,r2
JMP[EQ] @wpf_sd
MOVI r2,105
CMP r1,r2
JMP[EQ] @wpf_sd
MOVI r2,117
CMP r1,r2
JMP[EQ] @wpf_ud
MOVI r2,111
CMP r1,r2
JMP[EQ] @wpf_uo
MOVI r2,120
CMP r1,r2
JMP[EQ] @wpf_ux
MOVI r2,88
CMP r1,r2
JMP[EQ] @wpf_uX
MOVI r2,99
CMP r1,r2
JMP[EQ] @wpf_c
MOVI r2,115
CMP r1,r2
JMP[EQ] @wpf_s
MOVI r2,112
CMP r1,r2
JMP[EQ] @wpf_p
MOVI r2,37
CMP r1,r2
JMP[EQ] @wpf_pc
MOVI r1,63
CALL @wpf_put
JMP @wpf_l
wpf_sd:
MOVI r1,0
MOVI r2,10
MOVI r3,0
MOVI r4,0
CALL @wpf_int
JMP @wpf_l
wpf_ud:
MOVI r1,1
MOVI r2,10
MOVI r3,0
MOVI r4,0
CALL @wpf_int
JMP @wpf_l
wpf_uo:
MOVI r1,1
MOVI r2,8
MOVI r3,0
LD r4,r0,#W_WPF_FLAGS
MOVI r5,16
BOOL.8 r4,r4,r5
CALL @wpf_int
JMP @wpf_l
wpf_ux:
MOVI r1,1
MOVI r2,16
MOVI r3,0
LD r4,r0,#W_WPF_FLAGS
MOVI r5,16
BOOL.8 r4,r4,r5
CALL @wpf_int
JMP @wpf_l
wpf_uX:
MOVI r1,1
MOVI r2,16
MOVI r3,1
LD r4,r0,#W_WPF_FLAGS
MOVI r5,16
BOOL.8 r4,r4,r5
CALL @wpf_int
JMP @wpf_l
wpf_s:
MOVI r1,0
LD r2,r0,#W_WPF_LONG
CMP r2,r0
JMP[EQ] @wpf_s2
MOVI r1,1
wpf_s2:
CALL @wpf_str
JMP @wpf_l
wpf_c:
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
ST r1,r0,#W_WPF_VAL
LD r1,r0,#W_WPF_WIDTH
MOVI r2,1
CMP r1,r2
JMP[LE] @wpf_c1
SUB r1,r1,r2
LD r2,r0,#W_WPF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @wpf_c1
MOVI r2,32
CALL @wpf_pad
wpf_c1:
LD r1,r0,#W_WPF_VAL
CALL @wpf_put
LD r1,r0,#W_WPF_WIDTH
MOVI r2,1
CMP r1,r2
JMP[LE] @wpf_l
SUB r1,r1,r2
LD r2,r0,#W_WPF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @wpf_l
MOVI r2,32
CALL @wpf_pad
JMP @wpf_l
wpf_p:
MOVI r1,1
MOVI r2,16
MOVI r3,0
MOVI r4,1
CALL @wpf_int
JMP @wpf_l
wpf_pc:
MOVI r1,37
CALL @wpf_put
JMP @wpf_l
wpf_done:
LD r1,r0,#W_CALLWORDS
LD r2,r0,#R_SP
SUB r2,r2,r1
ST r2,r0,#R_SP
LD r1,r0,#W_WPF_CNT
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

; wsc_nextw: read next wide format char -> r1
wsc_nextw:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_WSC_POS
LD r1,r0,#W_WSC_FMT
ADD r1,r1,r2
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_WSC_CH
LD r2,r0,#W_WSC_POS
ADDI r2,r2,4
ST r2,r0,#W_WSC_POS
LD r1,r0,#W_WSC_CH
SUB r14,r14,r13
LD r15,r14,0
RET

; wsc_emit: r1=char -> append low byte to the narrow format buffer
wsc_emit:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_WSC_TMP
LD r2,r0,#W_WSC_NPOS
LA r3,#W_WSC_NFMT
ADD r3,r3,r2
LD r1,r0,#W_WSC_TMP
MOVI r2,255
BOOL.8 r1,r1,r2
STB r1,r3,0
LD r2,r0,#W_WSC_NPOS
ADD r2,r2,r13
ST r2,r0,#W_WSC_NPOS
SUB r14,r14,r13
LD r15,r14,0
RET

; nbi_wscanf: translate the wide format to narrow scanf syntax, delegate to
; the narrow scanner, then widen %ls destinations.
nbi_wscanf:
ST r0,r0,#W_PF_OFF
wscanf_body:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#CS_PBF
LD r1,r0,#W_WSC_IN
CMP r1,r0
JMP[EQ] @wsc_console
MOVI r1,0
ST r1,r0,#CS_MODE
LD r1,r0,#W_WSC_SRC
ST r1,r0,#CS_SRC
JMP @wsc_src_done
wsc_console:
MOVI r1,1
ST r1,r0,#CS_MODE
MOVI r1,1
ST r1,r0,#CS_SRC
wsc_src_done:
LD r1,r0,#R_T1
ST r1,r0,#W_PF_ARGC
MOVI r1,1
ST r1,r0,#W_WSC_ARG0
ST r1,r0,#W_WSC_RUNN
MOVI r1,0
CALL @ni_arg
ST r1,r0,#W_WSC_FMT
ST r0,r0,#W_WSC_POS
ST r0,r0,#W_WSC_NPOS
LD r1,r0,#W_WSC_ARG0
ST r1,r0,#W_WSC_ARGIDX
ST r0,r0,#W_WSC_NW
wsc_l:
CALL @wsc_nextw
CMP r1,r0
JMP[EQ] @wsc_end
MOVI r2,37
CMP r1,r2
JMP[EQ] @wsc_pct
CALL @wsc_emit
JMP @wsc_l
wsc_pct:
MOVI r1,37
CALL @wsc_emit
ST r0,r0,#W_WSC_LEN
ST r0,r0,#W_WSC_SUP
wsc_flags:
CALL @wsc_nextw
MOVI r2,45
CMP r1,r2
JMP[EQ] @wsc_flag
MOVI r2,43
CMP r1,r2
JMP[EQ] @wsc_flag
MOVI r2,32
CMP r1,r2
JMP[EQ] @wsc_flag
MOVI r2,35
CMP r1,r2
JMP[EQ] @wsc_flag
MOVI r2,48
CMP r1,r2
JMP[EQ] @wsc_flag
MOVI r2,42
CMP r1,r2
JMP[NE] @wsc_width
MOVI r2,1
ST r2,r0,#W_WSC_SUP
CALL @wsc_emit
JMP @wsc_flags
wsc_flag:
CALL @wsc_emit
JMP @wsc_flags
wsc_width:
MOVI r2,48
CMP r1,r2
JMP[LT] @wsc_wstar
MOVI r2,58
CMP r1,r2
JMP[GE] @wsc_wstar
wsc_wdig:
CALL @wsc_emit
CALL @wsc_nextw
MOVI r2,48
CMP r1,r2
JMP[LT] @wsc_wend
MOVI r2,58
CMP r1,r2
JMP[LT] @wsc_wdig
wsc_wend:
wsc_wstar:
MOVI r2,42
CMP r1,r2
JMP[NE] @wsc_dot
CALL @wsc_emit
LD r2,r0,#W_WSC_ARGIDX
ADD r2,r2,r13
ST r2,r0,#W_WSC_ARGIDX
CALL @wsc_nextw
JMP @wsc_dot
wsc_dot:
MOVI r2,46
CMP r1,r2
JMP[NE] @wsc_len
CALL @wsc_emit
CALL @wsc_nextw
MOVI r2,42
CMP r1,r2
JMP[NE] @wsc_pdig
CALL @wsc_emit
LD r2,r0,#W_WSC_ARGIDX
ADD r2,r2,r13
ST r2,r0,#W_WSC_ARGIDX
CALL @wsc_nextw
JMP @wsc_len
wsc_pdig:
MOVI r2,48
CMP r1,r2
JMP[LT] @wsc_len
MOVI r2,58
CMP r1,r2
JMP[GE] @wsc_len
CALL @wsc_emit
CALL @wsc_nextw
JMP @wsc_pdig
wsc_len:
MOVI r2,104
CMP r1,r2
JMP[EQ] @wsc_len_h
MOVI r2,108
CMP r1,r2
JMP[EQ] @wsc_len_l
MOVI r2,76
CMP r1,r2
JMP[EQ] @wsc_len_L
JMP @wsc_conv
wsc_len_h:
MOVI r2,1
ST r2,r0,#W_WSC_LEN
JMP @wsc_len_next
wsc_len_l:
LD r2,r0,#W_WSC_LEN
ADD r2,r2,r13
ST r2,r0,#W_WSC_LEN
JMP @wsc_len_next
wsc_len_L:
MOVI r2,1
ST r2,r0,#W_WSC_LEN
JMP @wsc_len_next
wsc_len_next:
CALL @wsc_nextw
JMP @wsc_len
wsc_conv:
ST r1,r0,#W_WSC_CH
MOVI r2,115
CMP r1,r2
JMP[NE] @wsc_other
LD r2,r0,#W_WSC_LEN
CMP r2,r0
JMP[EQ] @wsc_other
; %ls -> %s, remember the destination for widening
MOVI r1,115
CALL @wsc_emit
LD r2,r0,#W_WSC_SUP
CMP r2,r0
JMP[NE] @wsc_l
LD r2,r0,#W_WSC_NW
MOVI r3,16
CMP r2,r3
JMP[GE] @wsc_wskip
; original pointer
LD r1,r0,#W_WSC_ARGIDX
CALL @ni_arg
ST r1,r0,#W_WSC_TMP
; table entry
LD r2,r0,#W_WSC_NW
SHL r2,r2,3
LA r3,#W_WSC_TAB
ADD r3,r3,r2
LD r1,r0,#W_WSC_TMP
ST r1,r3,0
; temp buffer
LD r2,r0,#W_WSC_NW
SHL r2,r2,8
LA r1,#W_WSC_TEMPB
ADD r1,r1,r2
ST r1,r3,1
; replace the argument slot with the temp pointer
LD r2,r0,#W_WSC_ARGIDX
LD r3,r0,#R_SP
LD r4,r0,#R_T1
SUB r3,r3,r4
ADD r3,r3,r2
ST r1,r3,0
; count
LD r2,r0,#W_WSC_NW
ADD r2,r2,r13
ST r2,r0,#W_WSC_NW
wsc_wskip:
LD r2,r0,#W_WSC_ARGIDX
ADD r2,r2,r13
ST r2,r0,#W_WSC_ARGIDX
JMP @wsc_l
wsc_other:
; emit any length modifier (h/l/L), then the conversion
LD r2,r0,#W_WSC_LEN
CMP r2,r0
JMP[EQ] @wsc_conv_emit
LD r3,r0,#W_WSC_CH
MOVI r4,104
CMP r3,r4
JMP[EQ] @wsc_emit_h
wsc_emit_l:
MOVI r1,108
CALL @wsc_emit
SUB r2,r2,r13
ST r2,r0,#W_WSC_LEN
CMP r2,r0
JMP[NE] @wsc_emit_l
JMP @wsc_conv_emit
wsc_emit_h:
MOVI r1,104
CALL @wsc_emit
ST r0,r0,#W_WSC_LEN
wsc_conv_emit:
LD r1,r0,#W_WSC_CH
CALL @wsc_emit
LD r2,r0,#W_WSC_SUP
CMP r2,r0
JMP[NE] @wsc_l
LD r2,r0,#W_WSC_CH
MOVI r3,37
CMP r2,r3
JMP[EQ] @wsc_l
MOVI r3,110
CMP r2,r3
JMP[EQ] @wsc_l
LD r2,r0,#W_WSC_ARGIDX
ADD r2,r2,r13
ST r2,r0,#W_WSC_ARGIDX
JMP @wsc_l
wsc_end:
LD r2,r0,#W_WSC_NPOS
LA r3,#W_WSC_NFMT
ADD r3,r3,r2
STB r0,r3,0
LA r1,#W_WSC_NFMT
LD r2,r0,#W_WSC_RUNN
CALL @cs_run
ST r1,r0,#W_WSC_CNT
; stream input: advance the FILE position by the bytes consumed
LD r1,r0,#W_WSC_IN
MOVI r2,2
CMP r1,r2
JMP[NE] @wsc_no_adv
LD r1,r0,#CS_SRC
LD r2,r0,#W_WSC_START
SUB r1,r1,r2
ST r1,r0,#W_ISO_TMP
LD r2,r0,#W_WSC_STREAM
LD r3,r2,5
ADD r3,r3,r1
LD r4,r2,3
CMP r3,r4
JMP[LE] @wsc_adv_ok
ADD r3,r4,r0
wsc_adv_ok:
ST r3,r2,5
wsc_no_adv:
LD r1,r0,#W_WSC_CNT
CALL @cs_finish
; widen %ls buffers
ST r0,r0,#W_WSC_I
wsc_w_l:
LD r1,r0,#W_WSC_I
LD r2,r0,#W_WSC_NW
CMP r1,r2
JMP[GE] @wsc_d
SHL r1,r1,3
LA r2,#W_WSC_TAB
ADD r2,r2,r1
LD r1,r2,0
ST r1,r0,#W_WSC_TMP
LD r1,r2,1
ST r1,r0,#W_WSC_CH
ST r0,r0,#W_WSC_POS
wsc_w_ch:
LD r2,r0,#W_WSC_CH
LD r3,r0,#W_WSC_POS
ADD r1,r2,r3
LDB r4,r1,0
ST r4,r0,#W_WSC_C2
LD r1,r0,#W_WSC_TMP
LD r3,r0,#W_WSC_POS
SHL r3,r3,2
ADD r1,r1,r3
ADD r2,r4,r0
MOVI r3,#SZ_32
CALL @ni_storev
LD r4,r0,#W_WSC_C2
CMP r4,r0
JMP[EQ] @wsc_w_next
LD r2,r0,#W_WSC_POS
ADD r2,r2,r13
ST r2,r0,#W_WSC_POS
JMP @wsc_w_ch
wsc_w_next:
LD r2,r0,#W_WSC_I
ADD r2,r2,r13
ST r2,r0,#W_WSC_I
JMP @wsc_w_l
wsc_d:
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d

ncc_s_wprintf:
.str "wprintf"
ncc_s_wscanf:
.str "wscanf"
