; vprintf.nas - vprintf/vfprintf/vsprintf/vsnprintf (raw NaN16).
; The format is scanned to copy the va_list words onto the eval stack in the
; order ni_printf expects, then the normal printf formatter runs unchanged.

.equ W_VA_FMT    0xF073A
.equ W_VA_AP     0xF073B
.equ W_VA_WORDS  0xF073C
.equ W_VA_FP     0xF073D
.equ W_VA_CH     0xF073E
.equ W_VA_LEN    0xF073F
.equ W_VA_STREAM 0xF0740
.equ W_VA_DST    0xF0741
.equ W_VA_N      0xF0742
.equ W_VA_LIM    0xF0743

; va_arg_word: read one 32-bit word at W_VA_AP and advance it
va_arg_word:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_VA_AP
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_VA_CH
LD r2,r0,#W_VA_AP
ADDI r2,r2,4
ST r2,r0,#W_VA_AP
LD r1,r0,#W_VA_CH
SUB r14,r14,r13
LD r15,r14,0
RET

; va_push_word: copy one va_list word to the eval stack
va_push_word:
ST r15,r14,0
ADD r14,r14,r13
CALL @va_arg_word
ST r1,r0,#W_VA_CH
CALL @ni_push
LD r2,r0,#W_VA_WORDS
ADD r2,r2,r13
ST r2,r0,#W_VA_WORDS
LD r1,r0,#W_VA_CH
SUB r14,r14,r13
LD r15,r14,0
RET

; va_build: push format and its varargs; sets W_CALLWORDS
va_build:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_VA_FMT
CALL @ni_push
MOVI r1,1
ST r1,r0,#W_VA_WORDS
LD r1,r0,#W_VA_FMT
ST r1,r0,#W_VA_FP
ST r0,r0,#W_VA_LEN
vab_l:
LD r1,r0,#W_VA_FP
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @vab_done
MOVI r3,37
CMP r2,r3
JMP[EQ] @vab_pct
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
JMP @vab_l
vab_pct:
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
vab_flags:
LD r1,r0,#W_VA_FP
LDB r2,r1,0
MOVI r3,45
CMP r2,r3
JMP[EQ] @vab_flag
MOVI r3,43
CMP r2,r3
JMP[EQ] @vab_flag
MOVI r3,32
CMP r2,r3
JMP[EQ] @vab_flag
MOVI r3,35
CMP r2,r3
JMP[EQ] @vab_flag
MOVI r3,48
CMP r2,r3
JMP[EQ] @vab_flag
JMP @vab_width
vab_flag:
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
JMP @vab_flags
vab_width:
MOVI r3,48
CMP r2,r3
JMP[LT] @vab_wstar
MOVI r3,58
CMP r2,r3
JMP[GE] @vab_wstar
vab_wdig:
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
MOVI r3,48
CMP r2,r3
JMP[LT] @vab_wend
MOVI r3,58
CMP r2,r3
JMP[LT] @vab_wdig
vab_wend:
vab_wstar:
MOVI r3,42
CMP r2,r3
JMP[NE] @vab_prec
CALL @va_push_word
LD r1,r0,#W_VA_FP
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
vab_prec:
MOVI r3,46
CMP r2,r3
JMP[NE] @vab_len
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
MOVI r3,42
CMP r2,r3
JMP[NE] @vab_pdig
CALL @va_push_word
LD r1,r0,#W_VA_FP
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
JMP @vab_len
vab_pdig:
MOVI r3,48
CMP r2,r3
JMP[LT] @vab_len
MOVI r3,58
CMP r2,r3
JMP[GE] @vab_len
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
JMP @vab_pdig
vab_len:
MOVI r3,104
CMP r2,r3
JMP[EQ] @vab_len_h
MOVI r3,108
CMP r2,r3
JMP[EQ] @vab_len_l
MOVI r3,76
CMP r2,r3
JMP[EQ] @vab_len_one
MOVI r3,106
CMP r2,r3
JMP[EQ] @vab_len_one
MOVI r3,122
CMP r2,r3
JMP[EQ] @vab_len_one
MOVI r3,116
CMP r2,r3
JMP[EQ] @vab_len_one
JMP @vab_conv
vab_len_h:
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
MOVI r3,104
CMP r2,r3
JMP[NE] @vab_conv
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
JMP @vab_conv
vab_len_l:
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
MOVI r3,108
CMP r2,r3
JMP[NE] @vab_conv
MOVI r3,2
ST r3,r0,#W_VA_LEN
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
JMP @vab_conv
vab_len_one:
MOVI r3,1
ST r3,r0,#W_VA_LEN
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
LDB r2,r1,0
vab_conv:
MOVI r3,37
CMP r2,r3
JMP[EQ] @vab_adv
LD r3,r0,#W_VA_LEN
MOVI r4,2
CMP r3,r4
JMP[NE] @vab_one
; ll with an integer conversion consumes two words
MOVI r3,100
CMP r2,r3
JMP[EQ] @vab_two
MOVI r3,105
CMP r2,r3
JMP[EQ] @vab_two
MOVI r3,117
CMP r2,r3
JMP[EQ] @vab_two
MOVI r3,111
CMP r2,r3
JMP[EQ] @vab_two
MOVI r3,120
CMP r2,r3
JMP[EQ] @vab_two
MOVI r3,88
CMP r2,r3
JMP[EQ] @vab_two
JMP @vab_one
vab_two:
CALL @va_push_word
CALL @va_push_word
JMP @vab_adv
vab_one:
MOVI r3,100
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,105
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,117
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,111
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,120
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,88
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,99
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,115
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,112
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,110
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,102
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,101
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,69
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,103
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,71
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,97
CMP r2,r3
JMP[EQ] @vab_push
MOVI r3,65
CMP r2,r3
JMP[EQ] @vab_push
JMP @vab_adv
vab_push:
CALL @va_push_word
vab_adv:
LD r1,r0,#W_VA_FP
ADDI r1,r1,1
ST r1,r0,#W_VA_FP
ST r0,r0,#W_VA_LEN
JMP @vab_l
vab_done:
LD r1,r0,#W_VA_WORDS
ST r1,r0,#W_CALLWORDS
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ wrappers

