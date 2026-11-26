; extra.nas - C library parity additions: inttypes aliases, wide ctype,
; errno, assert, and fwide (ASCII locale).

; ---- helpers -------------------------------------------------------
; ex_streq: r1,r2 byte strings -> r1=1/0
ex_streq:
SHL r2,r2,2
ex_se_l:
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @ex_se_n
CMP r3,r0
JMP[EQ] @ex_se_y
ADD r1,r1,r13
ADD r2,r2,r13
JMP @ex_se_l
ex_se_y:
MOVI r1,1
RET
ex_se_n:
MOVI r1,0
RET

; ex_seterr: r1=errno value
ex_seterr:
ST r1,r0,#W_EX_B
LD r2,r0,#W_ERRNO
CMP r2,r0
JMP[EQ] @ex_err_d
ADD r1,r2,r0
LD r2,r0,#W_EX_B
MOVI r3,#SZ_32
JMP @ni_storev
ex_err_d:
RET

; ex_iswclass: r1=wide char r2=class 1..11 -> r1=0/1
ex_iswclass:
CMPS r1,r0
JMP[LT] @exic_no
MOVI r3,127
CMP r1,r3
JMP[GT] @exic_no
CMP r2,r0
JMP[LE] @exic_no
MOVI r3,11
CMP r2,r3
JMP[GT] @exic_no
ST r1,r0,#W_EX_A
ST r2,r0,#W_EX_B
LD r2,r0,#W_EX_B
ADDI r2,r2,-1
LA r3,@ex_class_tab
ADD r3,r3,r2
LD r2,r3,0
LD r1,r0,#W_EX_A
exic_l:
LD r4,r2,0
LA r5,0xFFFFFFFF
CMP r4,r5
JMP[EQ] @exic_no
LD r5,r2,1
CMP r1,r4
JMP[LT] @exic_next
CMP r1,r5
JMP[LE] @exic_yes
exic_next:
ADDI r2,r2,2
JMP @exic_l
exic_yes:
MOVI r1,1
RET
exic_no:
MOVI r1,0
RET

