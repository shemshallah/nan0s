; iso.nas - C11 <uchar.h> UTF-8/UTF-16/UTF-32 conversions.
; The multibyte encoding is UTF-8; char16_t is 16-bit, char32_t 32-bit.
; mbstate_t is a 32-bit integer: 0 means no pending code unit, otherwise it
; holds a pending low surrogate (0xDC00..0xDFFF).

.equ W_UC_A 0xF06F1
.equ W_UC_B 0xF06F2
.equ W_UC_C 0xF06F3
.equ W_UC_D 0xF06F4
.equ W_ISOFMT 3810000
.equ W_ISONBUF 3830000

; iso_utf8dec: r1=s r2=n -> r1=code point, r2=bytes consumed, r3=status
; status: 0 ok, 1 incomplete sequence, 2 invalid sequence.
iso_utf8dec:
ST r15,r14,0
ADD r14,r14,r13
ADD r7,r1,r0
ADD r8,r2,r0
CMP r8,r0
JMP[EQ] @iud_inc
LDB r4,r7,0
MOVI r5,128
CMP r4,r5
JMP[LT] @iud_ascii
MOVI r5,194
CMP r4,r5
JMP[LT] @iud_inv
MOVI r5,224
CMP r4,r5
JMP[LT] @iud_two
MOVI r5,240
CMP r4,r5
JMP[LT] @iud_three
MOVI r5,245
CMP r4,r5
JMP[LT] @iud_four
JMP @iud_inv
iud_ascii:
ADD r1,r4,r0
MOVI r2,1
MOVI r3,0
JMP @iud_d
iud_two:
MOVI r5,2
CMP r8,r5
JMP[LT] @iud_inc
LDB r6,r7,1
MOVI r5,192
BOOL.8 r6,r6,r5
MOVI r5,128
CMP r6,r5
JMP[NE] @iud_inv
MOVI r5,31
BOOL.8 r4,r4,r5
SHL r4,r4,6
LDB r6,r7,1
MOVI r5,63
BOOL.8 r6,r6,r5
BOOL.14 r1,r4,r6
MOVI r2,2
MOVI r3,0
JMP @iud_d
iud_three:
MOVI r5,3
CMP r8,r5
JMP[LT] @iud_inc
LDB r6,r7,1
MOVI r5,192
BOOL.8 r6,r6,r5
MOVI r5,128
CMP r6,r5
JMP[NE] @iud_inv
LDB r6,r7,2
MOVI r5,192
BOOL.8 r6,r6,r5
MOVI r5,128
CMP r6,r5
JMP[NE] @iud_inv
MOVI r5,15
BOOL.8 r4,r4,r5
SHL r4,r4,12
LDB r6,r7,1
MOVI r5,63
BOOL.8 r6,r6,r5
SHL r6,r6,6
BOOL.14 r4,r4,r6
LDB r6,r7,2
MOVI r5,63
BOOL.8 r6,r6,r5
BOOL.14 r1,r4,r6
; reject overlong and UTF-16 surrogates
MOVI r5,2048
CMP r1,r5
JMP[LT] @iud_inv
MOVI r5,0xD800
CMP r1,r5
JMP[LT] @iud_three_ok
MOVI r5,0xE000
CMP r1,r5
JMP[LT] @iud_inv
iud_three_ok:
MOVI r2,3
MOVI r3,0
JMP @iud_d
iud_four:
MOVI r5,4
CMP r8,r5
JMP[LT] @iud_inc
LDB r6,r7,1
MOVI r5,192
BOOL.8 r6,r6,r5
MOVI r5,128
CMP r6,r5
JMP[NE] @iud_inv
LDB r6,r7,2
MOVI r5,192
BOOL.8 r6,r6,r5
MOVI r5,128
CMP r6,r5
JMP[NE] @iud_inv
LDB r6,r7,3
MOVI r5,192
BOOL.8 r6,r6,r5
MOVI r5,128
CMP r6,r5
JMP[NE] @iud_inv
MOVI r5,7
BOOL.8 r4,r4,r5
SHL r4,r4,18
LDB r6,r7,1
MOVI r5,63
BOOL.8 r6,r6,r5
SHL r6,r6,12
BOOL.14 r4,r4,r6
LDB r6,r7,2
MOVI r5,63
BOOL.8 r6,r6,r5
SHL r6,r6,6
BOOL.14 r4,r4,r6
LDB r6,r7,3
MOVI r5,63
BOOL.8 r6,r6,r5
BOOL.14 r1,r4,r6
LA r5,0x10000
CMP r1,r5
JMP[LT] @iud_inv
LA r5,0x10FFFF
CMP r1,r5
JMP[GT] @iud_inv
MOVI r2,4
MOVI r3,0
JMP @iud_d
iud_inc:
MOVI r1,0
MOVI r2,0
MOVI r3,1
JMP @iud_d
iud_inv:
MOVI r1,0
MOVI r2,0
MOVI r3,2
iud_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; iso_utf8enc: r1=code point r2=dst -> r1=bytes written (0 = invalid)
iso_utf8enc:
ST r15,r14,0
ADD r14,r14,r13
ADD r8,r2,r0
CMPS r1,r0
JMP[LT] @iue_bad
LA r3,0x10FFFF
CMP r1,r3
JMP[GT] @iue_bad
MOVI r3,0xD800
CMP r1,r3
JMP[LT] @iue_range
MOVI r3,0xDFFF
CMP r1,r3
JMP[LE] @iue_bad
iue_range:
MOVI r3,128
CMP r1,r3
JMP[LT] @iue_one
MOVI r3,2048
CMP r1,r3
JMP[LT] @iue_two
LA r3,0x10000
CMP r1,r3
JMP[LT] @iue_three
JMP @iue_four
iue_one:
STB r1,r8,0
MOVI r1,1
JMP @iue_d
iue_two:
SHR r3,r1,6
MOVI r4,0xC0
BOOL.14 r3,r3,r4
STB r3,r8,0
MOVI r3,63
BOOL.8 r3,r1,r3
MOVI r4,0x80
BOOL.14 r3,r3,r4
STB r3,r8,1
MOVI r1,2
JMP @iue_d
iue_three:
SHR r3,r1,12
MOVI r4,0xE0
BOOL.14 r3,r3,r4
STB r3,r8,0
SHR r3,r1,6
MOVI r4,63
BOOL.8 r3,r3,r4
MOVI r4,0x80
BOOL.14 r3,r3,r4
STB r3,r8,1
MOVI r3,63
BOOL.8 r3,r1,r3
MOVI r4,0x80
BOOL.14 r3,r3,r4
STB r3,r8,2
MOVI r1,3
JMP @iue_d
iue_four:
SHR r3,r1,18
MOVI r4,0xF0
BOOL.14 r3,r3,r4
STB r3,r8,0
SHR r3,r1,12
MOVI r4,63
BOOL.8 r3,r3,r4
MOVI r4,0x80
BOOL.14 r3,r3,r4
STB r3,r8,1
SHR r3,r1,6
MOVI r4,63
BOOL.8 r3,r3,r4
MOVI r4,0x80
BOOL.14 r3,r3,r4
STB r3,r8,2
MOVI r3,63
BOOL.8 r3,r1,r3
MOVI r4,0x80
BOOL.14 r3,r3,r4
STB r3,r8,3
MOVI r1,4
JMP @iue_d
iue_bad:
MOVI r1,0
iue_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- mbrtoc32 ------------------------------------------------------
nbi_mbrtoc32:
CALL @ni_pop            ; ps
ADD r12,r1,r0
CALL @ni_pop            ; n
ADD r10,r1,r0
CALL @ni_pop            ; s
ADD r8,r1,r0
CALL @ni_pop            ; pc32
ADD r11,r1,r0
CMP r8,r0
JMP[EQ] @mt32_zero
CMP r10,r0
JMP[EQ] @mt32_minus2
ADD r1,r8,r0
ADD r2,r10,r0
CALL @iso_utf8dec
CMP r3,r0
JMP[EQ] @mt32_ok
MOVI r1,1
CMP r3,r1
JMP[EQ] @mt32_minus2
MOVI r1,84
CALL @ex_seterr
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d
mt32_minus2:
LA r1,0xFFFFFFFE
CALL @ni_push
JMP @nbi_d
mt32_zero:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
mt32_ok:
ST r1,r0,#W_UC_A
ST r2,r0,#W_UC_B
CMP r11,r0
JMP[EQ] @mt32_ret
ADD r1,r11,r0
LD r2,r0,#W_UC_A
MOVI r3,#SZ_32
CALL @ni_storev
mt32_ret:
LD r1,r0,#W_UC_A
CMP r1,r0
JMP[EQ] @mt32_zerolen
LD r1,r0,#W_UC_B
CALL @ni_push
JMP @nbi_d
mt32_zerolen:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