nbi_vprintf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_VA_FMT
; format into the shared buffer so the return count is exact
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
LA r1,#FMTBUF
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
LA r1,#FMTBUFSZ
SUB r1,r1,r13
ST r1,r0,#W_SNLIM
ST r0,r0,#W_PF_OFF
CALL @va_build
LD r1,r0,#W_VA_WORDS
CALL @ni_printf
CALL @ni_pop
LD r1,r0,#W_SNOUT
LD r2,r0,#W_SNPOS
ADD r1,r1,r2
STB r0,r1,0
LD r1,r0,#W_SNPOS
ST r1,r0,#W_VA_N
; restore and emit
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
LA r1,#FMTBUF
CALL @ni_puts
LD r1,r0,#W_VA_N
CALL @ni_push
JMP @nbi_d

nbi_vfprintf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_VA_FMT
CALL @ni_pop
ST r1,r0,#W_VA_STREAM
; save output state
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
LA r1,#FMTBUF
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
LA r1,#FMTBUFSZ
SUB r1,r1,r13
ST r1,r0,#W_SNLIM
ST r0,r0,#W_PF_OFF
CALL @va_build
LD r1,r0,#W_VA_WORDS
CALL @ni_printf
CALL @ni_pop
LD r1,r0,#W_SNPOS
ST r1,r0,#W_VA_N
; terminate the buffer
LD r1,r0,#W_SNOUT
LD r2,r0,#W_SNPOS
ADD r1,r1,r2
STB r0,r1,0
; restore output state
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
; emit to the stream
LD r1,r0,#W_VA_STREAM
MOVI r2,4
CMP r1,r2
JMP[GE] @nvf_file
LA r1,#FMTBUF
CALL @ni_puts
JMP @nvf_done
nvf_file:
CALL @st_entry
CMP r1,r0
JMP[EQ] @nvf_done
LA r2,#FMTBUF
LD r3,r0,#W_VA_N
CALL @st_write_buf
nvf_done:
LD r1,r0,#W_VA_N
CALL @ni_push
JMP @nbi_d

nbi_vsprintf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_VA_FMT
CALL @ni_pop
ST r1,r0,#W_VA_DST
; save output state
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
LD r1,r0,#W_VA_DST
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
LA r1,0xFFFFFFFF
ST r1,r0,#W_SNLIM
ST r0,r0,#W_PF_OFF
CALL @va_build
LD r1,r0,#W_VA_WORDS
CALL @ni_printf
CALL @ni_pop
LD r1,r0,#W_SNPOS
ST r1,r0,#W_VA_N
; terminate
LD r1,r0,#W_SNOUT
LD r2,r0,#W_SNPOS
ADD r1,r1,r2
STB r0,r1,0
; restore output
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
LD r1,r0,#W_VA_N
CALL @ni_push
JMP @nbi_d

nbi_vsnprintf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_VA_FMT
CALL @ni_pop
ST r1,r0,#W_VA_LIM
CALL @ni_pop
ST r1,r0,#W_VA_DST
; save output state
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
LD r1,r0,#W_VA_DST
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
LD r1,r0,#W_VA_LIM
ST r1,r0,#W_SNLIM
ST r0,r0,#W_PF_OFF
CALL @va_build
LD r1,r0,#W_VA_WORDS
CALL @ni_printf
CALL @ni_pop
LD r1,r0,#W_SNPOS
ST r1,r0,#W_VA_N
; terminate within the limit
LD r3,r0,#W_VA_LIM
CMP r3,r0
JMP[EQ] @nvs_no_nul
LD r1,r0,#W_SNOUT
LD r2,r0,#W_SNPOS
SUB r3,r3,r13
CMP r2,r3
JMP[LE] @nvs_at
ADD r2,r3,r0
nvs_at:
ADD r1,r1,r2
STB r0,r1,0
nvs_no_nul:
; restore output
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
LD r1,r0,#W_VA_N
CALL @ni_push
JMP @nbi_d

ncc_s_vprintf:
.str "vprintf"
ncc_s_vfprintf:
.str "vfprintf"
ncc_s_vsprintf:
.str "vsprintf"
ncc_s_vsnprintf:
.str "vsnprintf"
ncc_s_isalnum:
.str "isalnum"
ncc_s_iscntrl:
.str "iscntrl"
ncc_s_isgraph:
.str "isgraph"
ncc_s_isprint:
.str "isprint"
ncc_s_ispunct:
.str "ispunct"
ncc_s_isxdigit:
.str "isxdigit"
ncc_s_atol:
.str "atol"
ncc_s_atoll:
.str "atoll"
ncc_s_abort:
.str "abort"
ncc_s_setbuf:
.str "setbuf"
