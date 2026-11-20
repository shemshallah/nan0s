
; ncc.nas - NaN C compiler front end, written in raw NaN16.
; M1/M2: lexer -> recursive-descent parser -> compact stack IR -> interpreter.
; No host language is involved at run time: this file is assembled by nmk.awk
; (the seed assembler) or by the in-guest nasm0 once self-hosting is finished.
;
; ABI: r0=0 r13=1 r14=SP (grows up) r15=link. Routines that call save r15.
; All buffers live above word 1,000,000 (spec TODO A7). The 4M-word machine
; therefore holds source, IR, symbols, strings, globals and both stacks.
;
; Usage from a cart:
;   LA r1,@c_source
;   CALL @ncc_compile        ; returns 0, or prints !C<code>@<line> and HALTs
;   CALL @ncc_run            ; executes global initialisers then main()
;   HALT

; ------------------------------------------------------------------ memory map
.equ NCC_IRB    1200000      ; IR: 2 words per instruction
.equ NCC_IRMAX  400000
.equ NCC_IREND  1600000
.equ NCC_NAME   1600000      ; identifier spelling pool (4 chars/word)
.equ NCC_NAMEMAX 50000
.equ NCC_STRB   1650000      ; string literal pool (4 chars/word, NUL terminated)
.equ NCC_STRMAX 100000
.equ NCC_SYMB   1750000      ; 4096 entries x 8 words
.equ NCC_SYMMAX 32768
.equ NCC_GLOB   1800000      ; global variables, one word each
.equ NCC_GLOBMAX 100000
.equ NCC_ESB    2000000      ; expression stack
.equ NCC_ESMAX  200000
.equ NCC_ESEND  2200000
.equ NCC_FSB    2500000      ; call frames
.equ NCC_FSMAX  200000
.equ NCC_FSEND  2700000
.equ NCC_WORK   3000000      ; lexer tokens and compiler scratch
.equ NCC_PS     3000000      ; compiler/interpreter call stack (grows up)

; ------------------------------------------------------------------ token kinds
.equ K_EOF      1
.equ K_INT      2
.equ K_IDENT    3
.equ K_STRING   4
.equ K_CHAR     5
.equ K_PUNCT    6
.equ K_ERR      7
.equ K_KEYWORD  8

; token structure: 8 fields + 64 words of packed text
.equ TK_KIND    0
.equ TK_VAL     1
.equ TK_HASH    2
.equ TK_LEN     3
.equ TK_LINE    4
.equ TK_AUX     5
.equ TK_TEXT    8
.equ TKSZ       72

; keyword ids (C89, same order as the M0 lexer table)
.equ KW_AUTO     1
.equ KW_BREAK    2
.equ KW_CASE     3
.equ KW_CHAR     4
.equ KW_CONST    5
.equ KW_CONTINUE 6
.equ KW_DEFAULT  7
.equ KW_DO       8
.equ KW_DOUBLE   9
.equ KW_ELSE     10
.equ KW_ENUM     11
.equ KW_EXTERN   12
.equ KW_FLOAT    13
.equ KW_FOR      14
.equ KW_GOTO     15
.equ KW_IF       16
.equ KW_INT      17
.equ KW_LONG     18
.equ KW_REGISTER 19
.equ KW_RETURN   20
.equ KW_SHORT    21
.equ KW_SIGNED   22
.equ KW_SIZEOF   23
.equ KW_STATIC   24
.equ KW_STRUCT   25
.equ KW_SWITCH   26
.equ KW_TYPEDEF  27
.equ KW_UNION    28
.equ KW_UNSIGNED 29
.equ KW_VOID     30
.equ KW_VOLATILE 31
.equ KW_WHILE    32

; punctuator ids
.equ P_PLUS     1
.equ P_MINUS    2
.equ P_STAR     3
.equ P_SLASH    4
.equ P_PCT      5
.equ P_ASSIGN   6
.equ P_EQ       7
.equ P_NE       8
.equ P_LT       9
.equ P_GT       10
.equ P_LE       11
.equ P_GE       12
.equ P_SHL      13
.equ P_SHR      14
.equ P_LAND     15
.equ P_LOR      16
.equ P_AMP      17
.equ P_BAR      18
.equ P_CARET    19
.equ P_TILDE    20
.equ P_BANG     21
.equ P_INC      22
.equ P_DEC      23
.equ P_PLUSEQ   24
.equ P_MINUSEQ  25
.equ P_STAREQ   26
.equ P_SLASHEQ  27
.equ P_PCTEQ    28
.equ P_SHLEQ    29
.equ P_SHREQ    30
.equ P_AMPEQ    31
.equ P_BAREQ    32
.equ P_CARETEQ  33
.equ P_ARROW    34
.equ P_QUESTION 35
.equ P_COLON    36
.equ P_COMMA    37
.equ P_SEMI     38
.equ P_LPAREN   39
.equ P_RPAREN   40
.equ P_LBRACK   41
.equ P_RBRACK   42
.equ P_LBRACE   43
.equ P_RBRACE   44
.equ P_HASH     45

; IR opcodes (2 words: opcode, operand)
.equ I_HALT     0
.equ I_PUSH     1
.equ I_POP      2
.equ I_DUP      3
.equ I_SWAP     4
.equ I_LG       5
.equ I_SG       6
.equ I_LL       7
.equ I_SL       8
.equ I_ADD      10
.equ I_SUB      11
.equ I_MUL      12
.equ I_DIV      13
.equ I_MOD      14
.equ I_NEG      15
.equ I_AND      16
.equ I_OR       17
.equ I_XOR      18
.equ I_NOT      19
.equ I_SHL      20
.equ I_SHR      21
.equ I_EQ       22
.equ I_NE       23
.equ I_LT       24
.equ I_GT       25
.equ I_LE       26
.equ I_GE       27
.equ I_LNOT     28
.equ I_JMP      30
.equ I_JZ       31
.equ I_JNZ      32
.equ I_CALL     33
.equ I_RET      34
.equ I_GADDR    35
.equ I_LADDR    36
.equ I_SGK      37
.equ I_SLK      38
.equ I_LOAD_IND 39
.equ I_STORE_IND 40
.equ I_LZERO    41
.equ I_GZERO    42
.equ I_STORE_IND_KEEP 43

; symbol entry: 8 words
.equ SY_HASH    0
.equ SY_KIND    1
.equ SY_AUX     2
.equ SY_NP      3
.equ SY_NL      4
.equ SY_ENTRY   5
.equ SY_NAME    6
.equ SY_LEN     7
.equ SYSZ       8

.equ SK_GLOBAL  1
.equ SK_LOCAL   2
.equ SK_FUNC    3
.equ SK_BUILTIN 4

; builtin ids
.equ B_PUTCHAR  1
.equ B_PRINTINT 2
.equ B_PUTS     3
.equ B_HEX      4
.equ B_PUTSTR   5

; ------------------------------------------------------------------ compiler state
; Kept below word 65536 so ST/LD can use the 16-bit immediate form directly.
.equ W_IRPC     60000
.equ W_SYMUSED  60001
.equ W_GLOBUSED 60002
.equ W_NAMEP    60003
.equ W_STRP     60004
.equ W_FUNCSYM  60005
.equ W_NLOC     60006
.equ W_NPAR     60007
.equ W_LVAL     60008
.equ W_LKIND    60009
.equ W_LADDR    60010
.equ W_HAVE     60011
.equ W_ERRCODE  60012
.equ W_BRK_N    60013
.equ W_CNT_N    60014
.equ W_BRK_TAB  60064      ; 64 entries
.equ W_CNT_TAB  60128      ; 64 entries
.equ W_LOOPN    60600
.equ W_LOOPS    60608      ; 32 contexts x 8 words
.equ W_SIDX     60900
.equ W_SKIND    60901
.equ W_MIDX     60902
.equ W_BID      60903
.equ W_BNP      60904
.equ W_TMP2     60905
.equ W_PSAVE    60906
.equ W_PSAVE2   60907
.equ W_FSKIP    60908
.equ W_FENTRY   60909
.equ W_TKA      60200
.equ W_TKB      60272
.equ W_TMP      60400
.equ W_DECBUF   60402      ; 10 words

; lexer globals (absolute words)
.equ L_WP       60450
.equ L_BI       60451
.equ L_LINE     60452
.equ L_CH       60453
.equ L_TOKP     60454
.equ L_TADDR    60455
.equ L_TCNT     60456
.equ L_TMP0     60457
.equ L_TMP1     60458
.equ L_TMP2     60459
.equ L_TMP3     60460
.equ L_TMP4     60461
.equ L_TMP5     60462
.equ L_KIND     60463
.equ L_VAL      60464
.equ L_HASH     60465
.equ L_LEN      60466
.equ L_TLINE    60467
.equ L_TCAP     60468

; parser/interpreter globals
.equ R_PC       60500
.equ R_SP       60501
.equ R_FP       60502
.equ R_RETV     60503
.equ R_IP       60504
.equ R_T0       60505
.equ R_T1       60506
.equ R_T2       60507

; ------------------------------------------------------------------ entry points
ncc_compile:
ST r14,r0,#W_PSAVE
LA r14,#NCC_PS
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#L_WP
ST r0,r0,#L_BI
MOVI r1,1
ST r1,r0,#L_LINE
LA r1,#NCC_IRB
ST r1,r0,#W_IRPC
ST r0,r0,#W_SYMUSED
ST r0,r0,#W_GLOBUSED
ST r0,r0,#W_NAMEP
ST r0,r0,#W_STRP
ST r0,r0,#W_HAVE
ST r0,r0,#W_BRK_N
ST r0,r0,#W_CNT_N
CALL @ncc_builtins
CALL @np_init
CALL @p_tu
CALL @sym_find_main
ADD r2,r1,r0
LA r1,#I_CALL
CALL @ir_emit
LA r1,#I_HALT
MOVI r2,0
CALL @ir_emit
SUB r14,r14,r13
LD r15,r14,0
LD r14,r0,#W_PSAVE
RET

ncc_run:
ST r14,r0,#W_PSAVE2
LA r14,#NCC_PS
ST r15,r14,0
ADD r14,r14,r13
LA r1,#NCC_ESB
ST r1,r0,#R_SP
LA r1,#NCC_FSB
ST r1,r0,#R_FP
LA r1,#NCC_IRB
ST r1,r0,#R_IP
CALL @ni_loop
SUB r14,r14,r13
LD r15,r14,0
LD r14,r0,#W_PSAVE2
RET

; ------------------------------------------------------------------ output
; Every character the compiler/runtime prints goes through ncc_putc.
; ncc_out = 0 -> COM1; otherwise it is a guest function pointer called with
; r1=char and must preserve r2..r12 (the GUI terminal hook does).
ncc_putc:
LD r2,r0,@ncc_out
CMP r2,r0
JMP[EQ] @npc_serial
ST r15,r14,0
ADD r14,r14,r13
CALLR r2
SUB r14,r14,r13
LD r15,r14,0
RET
npc_serial:
PUTC r1
RET

; ------------------------------------------------------------------ fatal errors
; ncc_err: r1=code. Prints !Cxxxx@yyyy and halts.
ncc_err:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ERRCODE
MOVI r1,33
CALL @ncc_putc
MOVI r1,67
CALL @ncc_putc
LD r5,r0,#W_ERRCODE
CALL @puthex4
MOVI r1,64
CALL @ncc_putc
LD r5,r0,#L_LINE
CALL @puthex4
MOVI r1,91
CALL @ncc_putc
LD r5,r0,#W_TKA
CALL @puthex8
MOVI r1,58
CALL @ncc_putc
LD r5,r0,#W_TKA+1
CALL @puthex8
MOVI r1,93
CALL @ncc_putc
MOVI r1,10
CALL @ncc_putc
HALT

; puthex4: r5 = value -> 4 uppercase hex digits
puthex4:
MOVI r6,4
SHL r5,r5,16
JMP @puthexn
; puthex8: r5 = value -> 8 uppercase hex digits
puthex8:
MOVI r6,8
puthexn:
ST r15,r14,0
ADD r14,r14,r13
phn_l:
SHR r1,r5,28
CALL @puthex1
SHL r5,r5,4
SUB r6,r6,r13
CMP r6,r0
JMP[NE] @phn_l
SUB r14,r14,r13
LD r15,r14,0
RET
puthex1:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,10
CMP r1,r2
JMP[LT] @phx_d
ADDI r1,r1,55
CALL @ncc_putc
JMP @phx_e
phx_d:
ADDI r1,r1,48
CALL @ncc_putc
phx_e:
SUB r14,r14,r13
LD r15,r14,0
RET