; ---- type/global/enum registration ---------------------------------
ncc_extra_types:
ST r15,r14,0
ADD r14,r14,r13
; intmax_t
LA r1,0xED34307B
LA r2,@ncc_s_intmax_t
MOVI r3,8
MOVI r4,#T_LONGLONG
CALL @ncc_add_typedef
; uintmax_t
LA r1,0xE4A22E8E
LA r2,@ncc_s_uintmax_t
MOVI r3,9
MOVI r4,#T_ULONGLONG
CALL @ncc_add_typedef
; wctype_t / wctrans_t
LA r1,0x96A054A4
LA r2,@ncc_s_wctype_t
MOVI r3,8
MOVI r4,#T_ULONG
CALL @ncc_add_typedef
LA r1,0x66D49440
LA r2,@ncc_s_wctrans_t
MOVI r3,9
MOVI r4,#T_INT
CALL @ncc_add_typedef
; errno global and its address
LA r1,0x0C8F27AB
LA r2,@ncc_s_errno
MOVI r3,5
MOVI r4,#T_INT
MOVI r5,0
CALL @ncc_add_global
LD r1,r0,#W_AGSYM
LD r1,r1,#SY_AUX
ST r1,r0,#W_ERRNO
; errno constants
LA r1,0x4A78755C
LA r2,@ncc_s_EDOM
MOVI r3,4
MOVI r4,33
CALL @ncc_add_enum_const
LA r1,0x3B457F35
LA r2,@ncc_s_ERANGE
MOVI r3,6
MOVI r4,34
CALL @ncc_add_enum_const
LA r1,0xD78E2DFC
LA r2,@ncc_s_EILSEQ
MOVI r3,6
MOVI r4,84
CALL @ncc_add_enum_const
; reset stream orientation slots
ST r0,r0,#W_FWIDE_STD
ST r0,r0,#W_FWIDE_STD+1
ST r0,r0,#W_FWIDE_STD+2
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- builtin registration ------------------------------------------
ncc_extra_builtins:
ST r15,r14,0
ADD r14,r14,r13
; inttypes aliases
LA r1,0x39EF2266
LA r2,@ncc_s_imaxabs
MOVI r3,7
MOVI r4,#B_LLABS
MOVI r5,1
MOVI r6,#T_LONGLONG
CALL @ncc_add_builtin
LA r1,0x86F10805
LA r2,@ncc_s_imaxdiv
MOVI r3,7
MOVI r4,#B_LLDIV
MOVI r5,2
LD r6,r0,#W_LLDIVTYPE
CALL @ncc_add_builtin
LA r1,0xCAD4357E
LA r2,@ncc_s_strtoimax
MOVI r3,9
MOVI r4,#B_STRTOLL
MOVI r5,3
MOVI r6,#T_LONGLONG
CALL @ncc_add_builtin
LA r1,0xF509F6B2
LA r2,@ncc_s_strtoumax
MOVI r3,9
MOVI r4,#B_STRTOULL
MOVI r5,3
MOVI r6,#T_ULONGLONG
CALL @ncc_add_builtin
LA r1,0x78594F1A
LA r2,@ncc_s_wcstoimax
MOVI r3,9
MOVI r4,#B_WCSTOLL
MOVI r5,3
MOVI r6,#T_LONGLONG
CALL @ncc_add_builtin
LA r1,0xE1F40376
LA r2,@ncc_s_wcstoumax
MOVI r3,9
MOVI r4,#B_WCSTOULL
MOVI r5,3
MOVI r6,#T_ULONGLONG
CALL @ncc_add_builtin
; wide ctype: reuse the narrow builtin ids
LA r1,0xB7E47849
LA r2,@ncc_s_iswalnum
MOVI r3,8
MOVI r4,#B_ISALNUM
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xF6C3635E
LA r2,@ncc_s_iswalpha
MOVI r3,8
MOVI r4,#B_ISALPHA
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x9287E1AB
LA r2,@ncc_s_iswcntrl
MOVI r3,8
MOVI r4,#B_ISCNTRL
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x6FE4EF23
LA r2,@ncc_s_iswdigit
MOVI r3,8
MOVI r4,#B_ISDIGIT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x2F89FFEE
LA r2,@ncc_s_iswgraph
MOVI r3,8
MOVI r4,#B_ISGRAPH
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xB0CAA40B
LA r2,@ncc_s_iswlower
MOVI r3,8
MOVI r4,#B_ISLOWER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xE4F9D4E1
LA r2,@ncc_s_iswprint
MOVI r3,8
MOVI r4,#B_ISPRINT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xA24FFD96
LA r2,@ncc_s_iswpunct
MOVI r3,8
MOVI r4,#B_ISPUNCT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x2CEFF180
LA r2,@ncc_s_iswspace
MOVI r3,8
MOVI r4,#B_ISSPACE
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x6D17CC2A
LA r2,@ncc_s_iswupper
MOVI r3,8
MOVI r4,#B_ISUPPER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x2F1C7037
LA r2,@ncc_s_iswxdigit
MOVI r3,9
MOVI r4,#B_ISXDIGIT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x7E19EC76
LA r2,@ncc_s_towlower
MOVI r3,8
MOVI r4,#B_TOLOWER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xD7AD1083
LA r2,@ncc_s_towupper
MOVI r3,8
MOVI r4,#B_TOUPPER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; new builtins
LA r1,0xE4F256B7
LA r2,@ncc_s_wctype
MOVI r3,6
MOVI r4,#B_WCTYPE
MOVI r5,1
MOVI r6,#T_ULONG
CALL @ncc_add_builtin
LA r1,0x06F62387
LA r2,@ncc_s_iswctype
MOVI r3,8
MOVI r4,#B_ISWCTYPE
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x0E2FB2A3
LA r2,@ncc_s_wctrans
MOVI r3,7
MOVI r4,#B_WCTRANS
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x9AB672B0
LA r2,@ncc_s_towctrans
MOVI r3,9
MOVI r4,#B_TOWCTRANS
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xA5655C7B
LA r2,@ncc_s_assert
MOVI r3,6
MOVI r4,#B_ASSERT
MOVI r5,1
MOVI r6,#T_VOID
CALL @ncc_add_builtin
LA r1,0xE52DE7E6
LA r2,@ncc_s_fwide
MOVI r3,5
MOVI r4,#B_FWIDE
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- wctype / iswctype ---------------------------------------------
nbi_wctype:
CALL @ni_pop
ST r1,r0,#W_EX_A
LA r2,@ex_s_alnum
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_alnum
LD r1,r0,#W_EX_A
LA r2,@ex_s_alpha
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_alpha
LD r1,r0,#W_EX_A
LA r2,@ex_s_cntrl
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_cntrl
LD r1,r0,#W_EX_A
LA r2,@ex_s_digit
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_digit
LD r1,r0,#W_EX_A
LA r2,@ex_s_graph
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_graph
LD r1,r0,#W_EX_A
LA r2,@ex_s_lower
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_lower
LD r1,r0,#W_EX_A
LA r2,@ex_s_print
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_print
LD r1,r0,#W_EX_A
LA r2,@ex_s_punct
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_punct
LD r1,r0,#W_EX_A
LA r2,@ex_s_space
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_space
LD r1,r0,#W_EX_A
LA r2,@ex_s_upper
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_upper
LD r1,r0,#W_EX_A
LA r2,@ex_s_xdigit
CALL @ex_streq
CMP r1,r0
JMP[NE] @exw_xdigit
MOVI r1,0
JMP @exw_d
exw_alnum:
MOVI r1,1
JMP @exw_d
exw_alpha:
MOVI r1,2
JMP @exw_d
exw_cntrl:
MOVI r1,3
JMP @exw_d
exw_digit:
MOVI r1,4
JMP @exw_d
exw_graph:
MOVI r1,5
JMP @exw_d
exw_lower:
MOVI r1,6
JMP @exw_d
exw_print:
MOVI r1,7
JMP @exw_d
exw_punct:
MOVI r1,8
JMP @exw_d
exw_space:
MOVI r1,9
JMP @exw_d
exw_upper:
MOVI r1,10
JMP @exw_d
exw_xdigit:
MOVI r1,11
exw_d:
CALL @ni_push
JMP @nbi_d

