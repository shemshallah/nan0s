; mathx.nas - inverse trig (atan/atan2/asin/acos) for ncc.

.equ W_AT_SIGN 61880
.equ W_AT_INV  61881
.equ W_AT_X    61882
.equ W_AT_Y    61883

; ni_atan_poly: r1=|x|<=0.4143 -> r1=atan(x) by Taylor/Horner
ni_atan_poly:
FMUL r2,r1,r1
LA r3,0x3D2AAAAB
LA r4,0x3DE38E39
FMUL r5,r2,r3
FSUB r3,r4,r5
LA r4,0x3E124925
FMUL r5,r2,r3
FSUB r3,r4,r5
LA r4,0x3E4CCCCD
FMUL r5,r2,r3
FSUB r3,r4,r5
LA r4,0x3EAAAAAB
FMUL r5,r2,r3
FSUB r3,r4,r5
LA r4,0x3F800000
FMUL r5,r2,r3
FSUB r3,r4,r5
FMUL r1,r1,r3
RET

; ni_atan_core: r1=float bits -> r1=atan(x)
ni_atan_core:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_AT_SIGN
LA r2,0x7FFFFFFF
BOOL.8 r1,r1,r2
ST r0,r0,#W_AT_INV
LA r2,0x3F800000
FCMP r1,r2
JMP[LE] @atc_noinv
LA r2,0x3F800000
FDIV r1,r2,r1
MOVI r2,1
ST r2,r0,#W_AT_INV
atc_noinv:
ST r1,r0,#W_AT_X
LA r2,0x3ED413CD
FCMP r1,r2
JMP[LE] @atc_poly
LD r3,r0,#W_AT_X
LA r4,0x3F800000
FSUB r1,r3,r4
FADD r2,r3,r4
FDIV r1,r1,r2
CALL @ni_atan_poly
LA r2,0x3F490FDB
FADD r1,r1,r2
JMP @atc_inv
atc_poly:
CALL @ni_atan_poly
atc_inv:
LD r2,r0,#W_AT_INV
CMP r2,r0
JMP[EQ] @atc_sign
LA r2,0x3FC90FDB
FSUB r1,r2,r1
atc_sign:
LD r2,r0,#W_AT_SIGN
LA r3,0x80000000
BOOL.8 r2,r2,r3
BOOL.14 r1,r1,r2
SUB r14,r14,r13
LD r15,r14,0
RET


nbi_frexp:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
CMP r1,r0
JMP[NE] @frx_nz
LD r1,r0,#W_F2P
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
MOVI r1,0
CALL @ni_push
JMP @nbi_d
frx_nz:
ST r1,r0,#W_F2V
LA r2,0x7FFFFFFF
BOOL.8 r2,r1,r2
ADD r1,r2,r0
FLOG r1,r1
LA r2,0x3F317218
FDIV r1,r1,r2
CVTFI r3,r1
CVTIF r4,r3
FCMP r1,r4
JMP[GE] @frx_floor
SUB r3,r3,r13
frx_floor:
ADD r3,r3,r13
ST r3,r0,#W_F2S
CVTIF r1,r3
LA r2,0x80000000
BOOL.6 r1,r1,r2
LA r2,0x3F317218
FMUL r1,r1,r2
FEXP r1,r1
LD r2,r0,#W_F2V
FMUL r1,r1,r2
ST r1,r0,#W_F2V
LD r1,r0,#W_F2P
LD r2,r0,#W_F2S
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_F2V
CALL @ni_push
JMP @nbi_d