; putdec: r5 = signed value, prints decimal without newline.
putdec:
ST r15,r14,0
ADD r14,r14,r13
CMPS r5,r0
JMP[GE] @pd_pos
MOVI r1,45
CALL @ncc_putc
SUB r5,r0,r5
pd_pos:
CMPS r5,r0
JMP[NE] @pd_nz
MOVI r1,48
CALL @ncc_putc
JMP @pd_done
pd_nz:
MOVI r6,0
pd_l:
MOVI r7,10
DIVU r8,r5,r7
MUL r9,r8,r7
SUB r9,r5,r9
LA r10,#W_DECBUF
ADD r10,r10,r6
ST r9,r10,0
ADD r6,r6,r13
ADD r5,r8,r0
CMP r5,r0
JMP[NE] @pd_l
pd_r:
SUB r6,r6,r13
LA r10,#W_DECBUF
ADD r10,r10,r6
LD r1,r10,0
ADDI r1,r1,48
CALL @ncc_putc
CMP r6,r0
JMP[NE] @pd_r
pd_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== LEXER
; lx_lex: r1 = token address. Fills the token, source cursor advances.
lx_lex:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#L_TOKP
LD r2,r0,#L_LINE
ST r2,r0,#L_TLINE
CALL @skip_ws
CALL @lx_peek
CMP r1,r0
JMP[EQ] @lx_eof
ST r1,r0,#L_CH
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[NE] @lx_num
LD r1,r0,#L_CH
CALL @ident0
CMP r1,r0
JMP[NE] @lx_ident
LD r1,r0,#L_CH
MOVI r2,34
CMP r1,r2
JMP[EQ] @lx_str
MOVI r2,39
CMP r1,r2
JMP[EQ] @lx_chr
JMP @lx_punct
lx_num:
CALL @scan_num
JMP @lx_fin
lx_ident:
CALL @scan_ident
JMP @lx_fin
lx_str:
CALL @scan_string
JMP @lx_fin
lx_chr:
CALL @scan_char
JMP @lx_fin
lx_punct:
CALL @scan_punct
JMP @lx_fin
lx_eof:
MOVI r1,1
ST r1,r0,#L_KIND
ST r0,r0,#L_VAL
ST r0,r0,#L_HASH
ST r0,r0,#L_LEN
lx_fin:
LD r2,r0,#L_TOKP
LD r1,r0,#L_KIND
ST r1,r2,#TK_KIND
LD r1,r0,#L_VAL
ST r1,r2,#TK_VAL
LD r1,r0,#L_HASH
ST r1,r2,#TK_HASH
LD r1,r0,#L_LEN
ST r1,r2,#TK_LEN
LD r1,r0,#L_TLINE
ST r1,r2,#TK_LINE
ST r0,r2,#TK_AUX
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- cursor -------------------------------------------------------
lx_peek:
LD r2,r0,#L_WP
LD r1,r2,0
LD r3,r0,#L_BI
lpk_l:
CMP r3,r0
JMP[EQ] @lpk_d
SHR r1,r1,8
SUB r3,r3,r13
JMP @lpk_l
lpk_d:
MOVI r2,255
BOOL.8 r1,r1,r2
RET
lx_adv:
LD r2,r0,#L_BI
ADD r2,r2,r13
MOVI r3,4
CMP r2,r3
JMP[LT] @lad_s
MOVI r2,0
LD r3,r0,#L_WP
ADD r3,r3,r13
ST r3,r0,#L_WP
lad_s:
ST r2,r0,#L_BI
RET
lx_get:
ST r15,r14,0
ADD r14,r14,r13
CALL @lx_peek
ST r1,r0,#L_CH
CALL @lx_adv
LD r1,r0,#L_CH
MOVI r2,10
CMP r1,r2
JMP[NE] @lgt_d
LD r2,r0,#L_LINE
ADD r2,r2,r13
ST r2,r0,#L_LINE
lgt_d:
LD r1,r0,#L_CH
SUB r14,r14,r13
LD r15,r14,0
RET
; peekn: r10 = offset -> r1 byte, cursor unchanged
peekn:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#L_WP
ST r2,r0,#L_TMP3
LD r2,r0,#L_BI
ST r2,r0,#L_TMP4
pkn_l:
CMP r10,r0
JMP[EQ] @pkn_d
CALL @lx_adv
SUB r10,r10,r13
JMP @pkn_l
pkn_d:
CALL @lx_peek
ST r1,r0,#L_TMP5
LD r2,r0,#L_TMP3
ST r2,r0,#L_WP
LD r2,r0,#L_TMP4
ST r2,r0,#L_BI
LD r1,r0,#L_TMP5
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- token text ---------------------------------------------------
txt_reset:
LD r2,r0,#L_TOKP
ADDI r2,r2,#TK_TEXT
SHL r2,r2,2
ST r2,r0,#L_TADDR
ST r0,r0,#L_TCNT
RET
txt_putc:
LD r2,r0,#L_TCNT
MOVI r3,255
CMP r2,r3
JMP[GE] @tpc_done
LD r3,r0,#L_TADDR
ADD r3,r3,r2
STB r1,r3,0
ADD r2,r2,r13
ST r2,r0,#L_TCNT
tpc_done:
RET
txt_finish:
LD r2,r0,#L_TADDR
LD r3,r0,#L_TCNT
ADD r2,r2,r3
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
LD r1,r0,#L_TCNT
ST r1,r0,#L_LEN
RET

; ---- character classes --------------------------------------------
digit10:
MOVI r2,48
CMP r1,r2
JMP[LT] @d10_no
MOVI r2,58
CMP r1,r2
JMP[GE] @d10_no
ADDI r1,r1,-48
RET
d10_no:
MOVI r1,255
RET
hexval:
MOVI r2,48
CMP r1,r2
JMP[LT] @hx_no
MOVI r2,58
CMP r1,r2
JMP[LT] @hx_dec
MOVI r2,65
CMP r1,r2
JMP[LT] @hx_no
MOVI r2,71
CMP r1,r2
JMP[LT] @hx_uc
MOVI r2,97
CMP r1,r2
JMP[LT] @hx_no
MOVI r2,103
CMP r1,r2
JMP[LT] @hx_lc
JMP @hx_no
hx_dec:
ADDI r1,r1,-48
RET
hx_uc:
ADDI r1,r1,-55
RET
hx_lc:
ADDI r1,r1,-87
RET
hx_no:
MOVI r1,255
RET
digitv:
MOVI r3,16
CMP r2,r3
JMP[EQ] @dv_hex
MOVI r3,8
CMP r2,r3
JMP[EQ] @dv_oct
JMP @digit10
dv_hex:
JMP @hexval
dv_oct:
MOVI r3,48
CMP r1,r3
JMP[LT] @dv_no
MOVI r3,56
CMP r1,r3
JMP[GE] @dv_no
ADDI r1,r1,-48
RET
dv_no:
MOVI r1,255
RET
ident0:
MOVI r2,95
CMP r1,r2
JMP[NE] @i0_a
MOVI r1,1
RET
i0_a:
MOVI r2,65
CMP r1,r2
JMP[LT] @i0_b
MOVI r2,91
CMP r1,r2
JMP[LT] @i0_y
i0_b:
MOVI r2,97
CMP r1,r2
JMP[LT] @i0_n
MOVI r2,123
CMP r1,r2
JMP[LT] @i0_y
i0_n:
MOVI r1,0
RET
i0_y:
MOVI r1,1
RET
identc:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#L_TMP0
CALL @ident0
CMP r1,r0
JMP[NE] @ic_y
LD r1,r0,#L_TMP0
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[NE] @ic_y
MOVI r1,0
JMP @ic_d
ic_y:
MOVI r1,1
ic_d:
SUB r14,r14,r13
LD r15,r14,0
RET
hashc:
LD r2,r0,#L_HASH
BOOL.6 r2,r2,r1
LD r3,r0,@k_fnvp
MUL r2,r2,r3
ST r2,r0,#L_HASH
RET

; ---- whitespace and comments --------------------------------------
skip_ws:
ST r15,r14,0
ADD r14,r14,r13
sw_l:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @sw_d
MOVI r2,32
CMP r1,r2
JMP[EQ] @sw_c
MOVI r2,9
CMP r1,r2
JMP[EQ] @sw_c
MOVI r2,10
CMP r1,r2
JMP[EQ] @sw_c
MOVI r2,13
CMP r1,r2
JMP[EQ] @sw_c
JMP @sw_cm
sw_c:
CALL @lx_get
JMP @sw_l
sw_cm:
MOVI r2,47
CMP r1,r2
JMP[NE] @sw_d
MOVI r10,1
CALL @peekn
MOVI r2,47
CMP r1,r2
JMP[EQ] @sw_lc
MOVI r2,42
CMP r1,r2
JMP[EQ] @sw_bc
JMP @sw_d
sw_lc:
CALL @lx_get
CALL @lx_get
sw_lc_l:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @sw_d
MOVI r2,10
CMP r1,r2
JMP[EQ] @sw_lc_n
CALL @lx_get
JMP @sw_lc_l
sw_lc_n:
CALL @lx_get
JMP @sw_l
sw_bc:
CALL @lx_get
CALL @lx_get
sw_bc_l:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @sw_d
MOVI r2,42
CMP r1,r2
JMP[NE] @sw_bc_g
MOVI r10,1
CALL @peekn
MOVI r2,47
CMP r1,r2
JMP[EQ] @sw_bc_e
sw_bc_g:
CALL @lx_get
JMP @sw_bc_l
sw_bc_e:
CALL @lx_get
CALL @lx_get
JMP @sw_l
sw_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- integers ------------------------------------------------------
scan_num:
ST r15,r14,0
ADD r14,r14,r13
CALL @lx_get
MOVI r1,1
ST r1,r0,#L_LEN
MOVI r1,0
ST r1,r0,#L_VAL
MOVI r1,10
ST r1,r0,#L_TMP0
LD r1,r0,#L_CH
MOVI r2,48
CMP r1,r2
JMP[NE] @sn_first
MOVI r10,0
CALL @peekn
MOVI r2,120
CMP r1,r2
JMP[EQ] @sn_hex
MOVI r2,88
CMP r1,r2
JMP[EQ] @sn_hex
MOVI r2,48
CMP r1,r2
JMP[LT] @sn_fin
MOVI r2,56
CMP r1,r2
JMP[GE] @sn_fin
MOVI r1,8
ST r1,r0,#L_TMP0
JMP @sn_loop
sn_hex:
CALL @lx_get
LD r1,r0,#L_LEN
ADD r1,r1,r13
ST r1,r0,#L_LEN
MOVI r1,16
ST r1,r0,#L_TMP0
JMP @sn_loop
sn_first:
SUB r1,r1,r2
ST r1,r0,#L_VAL
sn_loop:
CALL @lx_peek
LD r2,r0,#L_TMP0
CALL @digitv
MOVI r2,255
CMP r1,r2
JMP[EQ] @sn_fin
LD r3,r0,#L_VAL
LD r4,r0,#L_TMP0
MUL r3,r3,r4
ADD r3,r3,r1
ST r3,r0,#L_VAL
LD r3,r0,#L_LEN
ADD r3,r3,r13
ST r3,r0,#L_LEN
CALL @lx_get
JMP @sn_loop
sn_fin:
MOVI r1,2
ST r1,r0,#L_KIND
LD r1,r0,#L_VAL
ST r1,r0,#L_VAL
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- identifiers / keywords ---------------------------------------
scan_ident:
ST r15,r14,0
ADD r14,r14,r13
CALL @txt_reset
LD r1,r0,@k_fnv0
ST r1,r0,#L_HASH
si_l:
CALL @lx_peek
CALL @identc
CMP r1,r0
JMP[EQ] @si_fin
CALL @lx_get
LD r1,r0,#L_CH
CALL @hashc
LD r1,r0,#L_CH
CALL @txt_putc
JMP @si_l
si_fin:
CALL @txt_finish
LD r1,r0,#L_HASH
CALL @kw_lookup
CMP r1,r0
JMP[EQ] @si_id
ST r1,r0,#L_VAL
MOVI r1,8
ST r1,r0,#L_KIND
JMP @si_d
si_id:
ST r0,r0,#L_VAL
MOVI r1,3
ST r1,r0,#L_KIND
si_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; kw_lookup: r1=hash -> r1=id or 0
kw_lookup:
LA r3,@kw_tab
kw_l:
LD r2,r3,0
CMP r2,r0
JMP[EQ] @kw_none
CMP r2,r1
JMP[EQ] @kw_hit
MOVI r4,2
ADD r3,r3,r4
JMP @kw_l
kw_hit:
LD r1,r3,1
RET
kw_none:
MOVI r1,0
RET

; ---- string literal ------------------------------------------------
scan_string:
ST r15,r14,0
ADD r14,r14,r13
CALL @txt_reset
CALL @lx_get
ss_l:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @ss_err
MOVI r2,10
CMP r1,r2
JMP[EQ] @ss_err
MOVI r2,34
CMP r1,r2
JMP[EQ] @ss_fin
MOVI r2,92
CMP r1,r2
JMP[EQ] @ss_esc
CALL @lx_get
CALL @txt_putc
JMP @ss_l
ss_esc:
CALL @lx_get
CALL @lex_esc
CALL @txt_putc
JMP @ss_l
ss_fin:
CALL @lx_get
CALL @txt_finish
MOVI r1,4
ST r1,r0,#L_KIND
ST r0,r0,#L_VAL
JMP @ss_d
ss_err:
CALL @txt_finish
MOVI r1,7
ST r1,r0,#L_KIND
ST r0,r0,#L_VAL
ss_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- character literal ---------------------------------------------
scan_char:
ST r15,r14,0
ADD r14,r14,r13
CALL @lx_get
CALL @lx_peek
CMP r1,r0
JMP[EQ] @sc_err
MOVI r2,10
CMP r1,r2
JMP[EQ] @sc_err
MOVI r2,39
CMP r1,r2
JMP[EQ] @sc_err
MOVI r2,92
CMP r1,r2
JMP[EQ] @sc_esc
CALL @lx_get
ST r1,r0,#L_VAL
JMP @sc_close
sc_esc:
CALL @lx_get
CALL @lex_esc
ST r1,r0,#L_VAL
sc_close:
CALL @lx_peek
MOVI r2,39
CMP r1,r2
JMP[NE] @sc_err
CALL @lx_get
MOVI r1,1
ST r1,r0,#L_LEN
MOVI r1,5
ST r1,r0,#L_KIND
JMP @sc_d
sc_err:
MOVI r1,1
ST r1,r0,#L_LEN
MOVI r1,7
ST r1,r0,#L_KIND
sc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; lex_esc: backslash already consumed; returns decoded byte in r1.
lex_esc:
ST r15,r14,0
ADD r14,r14,r13
CALL @lx_get
ST r1,r0,#L_TMP0
MOVI r2,110
CMP r1,r2
JMP[EQ] @le_n
MOVI r2,114
CMP r1,r2
JMP[EQ] @le_r
MOVI r2,116
CMP r1,r2
JMP[EQ] @le_t
MOVI r2,92
CMP r1,r2
JMP[EQ] @le_bs
MOVI r2,34
CMP r1,r2
JMP[EQ] @le_dq
MOVI r2,39
CMP r1,r2
JMP[EQ] @le_sq
MOVI r2,97
CMP r1,r2
JMP[EQ] @le_a
MOVI r2,98
CMP r1,r2
JMP[EQ] @le_b
MOVI r2,102
CMP r1,r2
JMP[EQ] @le_f
MOVI r2,118
CMP r1,r2
JMP[EQ] @le_v
MOVI r2,120
CMP r1,r2
JMP[EQ] @le_hex
MOVI r2,55
CMP r1,r2
JMP[GT] @le_plain
MOVI r2,48
CMP r1,r2
JMP[LT] @le_plain
JMP @le_oct
le_n:
MOVI r1,10
JMP @le_d
le_r:
MOVI r1,13
JMP @le_d
le_t:
MOVI r1,9
JMP @le_d
le_0:
MOVI r1,0
JMP @le_d
le_bs:
MOVI r1,92
JMP @le_d
le_dq:
MOVI r1,34
JMP @le_d
le_sq:
MOVI r1,39
JMP @le_d
le_a:
MOVI r1,7
JMP @le_d
le_b:
MOVI r1,8
JMP @le_d
le_f:
MOVI r1,12
JMP @le_d
le_v:
MOVI r1,11
JMP @le_d
le_plain:
LD r1,r0,#L_TMP0
JMP @le_d
le_hex:
MOVI r4,0
MOVI r5,0
le_hx_l:
CALL @lx_peek
CALL @hexval
MOVI r2,255
CMP r1,r2
JMP[EQ] @le_hx_d
CALL @lx_get
SHL r4,r4,4
ADD r4,r4,r1
ADD r5,r5,r13
MOVI r2,2
CMP r5,r2
JMP[LT] @le_hx_l
le_hx_d:
ADD r1,r4,r0
JMP @le_d
le_oct:
LD r4,r0,#L_TMP0
ADDI r4,r4,-48
MOVI r5,0
le_oc_l:
MOVI r2,2
CMP r5,r2
JMP[GE] @le_oc_d
CALL @lx_peek
MOVI r2,55
CMP r1,r2
JMP[GT] @le_oc_d
MOVI r2,48
CMP r1,r2
JMP[LT] @le_oc_d
CALL @lx_get
ADDI r1,r1,-48
SHL r4,r4,3
ADD r4,r4,r1
ADD r5,r5,r13
JMP @le_oc_l
le_oc_d:
ADD r1,r4,r0
le_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- punctuators ---------------------------------------------------
; p_set: r1=id r2=len -> stores, then consumes len bytes.
p_set:
ST r1,r0,#L_VAL
ST r2,r0,#L_LEN
ST r2,r0,#L_TMP3
MOVI r1,6
ST r1,r0,#L_KIND
p_cons:
LD r2,r0,#L_TMP3
CMP r2,r0
JMP[EQ] @p_cd
ST r15,r14,0
ADD r14,r14,r13
CALL @lx_get
SUB r14,r14,r13
LD r15,r14,0
LD r2,r0,#L_TMP3
SUB r2,r2,r13
ST r2,r0,#L_TMP3
JMP @p_cons
p_cd:
RET

