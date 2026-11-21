; ppexpr.nas - integer constant-expression evaluator for #if / #elif.
; The minimal preprocessor used to accept only 0/1/defined(NAME)/NAME; this
; parser adds the C preprocessor operator set over object-like macro values,
; integer and character constants, parentheses, and defined().
;
; Token kinds
.equ PPE_END   0
.equ PPE_NUM   1
.equ PPE_WORD  2
.equ PPE_OP    3
.equ PPE_LP    4
.equ PPE_RP    5
; Operators, in precedence order (low to high)
.equ PPE_OROR  1
.equ PPE_ANDAND 2
.equ PPE_BOR   3
.equ PPE_BXOR  4
.equ PPE_BAND  5
.equ PPE_EQ    6
.equ PPE_NE    7
.equ PPE_LT    8
.equ PPE_LE    9
.equ PPE_GT    10
.equ PPE_GE    11
.equ PPE_SHL   12
.equ PPE_SHR   13
.equ PPE_ADD   14
.equ PPE_SUB   15
.equ PPE_MUL   16
.equ PPE_DIV   17
.equ PPE_MOD   18
.equ PPE_NOT   19
.equ PPE_BNOT  20
.equ PPE_POS   21
.equ PPE_NEG   22
.equ PPE_QMARK 23
.equ PPE_COLON 24
; Scratch words (above the allocator/header scratch block)
.equ W_PPE_KIND 61828
.equ W_PPE_VAL  61829
.equ W_PPE_OP   61830
.equ W_PPE_HASH 61831
.equ W_PPE_LEN  61832
.equ W_PPE_T0   61833
.equ W_PPE_T1   61834
.equ W_PPE_T2   61835

; ppe_expr_eval: evaluate the rest of the directive line -> r1=0/1
ppe_expr_eval:
ST r15,r14,0
ADD r14,r14,r13
CALL @ppe_adv
MOVI r1,0
CALL @ppe_expr
ST r1,r0,#W_PPE_T0
LD r1,r0,#W_PPE_T0
CMP r1,r0
MOVI r1,0
MOVI[NE] r1,1
SUB r14,r14,r13
LD r15,r14,0
RET

; ppe_adv: read the next token into W_PPE_KIND/VAL/OP/HASH/LEN
ppe_adv:
ST r15,r14,0
ADD r14,r14,r13
CALL @q2_skipsp
CALL @lx_peek
CMP r1,r0
JMP[EQ] @ppe_end
MOVI r2,10
CMP r1,r2
JMP[EQ] @ppe_end
MOVI r2,13
CMP r1,r2
JMP[EQ] @ppe_end
; decimal digit
MOVI r2,48
CMP r1,r2
JMP[LT] @ppe_ident
MOVI r2,58
CMP r1,r2
JMP[LT] @ppe_num
ppe_ident:
; identifier start: '_' or letter
MOVI r2,95
CMP r1,r2
JMP[EQ] @ppe_word
MOVI r2,65
CMP r1,r2
JMP[LT] @ppe_punct
MOVI r2,91
CMP r1,r2
JMP[LT] @ppe_word
MOVI r2,97
CMP r1,r2
JMP[LT] @ppe_punct
MOVI r2,123
CMP r1,r2
JMP[LT] @ppe_word
ppe_punct:
MOVI r2,39
CMP r1,r2
JMP[EQ] @ppe_char
MOVI r2,40
CMP r1,r2
JMP[EQ] @ppe_lparen
MOVI r2,41
CMP r1,r2
JMP[EQ] @ppe_rparen
; two-character operators
MOVI r10,0
CALL @peekn
MOVI r2,124
CMP r1,r2
JMP[EQ] @ppe_p_or
MOVI r2,38
CMP r1,r2
JMP[EQ] @ppe_p_and
MOVI r2,60
CMP r1,r2
JMP[EQ] @ppe_p_lt
MOVI r2,62
CMP r1,r2
JMP[EQ] @ppe_p_gt
MOVI r2,61
CMP r1,r2
JMP[EQ] @ppe_p_eq
MOVI r2,33
CMP r1,r2
JMP[EQ] @ppe_p_ne
JMP @ppe_one

