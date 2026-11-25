; wide2.nas - remaining wide-string and multibyte helpers (raw NaN16).

.equ W_WTOK 0xF074E

.equ W_W2V 0xF074F
.equ W_W2A 0xF0750
.equ W_W2B 0xF0751
.equ W_W2C 0xF0752
.equ W_W2D 0xF0753
.equ W_W2E 0xF0754
.equ W_W2F 0xF0755
.equ W_W2G 0xF0756
.equ W_W2H 0xF0757
.equ W_W2I 0xF0758
.equ W_W2J 0xF0759
w2_load:
MOVI r2,#SZ_32
JMP @ni_loadv
w2_store:
MOVI r3,#SZ_32
JMP @ni_storev


; w2_strlen: r1=wide string -> r2=length
w2_strlen:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,0
w2s_l:
ADD r1,r1,r0
CALL @w2_load
ADD r3,r1,r0
CMP r3,r0
JMP[EQ] @w2s_d
ADDI r1,r1,4
ADD r2,r2,r13
JMP @w2s_l
w2s_d:
SUB r14,r14,r13
LD r15,r14,0
RET

w2_streq:
ST r15,r14,0
ADD r14,r14,r13
w2e_l:
ADD r8,r1,r0
ADD r9,r2,r0
ADD r1,r8,r0
CALL @w2_load
ADD r10,r1,r0
ADD r1,r9,r0
CALL @w2_load
ADD r11,r1,r0
CMP r10,r11
JMP[NE] @w2e_n
CMP r10,r0
JMP[EQ] @w2e_y
ADDI r8,r8,4
ADDI r9,r9,4
ADD r1,r8,r0
ADD r2,r9,r0
JMP @w2e_l
w2e_y:
MOVI r3,1
JMP @w2e_d
w2e_n:
MOVI r3,0
w2e_d:
SUB r14,r14,r13
LD r15,r14,0
RET


; w2_inlist: r1=char r2=wide list -> r1=1/0
w2_inlist:
ST r15,r14,0
ADD r14,r14,r13
ADD r8,r2,r0
ADD r9,r1,r0
w2il_l:
ADD r1,r8,r0
CALL @w2_load
CMP r1,r0
JMP[EQ] @w2il_n
CMP r1,r9
JMP[EQ] @w2il_y
ADDI r8,r8,4
JMP @w2il_l
w2il_y:
MOVI r1,1
JMP @w2il_d
w2il_n:
MOVI r1,0
w2il_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_wcschr:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ADD r7,r1,r0
wcschr_l:
ADD r1,r7,r0
CALL @w2_load
ADD r3,r1,r0
LD r4,r0,#W_TA
CMP r3,r4
JMP[EQ] @wcschr_y
CMP r3,r0
JMP[EQ] @wcschr_n
ADDI r7,r7,4
JMP @wcschr_l
wcschr_y:
ADD r1,r7,r0
JMP @wcschr_p
wcschr_n:
MOVI r1,0
wcschr_p:
CALL @ni_push
JMP @nbi_d

nbi_wcsrchr:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ADD r7,r1,r0
MOVI r10,0
wcsr_l:
ADD r1,r7,r0
CALL @w2_load
ADD r3,r1,r0
LD r4,r0,#W_TA
CMP r3,r4
JMP[NE] @wcsr_nx
ADD r10,r7,r0
wcsr_nx:
CMP r3,r0
JMP[EQ] @wcsr_d
ADDI r7,r7,4
JMP @wcsr_l
wcsr_d:
ADD r1,r10,r0
CALL @ni_push
JMP @nbi_d

nbi_wcsncmp:
CALL @ni_pop
ST r1,r0,#W_W2C
CALL @ni_pop
ST r1,r0,#W_W2B
CALL @ni_pop
ST r1,r0,#W_W2A
wcsncmp_l:
LD r1,r0,#W_W2C
CMP r1,r0
JMP[LE] @wcsncmp_z
LD r1,r0,#W_W2A
CALL @w2_load
ST r1,r0,#W_W2D
LD r1,r0,#W_W2B
CALL @w2_load
ST r1,r0,#W_W2E
LD r2,r0,#W_W2D
CMP r2,r1
JMP[NE] @wcsncmp_diff
CMP r2,r0
JMP[EQ] @wcsncmp_z
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
LD r1,r0,#W_W2B
ADDI r1,r1,4
ST r1,r0,#W_W2B
LD r1,r0,#W_W2C
ADDI r1,r1,-1
ST r1,r0,#W_W2C
JMP @wcsncmp_l
wcsncmp_diff:
LD r1,r0,#W_W2D
LD r2,r0,#W_W2E
CMPS r1,r2
JMP[LT] @wcsncmp_neg
MOVI r1,1
JMP @wcsncmp_p
wcsncmp_neg:
LA r1,0xFFFFFFFF
JMP @wcsncmp_p
wcsncmp_z:
MOVI r1,0
wcsncmp_p:
CALL @ni_push
JMP @nbi_d

