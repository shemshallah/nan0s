; mbs.nas - restartable multibyte conversions (ASCII subset), llabs,
; strncat, remquo, and strtof/strtold aliases (raw NaN16).
;
; The multibyte encoding is plain ASCII: every byte is one wide character and
; mbstate_t always describes the initial state.  mbsrtowcs/wcsrtombs follow the
; C rules for the source-pointer writeback (dst == NULL leaves *src untouched).

nbi_mbsinit:
CALL @ni_pop
MOVI r1,1
CALL @ni_push
JMP @nbi_d

nbi_mbrlen:
CALL @ni_pop            ; ps
CALL @ni_pop            ; n
ADD r8,r1,r0
CALL @ni_pop            ; s
CMP r1,r0
JMP[EQ] @mbl_zero
CMP r8,r0
JMP[EQ] @mbl_minus2
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mbl_zero
MOVI r1,1
CALL @ni_push
JMP @nbi_d
mbl_zero:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
mbl_minus2:
LA r1,0xFFFFFFFE
CALL @ni_push
JMP @nbi_d

nbi_mbrtowc:
CALL @ni_pop            ; ps
CALL @ni_pop            ; n
ADD r8,r1,r0
CALL @ni_pop            ; s
ADD r7,r1,r0
CALL @ni_pop            ; pwc
ADD r6,r1,r0
CMP r7,r0
JMP[EQ] @mbw_zero
CMP r8,r0
JMP[EQ] @mbw_minus2
LDB r2,r7,0
CMP r2,r0
JMP[EQ] @mbw_zero
CMP r6,r0
JMP[EQ] @mbw_ret
ADD r1,r6,r0
ADD r2,r2,r0
MOVI r3,#SZ_32
CALL @ni_storev
mbw_ret:
MOVI r1,1
CALL @ni_push
JMP @nbi_d
mbw_zero:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
mbw_minus2:
LA r1,0xFFFFFFFE
CALL @ni_push
JMP @nbi_d

nbi_wcrtomb:
CALL @ni_pop            ; ps
CALL @ni_pop            ; wc
ADD r8,r1,r0
CALL @ni_pop            ; s
ADD r7,r1,r0
CMP r7,r0
JMP[EQ] @wcm_one
CMPS r8,r0
JMP[LT] @wcm_err
MOVI r2,255
CMP r8,r2
JMP[GT] @wcm_err
STB r8,r7,0
MOVI r1,1
CALL @ni_push
JMP @nbi_d
wcm_one:
MOVI r1,1
CALL @ni_push
JMP @nbi_d
wcm_err:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

; mbsrtowcs(dst, &src, len, ps)
nbi_mbsrtowcs:
CALL @ni_pop            ; ps
CALL @ni_pop            ; len
ST r1,r0,#W_W2C
CALL @ni_pop            ; &src
ST r1,r0,#W_W2A
CALL @ni_pop            ; dst
ST r1,r0,#W_W2B
ST r0,r0,#W_W2D
LD r1,r0,#W_W2A
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_W2E
mrw_l:
LD r1,r0,#W_W2B
CMP r1,r0
JMP[EQ] @mrw_dstnull
LD r1,r0,#W_W2D
LD r2,r0,#W_W2C
CMP r1,r2
JMP[GE] @mrw_stop
mrw_dstnull:
LD r1,r0,#W_W2E
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mrw_nul
LD r3,r0,#W_W2B
CMP r3,r0
JMP[EQ] @mrw_adv
LD r1,r0,#W_W2D
SHL r1,r1,2
ADD r1,r3,r1
ADD r2,r2,r0
CALL @w2_store
mrw_adv:
LD r1,r0,#W_W2D
ADD r1,r1,r13
ST r1,r0,#W_W2D
LD r1,r0,#W_W2E
ADDI r1,r1,1
ST r1,r0,#W_W2E
JMP @mrw_l
mrw_nul:
LD r3,r0,#W_W2B
CMP r3,r0
JMP[EQ] @mrw_ret        ; dst == NULL: *src is not modified
LD r1,r0,#W_W2D
SHL r1,r1,2
ADD r1,r3,r1
MOVI r2,0
CALL @w2_store
LD r1,r0,#W_W2A
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
JMP @mrw_ret
mrw_stop:
LD r1,r0,#W_W2A
LD r2,r0,#W_W2E
MOVI r3,#SZ_32
CALL @ni_storev
mrw_ret:
LD r1,r0,#W_W2D
CALL @ni_push
JMP @nbi_d