scan_punct:
ST r15,r14,0
ADD r14,r14,r13
MOVI r10,0
CALL @peekn
ST r1,r0,#L_TMP0
MOVI r10,1
CALL @peekn
ST r1,r0,#L_TMP1
MOVI r10,2
CALL @peekn
ST r1,r0,#L_TMP2
LD r1,r0,#L_TMP0
MOVI r2,61
CMP r1,r2
JMP[EQ] @sp_eq
MOVI r2,33
CMP r1,r2
JMP[EQ] @sp_bang
MOVI r2,60
CMP r1,r2
JMP[EQ] @sp_lt
MOVI r2,62
CMP r1,r2
JMP[EQ] @sp_gt
MOVI r2,38
CMP r1,r2
JMP[EQ] @sp_amp
MOVI r2,124
CMP r1,r2
JMP[EQ] @sp_bar
MOVI r2,43
CMP r1,r2
JMP[EQ] @sp_plus
MOVI r2,45
CMP r1,r2
JMP[EQ] @sp_minus
MOVI r2,42
CMP r1,r2
JMP[EQ] @sp_star
MOVI r2,47
CMP r1,r2
JMP[EQ] @sp_slash
MOVI r2,37
CMP r1,r2
JMP[EQ] @sp_pct
MOVI r2,94
CMP r1,r2
JMP[EQ] @sp_caret
JMP @sp_single
sp_eq:
LD r2,r0,#L_TMP1
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_eq
MOVI r1,7
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_eq:
MOVI r1,6
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_bang:
LD r2,r0,#L_TMP1
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_bang
MOVI r1,8
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_bang:
MOVI r1,21
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_lt:
LD r2,r0,#L_TMP1
MOVI r3,60
CMP r2,r3
JMP[NE] @sp_lt_eq
LD r3,r0,#L_TMP2
MOVI r4,61
CMP r3,r4
JMP[NE] @sp_shl
MOVI r1,29
MOVI r2,3
CALL @p_set
JMP @sp_d
sp_shl:
MOVI r1,13
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_lt_eq:
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_lt
MOVI r1,11
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_lt:
MOVI r1,9
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_gt:
LD r2,r0,#L_TMP1
MOVI r3,62
CMP r2,r3
JMP[NE] @sp_gt_eq
LD r3,r0,#L_TMP2
MOVI r4,61
CMP r3,r4
JMP[NE] @sp_shr
MOVI r1,30
MOVI r2,3
CALL @p_set
JMP @sp_d
sp_shr:
MOVI r1,14
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_gt_eq:
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_gt
MOVI r1,12
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_gt:
MOVI r1,10
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_amp:
LD r2,r0,#L_TMP1
MOVI r3,38
CMP r2,r3
JMP[EQ] @sp_amp2
MOVI r3,61
CMP r2,r3
JMP[EQ] @sp_ampeq
MOVI r1,17
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_amp2:
MOVI r1,15
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_ampeq:
MOVI r1,31
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_bar:
LD r2,r0,#L_TMP1
MOVI r3,124
CMP r2,r3
JMP[EQ] @sp_bar2
MOVI r3,61
CMP r2,r3
JMP[EQ] @sp_bareq
MOVI r1,18
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_bar2:
MOVI r1,16
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_bareq:
MOVI r1,32
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_plus:
LD r2,r0,#L_TMP1
MOVI r3,43
CMP r2,r3
JMP[EQ] @sp_plus2
MOVI r3,61
CMP r2,r3
JMP[EQ] @sp_pluseq
MOVI r1,1
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_plus2:
MOVI r1,22
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_pluseq:
MOVI r1,24
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_minus:
LD r2,r0,#L_TMP1
MOVI r3,45
CMP r2,r3
JMP[EQ] @sp_minus2
MOVI r3,61
CMP r2,r3
JMP[EQ] @sp_minuseq
MOVI r3,62
CMP r2,r3
JMP[EQ] @sp_arrow
MOVI r1,2
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_minus2:
MOVI r1,23
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_minuseq:
MOVI r1,25
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_arrow:
MOVI r1,34
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_star:
LD r2,r0,#L_TMP1
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_star
MOVI r1,26
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_star:
MOVI r1,3
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_slash:
LD r2,r0,#L_TMP1
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_slash
MOVI r1,27
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_slash:
MOVI r1,4
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_pct:
LD r2,r0,#L_TMP1
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_pct
MOVI r1,28
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_pct:
MOVI r1,5
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_caret:
LD r2,r0,#L_TMP1
MOVI r3,61
CMP r2,r3
JMP[NE] @sp_one_caret
MOVI r1,33
MOVI r2,2
CALL @p_set
JMP @sp_d
sp_one_caret:
MOVI r1,19
MOVI r2,1
CALL @p_set
JMP @sp_d
sp_single:
LD r1,r0,#L_TMP0
MOVI r2,126
CMP r1,r2
JMP[EQ] @sp_tilde
MOVI r2,63
CMP r1,r2
JMP[EQ] @sp_quest
MOVI r2,58
CMP r1,r2
JMP[EQ] @sp_colon
MOVI r2,44
CMP r1,r2
JMP[EQ] @sp_comma
MOVI r2,59
CMP r1,r2
JMP[EQ] @sp_semi
MOVI r2,40
CMP r1,r2
JMP[EQ] @sp_lp
MOVI r2,41
CMP r1,r2
JMP[EQ] @sp_rp
MOVI r2,91
CMP r1,r2
JMP[EQ] @sp_lb
MOVI r2,93
CMP r1,r2
JMP[EQ] @sp_rb
MOVI r2,123
CMP r1,r2
JMP[EQ] @sp_lc
MOVI r2,125
CMP r1,r2
JMP[EQ] @sp_rc
MOVI r2,35
CMP r1,r2
JMP[EQ] @sp_hash
MOVI r1,1
MOVI r2,1
CALL @p_set
MOVI r1,7
ST r1,r0,#L_KIND
JMP @sp_d
sp_tilde:
MOVI r1,20
JMP @sp_one
sp_quest:
MOVI r1,35
JMP @sp_one
sp_colon:
MOVI r1,36
JMP @sp_one
sp_comma:
MOVI r1,37
JMP @sp_one
sp_semi:
MOVI r1,38
JMP @sp_one
sp_lp:
MOVI r1,39
JMP @sp_one
sp_rp:
MOVI r1,40
JMP @sp_one
sp_lb:
MOVI r1,41
JMP @sp_one
sp_rb:
MOVI r1,42
JMP @sp_one
sp_lc:
MOVI r1,43
JMP @sp_one
sp_rc:
MOVI r1,44
JMP @sp_one
sp_hash:
MOVI r1,45
sp_one:
MOVI r2,1
CALL @p_set
sp_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- output hook + constant tables --------------------------------
ncc_out:
.word 0
k_fnv0:
.word 0x811C9DC5
k_fnvp:
.word 0x01000193
kw_tab:
.word 0x923FA396, 1
.word 0xC9648178, 2
.word 0x9B2538B1, 3
.word 0xA84C031D, 4
.word 0x664FD1D4, 5
.word 0xB1727E44, 6
.word 0x933B5BDE, 7
.word 0x621CD814, 8
.word 0xA0EB0F08, 9
.word 0xBDBF5BF0, 10
.word 0x816CB000, 11
.word 0x9087DDB7, 12
.word 0xA6C45D85, 13
.word 0xACF38390, 14
.word 0xF5A30FE6, 15
.word 0x39386E06, 16
.word 0x95E97E5E, 17
.word 0xC2ECDF53, 18
.word 0x2D6871C0, 19
.word 0x85EE37BF, 20
.word 0xBA226BD5, 21
.word 0xB5712015, 22
.word 0x6EE13AFD, 23
.word 0xD290C23B, 24
.word 0x92C2BE20, 25
.word 0x93E05F71, 26
.word 0x221EDE24, 27
.word 0xDBDED6F4, 28
.word 0x0C547726, 29
.word 0x48B5725F, 30
.word 0x94E1036D, 31
.word 0x0DC628CE, 32
.word 0

; ================================================================== IR EMITTER
; ir_emit: r1=opcode r2=operand. Two words per instruction.
ir_emit:
ST r15,r14,0
ADD r14,r14,r13
LD r3,r0,#W_IRPC
LA r4,#NCC_IREND
CMP r3,r4
JMP[LT] @ie_ok
MOVI r1,1
JMP @ncc_err
ie_ok:
ST r1,r3,0
ST r2,r3,1
ADDI r3,r3,2
ST r3,r0,#W_IRPC
SUB r14,r14,r13
LD r15,r14,0
RET
; ir_op: r1=opcode, operand 0
ir_op:
MOVI r2,0
JMP @ir_emit
; ir_here -> r1 = current IR word address
ir_here:
LD r1,r0,#W_IRPC
RET
; ir_patch: r1=instruction word address, r2=operand
ir_patch:
ST r2,r1,1
RET

; ================================================================== TOKENS
; tok_copy: r1=dst r2=src
tok_copy:
ST r15,r14,0
ADD r14,r14,r13
MOVI r3,#TKSZ
BCOPY r1,r2,r3
SUB r14,r14,r13
LD r15,r14,0
RET

np_init:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_HAVE
CALL @p_adv
SUB r14,r14,r13
LD r15,r14,0
RET

; p_adv: consume lookahead or lex directly into TKA
p_adv:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_HAVE
CMP r1,r0
JMP[EQ] @pa_lex
LA r1,#W_TKA
LA r2,#W_TKB
CALL @tok_copy
ST r0,r0,#W_HAVE
JMP @pa_d
pa_lex:
LA r1,#W_TKA
CALL @lx_lex
pa_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_peek: lex the next token into TKB (once)
p_peek:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_HAVE
CMP r1,r0
JMP[NE] @pp_primary_done
LA r1,#W_TKB
CALL @lx_lex
MOVI r1,1
ST r1,r0,#W_HAVE
pp_primary_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_at_p: r1=punctuator id -> r1=1 if current token is it
p_at_p:
LD r2,r0,#W_TKA
MOVI r3,6
CMP r2,r3
JMP[NE] @pap_n
LD r2,r0,#W_TKA+1
CMP r1,r2
JMP[NE] @pap_n
MOVI r1,1
RET
pap_n:
MOVI r1,0
RET
; p_at_k: r1=keyword id
p_at_k:
LD r2,r0,#W_TKA
MOVI r3,8
CMP r2,r3
JMP[NE] @pak_n
LD r2,r0,#W_TKA+1
CMP r1,r2
JMP[NE] @pak_n
MOVI r1,1
RET
pak_n:
MOVI r1,0
RET
; p_at_kind: r1=kind
p_at_kind:
LD r2,r0,#W_TKA
CMP r1,r2
JMP[NE] @pakd_n
MOVI r1,1
RET
pakd_n:
MOVI r1,0
RET
; p_take_p: r1=id -> r1=1 if consumed
p_take_p:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#L_TMP0
CALL @p_at_p
CMP r1,r0
JMP[EQ] @ptp_n
CALL @p_adv
MOVI r1,1
JMP @ptp_d
ptp_n:
MOVI r1,0
ptp_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_err: r1=code -> diagnostic and halt (uses current token line)
p_err:
LD r2,r0,#W_TKA+4
ST r2,r0,#L_LINE
JMP @ncc_err

; p_expect_p: r1=id r2=error code
p_expect_p:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#L_TMP0
CALL @p_at_p
CMP r1,r0
JMP[NE] @pep_ok
LD r1,r0,#L_TMP0
CALL @p_err
pep_ok:
CALL @p_adv
SUB r14,r14,r13
LD r15,r14,0
RET
; p_expect_kind: r1=kind r2=code
p_expect_kind:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#L_TMP0
CALL @p_at_kind
CMP r1,r0
JMP[NE] @pek_ok
LD r1,r0,#L_TMP0
CALL @p_err
pek_ok:
CALL @p_adv
SUB r14,r14,r13
LD r15,r14,0
RET

; p_is_type: current token is a type/qualifier keyword
p_is_type:
LD r2,r0,#W_TKA
MOVI r3,8
CMP r2,r3
JMP[NE] @pit_n
LD r1,r0,#W_TKA+1
MOVI r2,4
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,9
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,13
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,17
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,18
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,21
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,22
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,29
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,30
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,5
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,12
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,19
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,24
CMP r1,r2
JMP[EQ] @pit_y
MOVI r2,31
CMP r1,r2
JMP[EQ] @pit_y
pit_n:
MOVI r1,0
RET
pit_y:
MOVI r1,1
RET

; kw_is_type: r1=keyword id -> 1 for type/qualifier words
kw_is_type:
MOVI r2,4
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,9
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,13
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,17
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,18
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,21
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,22
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,29
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,30
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,5
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,12
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,19
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,24
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,31
CMP r1,r2
JMP[EQ] @kit_y
MOVI r1,0
RET
kit_y:
MOVI r1,1
RET