; ---- c32rtomb ------------------------------------------------------
nbi_c32rtomb:
CALL @ni_pop            ; ps
CALL @ni_pop            ; c32
ADD r9,r1,r0
CALL @ni_pop            ; s
ADD r8,r1,r0
CMP r8,r0
JMP[EQ] @c32_one
LA r1,0x10FFFF
CMP r9,r1
JMP[GT] @c32_err
MOVI r1,0xD800
CMP r9,r1
JMP[LT] @c32_enc
MOVI r1,0xDFFF
CMP r9,r1
JMP[LE] @c32_err
c32_enc:
ADD r1,r9,r0
ADD r2,r8,r0
CALL @iso_utf8enc
CMP r1,r0
JMP[EQ] @c32_err
CALL @ni_push
JMP @nbi_d
c32_one:
MOVI r1,1
CALL @ni_push
JMP @nbi_d
c32_err:
MOVI r1,84
CALL @ex_seterr
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

; ---- mbrtoc16 ------------------------------------------------------
nbi_mbrtoc16:
CALL @ni_pop            ; ps
ADD r12,r1,r0
CALL @ni_pop            ; n
ADD r10,r1,r0
CALL @ni_pop            ; s
ADD r8,r1,r0
CALL @ni_pop            ; pc16
ADD r11,r1,r0
; a pending low surrogate is delivered before any new input is consumed
CMP r12,r0
JMP[EQ] @mt16_no_pending
ADD r1,r12,r0
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @mt16_no_pending
ST r1,r0,#W_UC_C
CMP r11,r0
JMP[EQ] @mt16_pclear
ADD r1,r11,r0
LD r2,r0,#W_UC_C
MOVI r3,#SZ_16U
CALL @ni_storev
mt16_pclear:
ADD r1,r12,r0
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
LA r1,0xFFFFFFFD
CALL @ni_push
JMP @nbi_d
mt16_no_pending:
CMP r8,r0
JMP[EQ] @mt16_state
CMP r10,r0
JMP[EQ] @mt16_minus2
ADD r1,r8,r0
ADD r2,r10,r0
CALL @iso_utf8dec
CMP r3,r0
JMP[EQ] @mt16_ok
MOVI r1,1
CMP r3,r1
JMP[EQ] @mt16_minus2
MOVI r1,84
CALL @ex_seterr
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d
mt16_minus2:
LA r1,0xFFFFFFFE
CALL @ni_push
JMP @nbi_d
mt16_ok:
ST r1,r0,#W_UC_A
ST r2,r0,#W_UC_B
MOVI r3,0xFFFF
CMP r1,r3
JMP[GT] @mt16_pair
CMP r11,r0
JMP[EQ] @mt16_ret
ADD r1,r11,r0
LD r2,r0,#W_UC_A
MOVI r3,#SZ_16U
CALL @ni_storev
mt16_ret:
LD r1,r0,#W_UC_A
CMP r1,r0
JMP[EQ] @mt16_zerolen
LD r1,r0,#W_UC_B
CALL @ni_push
JMP @nbi_d
mt16_zerolen:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
mt16_pair:
LD r1,r0,#W_UC_A
LA r2,0x10000
SUB r1,r1,r2
SHR r4,r1,10
MOVI r2,0xD800
ADD r4,r4,r2
MOVI r2,0x3FF
BOOL.8 r5,r1,r2
MOVI r2,0xDC00
ADD r5,r5,r2
CMP r11,r0
JMP[EQ] @mt16_ps
ADD r1,r11,r0
ADD r2,r4,r0
MOVI r3,#SZ_16U
CALL @ni_storev
mt16_ps:
CMP r12,r0
JMP[EQ] @mt16_pret
ADD r1,r12,r0
ADD r2,r5,r0
MOVI r3,#SZ_32
CALL @ni_storev
mt16_pret:
LD r1,r0,#W_UC_B
CALL @ni_push
JMP @nbi_d
mt16_state:
; s == NULL: return a pending low surrogate (-3) or 0
CMP r12,r0
JMP[EQ] @mt16_zero
ADD r1,r12,r0
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @mt16_zero
ST r1,r0,#W_UC_C
CMP r11,r0
JMP[EQ] @mt16_sclr
ADD r1,r11,r0
LD r2,r0,#W_UC_C
MOVI r3,#SZ_16U
CALL @ni_storev
mt16_sclr:
ADD r1,r12,r0
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
LA r1,0xFFFFFFFD
CALL @ni_push
JMP @nbi_d
mt16_zero:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

; ---- c16rtomb ------------------------------------------------------
nbi_c16rtomb:
CALL @ni_pop            ; ps
ADD r9,r1,r0
CALL @ni_pop            ; c16
MOVI r2,0xFFFF
BOOL.8 r8,r1,r2
CALL @ni_pop            ; s
ADD r7,r1,r0
CMP r7,r0
JMP[EQ] @c16_one
MOVI r2,0xD800
CMP r8,r2
JMP[LT] @c16_plain
MOVI r2,0xDBFF
CMP r8,r2
JMP[LE] @c16_high
MOVI r2,0xDC00
CMP r8,r2
JMP[LT] @c16_plain
MOVI r2,0xDFFF
CMP r8,r2
JMP[LE] @c16_low
JMP @c16_plain
c16_high:
CMP r9,r0
JMP[EQ] @c16_err
ADD r1,r9,r0
ADD r2,r8,r0
MOVI r3,#SZ_32
CALL @ni_storev
MOVI r1,0
CALL @ni_push
JMP @nbi_d
c16_low:
CMP r9,r0
JMP[EQ] @c16_err
ADD r1,r9,r0
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @c16_err
; cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
MOVI r2,0xD800
SUB r3,r1,r2
SHL r3,r3,10
MOVI r2,0xDC00
SUB r4,r8,r2
ADD r3,r3,r4
LA r2,0x10000
ADD r3,r3,r2
ST r3,r0,#W_UC_D
ADD r1,r9,r0
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
JMP @c16_enc3
c16_plain:
ADD r1,r8,r0
ST r1,r0,#W_UC_D
c16_enc3:
LD r1,r0,#W_UC_D
c16_enc4:
ADD r2,r7,r0
CALL @iso_utf8enc
CMP r1,r0
JMP[EQ] @c16_err
CALL @ni_push
JMP @nbi_d
c16_one:
MOVI r1,1
CALL @ni_push
JMP @nbi_d
c16_err:
MOVI r1,84
CALL @ex_seterr
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