nbi_wcsncpy:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
wcsncpy_l:
CMP r9,r0
JMP[LE] @wcsncpy_d
ADD r1,r8,r0
CALL @w2_load
ADD r3,r1,r0
ST r3,r0,#W_W2V
ADD r1,r7,r0
LD r2,r0,#W_W2V
CALL @w2_store
CMP r3,r0
JMP[EQ] @wcsncpy_pad
ADDI r7,r7,4
ADDI r8,r8,4
SUB r9,r9,r13
JMP @wcsncpy_l
wcsncpy_pad:
SUB r9,r9,r13
CMP r9,r0
JMP[LE] @wcsncpy_d
ADDI r7,r7,4
ST r0,r0,#W_W2V
ADD r1,r7,r0
LD r2,r0,#W_W2V
CALL @w2_store
JMP @wcsncpy_pad
wcsncpy_d:
CALL @ni_push
JMP @nbi_d

nbi_wcsncat:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
ST r7,r0,#W_TA
wcsncat_find:
ADD r1,r7,r0
CALL @w2_load
ADD r3,r1,r0
CMP r3,r0
JMP[EQ] @wcsncat_l
ADDI r7,r7,4
JMP @wcsncat_find
wcsncat_l:
CMP r9,r0
JMP[LE] @wcsncat_nul
ADD r1,r8,r0
CALL @w2_load
ADD r3,r1,r0
CMP r3,r0
JMP[EQ] @wcsncat_nul
ST r3,r0,#W_W2V
ADD r1,r7,r0
LD r2,r0,#W_W2V
CALL @w2_store
ADDI r7,r7,4
ADDI r8,r8,4
SUB r9,r9,r13
JMP @wcsncat_l
wcsncat_nul:
ST r0,r0,#W_W2V
ADD r1,r7,r0
LD r2,r0,#W_W2V
CALL @w2_store
LD r1,r0,#W_TA
CALL @ni_push
JMP @nbi_d

nbi_wcsspn:
CALL @ni_pop
ST r1,r0,#W_W2B
CALL @ni_pop
ST r1,r0,#W_W2A
ST r0,r0,#W_W2C
wcsspn_l:
LD r1,r0,#W_W2A
CALL @w2_load
ST r1,r0,#W_W2D
CMP r1,r0
JMP[EQ] @wcsspn_d
LD r2,r0,#W_W2B
LD r1,r0,#W_W2D
CALL @w2_inlist
CMP r1,r0
JMP[EQ] @wcsspn_d
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
LD r1,r0,#W_W2C
ADD r1,r1,r13
ST r1,r0,#W_W2C
JMP @wcsspn_l
wcsspn_d:
LD r1,r0,#W_W2C
CALL @ni_push
JMP @nbi_d

nbi_wcscspn:
CALL @ni_pop
ST r1,r0,#W_W2B
CALL @ni_pop
ST r1,r0,#W_W2A
ST r0,r0,#W_W2C
wcscspn_l:
LD r1,r0,#W_W2A
CALL @w2_load
ST r1,r0,#W_W2D
CMP r1,r0
JMP[EQ] @wcscspn_d
LD r2,r0,#W_W2B
LD r1,r0,#W_W2D
CALL @w2_inlist
CMP r1,r0
JMP[NE] @wcscspn_d
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
LD r1,r0,#W_W2C
ADD r1,r1,r13
ST r1,r0,#W_W2C
JMP @wcscspn_l
wcscspn_d:
LD r1,r0,#W_W2C
CALL @ni_push
JMP @nbi_d

nbi_wcspbrk:
CALL @ni_pop
ST r1,r0,#W_W2B
CALL @ni_pop
ST r1,r0,#W_W2A
wcspb_l:
LD r1,r0,#W_W2A
CALL @w2_load
ST r1,r0,#W_W2D
CMP r1,r0
JMP[EQ] @wcspb_n
LD r2,r0,#W_W2B
LD r1,r0,#W_W2D
CALL @w2_inlist
CMP r1,r0
JMP[NE] @wcspb_y
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
JMP @wcspb_l
wcspb_y:
LD r1,r0,#W_W2A
JMP @wcspb_p
wcspb_n:
MOVI r1,0
wcspb_p:
CALL @ni_push
JMP @nbi_d