nbi_nextafter:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
ST r1,r0,#W_F2V
LD r2,r0,#W_F2P
FCMP r1,r2
JMP[EQ] @nxa_same
CMP r1,r0
JMP[NE] @nxa_nz
LD r1,r0,#W_F2P
LA r2,0x80000000
BOOL.8 r1,r1,r2
ADDI r1,r1,1
JMP @nxa_pp
nxa_nz:
LD r2,r0,#W_F2V
MOVI r3,0
FCMP r2,r3
JMP[LT] @nxa_neg
LD r3,r0,#W_F2P
FCMP r2,r3
JMP[LT] @nxa_inc
SUB r2,r2,r13
JMP @nxa_p
nxa_inc:
ADDI r2,r2,1
JMP @nxa_p
nxa_neg:
LD r3,r0,#W_F2P
FCMP r2,r3
JMP[LT] @nxa_ndec
ADDI r2,r2,1
JMP @nxa_p
nxa_ndec:
SUB r2,r2,r13
JMP @nxa_p
nxa_same:
LD r1,r0,#W_F2P
JMP @nxa_pp
nxa_p:
ADD r1,r2,r0
nxa_pp:
CALL @ni_push
JMP @nbi_d


nbi_erf:
CALL @ni_pop
ST r1,r0,#W_F2S
LA r2,0x7FFFFFFF
BOOL.8 r1,r1,r2
ST r1,r0,#W_F2V
LA r2,0x3EA7BA05
FMUL r1,r1,r2
LA r2,0x3F800000
FADD r1,r1,r2
LA r2,0x3F800000
FDIV r1,r2,r1
ST r1,r0,#W_F2P
LA r4,0x3F87DC22
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0xBFBA00E3
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0x3FB5F0E3
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0xBE91A98E
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0x3E827906
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LD r1,r0,#W_F2V
FMUL r1,r1,r1
LA r2,0x80000000
BOOL.6 r1,r1,r2
FEXP r1,r1
FMUL r4,r4,r1
LA r2,0x3F800000
FSUB r1,r2,r4
LD r2,r0,#W_F2S
LA r3,0x80000000
BOOL.8 r2,r2,r3
BOOL.14 r1,r1,r2
CALL @ni_push
JMP @nbi_d

nbi_erfc:
CALL @ni_pop
ST r1,r0,#W_F2S
LA r2,0x7FFFFFFF
BOOL.8 r1,r1,r2
ST r1,r0,#W_F2V
LA r2,0x3EA7BA05
FMUL r1,r1,r2
LA r2,0x3F800000
FADD r1,r1,r2
LA r2,0x3F800000
FDIV r1,r2,r1
ST r1,r0,#W_F2P
LA r4,0x3F87DC22
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0xBFBA00E3
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0x3FB5F0E3
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0xBE91A98E
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LA r2,0x3E827906
FADD r4,r4,r2
LD r1,r0,#W_F2P
FMUL r4,r4,r1
LD r1,r0,#W_F2V
FMUL r1,r1,r1
LA r2,0x80000000
BOOL.6 r1,r1,r2
FEXP r1,r1
FMUL r4,r4,r1
LD r2,r0,#W_F2S
MOVI r3,0
FCMP r2,r3
JMP[GE] @erfc_pos
LA r2,0x40000000
FSUB r1,r2,r4
JMP @erfc_p
erfc_pos:
ADD r1,r4,r0
erfc_p:
CALL @ni_push
JMP @nbi_d

nbi_atan:
CALL @ni_pop
CALL @ni_atan_core
CALL @ni_push
JMP @nbi_d

nbi_asin:
CALL @ni_pop
ST r1,r0,#W_AT_X
LA r2,0x7FFFFFFF
BOOL.8 r2,r1,r2
LA r3,0x3F800000
FCMP r2,r3
JMP[GT] @nasin_nan
LA r3,0x3F800000
FCMP r2,r3
JMP[EQ] @nasin_half
LD r3,r0,#W_AT_X
FMUL r4,r3,r3
LA r5,0x3F800000
FSUB r4,r5,r4
FSQRT r4,r4
FDIV r3,r3,r4
ADD r1,r3,r0
CALL @ni_atan_core
CALL @ni_push
JMP @nbi_d
nasin_half:
LD r1,r0,#W_AT_X
LA r2,0x80000000
BOOL.8 r2,r1,r2
LA r1,0x3FC90FDB
BOOL.14 r1,r1,r2
CALL @ni_push
JMP @nbi_d
nasin_nan:
LA r1,0x7FC00000
CALL @ni_push
JMP @nbi_d