; iso_w2n: r1=wide string r2=narrow dst r3=limit -> r1=bytes stored
iso_w2n:
ST r15,r14,0
ADD r14,r14,r13
ADD r7,r1,r0
ADD r8,r2,r0
ADD r9,r3,r0
MOVI r10,0
iw2_l:
ADD r1,r7,r0
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @iw2_d
ADD r2,r10,r0
ADD r3,r9,r0
SUB r3,r3,r13
CMP r2,r3
JMP[GE] @iw2_skip
ADD r3,r8,r2
STB r1,r3,0
iw2_skip:
ADDI r7,r7,4
ADD r10,r10,r13
JMP @iw2_l
iw2_d:
CMP r9,r0
JMP[EQ] @iw2_ret
ADD r2,r10,r0
ADD r3,r9,r0
SUB r3,r3,r13
CMP r2,r3
JMP[GE] @iw2_ret
ADD r3,r8,r2
STB r0,r3,0
iw2_ret:
ADD r1,r10,r0
SUB r14,r14,r13
LD r15,r14,0
RET

; iso_read_stream: r1=FILE handle -> r1=stream entry (0 on error), CS_FBUF filled
iso_read_stream:
ST r15,r14,0
ADD r14,r14,r13
CALL @st_entry
CMP r1,r0
JMP[EQ] @irs_d
ST r1,r0,#W_ISO_TMP
LD r2,r1,5
LD r3,r1,3
CMP r2,r3
JMP[GE] @irs_empty
SUB r3,r3,r2
MOVI r4,8190
CMP r3,r4
JMP[LE] @irs_cap
MOVI r3,8190
irs_cap:
ST r3,r0,#W_UC_A
LD r4,r1,2
ADD r4,r4,r2
LA r5,#CS_FBUF
LD r6,r0,#W_UC_A
irs_cp:
CMP r6,r0
JMP[EQ] @irs_nul
LDB r7,r4,0
STB r7,r5,0
ADD r4,r4,r13
ADD r5,r5,r13
SUB r6,r6,r13
JMP @irs_cp
irs_nul:
STB r0,r5,0
LD r1,r0,#W_ISO_TMP
JMP @irs_x
irs_empty:
LA r5,#CS_FBUF
STB r0,r5,0
LD r1,r0,#W_ISO_TMP
JMP @irs_x
irs_d:
MOVI r1,0
irs_x:
SUB r14,r14,r13
LD r15,r14,0
RET

; wva_scan_build: push a wide scanf format and its destination pointers from
; the va_list at W_VA_AP; sets W_CALLWORDS and R_T1.
wva_scan_build:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_VA_FMT
CALL @ni_push
MOVI r1,1
ST r1,r0,#W_VA_WORDS
LD r1,r0,#W_VA_FMT
ST r1,r0,#W_VA_FP
wvs_l:
LD r1,r0,#W_VA_FP
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @wvs_done
MOVI r2,37
CMP r1,r2
JMP[EQ] @wvs_pct
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
JMP @wvs_l
wvs_pct:
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
ST r0,r0,#W_WSC_SUP
wvs_flags:
LD r1,r0,#W_VA_FP
MOVI r2,#SZ_32
CALL @ni_loadv
MOVI r2,42
CMP r1,r2
JMP[NE] @wvs_width
MOVI r1,1
ST r1,r0,#W_WSC_SUP
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
JMP @wvs_flags
wvs_width:
MOVI r2,48
CMP r1,r2
JMP[LT] @wvs_wstar
MOVI r2,58
CMP r1,r2
JMP[GE] @wvs_wstar
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
JMP @wvs_width
wvs_wstar:
MOVI r2,42
CMP r1,r2
JMP[NE] @wvs_len
CALL @wvs_push_ptr
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
wvs_len:
LD r1,r0,#W_VA_FP
MOVI r2,#SZ_32
CALL @ni_loadv
MOVI r2,104
CMP r1,r2
JMP[EQ] @wvs_len_adv
MOVI r2,108
CMP r1,r2
JMP[EQ] @wvs_len_adv
MOVI r2,76
CMP r1,r2
JMP[EQ] @wvs_len_adv
MOVI r2,106
CMP r1,r2
JMP[EQ] @wvs_len_adv
MOVI r2,122
CMP r1,r2
JMP[EQ] @wvs_len_adv
MOVI r2,116
CMP r1,r2
JMP[EQ] @wvs_len_adv
JMP @wvs_conv
wvs_len_adv:
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
JMP @wvs_len
wvs_conv:
LA r2,#W_WSC_SUP
LD r2,r0,#W_WSC_SUP
CMP r2,r0
JMP[NE] @wvs_adv
MOVI r2,37
CMP r1,r2
JMP[EQ] @wvs_adv
MOVI r2,91
CMP r1,r2
JMP[EQ] @wvs_scan
CALL @wvs_push_ptr
JMP @wvs_adv
wvs_scan:
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
LD r1,r0,#W_VA_FP
MOVI r2,#SZ_32
CALL @ni_loadv
MOVI r2,94
CMP r1,r2
JMP[NE] @wvs_scan_l
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
wvs_scan_l:
LD r1,r0,#W_VA_FP
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @wvs_done
MOVI r2,93
CMP r1,r2
JMP[EQ] @wvs_adv
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
JMP @wvs_scan_l
wvs_adv:
LD r1,r0,#W_VA_FP
ADDI r1,r1,4
ST r1,r0,#W_VA_FP
JMP @wvs_l
wvs_done:
LD r1,r0,#W_VA_WORDS
ST r1,r0,#W_CALLWORDS
ST r1,r0,#R_T1
SUB r14,r14,r13
LD r15,r14,0
RET

wvs_push_ptr:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_VA_AP
MOVI r2,#SZ_32
CALL @ni_loadv
CALL @ni_push
LD r2,r0,#W_VA_WORDS
ADD r2,r2,r13
ST r2,r0,#W_VA_WORDS
LD r2,r0,#W_VA_AP
ADDI r2,r2,4
ST r2,r0,#W_VA_AP
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- fwprintf/fwscanf/swprintf/v- variants -------------------------
; Output variants convert the wide format to the ASCII narrow form and reuse
; the narrow formatter (the C locale is ASCII; %ls keeps wide-string handling).
nbi_fwprintf:
MOVI r1,1
CALL @ni_arg
ST r1,r0,#W_UC_A
LD r1,r0,#W_UC_A
LA r2,#W_ISOFMT
MOVI r3,8192
CALL @iso_w2n
; replace the format slot (arg 1) with the narrow conversion
LD r1,r0,#W_CALLWORDS
LD r2,r0,#R_SP
SUB r2,r2,r1
ADDI r2,r2,1
LA r1,#W_ISOFMT
ST r1,r2,0
JMP @nbi_fprintf

nbi_swprintf:
MOVI r1,0
CALL @ni_arg
ST r1,r0,#W_UC_A
MOVI r1,1
CALL @ni_arg
ST r1,r0,#W_UC_B
MOVI r1,2
CALL @ni_arg
LA r2,#W_ISOFMT
MOVI r3,8192
CALL @iso_w2n
; replace the format slot (arg 2) with the narrow conversion
LD r1,r0,#W_CALLWORDS
LD r2,r0,#R_SP
SUB r2,r2,r1
ADDI r2,r2,2
LA r1,#W_ISOFMT
ST r1,r2,0
; save narrow output state
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
LA r1,#W_ISONBUF
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
MOVI r1,8191
ST r1,r0,#W_SNLIM
MOVI r1,2
ST r1,r0,#W_PF_OFF
LD r1,r0,#R_T1
ST r1,r0,#W_CALLWORDS
LD r1,r0,#R_T1
CALL @ni_printf
CALL @ni_pop
; widen the narrow result into the caller buffer
LD r1,r0,#W_SNPOS
ST r1,r0,#W_UC_C
LD r1,r0,#W_SNOUT
LD r2,r0,#W_SNPOS
ADD r1,r1,r2
STB r0,r1,0
LA r1,#W_ISONBUF
LD r2,r0,#W_UC_A
LD r3,r0,#W_UC_B
CALL @iso_n2w
; restore narrow output state
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
LD r1,r0,#W_UC_C
CALL @ni_push
JMP @nbi_d