nbi_wcsstr:
CALL @ni_pop
ST r1,r0,#W_W2B
CALL @ni_pop
ST r1,r0,#W_W2A
LD r1,r0,#W_W2B
CALL @w2_load
CMP r1,r0
JMP[NE] @wcsstr_l
LD r1,r0,#W_W2A
CALL @ni_push
JMP @nbi_d
wcsstr_l:
LD r1,r0,#W_W2A
CALL @w2_load
CMP r1,r0
JMP[EQ] @wcsstr_n
LD r1,r0,#W_W2A
LD r2,r0,#W_W2B
CALL @w2_streq
CMP r3,r0
JMP[NE] @wcsstr_y
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
JMP @wcsstr_l
wcsstr_y:
LD r1,r0,#W_W2A
JMP @wcsstr_p
wcsstr_n:
MOVI r1,0
wcsstr_p:
CALL @ni_push
JMP @nbi_d

nbi_wcstok:
CALL @ni_pop
ST r1,r0,#W_W2B
CALL @ni_pop
CMP r1,r0
JMP[NE] @wcstok_have
LD r1,r0,#W_WTOK
wcstok_have:
CMP r1,r0
JMP[EQ] @wcstok_none
ST r1,r0,#W_W2A
wcstok_skip:
LD r1,r0,#W_W2A
CALL @w2_load
ST r1,r0,#W_W2D
CMP r1,r0
JMP[EQ] @wcstok_none
LD r2,r0,#W_W2B
LD r1,r0,#W_W2D
CALL @w2_inlist
CMP r1,r0
JMP[EQ] @wcstok_start
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
JMP @wcstok_skip
wcstok_start:
LD r1,r0,#W_W2A
ST r1,r0,#W_W2C
wcstok_adv:
LD r1,r0,#W_W2A
CALL @w2_load
ST r1,r0,#W_W2D
CMP r1,r0
JMP[EQ] @wcstok_end
LD r2,r0,#W_W2B
LD r1,r0,#W_W2D
CALL @w2_inlist
CMP r1,r0
JMP[NE] @wcstok_cut
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
JMP @wcstok_adv
wcstok_cut:
LD r1,r0,#W_W2A
ADD r2,r1,r0
ST r0,r2,0
ADDI r1,r1,4
ST r1,r0,#W_WTOK
LD r1,r0,#W_W2C
JMP @wcstok_p
wcstok_end:
ST r0,r0,#W_WTOK
LD r1,r0,#W_W2C
JMP @wcstok_p
wcstok_none:
ST r0,r0,#W_WTOK
MOVI r1,0
wcstok_p:
CALL @ni_push
JMP @nbi_d

nbi_wmemchr:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
wmemchr_l:
CMP r9,r0
JMP[LE] @wmemchr_n
ADD r1,r7,r0
CALL @w2_load
ADD r3,r1,r0
CMP r3,r8
JMP[EQ] @wmemchr_y
ADDI r7,r7,4
SUB r9,r9,r13
JMP @wmemchr_l
wmemchr_y:
ADD r1,r7,r0
JMP @wmemchr_p
wmemchr_n:
MOVI r1,0
wmemchr_p:
CALL @ni_push
JMP @nbi_d

nbi_wmemcmp:
CALL @ni_pop
ST r1,r0,#W_W2C
CALL @ni_pop
ST r1,r0,#W_W2B
CALL @ni_pop
ST r1,r0,#W_W2A
wmemcmp_l:
LD r1,r0,#W_W2C
CMP r1,r0
JMP[LE] @wmemcmp_z
LD r1,r0,#W_W2A
CALL @w2_load
ST r1,r0,#W_W2D
LD r1,r0,#W_W2B
CALL @w2_load
ST r1,r0,#W_W2E
LD r2,r0,#W_W2D
CMP r2,r1
JMP[NE] @wmemcmp_diff
LD r1,r0,#W_W2A
ADDI r1,r1,4
ST r1,r0,#W_W2A
LD r1,r0,#W_W2B
ADDI r1,r1,4
ST r1,r0,#W_W2B
LD r1,r0,#W_W2C
ADDI r1,r1,-1
ST r1,r0,#W_W2C
JMP @wmemcmp_l
wmemcmp_diff:
LD r1,r0,#W_W2D
LD r2,r0,#W_W2E
CMPS r1,r2
JMP[LT] @wmemcmp_neg
MOVI r1,1
JMP @wmemcmp_p
wmemcmp_neg:
LA r1,0xFFFFFFFF
JMP @wmemcmp_p
wmemcmp_z:
MOVI r1,0
wmemcmp_p:
CALL @ni_push
JMP @nbi_d