ppe_p_or:
MOVI r10,1
CALL @peekn
MOVI r2,124
CMP r1,r2
JMP[NE] @ppe_one
CALL @lx_get
CALL @lx_get
MOVI r1,#PPE_OROR
JMP @ppe_setop
ppe_p_and:
MOVI r10,1
CALL @peekn
MOVI r2,38
CMP r1,r2
JMP[NE] @ppe_one
CALL @lx_get
CALL @lx_get
MOVI r1,#PPE_ANDAND
JMP @ppe_setop
ppe_p_lt:
MOVI r10,1
CALL @peekn
ST r1,r0,#W_PPE_T1
CALL @lx_get
LD r1,r0,#W_PPE_T1
MOVI r2,61
CMP r1,r2
JMP[EQ] @ppe_lt_eq
MOVI r2,60
CMP r1,r2
JMP[EQ] @ppe_lt_lt
MOVI r1,#PPE_LT
JMP @ppe_setop
ppe_lt_eq:
CALL @lx_get
MOVI r1,#PPE_LE
JMP @ppe_setop
ppe_lt_lt:
CALL @lx_get
MOVI r1,#PPE_SHL
JMP @ppe_setop
ppe_p_gt:
MOVI r10,1
CALL @peekn
ST r1,r0,#W_PPE_T1
CALL @lx_get
LD r1,r0,#W_PPE_T1
MOVI r2,61
CMP r1,r2
JMP[EQ] @ppe_gt_eq
MOVI r2,62
CMP r1,r2
JMP[EQ] @ppe_gt_gt
MOVI r1,#PPE_GT
JMP @ppe_setop
ppe_gt_eq:
CALL @lx_get
MOVI r1,#PPE_GE
JMP @ppe_setop
ppe_gt_gt:
CALL @lx_get
MOVI r1,#PPE_SHR
JMP @ppe_setop
ppe_p_eq:
MOVI r10,1
CALL @peekn
MOVI r2,61
CMP r1,r2
JMP[NE] @ppe_one
CALL @lx_get
CALL @lx_get
MOVI r1,#PPE_EQ
JMP @ppe_setop
ppe_p_ne:
MOVI r10,1
CALL @peekn
MOVI r2,61
CMP r1,r2
JMP[NE] @ppe_one
CALL @lx_get
CALL @lx_get
MOVI r1,#PPE_NE
JMP @ppe_setop

ppe_one:
CALL @lx_get
MOVI r2,43
CMP r1,r2
JMP[EQ] @ppe_op_add
MOVI r2,45
CMP r1,r2
JMP[EQ] @ppe_op_sub
MOVI r2,42
CMP r1,r2
JMP[EQ] @ppe_op_mul
MOVI r2,47
CMP r1,r2
JMP[EQ] @ppe_op_div
MOVI r2,37
CMP r1,r2
JMP[EQ] @ppe_op_mod
MOVI r2,38
CMP r1,r2
JMP[EQ] @ppe_op_band
MOVI r2,124
CMP r1,r2
JMP[EQ] @ppe_op_bor
MOVI r2,94
CMP r1,r2
JMP[EQ] @ppe_op_bxor
MOVI r2,33
CMP r1,r2
JMP[EQ] @ppe_op_not
MOVI r2,126
CMP r1,r2
JMP[EQ] @ppe_op_bnot
MOVI r2,60
CMP r1,r2
JMP[EQ] @ppe_op_lt
MOVI r2,62
CMP r1,r2
JMP[EQ] @ppe_op_gt
MOVI r2,63
CMP r1,r2
JMP[EQ] @ppe_op_qmark
MOVI r2,58
CMP r1,r2
JMP[EQ] @ppe_op_colon
; unknown byte: return numeric zero and consume it
MOVI r1,#PPE_NUM
ST r1,r0,#W_PPE_KIND
ST r0,r0,#W_PPE_VAL
JMP @ppe_adv_done
ppe_op_add:
MOVI r1,#PPE_ADD
JMP @ppe_setop
ppe_op_sub:
MOVI r1,#PPE_SUB
JMP @ppe_setop
ppe_op_mul:
MOVI r1,#PPE_MUL
JMP @ppe_setop
ppe_op_div:
MOVI r1,#PPE_DIV
JMP @ppe_setop
ppe_op_mod:
MOVI r1,#PPE_MOD
JMP @ppe_setop
ppe_op_band:
MOVI r1,#PPE_BAND
JMP @ppe_setop
ppe_op_bor:
MOVI r1,#PPE_BOR
JMP @ppe_setop
ppe_op_bxor:
MOVI r1,#PPE_BXOR
JMP @ppe_setop
ppe_op_not:
MOVI r1,#PPE_NOT
JMP @ppe_setop
ppe_op_bnot:
MOVI r1,#PPE_BNOT
JMP @ppe_setop
ppe_op_lt:
MOVI r1,#PPE_LT
JMP @ppe_setop
ppe_op_gt:
MOVI r1,#PPE_GT
JMP @ppe_setop
ppe_op_qmark:
MOVI r1,#PPE_QMARK
JMP @ppe_setop
ppe_op_colon:
MOVI r1,#PPE_COLON
JMP @ppe_setop