; p_skip_types: consume type/qualifier keywords and pointer stars
p_skip_types:
ST r15,r14,0
ADD r14,r14,r13
pst_l:
CALL @p_is_type
CMP r1,r0
JMP[NE] @pst_go
MOVI r1,#P_STAR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pst_types_done
pst_go:
CALL @p_adv
JMP @pst_l
pst_types_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== SYMBOLS
; sym_name_eq: r1=entry word address, r2=token text word addr, r3=len
sym_name_eq:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
ST r2,r0,#R_T1
ST r3,r0,#R_T2
LD r4,r1,#SY_LEN
CMP r4,r3
JMP[NE] @sne_n
LD r4,r1,#SY_NAME
LA r5,#NCC_NAME
ADD r4,r4,r5
SHL r4,r4,2
SHL r2,r2,2
sne_l:
CMP r3,r0
JMP[EQ] @sne_y
LDB r6,r4,0
LDB r7,r2,0
CMP r6,r7
JMP[NE] @sne_n
ADD r4,r4,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @sne_l
sne_y:
MOVI r1,1
JMP @sne_d
sne_n:
MOVI r1,0
sne_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; sym_find_cur: r1=kind (1 global, 2 local, 3 func, 4 builtin)
; uses the CURRENT token's hash/len/text. locals also match W_FUNCSYM.
sym_find_cur:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_SKIND
ST r0,r0,#W_SIDX
sf_l:
LD r2,r0,#W_SIDX
LD r3,r0,#W_SYMUSED
CMP r2,r3
JMP[GE] @sf_n
SHL r3,r2,3
LA r4,#NCC_SYMB
ADD r3,r3,r4
LD r4,r3,#SY_KIND
LD r5,r0,#W_SKIND
CMP r4,r5
JMP[NE] @sf_next
; local entries must belong to the current function
MOVI r5,2
CMP r4,r5
JMP[NE] @sf_hash
LD r4,r3,#SY_NP
LD r5,r0,#W_FUNCSYM
CMP r4,r5
JMP[NE] @sf_next
sf_hash:
LD r4,r3,#SY_HASH
LD r5,r0,#W_TKA+2
CMP r4,r5
JMP[NE] @sf_next
ADD r1,r3,r0
LA r2,#W_TKA+#TK_TEXT
LD r3,r0,#W_TKA+3
CALL @sym_name_eq
CMP r1,r0
JMP[EQ] @sf_next
LD r1,r0,#W_SIDX
JMP @sf_d
sf_next:
LD r2,r0,#W_SIDX
ADD r2,r2,r13
ST r2,r0,#W_SIDX
JMP @sf_l
sf_n:
MOVI r1,0xFFFF
SHL r1,r1,16
ADDI r1,r1,-1
sf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; sym_get_cur: r1=kind -> r1=index, creating the entry if missing.
sym_get_cur:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @sgc_d
; create
LD r1,r0,#W_SYMUSED
ST r1,r0,#R_T1
LA r2,#NCC_SYMMAX
CMP r1,r2
JMP[LT] @sgc_room
MOVI r1,2
JMP @ncc_err
sgc_room:
SHL r2,r1,3
LA r3,#NCC_SYMB
ADD r3,r3,r2
LD r4,r0,#W_TKA+2
ST r4,r3,#SY_HASH
LD r4,r0,#R_T0
ST r4,r3,#SY_KIND
ST r0,r3,#SY_AUX
ST r0,r3,#SY_NP
ST r0,r3,#SY_NL
ST r0,r3,#SY_ENTRY
; copy spelling into the name pool
LD r4,r0,#W_NAMEP
ST r4,r3,#SY_NAME
LD r5,r0,#W_TKA+3
ST r5,r3,#SY_LEN
LA r6,#NCC_NAME
ADD r6,r6,r4
LA r7,#W_TKA+#TK_TEXT
ADDI r8,r5,3
SHR r8,r8,2
BCOPY r6,r7,r8
ADD r4,r4,r8
ST r4,r0,#W_NAMEP
LD r2,r0,#R_T1
ADD r1,r2,r13
ST r1,r0,#W_SYMUSED
ADD r1,r2,r0
sgc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; sym_lookup_var: current token -> r1=index or -1. locals shadow globals.
sym_lookup_var:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,2
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @slv_d
MOVI r1,1
CALL @sym_find_cur
slv_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; sym_lookup_func: current token -> r1=index or -1
sym_lookup_func:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,3
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @slf_d
MOVI r1,4
CALL @sym_find_cur
slf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; sym_entry: r1=index -> r1=entry address
sym_entry:
SHL r1,r1,3
LA r2,#NCC_SYMB
ADD r1,r1,r2
RET

; sym_find_main: r1=index of main (function), or -1
sym_find_main:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,0
ST r2,r0,#W_MIDX
sfm_l:
LD r2,r0,#W_MIDX
LD r3,r0,#W_SYMUSED
CMP r2,r3
JMP[GE] @sfm_n
SHL r3,r2,3
LA r4,#NCC_SYMB
ADD r3,r3,r4
LD r4,r3,#SY_KIND
MOVI r5,3
CMP r4,r5
JMP[NE] @sfm_next
LD r4,r3,#SY_HASH
LA r5,0xEA90E208
CMP r4,r5
JMP[NE] @sfm_next
LD r4,r3,#SY_LEN
MOVI r5,4
CMP r4,r5
JMP[NE] @sfm_next
ADD r1,r3,r0
LA r2,@ncc_s_main
MOVI r3,4
CALL @sym_name_eq
CMP r1,r0
JMP[EQ] @sfm_next
LD r1,r0,#W_MIDX
JMP @sfm_d
sfm_next:
LD r2,r0,#W_MIDX
ADD r2,r2,r13
ST r2,r0,#W_MIDX
JMP @sfm_l
sfm_n:
MOVI r1,0xFFFF
SHL r1,r1,16
ADDI r1,r1,-1
sfm_d:
SUB r14,r14,r13
LD r15,r14,0
RET
ncc_s_main:
.str "main"

; ================================================================== BUILTINS
; Add the four C-runtime helpers used by M1 tests. Their names live in the
; same function namespace as user functions (user definitions win only if the
; builtin is shadowed; duplicate builtins are rejected by sym_get_cur).
ncc_builtins:
ST r15,r14,0
ADD r14,r14,r13
; putchar(c) -> c
LA r1,0x15026602
LA r2,@ncc_s_putchar
MOVI r3,7
MOVI r4,#B_PUTCHAR
MOVI r5,1
CALL @ncc_add_builtin
; print_int(v) -> 0
LA r1,0xE4983C0E
LA r2,@ncc_s_printint
MOVI r3,9
MOVI r4,#B_PRINTINT
MOVI r5,1
CALL @ncc_add_builtin
; puts(s) -> 0 (adds newline)
LA r1,0x9C67D227
LA r2,@ncc_s_puts
MOVI r3,4
MOVI r4,#B_PUTS
MOVI r5,1
CALL @ncc_add_builtin
; print_hex(v) -> 0
LA r1,0x4CC3F73A
LA r2,@ncc_s_printhex
MOVI r3,9
MOVI r4,#B_HEX
MOVI r5,1
CALL @ncc_add_builtin
; print_str(s) -> 0 (no newline)
LA r1,0x70BB0C00
LA r2,@ncc_s_printstr
MOVI r3,9
MOVI r4,#B_PUTSTR
MOVI r5,1
CALL @ncc_add_builtin
SUB r14,r14,r13
LD r15,r14,0
RET

; ncc_add_builtin: r1=hash r2=name(word addr) r3=len r4=id r5=nargs
ncc_add_builtin:
ST r15,r14,0
ADD r14,r14,r13
ST r4,r0,#W_BID
ST r5,r0,#W_BNP
ST r1,r0,#W_TKA+2
ST r3,r0,#W_TKA+3
ST r0,r0,#W_TKA
ST r0,r0,#W_TKA+1
; copy packed name into token text
LA r6,#W_TKA+#TK_TEXT
MOVI r7,3
ADD r7,r7,r3
SHR r7,r7,2
BCOPY r6,r2,r7
MOVI r1,4
CALL @sym_get_cur
CALL @sym_entry
LD r4,r0,#W_BID
ST r4,r1,#SY_AUX
LD r5,r0,#W_BNP
ST r5,r1,#SY_NP
SUB r14,r14,r13
LD r15,r14,0
RET

ncc_s_putchar:
.str "putchar"
ncc_s_printint:
.str "print_int"
ncc_s_puts:
.str "puts"
ncc_s_printhex:
.str "print_hex"
ncc_s_printstr:
.str "print_str"

; ================================================================== STRING POOL
; str_add_cur: current K_STRING token -> r1 = packed string word address
; One character per word: char pointers are plain word pointers, so s[i], &s[i]
; and pointer arithmetic all use the same addressing as int arrays.
str_add_cur:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_STRP
LD r3,r0,#W_TKA+3
ADD r3,r3,r13
ADD r3,r3,r2
LA r4,#NCC_STRMAX
CMP r3,r4
JMP[LT] @sac_room
MOVI r1,4
JMP @ncc_err
sac_room:
LA r4,#NCC_STRB
ADD r4,r4,r2
ST r4,r0,#R_T0
LA r5,#W_TKA+#TK_TEXT
SHL r5,r5,2
LD r6,r0,#W_TKA+3
MOVI r7,0
sac_l:
CMP r7,r6
JMP[GE] @sac_end
LDB r1,r5,0
ST r1,r4,0
ADD r5,r5,r13
ADD r4,r4,r13
ADD r7,r7,r13
JMP @sac_l
sac_end:
ST r0,r4,0
ADD r2,r2,r6
ADD r2,r2,r13
ST r2,r0,#W_STRP
LD r1,r0,#R_T0
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== CONSTANT EXPRESSIONS
; Compile-time integer arithmetic for array sizes. No IR is emitted.
p_cexpr:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_cterm
ST r1,r14,0
ADD r14,r14,r13
pce_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pce_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_PLUS
CMP r1,r2
JMP[EQ] @pce_op
MOVI r2,#P_MINUS
CMP r1,r2
JMP[EQ] @pce_op
JMP @pce_d
pce_op:
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_cterm
ST r1,r14,0
ADD r14,r14,r13
SUB r14,r14,r13
LD r2,r14,0
SUB r14,r14,r13
LD r3,r14,0
SUB r14,r14,r13
LD r1,r14,0
MOVI r4,#P_PLUS
CMP r3,r4
JMP[EQ] @pce_add
SUB r1,r1,r2
JMP @pce_push
pce_add:
ADD r1,r1,r2
pce_push:
ST r1,r14,0
ADD r14,r14,r13
JMP @pce_l
pce_d:
SUB r14,r14,r13
LD r1,r14,0
SUB r14,r14,r13
LD r15,r14,0
RET

p_cterm:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_cunary
ST r1,r14,0
ADD r14,r14,r13
pct_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pct_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_STAR
CMP r1,r2
JMP[EQ] @pct_op
MOVI r2,#P_SLASH
CMP r1,r2
JMP[EQ] @pct_op
MOVI r2,#P_PCT
CMP r1,r2
JMP[EQ] @pct_op
JMP @pct_d
pct_op:
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_cunary
ST r1,r14,0
ADD r14,r14,r13
SUB r14,r14,r13
LD r2,r14,0
SUB r14,r14,r13
LD r3,r14,0
SUB r14,r14,r13
LD r1,r14,0
MOVI r4,#P_STAR
CMP r3,r4
JMP[EQ] @pct_mul
MOVI r4,#P_SLASH
CMP r3,r4
JMP[EQ] @pct_div
MOD r1,r1,r2
JMP @pct_push
pct_div:
DIV r1,r1,r2
JMP @pct_push
pct_mul:
MUL r1,r1,r2
pct_push:
ST r1,r14,0
ADD r14,r14,r13
JMP @pct_l
pct_d:
SUB r14,r14,r13
LD r1,r14,0
SUB r14,r14,r13
LD r15,r14,0
RET

p_cunary:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pcu_prim
LD r1,r0,#W_TKA+1
MOVI r2,#P_PLUS
CMP r1,r2
JMP[EQ] @pcu_pos
MOVI r2,#P_MINUS
CMP r1,r2
JMP[EQ] @pcu_neg
pcu_prim:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pcu_lit
LD r1,r0,#W_TKA+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pcu_par
pcu_lit:
LD r1,r0,#W_TKA
MOVI r2,#K_INT
CMP r1,r2
JMP[EQ] @pcu_val
MOVI r2,#K_CHAR
CMP r1,r2
JMP[EQ] @pcu_val
MOVI r1,31
CALL @p_err
pcu_val:
LD r1,r0,#W_TKA+1
ST r1,r0,#W_TMP
CALL @p_adv
LD r1,r0,#W_TMP
JMP @pcu_d
pcu_pos:
CALL @p_adv
CALL @p_cunary
JMP @pcu_d
pcu_neg:
CALL @p_adv
CALL @p_cunary
SUB r1,r0,r1
JMP @pcu_d
pcu_par:
CALL @p_adv
CALL @p_cexpr
ST r1,r0,#W_TMP
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r1,r0,#W_TMP
pcu_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== EXPRESSIONS
; p_emit_rv: materialise a pending lvalue
p_emit_rv:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[EQ] @per_d
LD r1,r0,#W_LKIND
MOVI r3,4
CMP r1,r3
JMP[EQ] @per_arr_g
MOVI r3,5
CMP r1,r3
JMP[EQ] @per_arr_l
LD r2,r0,#W_LADDR
CALL @emit_load_lv
JMP @per_clear
per_arr_g:
LD r2,r0,#W_LADDR
MOVI r1,1
CALL @emit_addr_lv
JMP @per_clear
per_arr_l:
LD r2,r0,#W_LADDR
MOVI r1,2
CALL @emit_addr_lv
per_clear:
ST r0,r0,#W_LVAL
per_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; emit_load_lv: r1=kind(1 global,2 local) r2=address/offset
emit_load_lv:
ST r15,r14,0
ADD r14,r14,r13
MOVI r3,3
CMP r1,r3
JMP[EQ] @ell_ind
MOVI r3,1
CMP r1,r3
JMP[NE] @ell_local
LA r1,#I_LG
JMP @ell_go
ell_local:
LA r1,#I_LL
JMP @ell_go
ell_ind:
LA r1,#I_LOAD_IND
ell_go:
CALL @ir_emit
SUB r14,r14,r13
LD r15,r14,0
RET
; emit_store_lv: pops the value (indirect also pops the address)
emit_store_lv:
ST r15,r14,0
ADD r14,r14,r13
MOVI r3,3
CMP r1,r3
JMP[EQ] @esl_ind
MOVI r3,1
CMP r1,r3
JMP[NE] @esl_local
LA r1,#I_SG
JMP @esl_go
esl_local:
LA r1,#I_SL
JMP @esl_go
esl_ind:
LA r1,#I_STORE_IND
esl_go:
CALL @ir_emit
SUB r14,r14,r13
LD r15,r14,0
RET
; emit_store_keep_lv: stores the top value but leaves it on the stack
emit_store_keep_lv:
ST r15,r14,0
ADD r14,r14,r13
MOVI r3,3
CMP r1,r3
JMP[NE] @esk_direct
; [addr,val] -> store, leave val
LA r1,#I_STORE_IND_KEEP
MOVI r2,0
CALL @ir_emit
JMP @esk_d
esk_direct:
MOVI r3,1
CMP r1,r3
JMP[NE] @esk_local
LA r1,#I_SGK
JMP @esk_go
esk_local:
LA r1,#I_SLK
esk_go:
CALL @ir_emit
esk_d:
SUB r14,r14,r13
LD r15,r14,0
RET
; emit_addr_lv: r1=kind r2=addr -> push the address
emit_addr_lv:
ST r15,r14,0
ADD r14,r14,r13
MOVI r3,1
CMP r1,r3
JMP[NE] @eal_l
LA r1,#I_GADDR
JMP @eal_go
eal_l:
LA r1,#I_LADDR
eal_go:
CALL @ir_emit
SUB r14,r14,r13
LD r15,r14,0
RET