nbi_wmemcpy:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
ST r7,r0,#W_TA
wmemcpy_l:
CMP r9,r0
JMP[LE] @wmemcpy_d
ADD r1,r8,r0
CALL @w2_load
ADD r3,r1,r0
ST r3,r0,#W_W2V
ADD r1,r7,r0
LD r2,r0,#W_W2V
CALL @w2_store
ADDI r7,r7,4
ADDI r8,r8,4
SUB r9,r9,r13
JMP @wmemcpy_l
wmemcpy_d:
LD r1,r0,#W_TA
CALL @ni_push
JMP @nbi_d

nbi_wmemmove:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
ST r7,r0,#W_TA
CMPS r7,r8
JMP[LT] @wmemmove_fwd
; backward copy
MOVI r10,0
wmemmove_b:
CMP r10,r9
JMP[GE] @wmemmove_d
SUB r11,r9,r13
SUB r11,r11,r10
SHL r11,r11,2
ADD r12,r7,r11
ADD r11,r8,r11
ADD r1,r11,r0
CALL @w2_load
ADD r3,r1,r0
ST r3,r0,#W_W2V
ADD r1,r12,r0
LD r2,r0,#W_W2V
CALL @w2_store
ADD r10,r10,r13
JMP @wmemmove_b
wmemmove_fwd:
MOVI r10,0
wmemmove_f:
CMP r10,r9
JMP[GE] @wmemmove_d
SHL r11,r10,2
ADD r12,r7,r11
ADD r11,r8,r11
ADD r1,r11,r0
CALL @w2_load
ADD r3,r1,r0
ST r3,r0,#W_W2V
ADD r1,r12,r0
LD r2,r0,#W_W2V
CALL @w2_store
ADD r10,r10,r13
JMP @wmemmove_f
wmemmove_d:
LD r1,r0,#W_TA
CALL @ni_push
JMP @nbi_d

nbi_wmemset:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
ST r7,r0,#W_TA
wmemset_l:
CMP r9,r0
JMP[LE] @wmemset_d
ST r8,r0,#W_W2V
ADD r1,r7,r0
LD r2,r0,#W_W2V
CALL @w2_store
ADDI r7,r7,4
SUB r9,r9,r13
JMP @wmemset_l
wmemset_d:
LD r1,r0,#W_TA
CALL @ni_push
JMP @nbi_d

nbi_btowc:
CALL @ni_pop
CMPS r1,r0
JMP[LT] @btowc_e
MOVI r2,255
CMP r1,r2
JMP[GT] @btowc_e
CALL @ni_push
JMP @nbi_d
btowc_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_wctob:
CALL @ni_pop
CMPS r1,r0
JMP[LT] @wctob_e
MOVI r2,255
CMP r1,r2
JMP[GT] @wctob_e
CALL @ni_push
JMP @nbi_d
wctob_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_mblen:
CALL @ni_pop
CALL @ni_pop
CMP r1,r0
JMP[EQ] @mblen_z
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mblen_z
MOVI r1,1
CALL @ni_push
JMP @nbi_d
mblen_z:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_mbtowc:
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
CMP r8,r0
JMP[EQ] @mbtowc_z
LDB r3,r8,0
CMP r3,r0
JMP[EQ] @mbtowc_z
CMP r7,r0
JMP[EQ] @mbtowc_ok
ADD r1,r7,r0
ADD r2,r3,r0
MOVI r3,#SZ_32
CALL @ni_storev
mbtowc_ok:
MOVI r1,1
CALL @ni_push
JMP @nbi_d
mbtowc_z:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_wctomb:
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
CMP r7,r0
JMP[EQ] @wctomb_z
CMPS r8,r0
JMP[LT] @wctomb_e
MOVI r2,255
CMP r8,r2
JMP[GT] @wctomb_e
STB r8,r7,0
MOVI r1,1
CALL @ni_push
JMP @nbi_d
wctomb_z:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
wctomb_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_mbstowcs:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
MOVI r10,0
mbstowcs_l:
CMP r10,r9
JMP[GE] @mbstowcs_d
LDB r3,r8,0
CMP r3,r0
JMP[EQ] @mbstowcs_nul
CMP r7,r0
JMP[EQ] @mbstowcs_skip
SHL r11,r10,2
ADD r11,r7,r11
ADD r1,r11,r0
ADD r2,r3,r0
MOVI r3,#SZ_32
CALL @ni_storev
mbstowcs_skip:
ADDI r8,r8,1
ADD r10,r10,r13
JMP @mbstowcs_l
mbstowcs_nul:
CMP r7,r0
JMP[EQ] @mbstowcs_d
SHL r11,r10,2
ADD r11,r7,r11
ST r0,r0,#W_W2V
ADD r1,r11,r0
LD r2,r0,#W_W2V
CALL @w2_store
mbstowcs_d:
ADD r1,r10,r0
CALL @ni_push
JMP @nbi_d