ppe_lparen:
CALL @lx_get
MOVI r1,#PPE_LP
ST r1,r0,#W_PPE_KIND
JMP @ppe_adv_done
ppe_rparen:
CALL @lx_get
MOVI r1,#PPE_RP
ST r1,r0,#W_PPE_KIND
JMP @ppe_adv_done

ppe_num:
CALL @q2_num
LD r1,r0,#W_Q2VAL
ST r1,r0,#W_PPE_VAL
MOVI r1,#PPE_NUM
ST r1,r0,#W_PPE_KIND
JMP @ppe_adv_done
ppe_word:
CALL @q2_word
LD r1,r0,#W_Q2HASH
ST r1,r0,#W_PPE_HASH
LD r1,r0,#W_Q2LEN
ST r1,r0,#W_PPE_LEN
MOVI r1,#PPE_WORD
ST r1,r0,#W_PPE_KIND
JMP @ppe_adv_done

ppe_char:
CALL @lx_get              ; opening quote
CALL @lx_get              ; character
MOVI r2,92
CMP r1,r2
JMP[NE] @ppe_char_have
CALL @lx_get
MOVI r2,110                ; n
CMP r1,r2
JMP[EQ] @ppe_char_nl
MOVI r2,116                ; t
CMP r1,r2
JMP[EQ] @ppe_char_tab
MOVI r2,114                ; r
CMP r1,r2
JMP[EQ] @ppe_char_cr
MOVI r2,48                 ; 0
CMP r1,r2
JMP[EQ] @ppe_char_zero
MOVI r2,120                ; x
CMP r1,r2
JMP[EQ] @ppe_char_hex
; \\, \', \" and unknown escapes keep the escaped byte
JMP @ppe_char_have
ppe_char_nl:
MOVI r1,10
JMP @ppe_char_have
ppe_char_tab:
MOVI r1,9
JMP @ppe_char_have
ppe_char_cr:
MOVI r1,13
JMP @ppe_char_have
ppe_char_zero:
MOVI r1,0
JMP @ppe_char_have
ppe_char_hex:
MOVI r3,0
ST r3,r0,#W_PPE_T2
ppe_char_hex_l:
CALL @lx_peek
MOVI r2,16
CALL @digitv
MOVI r2,255
CMP r1,r2
JMP[EQ] @ppe_char_hex_done
CALL @lx_get
LD r3,r0,#W_PPE_T2
SHL r3,r3,4
ADD r3,r3,r1
ST r3,r0,#W_PPE_T2
JMP @ppe_char_hex_l
ppe_char_hex_done:
LD r1,r0,#W_PPE_T2
JMP @ppe_char_have
ppe_char_have:
ST r1,r0,#W_PPE_VAL
MOVI r2,39
CALL @lx_peek
CMP r1,r2
JMP[NE] @ppe_char_store
CALL @lx_get
ppe_char_store:
MOVI r1,#PPE_NUM
ST r1,r0,#W_PPE_KIND
JMP @ppe_adv_done