nbi_acos:
CALL @ni_pop
ST r1,r0,#W_AT_X
LA r2,0x7FFFFFFF
BOOL.8 r2,r1,r2
LA r3,0x3F800000
FCMP r2,r3
JMP[GT] @nacos_nan
; acos = pi/2 - asin
LD r1,r0,#W_AT_X
CALL @ni_asin_core2
LA r2,0x3FC90FDB
FSUB r1,r2,r1
CALL @ni_push
JMP @nbi_d
nacos_nan:
LA r1,0x7FC00000
CALL @ni_push
JMP @nbi_d

; ni_asin_core2: r1=x -> r1=asin(x) (same body as nbi_asin, no push)
ni_asin_core2:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_AT_X
LA r2,0x7FFFFFFF
BOOL.8 r2,r1,r2
LA r3,0x3F800000
FCMP r2,r3
JMP[GT] @ac2_nan
FCMP r2,r3
JMP[EQ] @ac2_half
LD r3,r0,#W_AT_X
FMUL r4,r3,r3
LA r5,0x3F800000
FSUB r4,r5,r4
FSQRT r4,r4
FDIV r3,r3,r4
ADD r1,r3,r0
CALL @ni_atan_core
JMP @ac2_d
ac2_half:
LD r1,r0,#W_AT_X
LA r2,0x80000000
BOOL.8 r2,r1,r2
LA r1,0x3FC90FDB
BOOL.14 r1,r1,r2
JMP @ac2_d
ac2_nan:
LA r1,0x7FC00000
ac2_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_atan2:
CALL @ni_pop
ST r1,r0,#W_AT_X
CALL @ni_pop
ST r1,r0,#W_AT_Y
LD r1,r0,#W_AT_Y
LD r2,r0,#W_AT_X
MOVI r3,0
ST r3,r0,#W_AT_INV
; x == 0?
FCMP r2,r3
JMP[NE] @at2_nz
; y > 0 -> pi/2, y < 0 -> -pi/2, y == 0 -> 0
FCMP r1,r3
JMP[GT] @at2_pihalf
JMP[LT] @at2_nihalf
MOVI r1,0
JMP @at2_p
at2_pihalf:
LA r1,0x3FC90FDB
JMP @at2_p
at2_nihalf:
LA r1,0xBFC90FDB
JMP @at2_p
at2_nz:
FCMP r2,r3
JMP[LT] @at2_negx
FDIV r1,r1,r2
CALL @ni_atan_core
JMP @at2_p
at2_negx:
FDIV r1,r1,r2
CALL @ni_atan_core
; add pi if y>=0 else -pi
LD r2,r0,#W_AT_Y
MOVI r3,0
FCMP r2,r3
JMP[LT] @at2_m
LA r2,0x40490FDB
FADD r1,r1,r2
JMP @at2_p
at2_m:
LA r2,0x40490FDB
FSUB r1,r1,r2
at2_p:
CALL @ni_push
JMP @nbi_d

ncc_s_atan:
.str "atan"
ncc_s_atan2:
.str "atan2"
ncc_s_asin:
.str "asin"
ncc_s_acos:
.str "acos"