nbi_vfwprintf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
LD r1,r0,#W_UC_A
LA r2,#W_ISOFMT
MOVI r3,8192
CALL @iso_w2n
LD r1,r0,#W_UC_B
CALL @ni_push
LA r1,#W_ISOFMT
CALL @ni_push
LD r1,r0,#W_VA_AP
CALL @ni_push
MOVI r1,3
ST r1,r0,#R_T1
JMP @nbi_vfprintf

nbi_vswprintf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
CALL @ni_pop
ST r1,r0,#W_UC_C
; convert format and build the narrow va argument list
LD r1,r0,#W_UC_A
LA r2,#W_ISOFMT
MOVI r3,8192
CALL @iso_w2n
LA r1,#W_ISOFMT
ST r1,r0,#W_VA_FMT
CALL @va_build
ST r0,r0,#W_PF_OFF
; redirect narrow output
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
LA r1,#W_ISONBUF
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
MOVI r1,8191
ST r1,r0,#W_SNLIM
LD r1,r0,#W_VA_WORDS
CALL @ni_printf
CALL @ni_pop
LD r1,r0,#W_SNPOS
ST r1,r0,#W_UC_D
LD r1,r0,#W_SNOUT
LD r2,r0,#W_SNPOS
ADD r1,r1,r2
STB r0,r1,0
LA r1,#W_ISONBUF
LD r2,r0,#W_UC_C
LD r3,r0,#W_UC_B
CALL @iso_n2w
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
LD r1,r0,#W_UC_D
CALL @ni_push
JMP @nbi_d

; iso_n2w: r1=narrow src r2=wide dst r3=limit -> r1=characters produced
iso_n2w:
ST r15,r14,0
ADD r14,r14,r13
ADD r7,r1,r0
ADD r8,r2,r0
ADD r9,r3,r0
MOVI r10,0
in2_l:
LDB r1,r7,0
CMP r1,r0
JMP[EQ] @in2_d
ADD r2,r10,r0
ADD r3,r9,r0
SUB r3,r3,r13
CMP r2,r3
JMP[GE] @in2_skip
SHL r4,r10,2
ADD r3,r8,r4
MOVI r4,255
BOOL.8 r2,r1,r4
MOVI r3,#SZ_32
; preserve address in r1: reload
SHL r5,r10,2
ADD r1,r8,r5
CALL @ni_storev
in2_skip:
ADDI r7,r7,1
ADD r10,r10,r13
JMP @in2_l
in2_d:
CMP r9,r0
JMP[EQ] @in2_ret
ADD r2,r10,r0
ADD r3,r9,r0
SUB r3,r3,r13
CMP r2,r3
JMP[GE] @in2_ret
SHL r5,r10,2
ADD r1,r8,r5
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
in2_ret:
ADD r1,r10,r0
SUB r14,r14,r13
LD r15,r14,0
RET

; iso_drop_first_arg: remove the first argument word from the eval stack and
; shrink R_T1/W_CALLWORDS. Used by fwscanf/swscanf so the wide scanner sees
; the format in slot 0, as wscanf does.
iso_drop_first_arg:
ST r15,r14,0
ADD r14,r14,r13
LD r8,r0,#R_T1
MOVI r2,1
CMP r8,r2
JMP[LT] @idfa_d
LD r9,r0,#R_SP
LD r10,r0,#W_CALLWORDS
SUB r9,r9,r10
ADD r10,r9,r0
ADDI r10,r10,1
SUB r8,r8,r13
idfa_l:
CMP r8,r0
JMP[EQ] @idfa_done
LD r1,r10,0
ST r1,r9,0
ADD r9,r9,r13
ADD r10,r10,r13
SUB r8,r8,r13
JMP @idfa_l
idfa_done:
LD r1,r0,#R_SP
SUB r1,r1,r13
ST r1,r0,#R_SP
LD r1,r0,#W_CALLWORDS
SUB r1,r1,r13
ST r1,r0,#W_CALLWORDS
LD r1,r0,#R_T1
SUB r1,r1,r13
ST r1,r0,#R_T1
idfa_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_fwscanf:
MOVI r1,0
CALL @ni_arg
CALL @iso_read_stream
CMP r1,r0
JMP[EQ] @fws_eof
ST r1,r0,#W_WSC_STREAM
LA r2,#CS_FBUF
ST r2,r0,#W_WSC_SRC
ST r2,r0,#W_WSC_START
MOVI r2,2
ST r2,r0,#W_WSC_IN
MOVI r1,1
ST r1,r0,#W_WSC_ARG0
ST r1,r0,#W_WSC_RUNN
CALL @iso_drop_first_arg
ST r0,r0,#W_PF_OFF
JMP @wscanf_body
fws_eof:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_swscanf:
MOVI r1,0
CALL @ni_arg
LA r2,#CS_FBUF
MOVI r3,8190
CALL @iso_w2n
LA r1,#CS_FBUF
ST r1,r0,#W_WSC_SRC
MOVI r1,1
ST r1,r0,#W_WSC_IN
MOVI r1,1
ST r1,r0,#W_WSC_ARG0
ST r1,r0,#W_WSC_RUNN
CALL @iso_drop_first_arg
ST r0,r0,#W_PF_OFF
JMP @wscanf_body

nbi_vfwscanf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_VA_FMT
CALL @ni_pop
CALL @iso_read_stream
CMP r1,r0
JMP[EQ] @vfws_eof
ST r1,r0,#W_WSC_STREAM
LA r2,#CS_FBUF
ST r2,r0,#W_WSC_SRC
ST r2,r0,#W_WSC_START
CALL @wva_scan_build
MOVI r1,2
ST r1,r0,#W_WSC_IN
MOVI r1,1
ST r1,r0,#W_WSC_ARG0
ST r1,r0,#W_WSC_RUNN
MOVI r1,0
ST r1,r0,#W_PF_OFF
JMP @wscanf_body
vfws_eof:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_vswscanf:
CALL @ni_pop
ST r1,r0,#W_VA_AP
CALL @ni_pop
ST r1,r0,#W_VA_FMT
CALL @ni_pop
LA r2,#CS_FBUF
MOVI r3,8190
CALL @iso_w2n
CALL @wva_scan_build
LA r1,#CS_FBUF
ST r1,r0,#W_WSC_SRC
MOVI r1,1
ST r1,r0,#W_WSC_IN
MOVI r1,1
ST r1,r0,#W_WSC_ARG0
ST r1,r0,#W_WSC_RUNN
MOVI r1,0
ST r1,r0,#W_PF_OFF
JMP @wscanf_body


; ---- single-threaded C11 atomics ----------------------------------
nbi_atomic_load:
CALL @ni_pop
MOVI r2,#SZ_32
CALL @ni_loadv
CALL @ni_push
JMP @nbi_d

nbi_atomic_store:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
LD r2,r0,#W_UC_A
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nbi_zero

nbi_atomic_init:
JMP @nbi_atomic_store

nbi_atomic_exch:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
LD r2,r0,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_UC_C
LD r1,r0,#W_UC_B
LD r2,r0,#W_UC_A
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_UC_C
CALL @ni_push
JMP @nbi_d