ppe_end:
MOVI r1,#PPE_END
ST r1,r0,#W_PPE_KIND
JMP @ppe_adv_done
ppe_setop:
ST r1,r0,#W_PPE_OP
MOVI r2,#PPE_OP
ST r2,r0,#W_PPE_KIND
ppe_adv_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ppe_prec: r1=operator -> r1=precedence, 0 if not a binary operator
ppe_prec:
MOVI r2,#PPE_OROR
CMP r1,r2
JMP[EQ] @ppep_1
MOVI r2,#PPE_ANDAND
CMP r1,r2
JMP[EQ] @ppep_2
MOVI r2,#PPE_BOR
CMP r1,r2
JMP[EQ] @ppep_3
MOVI r2,#PPE_BXOR
CMP r1,r2
JMP[EQ] @ppep_4
MOVI r2,#PPE_BAND
CMP r1,r2
JMP[EQ] @ppep_5
MOVI r2,#PPE_EQ
CMP r1,r2
JMP[EQ] @ppep_6
MOVI r2,#PPE_NE
CMP r1,r2
JMP[EQ] @ppep_6
MOVI r2,#PPE_LT
CMP r1,r2
JMP[EQ] @ppep_7
MOVI r2,#PPE_LE
CMP r1,r2
JMP[EQ] @ppep_7
MOVI r2,#PPE_GT
CMP r1,r2
JMP[EQ] @ppep_7
MOVI r2,#PPE_GE
CMP r1,r2
JMP[EQ] @ppep_7
MOVI r2,#PPE_SHL
CMP r1,r2
JMP[EQ] @ppep_8
MOVI r2,#PPE_SHR
CMP r1,r2
JMP[EQ] @ppep_8
MOVI r2,#PPE_ADD
CMP r1,r2
JMP[EQ] @ppep_9
MOVI r2,#PPE_SUB
CMP r1,r2
JMP[EQ] @ppep_9
MOVI r2,#PPE_MUL
CMP r1,r2
JMP[EQ] @ppep_10
MOVI r2,#PPE_DIV
CMP r1,r2
JMP[EQ] @ppep_10
MOVI r2,#PPE_MOD
CMP r1,r2
JMP[EQ] @ppep_10
MOVI r1,0
RET
ppep_1:
MOVI r1,1
RET
ppep_2:
MOVI r1,2
RET
ppep_3:
MOVI r1,3
RET
ppep_4:
MOVI r1,4
RET
ppep_5:
MOVI r1,5
RET
ppep_6:
MOVI r1,6
RET
ppep_7:
MOVI r1,7
RET
ppep_8:
MOVI r1,8
RET
ppep_9:
MOVI r1,9
RET
ppep_10:
MOVI r1,10
RET

; ppe_expr: precedence-climbing parser; r1=min precedence -> r1=value
ppe_expr:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ADD r14,r14,r13
CALL @ppe_unary
ST r1,r14,0
ADD r14,r14,r13
; ternary at the outermost precedence level
ADDI r3,r14,-2
LD r2,r3,0
CMP r2,r0
JMP[NE] @ppe_expr_l
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_OP
CMP r1,r2
JMP[NE] @ppe_expr_l
LD r1,r0,#W_PPE_OP
MOVI r2,#PPE_QMARK
CMP r1,r2
JMP[NE] @ppe_expr_l
CALL @ppe_adv
MOVI r1,0
CALL @ppe_expr
ST r1,r0,#W_PPE_T1
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_OP
CMP r1,r2
JMP[NE] @ppe_tern_keep
LD r1,r0,#W_PPE_OP
MOVI r2,#PPE_COLON
CMP r1,r2
JMP[NE] @ppe_tern_keep
CALL @ppe_adv
MOVI r1,0
CALL @ppe_expr
ST r1,r0,#W_PPE_T2
ADDI r3,r14,-1
LD r2,r3,0
CMP r2,r0
JMP[EQ] @ppe_tern_false
LD r1,r0,#W_PPE_T1
JMP @ppe_tern_store
ppe_tern_false:
LD r1,r0,#W_PPE_T2
ppe_tern_store:
ADDI r3,r14,-1
ST r1,r3,0
ppe_tern_keep:
JMP @ppe_expr_l
ppe_expr_l:
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_OP
CMP r1,r2
JMP[NE] @ppe_expr_d
LD r1,r0,#W_PPE_OP
MOVI r2,#PPE_COLON
CMP r1,r2
JMP[EQ] @ppe_expr_d
MOVI r2,#PPE_QMARK
CMP r1,r2
JMP[EQ] @ppe_expr_d
CALL @ppe_prec
CMP r1,r0
JMP[EQ] @ppe_expr_d
ADDI r3,r14,-2
LD r2,r3,0
CMP r1,r2
JMP[LT] @ppe_expr_d
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_PPE_OP
ST r1,r14,0
ADD r14,r14,r13
CALL @ppe_adv
ADDI r3,r14,-2
LD r1,r3,0
ADDI r1,r1,1
CALL @ppe_expr
SUB r14,r14,r13
LD r3,r14,0
SUB r14,r14,r13
ADDI r4,r14,-1
LD r2,r4,0
CALL @ppe_apply
ADDI r4,r14,-1
ST r1,r4,0
JMP @ppe_expr_l
ppe_expr_d:
SUB r14,r14,r13
LD r1,r14,0
SUB r14,r14,r13
SUB r14,r14,r13
LD r15,r14,0
RET