; ---- gamma via Lanczos (float) -------------------------------------
ni_lgamma_pos:
ST r1,r0,#W_GM_X
LA r2,0x3F800000
FSUB r1,r1,r2
ST r1,r0,#W_GM_X
; a = c0 + sum ci/(x+i)
LA r4,0x3F800000
LA r2,0x4429214E
LD r1,r0,#W_GM_X
LA r3,0x3F800000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
LA r2,0xC49D6474
LD r1,r0,#W_GM_X
LA r3,0x40000000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
LA r2,0x4440D4B3
LD r1,r0,#W_GM_X
LA r3,0x40400000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
LA r2,0xC3309D73
LD r1,r0,#W_GM_X
LA r3,0x40800000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
LA r2,0x41481E14
LD r1,r0,#W_GM_X
LA r3,0x40A00000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
LA r2,0xBE0DE595
LD r1,r0,#W_GM_X
LA r3,0x40C00000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
LA r2,0x3727828A
LD r1,r0,#W_GM_X
LA r3,0x40E00000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
LA r2,0x3421AA84
LD r1,r0,#W_GM_X
LA r3,0x41000000
FADD r1,r1,r3
FDIV r5,r2,r1
FADD r4,r4,r5
; t = x + g + 0.5
LD r1,r0,#W_GM_X
LA r2,0x40E00000
FADD r1,r1,r2
LA r2,0x3F000000
FADD r1,r1,r2
ST r1,r0,#W_GM_S
; log = halflog2pi + (x+0.5)*log(t) - t + log(a)
FLOG r6,r4
ST r6,r0,#W_GM_A
LD r1,r0,#W_GM_X
LA r2,0x3F000000
FADD r1,r1,r2
LD r2,r0,#W_GM_S
FLOG r2,r2
FMUL r1,r1,r2
LA r2,0x3F6B3F8E
FADD r1,r1,r2
LD r2,r0,#W_GM_S
FSUB r1,r1,r2
LD r2,r0,#W_GM_A
FADD r1,r1,r2
RET

ni_lgamma_core:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_GM_X
MOVI r2,1
ST r2,r0,#W_GM_SIGN
LA r2,0x3F000000
FSUB r2,r1,r2
LA r3,0x80000000
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @lgc_pos
; reflection
LA r2,0x40490FDB
FMUL r1,r1,r2
CALL @ni_sin
ST r1,r0,#W_GM_S
CMP r1,r0
JMP[EQ] @lgc_nan
LA r2,0x80000000
BOOL.8 r2,r1,r2
CMP r2,r0
JMP[EQ] @lgc_sp
LA r2,0xFFFFFFFF
ST r2,r0,#W_GM_SIGN
lgc_sp:
LA r2,0x7FFFFFFF
BOOL.8 r1,r1,r2
FLOG r1,r1
ST r1,r0,#W_GM_S
LA r2,0x3F928682
FSUB r1,r2,r1
ST r1,r0,#W_GM_P
; 1-x
LA r1,0x3F800000
LD r2,r0,#W_GM_X
FSUB r1,r1,r2
CALL @ni_lgamma_pos
LD r2,r0,#W_GM_P
FSUB r1,r2,r1
JMP @lgc_d
lgc_pos:
CALL @ni_lgamma_pos
JMP @lgc_d
lgc_nan:
LA r1,0x7FC00000
lgc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_lgamma:
CALL @ni_pop
CALL @ni_lgamma_core
ST r1,r0,#W_GM_S
LD r1,r0,#W_SIGNGAM
CMP r1,r0
JMP[EQ] @nlg_nosg
LD r2,r0,#W_GM_SIGN
MOVI r3,#SZ_32
CALL @ni_storev
nlg_nosg:
LD r1,r0,#W_GM_S
CALL @ni_push
JMP @nbi_d

nbi_tgamma:
CALL @ni_pop
CALL @ni_lgamma_core
FEXP r1,r1
LD r2,r0,#W_GM_SIGN
CMPS r2,r0
JMP[LT] @ntg_neg
LA r2,0x3F800000
JMP @ntg_mul
ntg_neg:
LA r2,0xBF800000
ntg_mul:
FMUL r1,r1,r2
CALL @ni_push
JMP @nbi_d

nbi_iface_version:
MOVI r1,1
CALL @ni_push
JMP @nbi_d

ncc_s_tgamma:
.str "tgamma"
ncc_s_lgamma:
.str "lgamma"
ncc_s_signgam:
.str "signgam"
ncc_s_iface_version:
.str "iface_version"