nbi_atomic_cas:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
CALL @ni_pop
ST r1,r0,#W_UC_C
LD r2,r0,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_UC_D
LD r1,r0,#W_UC_B
MOVI r2,#SZ_32
CALL @ni_loadv
LD r2,r0,#W_UC_D
CMP r1,r2
JMP[NE] @ncas_no
LD r1,r0,#W_UC_C
LD r2,r0,#W_UC_A
MOVI r3,#SZ_32
CALL @ni_storev
MOVI r1,1
CALL @ni_push
JMP @nbi_d
ncas_no:
LD r1,r0,#W_UC_B
LD r2,r0,#W_UC_D
MOVI r3,#SZ_32
CALL @ni_storev
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_atomic_fadd:
MOVI r1,1
JMP @nbi_atomic_fop
nbi_atomic_fsub:
MOVI r1,2
JMP @nbi_atomic_fop
nbi_atomic_for:
MOVI r1,3
JMP @nbi_atomic_fop
nbi_atomic_fxor:
MOVI r1,4
JMP @nbi_atomic_fop
nbi_atomic_fand:
MOVI r1,5
nbi_atomic_fop:
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
CALL @ni_pop
ST r1,r0,#W_UC_C
LD r2,r0,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_UC_D
ST r1,r0,#W_ISO_TMP
LD r2,r0,#W_UC_B
LD r1,r0,#W_UC_D
LD r3,r0,#W_UC_A
MOVI r4,1
CMP r3,r4
JMP[EQ] @nfop_add
MOVI r4,2
CMP r3,r4
JMP[EQ] @nfop_sub
MOVI r4,3
CMP r3,r4
JMP[EQ] @nfop_or
MOVI r4,4
CMP r3,r4
JMP[EQ] @nfop_xor
MOVI r3,63
BOOL.8 r1,r1,r3
BOOL.8 r2,r2,r3
BOOL.8 r1,r1,r2
JMP @nfop_store
nfop_add:
ADD r1,r1,r2
JMP @nfop_store
nfop_sub:
SUB r1,r1,r2
JMP @nfop_store
nfop_or:
BOOL.14 r1,r1,r2
JMP @nfop_store
nfop_xor:
BOOL.6 r1,r1,r2
nfop_store:
ST r1,r0,#W_UC_D
LD r1,r0,#W_UC_C
LD r2,r0,#W_UC_D
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_ISO_TMP
CALL @ni_push
JMP @nbi_d

nbi_atomic_flag_tas:
CALL @ni_pop
ST r1,r0,#W_UC_A
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_UC_B
LD r1,r0,#W_UC_A
MOVI r2,1
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_UC_B
CALL @ni_push
JMP @nbi_d

nbi_atomic_flag_clr:
CALL @ni_pop
ST r1,r0,#W_UC_A
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nbi_zero

nbi_atomic_fence:
CALL @ni_pop
JMP @nbi_zero

nbi_atomic_islf:
CALL @ni_pop
MOVI r1,1
CALL @ni_push
JMP @nbi_d

; explicit memory-order variants: drop the order argument(s), then reuse
nbi_atomic_load_ex:
CALL @ni_pop
JMP @nbi_atomic_load
nbi_atomic_store_ex:
CALL @ni_pop
JMP @nbi_atomic_store
nbi_atomic_exch_ex:
CALL @ni_pop
JMP @nbi_atomic_exch
nbi_atomic_cas_ex:
CALL @ni_pop
CALL @ni_pop
JMP @nbi_atomic_cas
nbi_atomic_fadd_ex:
CALL @ni_pop
JMP @nbi_atomic_fadd
nbi_atomic_fsub_ex:
CALL @ni_pop
JMP @nbi_atomic_fsub
nbi_atomic_for_ex:
CALL @ni_pop
JMP @nbi_atomic_for
nbi_atomic_fxor_ex:
CALL @ni_pop
JMP @nbi_atomic_fxor
nbi_atomic_fand_ex:
CALL @ni_pop
JMP @nbi_atomic_fand
nbi_atomic_flag_tas_ex:
CALL @ni_pop
JMP @nbi_atomic_flag_tas
nbi_atomic_flag_clr_ex:
CALL @ni_pop
JMP @nbi_atomic_flag_clr

; ---- fenv ----------------------------------------------------------
.equ W_FENV_ROUND 0xF077D
.equ W_TSS_N 0xF077F
.equ W_TSS_TAB 2500300
.equ W_THRD_RESULT 0xF077E
nbi_fegetround:
LD r1,r0,#W_FENV_ROUND
CALL @ni_push
JMP @nbi_d
nbi_fesetround:
CALL @ni_pop
ST r1,r0,#W_FENV_ROUND
JMP @nbi_zero
nbi_feclearexcept:
CALL @ni_pop
JMP @nbi_zero
nbi_feraiseexcept:
CALL @ni_pop
JMP @nbi_zero
nbi_fetestexcept:
CALL @ni_pop
JMP @nbi_zero
nbi_fegetenv:
CALL @ni_pop
ST r1,r0,#W_UC_A
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nbi_zero
nbi_fesetenv:
CALL @ni_pop
JMP @nbi_zero
nbi_feholdexcept:
CALL @ni_pop
ST r1,r0,#W_UC_A
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nbi_zero
nbi_feupdateenv:
CALL @ni_pop
JMP @nbi_zero
nbi_fegetexceptflag:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
LD r1,r0,#W_UC_A
MOVI r2,0
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nbi_zero
nbi_fesetexceptflag:
CALL @ni_pop
CALL @ni_pop
JMP @nbi_zero

; ---- threads: single-threaded serialized semantics -----------------
nbi_thrd_create:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
CALL @ni_pop
ST r1,r0,#W_UC_C
LD r1,r0,#W_UC_C
MOVI r2,1
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_UC_B
LD r2,r0,#W_UC_A
CALL @nbi_call1
ST r1,r0,#W_THRD_RESULT
nthc_done:
JMP @nbi_zero

nbi_thrd_join:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
CMP r1,r0
JMP[EQ] @nthj_done
LD r1,r0,#W_UC_A
LD r2,r0,#W_THRD_RESULT
MOVI r3,#SZ_32
CALL @ni_storev
nthj_done:
JMP @nbi_zero

nbi_thrd_current:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
nbi_thrd_equal:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
LD r2,r0,#W_UC_A
CMP r1,r2
MOVI r1,0
MOVI[EQ] r1,1
CALL @ni_push
JMP @nbi_d
nbi_thrd_sleep:
CALL @ni_pop
JMP @nbi_zero
nbi_thrd_yield:
JMP @nbi_zero
nbi_thrd_exit:
CALL @ni_pop
JMP @nbi_zero
nbi_thrd_detach:
CALL @ni_pop
JMP @nbi_zero

nbi_mtx_init:
CALL @ni_pop
CALL @ni_pop
ST r1,r0,#W_UC_A
MOVI r2,1
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nbi_zero
nbi_mtx_lock:
CALL @ni_pop
JMP @nbi_zero
nbi_mtx_trylock:
CALL @ni_pop
JMP @nbi_zero
nbi_mtx_timedlock:
CALL @ni_pop
CALL @ni_pop
JMP @nbi_zero
nbi_mtx_unlock:
CALL @ni_pop
JMP @nbi_zero
nbi_mtx_destroy:
CALL @ni_pop
JMP @nbi_zero
nbi_cnd_init:
CALL @ni_pop
JMP @nbi_zero
nbi_cnd_signal:
CALL @ni_pop
JMP @nbi_zero
nbi_cnd_broadcast:
CALL @ni_pop
JMP @nbi_zero
nbi_cnd_wait:
CALL @ni_pop
CALL @ni_pop
JMP @nbi_zero
nbi_cnd_timedwait:
CALL @ni_pop
CALL @ni_pop
CALL @ni_pop
JMP @nbi_zero
nbi_cnd_destroy:
CALL @ni_pop
JMP @nbi_zero