; ppe_unary: unary ! ~ + - then primary
ppe_unary:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_OP
CMP r1,r2
JMP[NE] @ppe_un_prim
LD r1,r0,#W_PPE_OP
MOVI r2,#PPE_NOT
CMP r1,r2
JMP[EQ] @ppe_un_not
MOVI r2,#PPE_BNOT
CMP r1,r2
JMP[EQ] @ppe_un_bnot
MOVI r2,#PPE_POS
CMP r1,r2
JMP[EQ] @ppe_un_pos
MOVI r2,#PPE_ADD
CMP r1,r2
JMP[EQ] @ppe_un_pos
MOVI r2,#PPE_NEG
CMP r1,r2
JMP[EQ] @ppe_un_neg
MOVI r2,#PPE_SUB
CMP r1,r2
JMP[EQ] @ppe_un_neg
JMP @ppe_un_prim
ppe_un_not:
CALL @ppe_adv
CALL @ppe_unary
CMP r1,r0
MOVI r2,0
MOVI[EQ] r2,1
ADD r1,r2,r0
JMP @ppe_un_d
ppe_un_bnot:
CALL @ppe_adv
CALL @ppe_unary
SUB r1,r0,r1
ADDI r1,r1,-1
JMP @ppe_un_d
ppe_un_pos:
CALL @ppe_adv
CALL @ppe_unary
JMP @ppe_un_d
ppe_un_neg:
CALL @ppe_adv
CALL @ppe_unary
SUB r1,r0,r1
JMP @ppe_un_d
ppe_un_prim:
CALL @ppe_primary
ppe_un_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ppe_primary: number, character, (expr), defined(name), macro name
ppe_primary:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_NUM
CMP r1,r2
JMP[EQ] @ppe_prim_num
MOVI r2,#PPE_LP
CMP r1,r2
JMP[EQ] @ppe_prim_lp
MOVI r2,#PPE_WORD
CMP r1,r2
JMP[EQ] @ppe_prim_word
MOVI r1,0
JMP @ppe_prim_d
ppe_prim_num:
LD r1,r0,#W_PPE_VAL
ST r1,r0,#W_PPE_T0
CALL @ppe_adv
LD r1,r0,#W_PPE_T0
JMP @ppe_prim_d
ppe_prim_lp:
CALL @ppe_adv
MOVI r1,0
CALL @ppe_expr
ST r1,r0,#W_PPE_T0
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_RP
CMP r1,r2
JMP[NE] @ppe_prim_lp_ret
CALL @ppe_adv
ppe_prim_lp_ret:
LD r1,r0,#W_PPE_T0
JMP @ppe_prim_d
ppe_prim_word:
; "defined"?
LD r1,r0,#W_PPE_LEN
MOVI r2,7
CMP r1,r2
JMP[NE] @ppe_prim_macro
LD r1,r0,#W_PPE_HASH
LA r2,0x0F1EB402
CMP r1,r2
JMP[NE] @ppe_prim_macro
CALL @ppe_adv
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_LP
CMP r1,r2
JMP[NE] @ppe_prim_def_word
CALL @ppe_adv
ppe_prim_def_word:
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_WORD
CMP r1,r2
JMP[NE] @ppe_prim_def_zero
LD r1,r0,#W_PPE_HASH
LD r2,r0,#W_PPE_LEN
CALL @q2_find
CMP r1,r0
JMP[EQ] @ppe_prim_def_zero
LD r2,r1,3
CMP r2,r0
JMP[EQ] @ppe_prim_def_zero
MOVI r3,1
JMP @ppe_prim_def_got
ppe_prim_def_zero:
MOVI r3,0
ppe_prim_def_got:
ST r3,r0,#W_PPE_T0
CALL @ppe_adv
LD r1,r0,#W_PPE_KIND
MOVI r2,#PPE_RP
CMP r1,r2
JMP[NE] @ppe_prim_def_ret
CALL @ppe_adv
ppe_prim_def_ret:
LD r1,r0,#W_PPE_T0
JMP @ppe_prim_d
ppe_prim_macro:
LD r1,r0,#W_PPE_HASH
LD r2,r0,#W_PPE_LEN
CALL @q2_macro
ST r1,r0,#W_PPE_T0
CALL @ppe_adv
LD r1,r0,#W_PPE_T0
ppe_prim_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ppe_apply: r1=b r2=a r3=operator -> r1=result
ppe_apply:
MOVI r4,#PPE_ADD
CMP r3,r4
JMP[EQ] @ppe_ap_add
MOVI r4,#PPE_SUB
CMP r3,r4
JMP[EQ] @ppe_ap_sub
MOVI r4,#PPE_MUL
CMP r3,r4
JMP[EQ] @ppe_ap_mul
MOVI r4,#PPE_DIV
CMP r3,r4
JMP[EQ] @ppe_ap_div
MOVI r4,#PPE_MOD
CMP r3,r4
JMP[EQ] @ppe_ap_mod
MOVI r4,#PPE_BAND
CMP r3,r4
JMP[EQ] @ppe_ap_band
MOVI r4,#PPE_BOR
CMP r3,r4
JMP[EQ] @ppe_ap_bor
MOVI r4,#PPE_BXOR
CMP r3,r4
JMP[EQ] @ppe_ap_bxor
MOVI r4,#PPE_SHL
CMP r3,r4
JMP[EQ] @ppe_ap_shl
MOVI r4,#PPE_SHR
CMP r3,r4
JMP[EQ] @ppe_ap_shr
MOVI r4,#PPE_EQ
CMP r3,r4
JMP[EQ] @ppe_ap_eq
MOVI r4,#PPE_NE
CMP r3,r4
JMP[EQ] @ppe_ap_ne
MOVI r4,#PPE_LT
CMP r3,r4
JMP[EQ] @ppe_ap_lt
MOVI r4,#PPE_LE
CMP r3,r4
JMP[EQ] @ppe_ap_le
MOVI r4,#PPE_GT
CMP r3,r4
JMP[EQ] @ppe_ap_gt
MOVI r4,#PPE_GE
CMP r3,r4
JMP[EQ] @ppe_ap_ge
MOVI r4,#PPE_ANDAND
CMP r3,r4
JMP[EQ] @ppe_ap_andand
MOVI r4,#PPE_OROR
CMP r3,r4
JMP[EQ] @ppe_ap_oror
MOVI r1,0
RET
ppe_ap_add:
ADD r1,r2,r1
RET
ppe_ap_sub:
SUB r1,r2,r1
RET
ppe_ap_mul:
MUL r1,r2,r1
RET
ppe_ap_div:
CMP r1,r0
JMP[EQ] @ppe_ap_zero
DIV r1,r2,r1
RET
ppe_ap_mod:
CMP r1,r0
JMP[EQ] @ppe_ap_zero
MOD r1,r2,r1
RET
ppe_ap_zero:
MOVI r1,0
RET
ppe_ap_band:
BOOL.8 r1,r2,r1
RET
ppe_ap_bor:
BOOL.14 r1,r2,r1
RET
ppe_ap_bxor:
BOOL.6 r1,r2,r1
RET
ppe_ap_shl:
MOVI r3,31
BOOL.8 r1,r1,r3
ppe_shl_l:
CMP r1,r0
JMP[EQ] @ppe_shl_d
SHL r2,r2,1
SUB r1,r1,r13
JMP @ppe_shl_l
ppe_shl_d:
ADD r1,r2,r0
RET
ppe_ap_shr:
MOVI r3,31
BOOL.8 r1,r1,r3
ppe_shr_l:
CMP r1,r0
JMP[EQ] @ppe_shr_d
SAR r2,r2,1
SUB r1,r1,r13
JMP @ppe_shr_l
ppe_shr_d:
ADD r1,r2,r0
RET
ppe_ap_eq:
CMP r2,r1
MOVI r1,0
MOVI[EQ] r1,1
RET
ppe_ap_ne:
CMP r2,r1
MOVI r1,0
MOVI[NE] r1,1
RET
ppe_ap_lt:
CMPS r2,r1
MOVI r1,0
MOVI[LT] r1,1
RET
ppe_ap_le:
CMPS r2,r1
MOVI r1,0
MOVI[LE] r1,1
RET
ppe_ap_gt:
CMPS r2,r1
MOVI r1,0
MOVI[GT] r1,1
RET
ppe_ap_ge:
CMPS r2,r1
MOVI r1,0
MOVI[GE] r1,1
RET
ppe_ap_andand:
CMP r2,r0
MOVI r4,0
MOVI[NE] r4,1
CMP r1,r0
MOVI r5,0
MOVI[NE] r5,1
BOOL.8 r1,r4,r5
RET
ppe_ap_oror:
CMP r2,r0
MOVI r4,0
MOVI[NE] r4,1
CMP r1,r0
MOVI r5,0
MOVI[NE] r5,1
BOOL.14 r1,r4,r5
RET