; p_primary: literals, identifiers, calls, parenthesised expressions
p_primary:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,2
CMP r1,r2
JMP[EQ] @pp_int
MOVI r2,5
CMP r1,r2
JMP[EQ] @pp_int
MOVI r2,4
CMP r1,r2
JMP[EQ] @pp_str
MOVI r2,3
CMP r1,r2
JMP[EQ] @pp_ident
MOVI r2,6
CMP r1,r2
JMP[EQ] @pp_punct
MOVI r1,5
CALL @p_err
pp_int:
LD r2,r0,#W_TKA+1
LA r1,#I_PUSH
CALL @ir_emit
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_d
pp_str:
CALL @str_add_cur
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_d
pp_ident:
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,6
CMP r1,r2
JMP[NE] @pp_var
LD r1,r0,#W_TKB+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pp_call
pp_var:
CALL @sym_lookup_var
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @pp_var_ok
MOVI r1,6
CALL @p_err
pp_var_ok:
CALL @sym_entry
LD r2,r1,#SY_KIND
LD r3,r1,#SY_AUX
ST r3,r0,#W_LADDR
LD r4,r1,#SY_NL
CMP r4,r0
JMP[EQ] @pp_var_scalar
; array name: its value is the base address
MOVI r3,1
CMP r2,r3
JMP[NE] @pp_var_arr_l
MOVI r3,4
ST r3,r0,#W_LKIND
JMP @pp_var_arr_done
pp_var_arr_l:
MOVI r3,5
ST r3,r0,#W_LKIND
pp_var_arr_done:
MOVI r3,1
ST r3,r0,#W_LVAL
CALL @p_adv
JMP @pp_d
pp_var_scalar:
MOVI r3,1
CMP r2,r3
JMP[EQ] @pp_var_g
MOVI r3,2
ST r3,r0,#W_LKIND
JMP @pp_var_s
pp_var_g:
MOVI r3,1
ST r3,r0,#W_LKIND
pp_var_s:
MOVI r3,1
ST r3,r0,#W_LVAL
CALL @p_adv
JMP @pp_d
pp_call:
CALL @sym_lookup_func
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @pp_call_ok
MOVI r1,8
CALL @p_err
pp_call_ok:
ST r1,r14,0
ADD r14,r14,r13
ST r0,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pp_args_done
pp_args_l:
CALL @p_assign
CALL @p_emit_rv
ADDI r1,r14,-1
LD r2,r1,0
ADD r2,r2,r13
ST r2,r1,0
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pp_args_l
pp_args_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
ADDI r3,r14,-1
LD r2,r3,0
SHL r2,r2,16
ADDI r3,r3,-1
LD r3,r3,0
BOOL.14 r2,r2,r3
LA r1,#I_CALL
CALL @ir_emit
ADDI r14,r14,-2
ST r0,r0,#W_LVAL
JMP @pp_d
pp_punct:
LD r1,r0,#W_TKA+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pp_paren
MOVI r1,7
CALL @p_err
pp_paren:
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @pp_paren_expr
LD r1,r0,#W_TKB+1
CALL @kw_is_type
CMP r1,r0
JMP[EQ] @pp_paren_expr
; cast: ( type ) unary
CALL @p_adv
CALL @p_skip_types
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
CALL @p_unary
CALL @p_emit_rv
ST r0,r0,#W_LVAL
JMP @pp_d
pp_paren_expr:
CALL @p_adv
CALL @p_expr
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
JMP @pp_d
pp_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_postfix: identifier++ / identifier--
p_postfix:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_primary
ppf_idx:
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[EQ] @ppf_inc
CALL @p_emit_rv
CALL @p_adv
CALL @p_expr
CALL @p_emit_rv
MOVI r1,#P_RBRACK
MOVI r2,33
CALL @p_expect_p
LA r1,#I_ADD
CALL @ir_op
MOVI r1,3
ST r1,r0,#W_LKIND
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @ppf_idx
ppf_inc:
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[EQ] @ppf_d
LD r1,r0,#W_TKA
MOVI r2,6
CMP r1,r2
JMP[NE] @ppf_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @ppf_go
MOVI r2,#P_DEC
CMP r1,r2
JMP[NE] @ppf_d
ppf_go:
LD r3,r0,#W_LKIND
ST r3,r14,0
ADD r14,r14,r13
LD r3,r0,#W_LADDR
ST r3,r14,0
ADD r14,r14,r13
LD r3,r0,#W_TKA+1
ST r3,r14,0
ADD r14,r14,r13
CALL @p_adv
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,3
CMP r1,r2
JMP[EQ] @ppf_ind
; direct lvalue
ADDI r3,r14,-3
LD r1,r3,0
LD r2,r3,1
CALL @emit_load_lv
LA r1,#I_DUP
CALL @ir_op
LA r1,#I_PUSH
MOVI r2,1
CALL @ir_emit
ADDI r3,r14,-1
LD r1,r3,0
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @ppf_dinc
LA r1,#I_SUB
JMP @ppf_dop
ppf_dinc:
LA r1,#I_ADD
ppf_dop:
CALL @ir_op
ADDI r3,r14,-3
LD r1,r3,0
LD r2,r3,1
CALL @emit_store_keep_lv
LA r1,#I_POP
CALL @ir_op
JMP @ppf_fin
ppf_ind:
LA r1,#I_DUP
CALL @ir_op
MOVI r1,3
MOVI r2,0
CALL @emit_load_lv
LA r1,#I_PUSH
MOVI r2,1
CALL @ir_emit
ADDI r3,r14,-1
LD r1,r3,0
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @ppf_iinc
LA r1,#I_SUB
JMP @ppf_iop
ppf_iinc:
LA r1,#I_ADD
ppf_iop:
CALL @ir_op
LA r1,#I_STORE_IND_KEEP
MOVI r2,0
CALL @ir_emit
; recover the old value: new-1 for ++, new+1 for --
LA r1,#I_PUSH
MOVI r2,1
CALL @ir_emit
ADDI r3,r14,-1
LD r1,r3,0
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @ppf_oldinc
LA r1,#I_ADD
JMP @ppf_oldop
ppf_oldinc:
LA r1,#I_SUB
ppf_oldop:
CALL @ir_op
ppf_fin:
ADDI r14,r14,-3
ST r0,r0,#W_LVAL
ppf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_unary
p_unary:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @pu_punct
LD r1,r0,#W_TKA+1
MOVI r2,#KW_SIZEOF
CMP r1,r2
JMP[EQ] @pu_sizeof
JMP @pu_post
pu_punct:
LD r1,r0,#W_TKA
MOVI r2,6
CMP r1,r2
JMP[NE] @pu_post
LD r1,r0,#W_TKA+1
MOVI r2,#P_PLUS
CMP r1,r2
JMP[EQ] @pu_plus
MOVI r2,#P_MINUS
CMP r1,r2
JMP[EQ] @pu_minus
MOVI r2,#P_BANG
CMP r1,r2
JMP[EQ] @pu_lnot
MOVI r2,#P_TILDE
CMP r1,r2
JMP[EQ] @pu_not
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pu_incdec
MOVI r2,#P_DEC
CMP r1,r2
JMP[EQ] @pu_incdec
MOVI r2,#P_AMP
CMP r1,r2
JMP[EQ] @pu_addr
MOVI r2,#P_STAR
CMP r1,r2
JMP[EQ] @pu_deref
JMP @pu_post
pu_plus:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
JMP @pu_d
pu_minus:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
LA r1,#I_NEG
CALL @ir_op
ST r0,r0,#W_LVAL
JMP @pu_d
pu_lnot:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
LA r1,#I_LNOT
CALL @ir_op
ST r0,r0,#W_LVAL
JMP @pu_d
pu_not:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
LA r1,#I_NOT
CALL @ir_op
ST r0,r0,#W_LVAL
JMP @pu_d
pu_addr:
CALL @p_adv
CALL @p_unary
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pu_addr_ok
MOVI r1,34
CALL @p_err
pu_addr_ok:
LD r1,r0,#W_LKIND
MOVI r2,3
CMP r1,r2
JMP[EQ] @pu_addr_ind
MOVI r2,4
CMP r1,r2
JMP[EQ] @pu_addr_arr
MOVI r2,5
CMP r1,r2
JMP[EQ] @pu_addr_arr
; direct variable: emit its address
LD r2,r0,#W_LADDR
CALL @emit_addr_lv
JMP @pu_addr_done
pu_addr_arr:
CALL @p_emit_rv
JMP @pu_addr_done
pu_addr_ind:
; the address is already on the eval stack
pu_addr_done:
ST r0,r0,#W_LVAL
JMP @pu_d
pu_deref:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
MOVI r1,3
ST r1,r0,#W_LKIND
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pu_d
pu_sizeof:
CALL @p_adv
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pu_szsimple
LD r1,r0,#W_TKA+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[NE] @pu_szsimple
CALL @p_peek
; sizeof(type)
LD r1,r0,#W_TKB
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @pu_sz_paren_name
LD r1,r0,#W_TKB+1
CALL @kw_is_type
CMP r1,r0
JMP[EQ] @pu_szexpr
CALL @p_adv
CALL @p_skip_types
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
JMP @pu_sz_push1
; sizeof(identifier...) - simple name if the next token is ')'
pu_sz_paren_name:
LD r1,r0,#W_TKB
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pu_szexpr
CALL @p_adv
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pu_sz_paren_expr
LD r1,r0,#W_TKB+1
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[NE] @pu_sz_paren_expr
CALL @pu_size_ident
ST r1,r0,#W_TMP
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r2,r0,#W_TMP
JMP @pu_sz_emit
pu_sz_paren_expr:
CALL @p_unary
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
JMP @pu_sz_push1
pu_szsimple:
CALL @p_is_type
CMP r1,r0
JMP[EQ] @pu_szident
CALL @p_skip_types
JMP @pu_sz_push1
pu_szident:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pu_szexpr
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pu_szident_go
LD r1,r0,#W_TKB+1
MOVI r2,#P_LBRACK
CMP r1,r2
JMP[EQ] @pu_szexpr
pu_szident_go:
CALL @pu_size_ident
ADD r2,r1,r0
JMP @pu_sz_emit
pu_szexpr:
CALL @p_unary
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
pu_sz_push1:
MOVI r2,1
pu_sz_emit:
LA r1,#I_PUSH
CALL @ir_emit
ST r0,r0,#W_LVAL
JMP @pu_d

; pu_size_ident: current identifier -> r1 = array length or 1; consumes it.
pu_size_ident:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pusi_one
CALL @sym_lookup_var
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @pusi_one
CALL @sym_entry
LD r1,r1,#SY_NL
CMP r1,r0
JMP[EQ] @pusi_one
ST r1,r0,#W_TMP
CALL @p_adv
LD r1,r0,#W_TMP
JMP @pusi_d
pusi_one:
MOVI r1,1
pusi_d:
SUB r14,r14,r13
LD r15,r14,0
RET
pu_incdec:
LD r1,r0,#W_TKA+1
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_unary
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pu_id_ok
MOVI r1,11
CALL @p_err
pu_id_ok:
LD r1,r0,#W_LKIND
MOVI r2,4
CMP r1,r2
JMP[GE] @pu_id_bad
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_LADDR
ST r1,r14,0
ADD r14,r14,r13
; indirect: keep a copy of the address under the value
ADDI r3,r14,-2
LD r1,r3,0
MOVI r2,3
CMP r1,r2
JMP[NE] @pu_id_load
LA r1,#I_DUP
CALL @ir_op
pu_id_load:
ADDI r3,r14,-2
LD r1,r3,0
LD r2,r3,1
CALL @emit_load_lv
LA r1,#I_PUSH
MOVI r2,1
CALL @ir_emit
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pu_inc
LA r1,#I_SUB
JMP @pu_iop
pu_id_bad:
MOVI r1,34
CALL @p_err
pu_inc:
LA r1,#I_ADD
pu_iop:
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
MOVI r4,3
CMP r1,r4
JMP[EQ] @pu_i_keep
LA r1,#I_DUP
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
LD r2,r3,1
CALL @emit_store_lv
JMP @pu_i_done
pu_i_keep:
ADDI r3,r14,-2
LD r2,r3,1
CALL @emit_store_keep_lv
pu_i_done:
ADDI r14,r14,-3
ST r0,r0,#W_LVAL
JMP @pu_d
pu_post:
CALL @p_postfix
pu_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; binary levels -----------------------------------------------------
p_mul:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_unary
pm_l:
LD r1,r0,#W_TKA
MOVI r2,6
CMP r1,r2
JMP[NE] @pm_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_STAR
CMP r1,r2
JMP[EQ] @pm_star
MOVI r2,#P_SLASH
CMP r1,r2
JMP[EQ] @pm_slash
MOVI r2,#P_PCT
CMP r1,r2
JMP[EQ] @pm_pct
JMP @pm_d
pm_star:
LA r3,#I_MUL
JMP @pm_go
pm_slash:
LA r3,#I_DIV
JMP @pm_go
pm_pct:
LA r3,#I_MOD
pm_go:
ST r3,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
SUB r14,r14,r13
LD r1,r14,0
CALL @ir_op
JMP @pm_l
pm_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_add:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_mul
pa_l:
LD r1,r0,#W_TKA
MOVI r2,6
CMP r1,r2
JMP[NE] @padd_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_PLUS
CMP r1,r2
JMP[EQ] @padd_plus
MOVI r2,#P_MINUS
CMP r1,r2
JMP[EQ] @padd_minus
JMP @padd_d
padd_plus:
LA r3,#I_ADD
JMP @padd_go
padd_minus:
LA r3,#I_SUB
padd_go:
ST r3,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
CALL @p_adv
CALL @p_mul
CALL @p_emit_rv
SUB r14,r14,r13
LD r1,r14,0
CALL @ir_op
JMP @pa_l
padd_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_shift:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_add
ps_l:
LD r1,r0,#W_TKA
MOVI r2,6
CMP r1,r2
JMP[NE] @ncc_ps_done
LD r1,r0,#W_TKA+1
MOVI r2,#P_SHL
CMP r1,r2
JMP[EQ] @ps_shl
MOVI r2,#P_SHR
CMP r1,r2
JMP[EQ] @ps_shr
JMP @ncc_ps_done
ps_shl:
LA r3,#I_SHL
JMP @ps_go
ps_shr:
LA r3,#I_SHR
ps_go:
ST r3,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
CALL @p_adv
CALL @p_add
CALL @p_emit_rv
SUB r14,r14,r13
LD r1,r14,0
CALL @ir_op
JMP @ps_l
ncc_ps_done:
SUB r14,r14,r13
LD r15,r14,0
RET

