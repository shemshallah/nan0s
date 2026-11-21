; wide.nas - minimal wide stdio (wprintf subset, wscanf stub).

.equ W_WPF_FMT 61680
.equ W_WPF_OFF 61681
.equ W_WPF_CNT 61682
.equ W_WPF_IDX 61683
.equ W_WPF_LEN 61684
.equ W_WPF_TMP 61685
.equ W_WPF_CASE 61686
.equ W_WPF_OFF2 61687

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

; wpf_put: r1=wide char, low byte to output
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

nbi_wprintf:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_PF_OFF
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
JMP[NE] @wpf_lit
CALL @wpf_next
ST r0,r0,#W_WPF_LEN
wpf_skip:
MOVI r2,48
CMP r1,r2
JMP[LT] @wpf_nodigit
MOVI r2,57
CMP r1,r2
JMP[LE] @wpf_nextch
wpf_nodigit:
MOVI r2,45
CMP r1,r2
JMP[EQ] @wpf_nextch
MOVI r2,43
CMP r1,r2
JMP[EQ] @wpf_nextch
MOVI r2,32
CMP r1,r2
JMP[EQ] @wpf_nextch
MOVI r2,35
CMP r1,r2
JMP[EQ] @wpf_nextch
MOVI r2,46
CMP r1,r2
JMP[EQ] @wpf_nextch
MOVI r2,108
CMP r1,r2
JMP[EQ] @wpf_setlen
JMP @wpf_conv
wpf_nextch:
CALL @wpf_next
JMP @wpf_skip
wpf_setlen:
MOVI r1,1
ST r1,r0,#W_WPF_LEN
CALL @wpf_next
wpf_conv:
MOVI r2,37
CMP r1,r2
JMP[EQ] @wpf_pct
MOVI r2,100
CMP r1,r2
JMP[EQ] @wpf_int
MOVI r2,105
CMP r1,r2
JMP[EQ] @wpf_int
MOVI r2,117
CMP r1,r2
JMP[EQ] @wpf_uint
MOVI r2,120
CMP r1,r2
JMP[EQ] @wpf_hexl
MOVI r2,88
CMP r1,r2
JMP[EQ] @wpf_hexu
MOVI r2,115
CMP r1,r2
JMP[EQ] @wpf_str
MOVI r2,99
CMP r1,r2
JMP[EQ] @wpf_chr
MOVI r1,63
CALL @wpf_put
JMP @wpf_l
wpf_pct:
MOVI r1,37
CALL @wpf_put
JMP @wpf_l
wpf_int:
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
ST r1,r0,#W_WPF_TMP
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
ADD r1,r1,r0
CALL @ni_decdigits
LD r3,r0,#W_WPF_CNT
ADD r3,r3,r2
ST r3,r0,#W_WPF_CNT
LD r5,r0,#W_WPF_TMP
CALL @putdec
JMP @wpf_l
wpf_uint:
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
ST r1,r0,#W_WPF_TMP
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
ADD r1,r1,r0
CALL @ni_decdigits
LD r3,r0,#W_WPF_CNT
ADD r3,r3,r2
ST r3,r0,#W_WPF_CNT
LD r5,r0,#W_WPF_TMP
CALL @putudec
JMP @wpf_l
wpf_hexl:
ST r0,r0,#W_WPF_CASE
JMP @wpf_hex
wpf_hexu:
MOVI r1,1
ST r1,r0,#W_WPF_CASE
wpf_hex:
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
ST r1,r0,#W_WPF_TMP
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
LA r7,11021400
MOVI r6,0
LD r4,r0,#W_WPF_TMP
CMP r4,r0
JMP[NE] @wpf_hexl_l
MOVI r1,48
CALL @wpf_put
JMP @wpf_l
wpf_hexl_l:
MOVI r3,15
BOOL.8 r3,r4,r3
MOVI r2,9
CMP r3,r2
JMP[LE] @wpf_hexn
MOVI r2,1
LD r1,r0,#W_WPF_CASE
CMP r1,r2
JMP[EQ] @wpf_hexup
ADDI r3,r3,87
JMP @wpf_hexst
wpf_hexup:
ADDI r3,r3,55
JMP @wpf_hexst
wpf_hexn:
ADDI r3,r3,48
wpf_hexst:
ADD r5,r7,r6
STB r3,r5,0
ADD r6,r6,r13
SHR r4,r4,4
CMP r4,r0
JMP[NE] @wpf_hexl_l
ADDI r6,r6,-1
wpf_hexp:
ADD r5,r7,r6
LDB r1,r5,0
CALL @wpf_put
ADDI r6,r6,-1
CMPS r6,r0
JMP[GE] @wpf_hexp
JMP @wpf_l
wpf_str:
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
ST r1,r0,#W_WPF_TMP
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
LD r1,r0,#W_WPF_LEN
CMP r1,r0
JMP[NE] @wpf_wstr
LD r1,r0,#W_WPF_TMP
CALL @ni_strlen
LD r3,r0,#W_WPF_CNT
ADD r3,r3,r1
ST r3,r0,#W_WPF_CNT
LD r1,r0,#W_WPF_TMP
CALL @ni_puts
JMP @wpf_l
wpf_wstr:
LD r1,r0,#W_WPF_TMP
ST r1,r0,#W_WPF_OFF2
wpf_ws_l:
LD r1,r0,#W_WPF_OFF2
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @wpf_l
CALL @wpf_put
LD r1,r0,#W_WPF_OFF2
ADDI r1,r1,4
ST r1,r0,#W_WPF_OFF2
JMP @wpf_ws_l
wpf_chr:
LD r1,r0,#W_WPF_IDX
CALL @ni_arg
LD r2,r0,#W_WPF_IDX
ADD r2,r2,r13
ST r2,r0,#W_WPF_IDX
CALL @wpf_put
JMP @wpf_l
wpf_lit:
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

nbi_wscanf:
LD r1,r0,#W_CALLWORDS
LD r2,r0,#R_SP
SUB r2,r2,r1
ST r2,r0,#R_SP
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

ncc_s_wprintf:
.str "wprintf"
ncc_s_wscanf:
.str "wscanf"