; wcsrtombs(dst, &src, len, ps)
nbi_wcsrtombs:
CALL @ni_pop            ; ps
CALL @ni_pop            ; len
ST r1,r0,#W_W2C
CALL @ni_pop            ; &src
ST r1,r0,#W_W2A
CALL @ni_pop            ; dst
ST r1,r0,#W_W2B
ST r0,r0,#W_W2D
LD r1,r0,#W_W2A
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_W2E
wsm_l:
LD r1,r0,#W_W2B
CMP r1,r0
JMP[EQ] @wsm_dstnull
LD r1,r0,#W_W2D
LD r2,r0,#W_W2C
CMP r1,r2
JMP[GE] @wsm_stop
wsm_dstnull:
LD r1,r0,#W_W2E
CALL @w2_load
CMPS r1,r0
JMP[LT] @wsm_err
CMP r1,r0
JMP[EQ] @wsm_nul
MOVI r2,255
CMP r1,r2
JMP[GT] @wsm_err
LD r3,r0,#W_W2B
CMP r3,r0
JMP[EQ] @wsm_adv
LD r2,r0,#W_W2D
ADD r2,r3,r2
STB r1,r2,0
wsm_adv:
LD r1,r0,#W_W2D
ADD r1,r1,r13
ST r1,r0,#W_W2D
LD r1,r0,#W_W2E
ADDI r1,r1,4
ST r1,r0,#W_W2E
JMP @wsm_l
wsm_nul:
LD r3,r0,#W_W2B
CMP r3,r0
JMP[EQ] @wsm_ret        ; dst == NULL: *src is not modified
LD r2,r0,#W_W2D
ADD r2,r3,r2
STB r0,r2,0
LD r1,r0,#W_W2A
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
JMP @wsm_ret
wsm_stop:
LD r1,r0,#W_W2A
LD r2,r0,#W_W2E
MOVI r3,#SZ_32
CALL @ni_storev
wsm_ret:
LD r1,r0,#W_W2D
CALL @ni_push
JMP @nbi_d
wsm_err:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

; strncat(dst, src, n) - always NUL-terminates, returns dst.
nbi_strncat:
CALL @ni_pop
ADD r9,r1,r0            ; n
CALL @ni_pop
ADD r8,r1,r0            ; src
CALL @ni_pop
ADD r7,r1,r0            ; dst
ST r7,r0,#W_W2B
nscat_find:
LDB r2,r7,0
CMP r2,r0
JMP[EQ] @nscat_l
ADD r7,r7,r13
JMP @nscat_find
nscat_l:
CMP r9,r0
JMP[LE] @nscat_nul
LDB r2,r8,0
CMP r2,r0
JMP[EQ] @nscat_nul
STB r2,r7,0
ADD r7,r7,r13
ADD r8,r8,r13
SUB r9,r9,r13
JMP @nscat_l
nscat_nul:
STB r0,r7,0
LD r1,r0,#W_W2B
CALL @ni_push
JMP @nbi_d

; llabs(x): 64-bit absolute value.  Handle both a promoted long long
; argument (two words) and an unprototyped int argument (one word).
nbi_llabs:
LD r1,r0,#W_CALLWORDS
MOVI r2,2
CMP r1,r2
JMP[EQ] @lla_two
CALL @ni_pop
ADD r7,r1,r0
ST r7,r0,#W_LLD0
ST r0,r0,#W_LLD1
CMPS r7,r0
JMP[GE] @lla_push
LA r8,0xFFFFFFFF
ST r8,r0,#W_LLD1
JMP @lla_push
lla_two:
CALL @ni_pop
ST r1,r0,#W_LLD1
CALL @ni_pop
ST r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CMPS r2,r0
JMP[GE] @lla_push
LD r1,r0,#W_LLD0
CALL @ll_neg_pair
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
lla_push:
LD r1,r0,#W_LLD0
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
JMP @nbi_d

; remquo(x, y, &quo) - the remainder is computed exactly like remainder()
; and the low bits of the rounded quotient are stored in *quo.
nbi_remquo:
CALL @ni_pop
ST r1,r0,#W_TA          ; &quo
CALL @ni_pop
ST r1,r0,#W_F2P         ; y
CALL @ni_pop
ST r1,r0,#W_F2V         ; x
LD r2,r0,#W_F2P
FDIV r1,r1,r2
CALL @ni_round_even_bits
ST r1,r0,#W_F2S         ; rounded q as float
CVTFI r3,r1
LD r4,r0,#W_TA
CMP r4,r0
JMP[EQ] @nrq_rem
ADD r1,r4,r0
ADD r2,r3,r0
MOVI r3,#SZ_32
CALL @ni_storev
nrq_rem:
LD r1,r0,#W_F2S
LD r2,r0,#W_F2P
FMUL r1,r1,r2
LD r2,r0,#W_F2V
FSUB r1,r2,r1
CALL @ni_push
JMP @nbi_d

ncc_s_strtof:
.str "strtof"
ncc_s_strtold:
.str "strtold"
ncc_s_llabs:
.str "llabs"
ncc_s_strncat:
.str "strncat"
ncc_s_remquo:
.str "remquo"
ncc_s_mbsinit:
.str "mbsinit"
ncc_s_mbrlen:
.str "mbrlen"
ncc_s_mbrtowc:
.str "mbrtowc"
ncc_s_wcrtomb:
.str "wcrtomb"
ncc_s_mbsrtowcs:
.str "mbsrtowcs"
ncc_s_wcsrtombs:
.str "wcsrtombs"