p_rel:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_shift
pr_l:
LD r1,r0,#W_TKA
MOVI r2,6
CMP r1,r2
JMP[NE] @pr_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_LT
CMP r1,r2
JMP[EQ] @pr_lt
MOVI r2,#P_GT
CMP r1,r2
JMP[EQ] @pr_gt
MOVI r2,#P_LE
CMP r1,r2
JMP[EQ] @pr_le
MOVI r2,#P_GE
CMP r1,r2
JMP[EQ] @pr_ge
JMP @pr_d
pr_lt:
LA r3,#I_LT
JMP @pr_go
pr_gt:
LA r3,#I_GT
JMP @pr_go
pr_le:
LA r3,#I_LE
JMP @pr_go
pr_ge:
LA r3,#I_GE
pr_go:
ST r3,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
CALL @p_adv
CALL @p_shift
CALL @p_emit_rv
SUB r14,r14,r13
LD r1,r14,0
CALL @ir_op
JMP @pr_l
pr_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_eq:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_rel
pe_l:
LD r1,r0,#W_TKA
MOVI r2,6
CMP r1,r2
JMP[NE] @pe_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_EQ
CMP r1,r2
JMP[EQ] @pe_eq
MOVI r2,#P_NE
CMP r1,r2
JMP[EQ] @pe_ne
JMP @pe_d
pe_eq:
LA r3,#I_EQ
JMP @pe_go
pe_ne:
LA r3,#I_NE
pe_go:
ST r3,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
CALL @p_adv
CALL @p_rel
CALL @p_emit_rv
SUB r14,r14,r13
LD r1,r14,0
CALL @ir_op
JMP @pe_l
pe_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_band:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_eq
pba_l:
MOVI r1,#P_AMP
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pba_d
CALL @p_emit_rv
CALL @p_adv
CALL @p_eq
CALL @p_emit_rv
LA r1,#I_AND
CALL @ir_op
JMP @pba_l
pba_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_bxor:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_band
pbx_l:
MOVI r1,#P_CARET
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pbx_d
CALL @p_emit_rv
CALL @p_adv
CALL @p_band
CALL @p_emit_rv
LA r1,#I_XOR
CALL @ir_op
JMP @pbx_l
pbx_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_bor:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_bxor
pbo_l:
MOVI r1,#P_BAR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pbo_d
CALL @p_emit_rv
CALL @p_adv
CALL @p_bxor
CALL @p_emit_rv
LA r1,#I_OR
CALL @ir_op
JMP @pbo_l
pbo_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_land:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_bor
pl_l:
MOVI r1,#P_LAND
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pl_d
CALL @p_emit_rv
CALL @p_adv
LA r1,#I_JZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
CALL @p_bor
CALL @p_emit_rv
LA r1,#I_JZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
LA r1,#I_PUSH
MOVI r2,1
CALL @ir_emit
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
; save the end-jump index, then patch both false jumps to here
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#R_T0
CALL @ir_here
ST r1,r0,#R_T1
SUB r14,r14,r13
LD r1,r14,0
LD r2,r0,#R_T1
CALL @ir_patch
CALL @ir_here
ST r1,r0,#R_T1
SUB r14,r14,r13
LD r1,r14,0
LD r2,r0,#R_T1
CALL @ir_patch
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
CALL @ir_here
ST r1,r0,#R_T1
LD r1,r0,#R_T0
LD r2,r0,#R_T1
CALL @ir_patch
JMP @pl_l
pl_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_lor:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_land
plo_l:
MOVI r1,#P_LOR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @plo_d
CALL @p_emit_rv
CALL @p_adv
LA r1,#I_JNZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
CALL @p_land
CALL @p_emit_rv
LA r1,#I_JNZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#R_T0
CALL @ir_here
ST r1,r0,#R_T1
SUB r14,r14,r13
LD r1,r14,0
LD r2,r0,#R_T1
CALL @ir_patch
CALL @ir_here
ST r1,r0,#R_T1
SUB r14,r14,r13
LD r1,r14,0
LD r2,r0,#R_T1
CALL @ir_patch
LA r1,#I_PUSH
MOVI r2,1
CALL @ir_emit
CALL @ir_here
ST r1,r0,#R_T1
LD r1,r0,#R_T0
LD r2,r0,#R_T1
CALL @ir_patch
JMP @plo_l
plo_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_cond:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_lor
MOVI r1,#P_QUESTION
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pc_d
CALL @p_emit_rv
CALL @p_adv
LA r1,#I_JZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
CALL @p_expr
CALL @p_emit_rv
MOVI r1,#P_COLON
MOVI r2,12
CALL @p_expect_p
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
CALL @ir_here
ADD r4,r1,r0
ADDI r3,r14,-2
LD r1,r3,0
ADD r2,r4,r0
CALL @ir_patch
CALL @p_cond
CALL @p_emit_rv
CALL @ir_here
ADD r4,r1,r0
ADDI r3,r14,-1
LD r1,r3,0
ADD r2,r4,r0
CALL @ir_patch
ADDI r14,r14,-2
ST r0,r0,#W_LVAL
JMP @pc_d
pc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_compop: r1=assignment punct -> r1=binary IR op
p_compop:
MOVI r2,#P_PLUSEQ
CMP r1,r2
JMP[EQ] @pco_add
MOVI r2,#P_MINUSEQ
CMP r1,r2
JMP[EQ] @pco_sub
MOVI r2,#P_STAREQ
CMP r1,r2
JMP[EQ] @pco_mul
MOVI r2,#P_SLASHEQ
CMP r1,r2
JMP[EQ] @pco_div
MOVI r2,#P_PCTEQ
CMP r1,r2
JMP[EQ] @pco_mod
MOVI r2,#P_SHLEQ
CMP r1,r2
JMP[EQ] @pco_shl
MOVI r2,#P_SHREQ
CMP r1,r2
JMP[EQ] @pco_shr
MOVI r2,#P_AMPEQ
CMP r1,r2
JMP[EQ] @pco_and
MOVI r2,#P_BAREQ
CMP r1,r2
JMP[EQ] @pco_or
MOVI r1,#I_XOR
RET
pco_add:
MOVI r1,#I_ADD
RET
pco_sub:
MOVI r1,#I_SUB
RET
pco_mul:
MOVI r1,#I_MUL
RET
pco_div:
MOVI r1,#I_DIV
RET
pco_mod:
MOVI r1,#I_MOD
RET
pco_shl:
MOVI r1,#I_SHL
RET
pco_shr:
MOVI r1,#I_SHR
RET
pco_and:
MOVI r1,#I_AND
RET
pco_or:
MOVI r1,#I_OR
RET

p_assign:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_cond
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[EQ] @pas_d
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pas_d
LD r1,r0,#W_TKA+1
CALL @p_is_assign
CMP r1,r0
JMP[EQ] @pas_d
LD r1,r0,#W_LKIND
MOVI r2,4
CMP r1,r2
JMP[LT] @pas_lv_ok
MOVI r1,32
CALL @p_err
pas_lv_ok:
LD r3,r0,#W_LKIND
ST r3,r14,0
ADD r14,r14,r13
LD r3,r0,#W_LADDR
ST r3,r14,0
ADD r14,r14,r13
LD r3,r0,#W_TKA+1
ST r3,r14,0
ADD r14,r14,r13
CALL @p_adv
ADDI r3,r14,-1
LD r1,r3,0
MOVI r2,#P_ASSIGN
CMP r1,r2
JMP[EQ] @pas_simple
; compound assignment
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,3
CMP r1,r2
JMP[NE] @pas_c_load
LA r1,#I_DUP
CALL @ir_op
pas_c_load:
ADDI r3,r14,-3
LD r1,r3,0
ADDI r3,r14,-2
LD r2,r3,0
CALL @emit_load_lv
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-1
LD r1,r3,0
CALL @p_compop
CALL @ir_op
ADDI r3,r14,-3
LD r1,r3,0
MOVI r4,3
CMP r1,r4
JMP[EQ] @pas_c_keep
LA r1,#I_DUP
CALL @ir_op
ADDI r3,r14,-3
LD r1,r3,0
ADDI r3,r14,-2
LD r2,r3,0
CALL @emit_store_lv
JMP @pas_c_stored
pas_c_keep:
ADDI r3,r14,-2
LD r2,r3,0
CALL @emit_store_keep_lv
pas_c_stored:
ADDI r14,r14,-3
ST r0,r0,#W_LVAL
JMP @pas_d
pas_simple:
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-3
LD r1,r3,0
MOVI r4,3
CMP r1,r4
JMP[EQ] @pas_s_keep
LA r1,#I_DUP
CALL @ir_op
ADDI r3,r14,-3
LD r1,r3,0
ADDI r3,r14,-2
LD r2,r3,0
CALL @emit_store_lv
JMP @pas_s_stored
pas_s_keep:
ADDI r3,r14,-2
LD r2,r3,0
CALL @emit_store_keep_lv
pas_s_stored:
ADDI r14,r14,-3
ST r0,r0,#W_LVAL
pas_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_is_assign:
MOVI r2,#P_ASSIGN
CMP r1,r2
JMP[EQ] @pia_y
MOVI r2,#P_PLUSEQ
CMP r1,r2
JMP[LT] @pia_n
MOVI r2,#P_CARETEQ
CMP r1,r2
JMP[GT] @pia_n
pia_y:
MOVI r1,1
RET
pia_n:
MOVI r1,0
RET

; p_expr: comma expression
p_expr:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_assign
pex_l:
MOVI r1,#P_COMMA
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pex_d
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
CALL @p_adv
CALL @p_assign
JMP @pex_l
pex_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== STATEMENTS
; p_block: current token is '{'
p_block:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#P_LBRACE
MOVI r2,20
CALL @p_expect_p
pb_l:
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pb_d
LD r1,r0,#W_TKA
MOVI r2,#K_EOF
CMP r1,r2
JMP[NE] @pb_s
MOVI r1,21
CALL @p_err
pb_s:
CALL @p_stmt
JMP @pb_l
pb_d:
CALL @p_adv
SUB r14,r14,r13
LD r15,r14,0
RET

; p_stmt
p_stmt:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pst_kw
LD r1,r0,#W_TKA+1
MOVI r2,#P_LBRACE
CMP r1,r2
JMP[EQ] @pst_block
MOVI r2,#P_SEMI
CMP r1,r2
JMP[EQ] @pst_empty
JMP @pst_expr
pst_block:
CALL @p_block
JMP @pst_d
pst_empty:
CALL @p_adv
JMP @pst_d
pst_kw:
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @pst_expr
LD r1,r0,#W_TKA+1
MOVI r2,#KW_IF
CMP r1,r2
JMP[EQ] @pst_if
MOVI r2,#KW_WHILE
CMP r1,r2
JMP[EQ] @pst_while
MOVI r2,#KW_FOR
CMP r1,r2
JMP[EQ] @pst_for
MOVI r2,#KW_DO
CMP r1,r2
JMP[EQ] @pst_do
MOVI r2,#KW_RETURN
CMP r1,r2
JMP[EQ] @pst_ret
MOVI r2,#KW_BREAK
CMP r1,r2
JMP[EQ] @pst_break
MOVI r2,#KW_CONTINUE
CMP r1,r2
JMP[EQ] @pst_cont
CALL @p_is_type
CMP r1,r0
JMP[NE] @pst_decl
JMP @pst_expr
pst_if:
CALL @p_if
JMP @pst_d
pst_while:
CALL @p_while
JMP @pst_d
pst_for:
CALL @p_for
JMP @pst_d
pst_do:
CALL @p_do
JMP @pst_d
pst_ret:
CALL @p_return
JMP @pst_d
pst_break:
CALL @p_break
JMP @pst_d
pst_cont:
CALL @p_continue
JMP @pst_d
pst_decl:
CALL @p_decl
JMP @pst_d
pst_expr:
CALL @p_expr
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
MOVI r1,#P_SEMI
MOVI r2,22
CALL @p_expect_p
pst_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_decl: local declarations (one or more declarators)
p_decl:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_skip_types
pd_one:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pd_ident
MOVI r1,23
CALL @p_err
pd_ident:
MOVI r1,#SK_LOCAL
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
; optional array bound
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pd_scalar
CALL @p_adv
CALL @p_cexpr
CMP r1,r0
JMP[GT] @pd_count_ok
MOVI r1,31
CALL @p_err
pd_count_ok:
ST r1,r14,0
ADD r14,r14,r13
MOVI r1,#P_RBRACK
MOVI r2,33
CALL @p_expect_p
JMP @pd_count_done
pd_scalar:
ST r0,r14,0
ADD r14,r14,r13
pd_count_done:
; stack: symidx, count; push the local offset
LD r2,r0,#W_NLOC
ST r2,r14,0
ADD r14,r14,r13
ADDI r3,r14,-3
LD r1,r3,0
CALL @sym_entry
ADDI r3,r14,-1
LD r2,r3,0
ST r2,r1,#SY_AUX
LD r3,r0,#W_FUNCSYM
ST r3,r1,#SY_NP
ADDI r3,r14,-2
LD r3,r3,0
ST r3,r1,#SY_NL
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r14,-2
LD r3,r3,0
CMP r3,r0
JMP[NE] @pd_nloc_arr
ADD r2,r2,r13
JMP @pd_nloc_set
pd_nloc_arr:
ADD r2,r2,r3
pd_nloc_set:
ST r2,r0,#W_NLOC
; zero an array before any initialiser
ADDI r3,r14,-2
LD r3,r3,0
CMP r3,r0
JMP[EQ] @pd_init
ADDI r3,r14,-2
LD r1,r3,0
SHL r1,r1,16
ADDI r3,r14,-1
LD r2,r3,0
BOOL.14 r2,r2,r1
LA r1,#I_LZERO
CALL @ir_emit
pd_init:
MOVI r1,#P_ASSIGN
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pd_noinit
; array initialiser list?
ADDI r3,r14,-2
LD r3,r3,0
CMP r3,r0
JMP[EQ] @pd_scalar_init
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pd_array_scalar
CALL @p_adv
MOVI r1,0
ST r1,r14,0
ADD r14,r14,r13
pd_ai_l:
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pd_ai_done
; store only while idx < count
ADDI r3,r14,-1
LD r4,r3,0
ADDI r3,r14,-3
LD r5,r3,0
CMP r4,r5
JMP[GE] @pd_ai_skip
ADDI r3,r14,-2
LD r2,r3,0
ADD r2,r2,r4
LA r1,#I_LADDR
CALL @ir_emit
CALL @p_assign
CALL @p_emit_rv
LA r1,#I_STORE_IND
MOVI r2,0
CALL @ir_emit
JMP @pd_ai_step
pd_ai_skip:
CALL @p_assign
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
pd_ai_step:
ADDI r3,r14,-1
LD r4,r3,0
ADD r4,r4,r13
ST r4,r3,0
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pd_ai_l
pd_ai_done:
MOVI r1,#P_RBRACE
MOVI r2,35
CALL @p_expect_p
ADDI r14,r14,-1
JMP @pd_afterinit
pd_array_scalar:
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
MOVI r1,2
CALL @emit_store_lv
JMP @pd_afterinit
pd_scalar_init:
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
MOVI r1,2
CALL @emit_store_lv
JMP @pd_afterinit
pd_noinit:
ADDI r3,r14,-2
LD r3,r3,0
CMP r3,r0
JMP[NE] @pd_afterinit
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
ADDI r3,r14,-1
LD r2,r3,0
MOVI r1,2
CALL @emit_store_lv
pd_afterinit:
ADDI r14,r14,-3
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pd_one
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- break / continue ----------------------------------------------
p_break:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
LA r1,#I_JMP
CALL @ir_op
LD r1,r0,#W_BRK_N
MOVI r2,64
CMP r1,r2
JMP[LT] @pbr_ok
MOVI r1,25
CALL @p_err
pbr_ok:
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
LA r3,#W_BRK_TAB
ADD r3,r3,r1
ST r2,r3,0
ADD r1,r1,r13
ST r1,r0,#W_BRK_N
SUB r14,r14,r13
LD r15,r14,0
RET