nbi_tss_create:
CALL @ni_pop
CALL @ni_pop
ST r1,r0,#W_UC_A
LD r2,r0,#W_TSS_N
ADD r2,r2,r13
ST r2,r0,#W_TSS_N
LD r1,r0,#W_UC_A
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nbi_zero
nbi_tss_get:
CALL @ni_pop
LA r2,#W_TSS_TAB
ADD r1,r2,r1
LD r1,r1,0
CALL @ni_push
JMP @nbi_d
nbi_tss_set:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
LA r2,#W_TSS_TAB
ADD r1,r2,r1
LD r2,r0,#W_UC_A
ST r2,r1,0
JMP @nbi_zero
nbi_tss_delete:
CALL @ni_pop
LA r2,#W_TSS_TAB
ADD r1,r2,r1
ST r0,r1,0
JMP @nbi_zero
nbi_call_once:
CALL @ni_pop
ST r1,r0,#W_UC_A
CALL @ni_pop
ST r1,r0,#W_UC_B
LD r1,r0,#W_UC_B
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[NE] @nco_done
LD r1,r0,#W_UC_B
MOVI r2,1
MOVI r3,#SZ_32
CALL @ni_storev
LD r2,r0,#W_UC_A
CMP r2,r0
JMP[EQ] @nco_done
LD r1,r0,#W_UC_A
CALL @nbi_call0
nco_done:
JMP @nbi_zero

; ---- registration of C11 headers -----------------------------------
iso_register_all:
ST r15,r14,0
ADD r14,r14,r13
CALL @iso_register_types
CALL @iso_register_enums
CALL @iso_register_builtins
SUB r14,r14,r13
LD r15,r14,0
RET

iso_register_types:
ST r15,r14,0
ADD r14,r14,r13
LA r8,@iso_type_tab
irt_l:
LD r1,r8,0
CMP r1,r0
JMP[EQ] @irt_d
ST r8,r14,0
ADD r14,r14,r13
LD r2,r8,1
LD r3,r8,2
LD r4,r8,3
CALL @ncc_add_typedef
SUB r14,r14,r13
LD r8,r14,0
ADDI r8,r8,4
JMP @irt_l
irt_d:
SUB r14,r14,r13
LD r15,r14,0
RET

iso_register_enums:
ST r15,r14,0
ADD r14,r14,r13
LA r8,@iso_enum_tab
ire_l:
LD r1,r8,0
CMP r1,r0
JMP[EQ] @ire_d
ST r8,r14,0
ADD r14,r14,r13
LD r2,r8,1
LD r3,r8,2
LD r4,r8,3
CALL @ncc_add_enum_const
SUB r14,r14,r13
LD r8,r14,0
ADDI r8,r8,4
JMP @ire_l
ire_d:
SUB r14,r14,r13
LD r15,r14,0
RET

iso_register_builtins:
ST r15,r14,0
ADD r14,r14,r13
LA r8,@iso_builtin_tab
irb_l:
LD r1,r8,0
CMP r1,r0
JMP[EQ] @irb_d
ST r8,r14,0
ADD r14,r14,r13
LD r2,r8,1
LD r3,r8,2
LD r4,r8,3
LD r5,r8,4
LD r6,r8,5
CALL @ncc_add_builtin
SUB r14,r14,r13
LD r8,r14,0
ADDI r8,r8,6
JMP @irb_l
irb_d:
SUB r14,r14,r13
LD r15,r14,0
RET

iso_type_tab:
.word 0xDC30B275, @ncc_s_atomic_bool, 11, 12
.word 0x5351F095, @ncc_s_atomic_char, 11, 2
.word 0xD1941ADE, @ncc_s_atomic_schar, 12, 2
.word 0xD6BA4F14, @ncc_s_atomic_uchar, 12, 3
.word 0x70BCC46D, @ncc_s_atomic_short, 12, 4
.word 0xCF47BDCA, @ncc_s_atomic_ushort, 13, 5
.word 0x7584C4D6, @ncc_s_atomic_int, 10, 6
.word 0x76C53389, @ncc_s_atomic_uint, 11, 7
.word 0x1610484B, @ncc_s_atomic_long, 11, 8
.word 0x81CFE0F6, @ncc_s_atomic_ulong, 12, 9
.word 0x878C940D, @ncc_s_atomic_llong, 12, 13
.word 0x206A68EA, @ncc_s_atomic_ullong, 13, 14
.word 0x0809E275, @ncc_s_atomic_char16_t, 15, 5
.word 0x26BA8BDB, @ncc_s_atomic_char32_t, 15, 7
.word 0xF32BE589, @ncc_s_atomic_wchar_t, 14, 6
.word 0x37FA769B, @ncc_s_atomic_intptr_t, 15, 6
.word 0xE4A60A36, @ncc_s_atomic_uintptr_t, 16, 7
.word 0xC133EF6F, @ncc_s_atomic_size_t, 13, 7
.word 0xC1D56405, @ncc_s_atomic_ptrdiff_t, 16, 6
.word 0x23EA350F, @ncc_s_atomic_flag, 11, 12
.word 0x1A9D67B4, @ncc_s_thrd_t, 6, 6
.word 0x0C19777F, @ncc_s_mtx_t, 5, 6
.word 0x747FDD6B, @ncc_s_cnd_t, 5, 6
.word 0xDEFBFC92, @ncc_s_tss_t, 5, 7
.word 0xD958A31B, @ncc_s_once_flag, 9, 6
.word 0xCDEB2F93, @ncc_s_fenv_t, 6, 7
.word 0x465A7C67, @ncc_s_fexcept_t, 9, 7
.word 0

iso_enum_tab:
.word 0x86AD2ED5, @ncc_s_memory_order_relaxed, 20, 0
.word 0xEDC727B8, @ncc_s_memory_order_consume, 20, 1
.word 0xAF651796, @ncc_s_memory_order_acquire, 20, 2
.word 0xD0990457, @ncc_s_memory_order_release, 20, 3
.word 0xF8816161, @ncc_s_memory_order_acq_rel, 20, 4
.word 0x14F55C78, @ncc_s_memory_order_seq_cst, 20, 5
.word 0x7D9D0332, @ncc_s_ATOMIC_FLAG_INIT, 16, 0
.word 0xFC947B22, @ncc_s_FE_TONEAREST, 12, 0
.word 0x0BD00A8F, @ncc_s_FE_DOWNWARD, 11, 1
.word 0xB87B1E1E, @ncc_s_FE_UPWARD, 9, 2
.word 0x2B515528, @ncc_s_FE_TOWARDZERO, 13, 3
.word 0xBDC055A5, @ncc_s_FE_INEXACT, 10, 1
.word 0x01846977, @ncc_s_FE_DIVBYZERO, 12, 2
.word 0xCF9116D1, @ncc_s_FE_UNDERFLOW, 12, 4
.word 0xC00E332F, @ncc_s_FE_OVERFLOW, 11, 8
.word 0x54F2D4B4, @ncc_s_FE_INVALID, 10, 16
.word 0x676609C0, @ncc_s_FE_ALL_EXCEPT, 13, 31
.word 0x473D39DB, @ncc_s_thrd_success, 12, 0
.word 0xDDCBCCA4, @ncc_s_thrd_nomem, 10, 1
.word 0xB132D3B1, @ncc_s_thrd_timedout, 13, 2
.word 0xB36FC7CD, @ncc_s_thrd_busy, 9, 3
.word 0xB1EFD74E, @ncc_s_thrd_error, 10, 4
.word 0x498C407B, @ncc_s_mtx_plain, 9, 0
.word 0x698AEB3B, @ncc_s_mtx_recursive, 13, 1
.word 0x1DF95E24, @ncc_s_mtx_timed, 9, 2
.word 0x15B9CE55, @ncc_s_STDC_UTF16, 15, 1
.word 0x27CC9417, @ncc_s_STDC_UTF32, 15, 1
.word 0x3407D4D1, @ncc_s_STDC_NOVLA, 16, 1
.word 0