nbi_iswctype:
CALL @ni_pop
ST r1,r0,#W_EX_A
CALL @ni_pop
LD r2,r0,#W_EX_A
CALL @ex_iswclass
CALL @ni_push
JMP @nbi_d

; ---- wctrans / towctrans -------------------------------------------
nbi_wctrans:
CALL @ni_pop
ST r1,r0,#W_EX_A
LA r2,@ex_s_tolower
CALL @ex_streq
CMP r1,r0
JMP[NE] @ext_lower
LD r1,r0,#W_EX_A
LA r2,@ex_s_toupper
CALL @ex_streq
CMP r1,r0
JMP[NE] @ext_upper
MOVI r1,0
JMP @ext_d
ext_lower:
MOVI r1,1
JMP @ext_d
ext_upper:
MOVI r1,2
ext_d:
CALL @ni_push
JMP @nbi_d

nbi_towctrans:
CALL @ni_pop
ADD r3,r1,r0
CALL @ni_pop
ADD r1,r1,r0
MOVI r2,1
CMP r3,r2
JMP[EQ] @extc_lower
MOVI r2,2
CMP r3,r2
JMP[EQ] @extc_upper
JMP @extc_d
extc_lower:
CMPS r1,r0
JMP[LT] @extc_d
MOVI r2,90
CMP r1,r2
JMP[GT] @extc_d
MOVI r2,65
CMP r1,r2
JMP[LT] @extc_d
ADDI r1,r1,32
JMP @extc_d
extc_upper:
CMPS r1,r0
JMP[LT] @extc_d
MOVI r2,122
CMP r1,r2
JMP[GT] @extc_d
MOVI r2,97
CMP r1,r2
JMP[LT] @extc_d
ADDI r1,r1,-32
extc_d:
CALL @ni_push
JMP @nbi_d

; ---- assert --------------------------------------------------------
nbi_assert:
CALL @ni_pop
CMP r1,r0
JMP[NE] @exa_ok
; assertion text is stderr when descriptors are active.
LD r2,r0,@ncc_fd
CMP r2,r0
JMP[EQ] @exa_nofd
MOVI r2,3
ST r2,r0,@ncc_fd
exa_nofd:
LA r1,@ex_assert_msg
SHL r1,r1,2
CALL @ni_puts
MOVI r1,10
CALL @ncc_putc
JMP @nbi_abort
exa_ok:
JMP @nbi_zero