p_continue:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
LA r1,#I_JMP
CALL @ir_op
LD r1,r0,#W_CNT_N
MOVI r2,64
CMP r1,r2
JMP[LT] @pcn_ok
MOVI r1,25
CALL @p_err
pcn_ok:
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
LA r3,#W_CNT_TAB
ADD r3,r3,r1
ST r2,r3,0
ADD r1,r1,r13
ST r1,r0,#W_CNT_N
SUB r14,r14,r13
LD r15,r14,0
RET

; p_patch_cont: r1=base, r2=target
p_patch_cont:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
ST r2,r0,#R_T1
ppc_l:
LD r1,r0,#R_T0
LD r2,r0,#W_CNT_N
CMP r1,r2
JMP[GE] @ppc_d
LA r3,#W_CNT_TAB
ADD r3,r3,r1
LD r1,r3,0
LD r2,r0,#R_T1
CALL @ir_patch
LD r1,r0,#R_T0
ADD r1,r1,r13
ST r1,r0,#R_T0
JMP @ppc_l
ppc_d:
SUB r14,r14,r13
LD r15,r14,0
RET
; p_patch_brk: r1=base, r2=target
p_patch_brk:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
ST r2,r0,#R_T1
ppb_l:
LD r1,r0,#R_T0
LD r2,r0,#W_BRK_N
CMP r1,r2
JMP[GE] @ppb_d
LA r3,#W_BRK_TAB
ADD r3,r3,r1
LD r1,r3,0
LD r2,r0,#R_T1
CALL @ir_patch
LD r1,r0,#R_T0
ADD r1,r1,r13
ST r1,r0,#R_T0
JMP @ppb_l
ppb_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- if ------------------------------------------------------------
p_if:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_expr
CALL @p_emit_rv
LA r1,#I_JZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
CALL @p_stmt
MOVI r1,#KW_ELSE
CALL @p_at_k
CMP r1,r0
JMP[EQ] @pif_noelse
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r14,0
ADD r14,r14,r13
; patch the JZ to here
CALL @ir_here
ADD r4,r1,r0
ADDI r3,r14,-2
LD r1,r3,0
ADD r2,r4,r0
CALL @ir_patch
CALL @p_adv
CALL @p_stmt
CALL @ir_here
ADD r4,r1,r0
ADDI r3,r14,-1
LD r1,r3,0
ADD r2,r4,r0
CALL @ir_patch
ADDI r14,r14,-2
JMP @pif_d
pif_noelse:
CALL @ir_here
ADD r4,r1,r0
ADDI r3,r14,-1
LD r1,r3,0
ADD r2,r4,r0
CALL @ir_patch
ADDI r14,r14,-1
pif_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_while:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @loop_enter
MOVI r1,2
CALL @loop_set_here
CALL @p_expr
CALL @p_emit_rv
LA r1,#I_JZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
MOVI r1,3
CALL @loop_set
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
CALL @p_stmt
MOVI r1,2
CALL @loop_get
ADD r2,r1,r0
LA r1,#I_JMP
CALL @ir_emit
MOVI r1,5
CALL @loop_set_here
MOVI r1,1
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,2
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @p_patch_cont
MOVI r1,0
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,5
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @p_patch_brk
MOVI r1,3
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,5
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @ir_patch
CALL @loop_leave
SUB r14,r14,r13
LD r15,r14,0
RET

p_for:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @loop_enter
MOVI r1,#P_SEMI
CALL @p_at_p
CMP r1,r0
JMP[NE] @pf_cond
CALL @p_is_type
CMP r1,r0
JMP[EQ] @pf_expinit
CALL @p_decl
JMP @pf_cond
pf_expinit:
CALL @p_expr
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
MOVI r1,#P_SEMI
MOVI r2,22
CALL @p_expect_p
pf_cond:
MOVI r1,2
CALL @loop_set_here
MOVI r1,#P_SEMI
CALL @p_at_p
CMP r1,r0
JMP[NE] @pf_condtrue
CALL @p_expr
CALL @p_emit_rv
JMP @pf_condtest
pf_condtrue:
LA r1,#I_PUSH
MOVI r2,1
CALL @ir_emit
pf_condtest:
LA r1,#I_JZ
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
MOVI r1,3
CALL @loop_set
MOVI r1,#P_SEMI
MOVI r2,22
CALL @p_expect_p
; post expression emitted here, skipped on the first pass
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
MOVI r1,6
CALL @loop_set
MOVI r1,4
CALL @loop_set_here
CALL @p_expr
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,2
CALL @loop_get
ADD r2,r1,r0
LA r1,#I_JMP
CALL @ir_emit
; body starts here
MOVI r1,5
CALL @loop_set_here
MOVI r1,6
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,5
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @ir_patch
CALL @p_stmt
MOVI r1,4
CALL @loop_get
ADD r2,r1,r0
LA r1,#I_JMP
CALL @ir_emit
; end
MOVI r1,7
CALL @loop_set_here
MOVI r1,1
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,4
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @p_patch_cont
MOVI r1,0
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,7
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @p_patch_brk
MOVI r1,3
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,7
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @ir_patch
CALL @loop_leave
SUB r14,r14,r13
LD r15,r14,0
RET

p_do:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @loop_enter
MOVI r1,2
CALL @loop_set_here
CALL @p_stmt
MOVI r1,#KW_WHILE
MOVI r2,26
CALL @p_expect_k
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,4
CALL @loop_set_here
CALL @p_expr
CALL @p_emit_rv
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
MOVI r1,2
CALL @loop_get
ADD r2,r1,r0
LA r1,#I_JNZ
CALL @ir_emit
MOVI r1,5
CALL @loop_set_here
MOVI r1,1
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,4
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @p_patch_cont
MOVI r1,0
CALL @loop_get
ST r1,r0,#R_T0
MOVI r1,5
CALL @loop_get
ADD r2,r1,r0
LD r1,r0,#R_T0
CALL @p_patch_brk
CALL @loop_leave
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- loop context ------------------------------------------------
loop_enter:
LD r1,r0,#W_LOOPN
MOVI r2,32
CMP r1,r2
JMP[LT] @len_ok
MOVI r1,27
JMP @ncc_err
len_ok:
SHL r2,r1,3
LA r3,#W_LOOPS
ADD r2,r2,r3
LD r3,r0,#W_BRK_N
ST r3,r2,0
LD r3,r0,#W_CNT_N
ST r3,r2,1
ST r0,r2,2
ST r0,r2,3
ST r0,r2,4
ST r0,r2,5
ST r0,r2,6
ST r0,r2,7
ADD r1,r1,r13
ST r1,r0,#W_LOOPN
RET
loop_leave:
LD r1,r0,#W_LOOPN
SUB r1,r1,r13
ST r1,r0,#W_LOOPN
RET
; loop_get: r1=field -> r1=value
loop_get:
LD r2,r0,#W_LOOPN
SUB r2,r2,r13
SHL r2,r2,3
LA r3,#W_LOOPS
ADD r2,r2,r3
ADD r2,r2,r1
LD r1,r2,0
RET
; loop_set: r1=field r2=value
loop_set:
LD r3,r0,#W_LOOPN
SUB r3,r3,r13
SHL r3,r3,3
LA r4,#W_LOOPS
ADD r3,r3,r4
ADD r3,r3,r1
ST r2,r3,0
RET
; loop_set_here: r1=field, value = current IR position
loop_set_here:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TMP2
CALL @ir_here
ADD r2,r1,r0
LD r1,r0,#W_TMP2
CALL @loop_set
SUB r14,r14,r13
LD r15,r14,0
RET

p_expect_k:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#L_TMP0
CALL @p_at_k
CMP r1,r0
JMP[NE] @pek2_ok
LD r1,r0,#L_TMP0
CALL @p_err
pek2_ok:
CALL @p_adv
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- return ------------------------------------------------------
p_return:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_SEMI
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pret_val
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
JMP @pret_go
pret_val:
CALL @p_expr
CALL @p_emit_rv
pret_go:
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
LA r1,#I_RET
CALL @ir_op
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== TOP LEVEL
p_func:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#SK_FUNC
CALL @sym_get_cur
ST r1,r0,#W_FUNCSYM
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
ST r0,r0,#W_NPAR
ST r0,r0,#W_NLOC
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pfu_params_done
MOVI r1,#KW_VOID
CALL @p_at_k
CMP r1,r0
JMP[EQ] @pfu_params
CALL @p_adv
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pfu_params_done
pfu_params:
CALL @p_skip_types
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pfu_pid
MOVI r1,23
CALL @p_err
pfu_pid:
MOVI r1,#SK_LOCAL
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @sym_entry
LD r2,r0,#W_NLOC
ST r2,r1,#SY_AUX
LD r3,r0,#W_FUNCSYM
ST r3,r1,#SY_NP
LD r2,r0,#W_NLOC
ADD r2,r2,r13
ST r2,r0,#W_NLOC
LD r2,r0,#W_NPAR
ADD r2,r2,r13
ST r2,r0,#W_NPAR
SUB r14,r14,r13
CALL @p_adv
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pfu_params
pfu_params_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,#P_SEMI
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pfu_body
LD r1,r0,#W_FUNCSYM
CALL @sym_entry
LD r2,r0,#W_NPAR
ST r2,r1,#SY_NP
JMP @pfu_d
pfu_body:
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r0,#W_FSKIP
CALL @ir_here
ST r1,r0,#W_FENTRY
LD r1,r0,#W_FUNCSYM
CALL @sym_entry
LD r2,r0,#W_FENTRY
ST r2,r1,#SY_ENTRY
CALL @p_block
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LA r1,#I_RET
CALL @ir_op
CALL @ir_here
ST r1,r0,#W_FENTRY
LD r1,r0,#W_FSKIP
LD r2,r0,#W_FENTRY
CALL @ir_patch
LD r1,r0,#W_FUNCSYM
CALL @sym_entry
LD r2,r0,#W_NPAR
ST r2,r1,#SY_NP
LD r2,r0,#W_NLOC
ST r2,r1,#SY_NL
pfu_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_global_one: current token is a global variable name
p_global_one:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#SK_GLOBAL
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pgo_scalar
CALL @p_adv
CALL @p_cexpr
CMP r1,r0
JMP[GT] @pgo_count_ok
MOVI r1,31
CALL @p_err
pgo_count_ok:
ST r1,r14,0
ADD r14,r14,r13
MOVI r1,#P_RBRACK
MOVI r2,33
CALL @p_expect_p
JMP @pgo_count_done
pgo_scalar:
ST r0,r14,0
ADD r14,r14,r13
pgo_count_done:
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_NP
CMP r2,r0
JMP[NE] @pgo_allocd
LD r2,r0,#W_GLOBUSED
ADDI r3,r14,-1
LD r4,r3,0
CMP r4,r0
JMP[NE] @pgo_sz_arr
MOVI r4,1
pgo_sz_arr:
ADD r5,r2,r4
LA r3,#NCC_GLOBMAX
CMP r5,r3
JMP[LT] @pgo_room
MOVI r1,28
CALL @p_err
pgo_room:
ST r2,r1,#SY_AUX
MOVI r3,1
ST r3,r1,#SY_NP
ADDI r3,r14,-1
LD r3,r3,0
ST r3,r1,#SY_NL
ADD r2,r2,r4
ST r2,r0,#W_GLOBUSED
pgo_allocd:
LD r2,r1,#SY_AUX
ST r2,r14,0
ADD r14,r14,r13
; zero an array first
ADDI r3,r14,-2
LD r4,r3,0
CMP r4,r0
JMP[EQ] @pgo_init
MOVI r5,0xFFFF
CMP r4,r5
JMP[LT] @pgo_zok
MOVI r1,36
CALL @p_err
pgo_zok:
MOVI r5,0xFFFF
CMP r4,r5
JMP[LT] @pgo_zok1
MOVI r1,36
CALL @p_err
pgo_zok1:
ADDI r3,r14,-1
LD r3,r3,0
CMP r3,r5
JMP[LT] @pgo_zok2
MOVI r1,36
CALL @p_err
pgo_zok2:
SHL r4,r4,16
BOOL.14 r3,r3,r4
LA r1,#I_GZERO
CALL @ir_emit
pgo_init:
MOVI r1,#P_ASSIGN
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pgo_noinit
ADDI r3,r14,-2
LD r3,r3,0
CMP r3,r0
JMP[EQ] @pgo_scalar_init
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pgo_array_scalar
CALL @p_adv
MOVI r1,0
ST r1,r14,0
ADD r14,r14,r13
pgo_ai_l:
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pgo_ai_done
ADDI r3,r14,-1
LD r4,r3,0
ADDI r3,r14,-3
LD r5,r3,0
CMP r4,r5
JMP[GE] @pgo_ai_skip
ADDI r3,r14,-2
LD r2,r3,0
ADD r2,r2,r4
LA r1,#I_GADDR
CALL @ir_emit
CALL @p_assign
CALL @p_emit_rv
LA r1,#I_STORE_IND
MOVI r2,0
CALL @ir_emit
JMP @pgo_ai_step
pgo_ai_skip:
CALL @p_assign
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
pgo_ai_step:
ADDI r3,r14,-1
LD r4,r3,0
ADD r4,r4,r13
ST r4,r3,0
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pgo_ai_l
pgo_ai_done:
MOVI r1,#P_RBRACE
MOVI r2,35
CALL @p_expect_p
ADDI r14,r14,-1
JMP @pgo_afterinit
pgo_array_scalar:
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
MOVI r1,1
CALL @emit_store_lv
JMP @pgo_afterinit
pgo_scalar_init:
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
MOVI r1,1
CALL @emit_store_lv
JMP @pgo_afterinit
pgo_noinit:
ADDI r3,r14,-2
LD r3,r3,0
CMP r3,r0
JMP[NE] @pgo_afterinit
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
ADDI r3,r14,-1
LD r2,r3,0
MOVI r1,1
CALL @emit_store_lv
pgo_afterinit:
ADDI r14,r14,-3
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pgo_more
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
JMP @pgo_d
pgo_more:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pgo_more_ok
MOVI r1,23
CALL @p_err
pgo_more_ok:
CALL @p_global_one
JMP @pgo_d
pgo_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_tu
p_tu:
ST r15,r14,0
ADD r14,r14,r13
ptu_l:
LD r1,r0,#W_TKA
MOVI r2,#K_EOF
CMP r1,r2
JMP[EQ] @ptu_d
MOVI r2,#P_SEMI
CMP r1,r2
JMP[NE] @ptu_try
CALL @p_adv
JMP @ptu_l
ptu_try:
CALL @p_is_type
CMP r1,r0
JMP[NE] @ptu_decl
MOVI r1,30
CALL @p_err
ptu_decl:
CALL @p_skip_types
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @ptu_name
MOVI r1,23
CALL @p_err
ptu_name:
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @ptu_global
LD r1,r0,#W_TKB+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @ptu_func
ptu_global:
CALL @p_global_one
JMP @ptu_l
ptu_func:
CALL @p_func
JMP @ptu_l
ptu_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== INTERPRETER
ni_push:
LD r2,r0,#R_SP
LA r3,#NCC_ESEND
CMP r2,r3
JMP[LT] @np_ok
MOVI r1,43
JMP @ncc_err
np_ok:
ST r1,r2,0
ADD r2,r2,r13
ST r2,r0,#R_SP
RET
ni_pop:
LD r2,r0,#R_SP
SUB r2,r2,r13
ST r2,r0,#R_SP
LD r1,r2,0
RET