iso_builtin_tab:
.word 0xAFFAE54B, @ncc_s_atomic_init, 11, 249, 2, 1
.word 0x19038111, @ncc_s_atomic_load, 11, 250, 1, 7
.word 0x946CE076, @ncc_s_atomic_store, 12, 251, 2, 1
.word 0x8A74AD98, @ncc_s_atomic_exchange, 15, 252, 2, 7
.word 0x17E0FF06, @ncc_s_atomic_compare_exchange_strong, 30, 253, 3, 6
.word 0x33A35D65, @ncc_s_atomic_compare_exchange_weak, 28, 253, 3, 6
.word 0x907F7747, @ncc_s_atomic_fetch_add, 16, 254, 2, 7
.word 0x985555CE, @ncc_s_atomic_fetch_sub, 16, 255, 2, 7
.word 0xD50837A1, @ncc_s_atomic_fetch_or, 15, 256, 2, 7
.word 0xDB4C7591, @ncc_s_atomic_fetch_xor, 16, 257, 2, 7
.word 0x748E55BD, @ncc_s_atomic_fetch_and, 16, 258, 2, 7
.word 0x7EA14E05, @ncc_s_atomic_flag_test_and_set, 24, 259, 1, 6
.word 0x401AEC9D, @ncc_s_atomic_flag_clear, 17, 260, 1, 1
.word 0x9D734743, @ncc_s_atomic_thread_fence, 19, 261, 1, 1
.word 0xC37D903B, @ncc_s_atomic_signal_fence, 19, 261, 1, 1
.word 0xC4866990, @ncc_s_atomic_is_lock_free, 19, 262, 1, 6
.word 0xCC50CE3A, @ncc_s_atomic_load_explicit, 20, 263, 2, 7
.word 0x019C86F3, @ncc_s_atomic_store_explicit, 21, 264, 3, 1
.word 0x431453C9, @ncc_s_atomic_exchange_explicit, 24, 265, 3, 7
.word 0xBAD107A3, @ncc_s_atomic_compare_exchange_strong_explicit, 39, 266, 5, 6
.word 0x2FFC36C6, @ncc_s_atomic_compare_exchange_weak_explicit, 37, 266, 5, 6
.word 0x41D379E4, @ncc_s_atomic_fetch_add_explicit, 25, 267, 3, 7
.word 0x0AEAAD6B, @ncc_s_atomic_fetch_sub_explicit, 25, 268, 3, 7
.word 0x9FB28B2A, @ncc_s_atomic_fetch_or_explicit, 24, 269, 3, 7
.word 0x32F0E3BA, @ncc_s_atomic_fetch_xor_explicit, 25, 270, 3, 7
.word 0x38981DFE, @ncc_s_atomic_fetch_and_explicit, 25, 271, 3, 7
.word 0xA3B23D26, @ncc_s_atomic_flag_test_and_set_explicit, 33, 272, 2, 6
.word 0x269AF49E, @ncc_s_atomic_flag_clear_explicit, 26, 273, 2, 1
.word 0xD9AC4508, @ncc_s_fegetround, 10, 274, 0, 6
.word 0x865AA3FC, @ncc_s_fesetround, 10, 275, 1, 6
.word 0xB63D967C, @ncc_s_feclearexcept, 13, 276, 1, 6
.word 0xF80683BD, @ncc_s_feraiseexcept, 13, 277, 1, 6
.word 0x89D74561, @ncc_s_fetestexcept, 12, 278, 1, 6
.word 0x53A2081F, @ncc_s_fegetenv, 8, 279, 1, 6
.word 0xDB710A5B, @ncc_s_fesetenv, 8, 280, 1, 6
.word 0xF4161E3C, @ncc_s_feholdexcept, 12, 281, 1, 6
.word 0xBE306404, @ncc_s_feupdateenv, 11, 282, 1, 6
.word 0x7DAAB17B, @ncc_s_fegetexceptflag, 15, 283, 2, 6
.word 0xFA891FB7, @ncc_s_fesetexceptflag, 15, 284, 2, 6
.word 0xF0CBF76C, @ncc_s_thrd_create, 11, 285, 3, 6
.word 0x278EF0F8, @ncc_s_thrd_join, 9, 286, 2, 6
.word 0x5D6B5C0D, @ncc_s_thrd_current, 12, 287, 0, 7
.word 0xFEAA4FA0, @ncc_s_thrd_equal, 10, 288, 2, 6
.word 0xF618CF7B, @ncc_s_thrd_sleep, 10, 289, 1, 6
.word 0xAF47B349, @ncc_s_thrd_yield, 10, 290, 0, 1
.word 0x02473FD8, @ncc_s_thrd_exit, 9, 291, 1, 1
.word 0xE388CA6F, @ncc_s_thrd_detach, 11, 292, 1, 6
.word 0xE03EF7AF, @ncc_s_mtx_init, 8, 293, 2, 6
.word 0xF86E2FDE, @ncc_s_mtx_lock, 8, 294, 1, 6
.word 0xB253F045, @ncc_s_mtx_trylock, 11, 295, 1, 6
.word 0x4256188B, @ncc_s_mtx_timedlock, 13, 296, 2, 6
.word 0xAE70D551, @ncc_s_mtx_unlock, 10, 297, 1, 6
.word 0xCB05DD19, @ncc_s_mtx_destroy, 11, 298, 1, 1
.word 0x7E277E5B, @ncc_s_cnd_init, 8, 299, 1, 6
.word 0x25B74DF1, @ncc_s_cnd_signal, 10, 300, 1, 6
.word 0x835DC6AC, @ncc_s_cnd_broadcast, 13, 301, 1, 6
.word 0x6F941008, @ncc_s_cnd_wait, 8, 302, 2, 6
.word 0xE25FF119, @ncc_s_cnd_timedwait, 13, 303, 3, 6
.word 0x1C6FB46D, @ncc_s_cnd_destroy, 11, 304, 1, 1
.word 0x824883C6, @ncc_s_tss_create, 10, 305, 2, 6
.word 0x6EA2DFBE, @ncc_s_tss_get, 7, 306, 1, 7
.word 0xDCB0F022, @ncc_s_tss_set, 7, 307, 2, 6
.word 0x247D8A6D, @ncc_s_tss_delete, 10, 308, 1, 1
.word 0xCDF0CF17, @ncc_s_call_once, 9, 309, 2, 1
.word 0
ncc_s_atomic_bool:
.str "atomic_bool"
ncc_s_atomic_char:
.str "atomic_char"
ncc_s_atomic_schar:
.str "atomic_schar"
ncc_s_atomic_uchar:
.str "atomic_uchar"
ncc_s_atomic_short:
.str "atomic_short"
ncc_s_atomic_ushort:
.str "atomic_ushort"
ncc_s_atomic_int:
.str "atomic_int"
ncc_s_atomic_uint:
.str "atomic_uint"
ncc_s_atomic_long:
.str "atomic_long"
ncc_s_atomic_ulong:
.str "atomic_ulong"
ncc_s_atomic_llong:
.str "atomic_llong"
ncc_s_atomic_ullong:
.str "atomic_ullong"
ncc_s_atomic_char16_t:
.str "atomic_char16_t"
ncc_s_atomic_char32_t:
.str "atomic_char32_t"
ncc_s_atomic_wchar_t:
.str "atomic_wchar_t"
ncc_s_atomic_intptr_t:
.str "atomic_intptr_t"
ncc_s_atomic_uintptr_t:
.str "atomic_uintptr_t"
ncc_s_atomic_size_t:
.str "atomic_size_t"
ncc_s_atomic_ptrdiff_t:
.str "atomic_ptrdiff_t"
ncc_s_atomic_flag:
.str "atomic_flag"
ncc_s_thrd_t:
.str "thrd_t"
ncc_s_mtx_t:
.str "mtx_t"
ncc_s_cnd_t:
.str "cnd_t"
ncc_s_tss_t:
.str "tss_t"
ncc_s_once_flag:
.str "once_flag"
ncc_s_fenv_t:
.str "fenv_t"
ncc_s_fexcept_t:
.str "fexcept_t"
ncc_s_memory_order_relaxed:
.str "memory_order_relaxed"
ncc_s_memory_order_consume:
.str "memory_order_consume"
ncc_s_memory_order_acquire:
.str "memory_order_acquire"
ncc_s_memory_order_release:
.str "memory_order_release"
ncc_s_memory_order_acq_rel:
.str "memory_order_acq_rel"
ncc_s_memory_order_seq_cst:
.str "memory_order_seq_cst"
ncc_s_ATOMIC_FLAG_INIT:
.str "ATOMIC_FLAG_INIT"
ncc_s_FE_TONEAREST:
.str "FE_TONEAREST"
ncc_s_FE_DOWNWARD:
.str "FE_DOWNWARD"
ncc_s_FE_UPWARD:
.str "FE_UPWARD"
ncc_s_FE_TOWARDZERO:
.str "FE_TOWARDZERO"
ncc_s_FE_INEXACT:
.str "FE_INEXACT"
ncc_s_FE_DIVBYZERO:
.str "FE_DIVBYZERO"
ncc_s_FE_UNDERFLOW:
.str "FE_UNDERFLOW"
ncc_s_FE_OVERFLOW:
.str "FE_OVERFLOW"
ncc_s_FE_INVALID:
.str "FE_INVALID"
ncc_s_FE_ALL_EXCEPT:
.str "FE_ALL_EXCEPT"
ncc_s_thrd_success:
.str "thrd_success"
ncc_s_thrd_nomem:
.str "thrd_nomem"
ncc_s_thrd_timedout:
.str "thrd_timedout"
ncc_s_thrd_busy:
.str "thrd_busy"
ncc_s_thrd_error:
.str "thrd_error"
ncc_s_mtx_plain:
.str "mtx_plain"
ncc_s_mtx_recursive:
.str "mtx_recursive"
ncc_s_mtx_timed:
.str "mtx_timed"
ncc_s_atomic_init:
.str "atomic_init"
ncc_s_atomic_load:
.str "atomic_load"
ncc_s_atomic_store:
.str "atomic_store"
ncc_s_atomic_exchange:
.str "atomic_exchange"
ncc_s_atomic_compare_exchange_strong:
.str "atomic_compare_exchange_strong"
ncc_s_atomic_compare_exchange_weak:
.str "atomic_compare_exchange_weak"
ncc_s_atomic_fetch_add:
.str "atomic_fetch_add"
ncc_s_atomic_fetch_sub:
.str "atomic_fetch_sub"
ncc_s_atomic_fetch_or:
.str "atomic_fetch_or"
ncc_s_atomic_fetch_xor:
.str "atomic_fetch_xor"
ncc_s_atomic_fetch_and:
.str "atomic_fetch_and"
ncc_s_atomic_flag_test_and_set:
.str "atomic_flag_test_and_set"
ncc_s_atomic_flag_clear:
.str "atomic_flag_clear"
ncc_s_atomic_thread_fence:
.str "atomic_thread_fence"
ncc_s_atomic_signal_fence:
.str "atomic_signal_fence"
ncc_s_atomic_is_lock_free:
.str "atomic_is_lock_free"
ncc_s_atomic_load_explicit:
.str "atomic_load_explicit"
ncc_s_atomic_store_explicit:
.str "atomic_store_explicit"
ncc_s_atomic_exchange_explicit:
.str "atomic_exchange_explicit"
ncc_s_atomic_compare_exchange_strong_explicit:
.str "atomic_compare_exchange_strong_explicit"
ncc_s_atomic_compare_exchange_weak_explicit:
.str "atomic_compare_exchange_weak_explicit"
ncc_s_atomic_fetch_add_explicit:
.str "atomic_fetch_add_explicit"
ncc_s_atomic_fetch_sub_explicit:
.str "atomic_fetch_sub_explicit"
ncc_s_atomic_fetch_or_explicit:
.str "atomic_fetch_or_explicit"
ncc_s_atomic_fetch_xor_explicit:
.str "atomic_fetch_xor_explicit"
ncc_s_atomic_fetch_and_explicit:
.str "atomic_fetch_and_explicit"
ncc_s_atomic_flag_test_and_set_explicit:
.str "atomic_flag_test_and_set_explicit"
ncc_s_atomic_flag_clear_explicit:
.str "atomic_flag_clear_explicit"
ncc_s_fegetround:
.str "fegetround"
ncc_s_fesetround:
.str "fesetround"
ncc_s_feclearexcept:
.str "feclearexcept"
ncc_s_feraiseexcept:
.str "feraiseexcept"
ncc_s_fetestexcept:
.str "fetestexcept"
ncc_s_fegetenv:
.str "fegetenv"
ncc_s_fesetenv:
.str "fesetenv"
ncc_s_feholdexcept:
.str "feholdexcept"
ncc_s_feupdateenv:
.str "feupdateenv"
ncc_s_fegetexceptflag:
.str "fegetexceptflag"
ncc_s_fesetexceptflag:
.str "fesetexceptflag"
ncc_s_thrd_create:
.str "thrd_create"
ncc_s_thrd_join:
.str "thrd_join"
ncc_s_thrd_current:
.str "thrd_current"
ncc_s_thrd_equal:
.str "thrd_equal"
ncc_s_thrd_sleep:
.str "thrd_sleep"
ncc_s_thrd_yield:
.str "thrd_yield"
ncc_s_thrd_exit:
.str "thrd_exit"
ncc_s_thrd_detach:
.str "thrd_detach"
ncc_s_mtx_init:
.str "mtx_init"
ncc_s_mtx_lock:
.str "mtx_lock"
ncc_s_mtx_trylock:
.str "mtx_trylock"
ncc_s_mtx_timedlock:
.str "mtx_timedlock"
ncc_s_mtx_unlock:
.str "mtx_unlock"
ncc_s_mtx_destroy:
.str "mtx_destroy"
ncc_s_cnd_init:
.str "cnd_init"
ncc_s_cnd_signal:
.str "cnd_signal"
ncc_s_cnd_broadcast:
.str "cnd_broadcast"
ncc_s_cnd_wait:
.str "cnd_wait"
ncc_s_cnd_timedwait:
.str "cnd_timedwait"
ncc_s_cnd_destroy:
.str "cnd_destroy"
ncc_s_tss_create:
.str "tss_create"
ncc_s_tss_get:
.str "tss_get"
ncc_s_tss_set:
.str "tss_set"
ncc_s_tss_delete:
.str "tss_delete"
ncc_s_call_once:
.str "call_once"
ncc_s_STDC_UTF16:
.str "__STDC_UTF_16__"
ncc_s_STDC_UTF32:
.str "__STDC_UTF_32__"
ncc_s_STDC_NOVLA:
.str "__STDC_NO_VLA__"
ncc_s_char16_t:
.str "char16_t"
ncc_s_char32_t:
.str "char32_t"
ncc_s_mbrtoc16:
.str "mbrtoc16"
ncc_s_c16rtomb:
.str "c16rtomb"
ncc_s_mbrtoc32:
.str "mbrtoc32"
ncc_s_c32rtomb:
.str "c32rtomb"
ncc_s_fwprintf:
.str "fwprintf"
ncc_s_fwscanf:
.str "fwscanf"
ncc_s_swprintf:
.str "swprintf"
ncc_s_swscanf:
.str "swscanf"
ncc_s_vfwprintf:
.str "vfwprintf"
ncc_s_vswprintf:
.str "vswprintf"
ncc_s_vfwscanf:
.str "vfwscanf"
ncc_s_vswscanf:
.str "vswscanf"