; ---- fwide ---------------------------------------------------------
nbi_fwide:
CALL @ni_pop
ADD r5,r1,r0
CALL @ni_pop
CMP r1,r0
JMP[EQ] @exfw_zero
MOVI r2,4
CMP r1,r2
JMP[LT] @exfw_std
CALL @st_entry
CMP r1,r0
JMP[EQ] @exfw_zero
LD r3,r1,9
CMP r3,r0
JMP[NE] @exfw_ret
CMP r5,r0
JMP[EQ] @exfw_ret
CMP r5,r0
JMP[LT] @exfw_byte
MOVI r3,1
JMP @exfw_set
exfw_byte:
LA r3,0xFFFFFFFF
exfw_set:
ST r3,r1,9
exfw_ret:
ADD r1,r3,r0
CALL @ni_push
JMP @nbi_d
exfw_std:
LA r2,#W_FWIDE_STD
ADD r2,r2,r1
ADDI r2,r2,-1
LD r3,r2,0
CMP r3,r0
JMP[NE] @exfw_std_ret
CMP r5,r0
JMP[EQ] @exfw_std_ret
CMP r5,r0
JMP[LT] @exfw_std_byte
MOVI r3,1
JMP @exfw_std_set
exfw_std_byte:
LA r3,0xFFFFFFFF
exfw_std_set:
ST r3,r2,0
exfw_std_ret:
ADD r1,r3,r0
CALL @ni_push
JMP @nbi_d
exfw_zero:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

; ---- class range tables -------------------------------------------
ex_class_tab:
.word @ex_r_alnum,@ex_r_alpha,@ex_r_cntrl,@ex_r_digit,@ex_r_graph
.word @ex_r_lower,@ex_r_print,@ex_r_punct,@ex_r_space,@ex_r_upper,@ex_r_xdigit
ex_r_alnum:
.word 48,57,65,90,97,122,0xFFFFFFFF,0
ex_r_alpha:
.word 65,90,97,122,0xFFFFFFFF,0
ex_r_cntrl:
.word 0,31,127,127,0xFFFFFFFF,0
ex_r_digit:
.word 48,57,0xFFFFFFFF,0
ex_r_graph:
.word 33,126,0xFFFFFFFF,0
ex_r_lower:
.word 97,122,0xFFFFFFFF,0
ex_r_print:
.word 32,126,0xFFFFFFFF,0
ex_r_punct:
.word 33,47,58,64,91,96,123,126,0xFFFFFFFF,0
ex_r_space:
.word 9,13,32,32,0xFFFFFFFF,0
ex_r_upper:
.word 65,90,0xFFFFFFFF,0
ex_r_xdigit:
.word 48,57,65,70,97,102,0xFFFFFFFF,0

ncc_s_intmax_t:
.str "intmax_t"
ncc_s_uintmax_t:
.str "uintmax_t"
ncc_s_imaxdiv_t:
.str "imaxdiv_t"
ncc_s_wctype_t:
.str "wctype_t"
ncc_s_wctrans_t:
.str "wctrans_t"
ncc_s_errno:
.str "errno"
ncc_s_EDOM:
.str "EDOM"
ncc_s_ERANGE:
.str "ERANGE"
ncc_s_EILSEQ:
.str "EILSEQ"
ncc_s_imaxabs:
.str "imaxabs"
ncc_s_imaxdiv:
.str "imaxdiv"
ncc_s_strtoimax:
.str "strtoimax"
ncc_s_strtoumax:
.str "strtoumax"
ncc_s_wcstoimax:
.str "wcstoimax"
ncc_s_wcstoumax:
.str "wcstoumax"
ncc_s_iswalnum:
.str "iswalnum"
ncc_s_iswalpha:
.str "iswalpha"
ncc_s_iswcntrl:
.str "iswcntrl"
ncc_s_iswdigit:
.str "iswdigit"
ncc_s_iswgraph:
.str "iswgraph"
ncc_s_iswlower:
.str "iswlower"
ncc_s_iswprint:
.str "iswprint"
ncc_s_iswpunct:
.str "iswpunct"
ncc_s_iswspace:
.str "iswspace"
ncc_s_iswupper:
.str "iswupper"
ncc_s_iswxdigit:
.str "iswxdigit"
ncc_s_towlower:
.str "towlower"
ncc_s_towupper:
.str "towupper"
ncc_s_wctype:
.str "wctype"
ncc_s_iswctype:
.str "iswctype"
ncc_s_wctrans:
.str "wctrans"
ncc_s_towctrans:
.str "towctrans"
ncc_s_assert:
.str "assert"
ncc_s_fwide:
.str "fwide"
ex_s_alnum:
.str "alnum"
ex_s_alpha:
.str "alpha"
ex_s_cntrl:
.str "cntrl"
ex_s_digit:
.str "digit"
ex_s_graph:
.str "graph"
ex_s_lower:
.str "lower"
ex_s_print:
.str "print"
ex_s_punct:
.str "punct"
ex_s_space:
.str "space"
ex_s_upper:
.str "upper"
ex_s_xdigit:
.str "xdigit"
ex_s_tolower:
.str "tolower"
ex_s_toupper:
.str "toupper"
ex_assert_msg:
.str "assertion failed"