nbi_wcstombs:
CALL @ni_pop
ADD r9,r1,r0
CALL @ni_pop
ADD r8,r1,r0
CALL @ni_pop
ADD r7,r1,r0
MOVI r10,0
wcstombs_l:
CMP r10,r9
JMP[GE] @wcstombs_d
ADD r1,r8,r0
CALL @w2_load
ADD r3,r1,r0
CMP r3,r0
JMP[EQ] @wcstombs_nul
CMP r7,r0
JMP[EQ] @wcstombs_skip
MOVI r2,255
CMP r3,r2
JMP[GT] @wcstombs_e
ADD r11,r7,r10
STB r3,r11,0
wcstombs_skip:
ADDI r8,r8,4
ADD r10,r10,r13
JMP @wcstombs_l
wcstombs_nul:
CMP r7,r0
JMP[EQ] @wcstombs_d
ADD r11,r7,r10
STB r0,r11,0
wcstombs_d:
ADD r1,r10,r0
CALL @ni_push
JMP @nbi_d
wcstombs_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

ncc_s_wcschr:
.str "wcschr"
ncc_s_wcsrchr:
.str "wcsrchr"
ncc_s_wcsncmp:
.str "wcsncmp"
ncc_s_wcsncpy:
.str "wcsncpy"
ncc_s_wcsncat:
.str "wcsncat"
ncc_s_wcsspn:
.str "wcsspn"
ncc_s_wcscspn:
.str "wcscspn"
ncc_s_wcspbrk:
.str "wcspbrk"
ncc_s_wcsstr:
.str "wcsstr"
ncc_s_wcstok:
.str "wcstok"
ncc_s_wmemchr:
.str "wmemchr"
ncc_s_wmemcmp:
.str "wmemcmp"
ncc_s_wmemcpy:
.str "wmemcpy"
ncc_s_wmemmove:
.str "wmemmove"
ncc_s_wmemset:
.str "wmemset"
ncc_s_btowc:
.str "btowc"
ncc_s_wctob:
.str "wctob"
ncc_s_mblen:
.str "mblen"
ncc_s_mbtowc:
.str "mbtowc"
ncc_s_wctomb:
.str "wctomb"
ncc_s_mbstowcs:
.str "mbstowcs"
ncc_s_wcstombs:
.str "wcstombs"
ncc_s_exp2:
.str "exp2"
ncc_s_log2:
.str "log2"
ncc_s_log1p:
.str "log1p"
ncc_s_expm1:
.str "expm1"
ncc_s_hypot:
.str "hypot"
ncc_s_cbrt:
.str "cbrt"
ncc_s_sinh:
.str "sinh"
ncc_s_cosh:
.str "cosh"
ncc_s_asinh:
.str "asinh"
ncc_s_acosh:
.str "acosh"
ncc_s_atanh:
.str "atanh"
ncc_s_trunc:
.str "trunc"
ncc_s_round:
.str "round"
ncc_s_rint:
.str "rint"
ncc_s_nearbyint:
.str "nearbyint"
ncc_s_copysign:
.str "copysign"
ncc_s_nan:
.str "nan"
ncc_s_fdim:
.str "fdim"
ncc_s_fma:
.str "fma"
ncc_s_modf:
.str "modf"
ncc_s_ldexp:
.str "ldexp"
ncc_s_scalbn:
.str "scalbn"
ncc_s_remainder:
.str "remainder"
ncc_s_atexit:
.str "atexit"
ncc_s__Exit:
.str "_Exit"
atexit_tab:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