ni_shl:
MOVI r3,31
BOOL.8 r2,r2,r3
nsh_l:
CMP r2,r0
JMP[EQ] @nsh_d
SHL r1,r1,1
SUB r2,r2,r13
JMP @nsh_l
nsh_d:
RET
ni_sar:
MOVI r3,31
BOOL.8 r2,r2,r3
nsa_l:
CMP r2,r0
JMP[EQ] @nsa_d
SAR r1,r1,1
SUB r2,r2,r13
JMP @nsa_l
nsa_d:
RET

ni_puts:
ST r15,r14,0
ADD r14,r14,r13
ni_puts_l:
LD r2,r1,0
CMP r2,r0
JMP[EQ] @ni_puts_d
MOVI r3,255
BOOL.8 r2,r2,r3
ST r1,r14,0
ADD r14,r14,r13
ADD r1,r2,r0
CALL @ncc_putc
SUB r14,r14,r13
LD r1,r14,0
ADD r1,r1,r13
JMP @ni_puts_l
ni_puts_d:
SUB r14,r14,r13
LD r15,r14,0
RET

ni_builtin:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
CALL @ni_pop
ST r1,r0,#R_T1
LD r2,r0,#R_T0
MOVI r3,#B_PUTCHAR
CMP r2,r3
JMP[EQ] @nbi_putc
MOVI r3,#B_PRINTINT
CMP r2,r3
JMP[EQ] @nbi_pint
MOVI r3,#B_PUTS
CMP r2,r3
JMP[EQ] @nbi_puts
MOVI r3,#B_HEX
CMP r2,r3
JMP[EQ] @nbi_hex
MOVI r3,#B_PUTSTR
CMP r2,r3
JMP[EQ] @nbi_pstr
JMP @nbi_zero
nbi_putc:
LD r1,r0,#R_T1
MOVI r2,255
BOOL.8 r1,r1,r2
CALL @ncc_putc
LD r1,r0,#R_T1
CALL @ni_push
JMP @nbi_d
nbi_pint:
LD r5,r0,#R_T1
CALL @putdec
JMP @nbi_zero
nbi_puts:
LD r1,r0,#R_T1
CALL @ni_puts
MOVI r1,10
CALL @ncc_putc
JMP @nbi_zero
nbi_hex:
LD r5,r0,#R_T1
CALL @puthex8
JMP @nbi_zero
nbi_pstr:
LD r1,r0,#R_T1
CALL @ni_puts
JMP @nbi_zero
nbi_zero:
MOVI r1,0
CALL @ni_push
nbi_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_call: operand in R_T0 (symid | argc<<16)
ni_call:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#R_T0
MOVI r3,0xFFFF
BOOL.8 r1,r2,r3
SHR r2,r2,16
ST r2,r0,#R_T1
CALL @sym_entry
LD r3,r1,#SY_KIND
MOVI r4,#SK_BUILTIN
CMP r3,r4
JMP[NE] @ncl_func
LD r5,r1,#SY_NP
LD r6,r0,#R_T1
CMP r5,r6
JMP[EQ] @ncl_bok
MOVI r1,40
CALL @ncc_err
ncl_bok:
LD r1,r1,#SY_AUX
LD r2,r0,#R_T1
CALL @ni_builtin
JMP @ncl_d
ncl_func:
MOVI r4,#SK_FUNC
CMP r3,r4
JMP[NE] @ncl_bad
LD r4,r1,#SY_ENTRY
CMP r4,r0
JMP[NE] @ncl_def
MOVI r1,41
CALL @ncc_err
ncl_def:
LD r5,r1,#SY_NP
LD r6,r0,#R_T1
CMP r5,r6
JMP[EQ] @ncl_argc_ok
MOVI r1,40
CALL @ncc_err
ncl_argc_ok:
LD r5,r1,#SY_NL
LD r7,r0,#R_FP
LD r8,r7,3
ADDI r8,r8,4
ADD r8,r7,r8
LA r9,#NCC_FSEND
ADDI r10,r8,4
ADD r10,r10,r5
CMP r10,r9
JMP[LE] @ncl_room
MOVI r1,42
CALL @ncc_err
ncl_room:
ST r7,r8,0
LD r9,r0,#R_IP
ST r9,r8,1
LD r9,r0,#R_SP
LD r10,r0,#R_T1
SUB r9,r9,r10
ST r9,r8,2
ST r5,r8,3
MOVI r11,0
ncl_copy:
CMP r11,r10
JMP[GE] @ncl_copy_d
LD r12,r0,#R_SP
SUB r12,r12,r10
ADD r12,r12,r11
LD r12,r12,0
ADDI r9,r8,4
ADD r9,r9,r11
ST r12,r9,0
ADD r11,r11,r13
JMP @ncl_copy
ncl_copy_d:
LD r9,r0,#R_SP
SUB r9,r9,r10
ST r9,r0,#R_SP
ST r8,r0,#R_FP
ST r4,r0,#R_IP
JMP @ncl_d
ncl_bad:
MOVI r1,44
CALL @ncc_err
ncl_d:
SUB r14,r14,r13
LD r15,r14,0
RET

ni_ret:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#R_FP
LD r3,r2,2
LD r4,r0,#R_SP
CMP r4,r3
JMP[LE] @nrt_none
SUB r4,r4,r13
LD r5,r4,0
JMP @nrt_have
nrt_none:
MOVI r5,0
nrt_have:
ST r3,r0,#R_SP
ADD r1,r5,r0
CALL @ni_push
LD r2,r0,#R_FP
LD r1,r2,1
ST r1,r0,#R_IP
LD r1,r2,0
ST r1,r0,#R_FP
SUB r14,r14,r13
LD r15,r14,0
RET

ni_loop:
ST r15,r14,0
ADD r14,r14,r13
nil_again:
LD r2,r0,#R_IP
LD r1,r2,0
LD r3,r2,1
ADDI r2,r2,2
ST r2,r0,#R_IP
ST r3,r0,#R_T0
CMP r1,r0
JMP[EQ] @nil_halt
MOVI r2,#I_PUSH
CMP r1,r2
JMP[EQ] @nil_push
MOVI r2,#I_POP
CMP r1,r2
JMP[EQ] @nil_pop
MOVI r2,#I_DUP
CMP r1,r2
JMP[EQ] @nil_dup
MOVI r2,#I_SWAP
CMP r1,r2
JMP[EQ] @nil_swap
MOVI r2,#I_LG
CMP r1,r2
JMP[EQ] @nil_lg
MOVI r2,#I_SG
CMP r1,r2
JMP[EQ] @nil_sg
MOVI r2,#I_LL
CMP r1,r2
JMP[EQ] @nil_ll
MOVI r2,#I_SL
CMP r1,r2
JMP[EQ] @nil_sl
MOVI r2,#I_ADD
CMP r1,r2
JMP[EQ] @nil_add
MOVI r2,#I_SUB
CMP r1,r2
JMP[EQ] @nil_sub
MOVI r2,#I_MUL
CMP r1,r2
JMP[EQ] @nil_mul
MOVI r2,#I_DIV
CMP r1,r2
JMP[EQ] @nil_div
MOVI r2,#I_MOD
CMP r1,r2
JMP[EQ] @nil_mod
MOVI r2,#I_NEG
CMP r1,r2
JMP[EQ] @nil_neg
MOVI r2,#I_AND
CMP r1,r2
JMP[EQ] @nil_and
MOVI r2,#I_OR
CMP r1,r2
JMP[EQ] @nil_or
MOVI r2,#I_XOR
CMP r1,r2
JMP[EQ] @nil_xor
MOVI r2,#I_NOT
CMP r1,r2
JMP[EQ] @nil_not
MOVI r2,#I_SHL
CMP r1,r2
JMP[EQ] @nil_shl
MOVI r2,#I_SHR
CMP r1,r2
JMP[EQ] @nil_shr
MOVI r2,#I_EQ
CMP r1,r2
JMP[EQ] @nil_eq
MOVI r2,#I_NE
CMP r1,r2
JMP[EQ] @nil_ne
MOVI r2,#I_LT
CMP r1,r2
JMP[EQ] @nil_lt
MOVI r2,#I_GT
CMP r1,r2
JMP[EQ] @nil_gt
MOVI r2,#I_LE
CMP r1,r2
JMP[EQ] @nil_le
MOVI r2,#I_GE
CMP r1,r2
JMP[EQ] @nil_ge
MOVI r2,#I_LNOT
CMP r1,r2
JMP[EQ] @nil_lnot
MOVI r2,#I_JMP
CMP r1,r2
JMP[EQ] @nil_jmp
MOVI r2,#I_JZ
CMP r1,r2
JMP[EQ] @nil_jz
MOVI r2,#I_JNZ
CMP r1,r2
JMP[EQ] @nil_jnz
MOVI r2,#I_CALL
CMP r1,r2
JMP[EQ] @nil_call
MOVI r2,#I_RET
CMP r1,r2
JMP[EQ] @nil_ret
MOVI r2,#I_SGK
CMP r1,r2
JMP[EQ] @nil_sgk
MOVI r2,#I_SLK
CMP r1,r2
JMP[EQ] @nil_slk
MOVI r2,#I_GADDR
CMP r1,r2
JMP[EQ] @nil_gaddr
MOVI r2,#I_LADDR
CMP r1,r2
JMP[EQ] @nil_laddr
MOVI r2,#I_LOAD_IND
CMP r1,r2
JMP[EQ] @nil_ldind
MOVI r2,#I_STORE_IND
CMP r1,r2
JMP[EQ] @nil_stind
MOVI r2,#I_LZERO
CMP r1,r2
JMP[EQ] @nil_lzero
MOVI r2,#I_GZERO
CMP r1,r2
JMP[EQ] @nil_gzero
MOVI r2,#I_STORE_IND_KEEP
CMP r1,r2
JMP[EQ] @nil_stindk
JMP @nil_bad

nil_halt:
SUB r14,r14,r13
LD r15,r14,0
RET
nil_push:
LD r1,r0,#R_T0
CALL @ni_push
JMP @nil_again
nil_pop:
CALL @ni_pop
JMP @nil_again
nil_dup:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_push
LD r1,r0,#R_T1
CALL @ni_push
JMP @nil_again
nil_swap:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
ST r1,r0,#R_T2
LD r1,r0,#R_T1
CALL @ni_push
LD r1,r0,#R_T2
CALL @ni_push
JMP @nil_again
nil_lg:
LA r2,#NCC_GLOB
LD r1,r0,#R_T0
ADD r2,r2,r1
LD r1,r2,0
CALL @ni_push
JMP @nil_again
nil_sg:
CALL @ni_pop
LA r2,#NCC_GLOB
LD r3,r0,#R_T0
ADD r2,r2,r3
ST r1,r2,0
JMP @nil_again
nil_ll:
LD r2,r0,#R_FP
ADDI r2,r2,4
LD r1,r0,#R_T0
ADD r2,r2,r1
LD r1,r2,0
CALL @ni_push
JMP @nil_again
nil_sl:
CALL @ni_pop
LD r2,r0,#R_FP
ADDI r2,r2,4
LD r3,r0,#R_T0
ADD r2,r2,r3
ST r1,r2,0
JMP @nil_again
nil_sgk:
LA r2,#NCC_GLOB
LD r1,r0,#R_T0
ADD r2,r2,r1
LD r1,r0,#R_SP
SUB r1,r1,r13
LD r1,r1,0
ST r1,r2,0
JMP @nil_again
nil_slk:
LD r2,r0,#R_FP
ADDI r2,r2,4
LD r1,r0,#R_T0
ADD r2,r2,r1
LD r1,r0,#R_SP
SUB r1,r1,r13
LD r1,r1,0
ST r1,r2,0
JMP @nil_again
nil_add:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
ADD r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_sub:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
SUB r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_mul:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
MUL r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_div:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
DIV r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_mod:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
MOD r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_neg:
CALL @ni_pop
SUB r1,r0,r1
CALL @ni_push
JMP @nil_again
nil_and:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
BOOL.8 r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_or:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
BOOL.14 r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_xor:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
BOOL.6 r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_not:
CALL @ni_pop
MOVI r2,0
BOOL.3 r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_shl:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CALL @ni_shl
CALL @ni_push
JMP @nil_again
nil_shr:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CALL @ni_sar
CALL @ni_push
JMP @nil_again
nil_eq:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMP r1,r2
MOVI r3,0
MOVI[EQ] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_ne:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMP r1,r2
MOVI r3,0
MOVI[NE] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_lt:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMPS r1,r2
MOVI r3,0
MOVI[LT] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_gt:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMPS r1,r2
MOVI r3,0
MOVI[GT] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_le:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMPS r1,r2
MOVI r3,0
MOVI[LE] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_ge:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMPS r1,r2
MOVI r3,0
MOVI[GE] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_lnot:
CALL @ni_pop
CMP r1,r0
MOVI r2,0
MOVI[EQ] r2,1
ADD r1,r2,r0
CALL @ni_push
JMP @nil_again
nil_jmp:
LD r1,r0,#R_T0
ST r1,r0,#R_IP
JMP @nil_again
nil_jz:
CALL @ni_pop
CMP r1,r0
JMP[NE] @nil_again
LD r1,r0,#R_T0
ST r1,r0,#R_IP
JMP @nil_again
nil_jnz:
CALL @ni_pop
CMP r1,r0
JMP[EQ] @nil_again
LD r1,r0,#R_T0
ST r1,r0,#R_IP
JMP @nil_again
nil_call:
CALL @ni_call
JMP @nil_again
nil_ret:
CALL @ni_ret
JMP @nil_again
nil_gaddr:
LA r2,#NCC_GLOB
LD r1,r0,#R_T0
ADD r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_laddr:
LD r1,r0,#R_FP
ADDI r1,r1,4
LD r2,r0,#R_T0
ADD r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_ldind:
CALL @ni_pop
LD r2,r1,0
ADD r1,r2,r0
CALL @ni_push
JMP @nil_again
nil_stind:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
ST r2,r1,0
JMP @nil_again
nil_stindk:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
ST r2,r1,0
ADD r1,r2,r0
CALL @ni_push
JMP @nil_again
nil_lzero:
LD r2,r0,#R_FP
ADDI r2,r2,4
LD r1,r0,#R_T0
MOVI r3,0xFFFF
BOOL.8 r4,r1,r3
ADD r2,r2,r4
SHR r1,r1,16
lz_l:
CMP r1,r0
JMP[EQ] @nil_again
ST r0,r2,0
ADD r2,r2,r13
SUB r1,r1,r13
JMP @lz_l
nil_gzero:
LA r2,#NCC_GLOB
LD r1,r0,#R_T0
MOVI r3,0xFFFF
BOOL.8 r4,r1,r3
ADD r2,r2,r4
SHR r1,r1,16
gz_l:
CMP r1,r0
JMP[EQ] @nil_again
ST r0,r2,0
ADD r2,r2,r13
SUB r1,r1,r13
JMP @gz_l
nil_bad:
MOVI r1,46
JMP @ncc_err
