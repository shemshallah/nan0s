
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
.equ NCC_STRB   1650000      ; scratch / preprocessor text
.equ NCC_STRMAX 50000
.equ NCC_SYMB   1750000      ; 4096 entries x 16 words
.equ NCC_SYMMAX 65536
.equ NCC_SYMENTRIES 4096
.equ NCC_TYPEB  1820000      ; 4096 type entries x 8 words
.equ NCC_TYPEMAX 32768
.equ NCC_PARM   1860000      ; function parameter descriptor tables
.equ NCC_PARMMAX 32768
.equ NCC_MEMB   1900000      ; struct/union member tables
.equ NCC_MEMBMAX 32768
.equ NCC_CASEB  1940000      ; switch case table: 2048 x (value,target)
.equ NCC_CASEMAX 4096
.equ NCC_GOTOB  1950000      ; pending goto patches: 2048 x (label-sym,jmp-index)
.equ NCC_GOTOMAX 4096
.equ NCC_ESB    2000000      ; expression stack (words)
.equ NCC_ESMAX  200000
.equ NCC_ESEND  2200000
.equ NCC_PS     2900000      ; compiler/interpreter call stack (words)
; C program memory is byte-addressed: 4 payload bytes per NaN word.
.equ C_RODATA   12000000     ; string literals and const data
.equ C_ROEND    12500000
.equ C_GLOB     12500000     ; globals and static locals
.equ C_GLOBEND  13000000
.equ C_HEAP     13000000     ; malloc arena
.equ C_HEAP_END 15000000
.equ C_STACK    15000000     ; C call stack (bytes, grows up)
.equ C_STACK_END 16000000

; ------------------------------------------------------------------ token kinds
.equ K_EOF      1
.equ K_INT      2
.equ K_IDENT    3
.equ K_STRING   4
.equ K_CHAR     5
.equ K_PUNCT    6
.equ K_ERR      7
.equ K_KEYWORD  8
.equ K_FLOAT    9

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
.equ P_DOT      46

; IR opcodes (2 words: opcode, operand)
.equ I_HALT     0
.equ I_PUSH     1
.equ I_POP      2
.equ I_DUP      3
.equ I_SWAP     4
.equ I_GADDR    5
.equ I_LADDR    7
.equ I_LOAD     8
.equ I_STORE    9
.equ I_STORE_K  6
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
.equ I_LZERO    41
.equ I_GZERO    42
.equ I_DIVU     44
.equ I_MODU     45
.equ I_SHRU     46
.equ I_LTU      47
.equ I_GTU      48
.equ I_LEU      49
.equ I_GEU      50
.equ I_CAST     51
.equ I_MEMCPY   52
.equ I_MEMSET   53
.equ I_EXIT     54
.equ I_FADD     55
.equ I_FSUB     56
.equ I_FMUL     57
.equ I_FDIV     58
.equ I_FNEG     59
.equ I_FLT      60
.equ I_FGT      61
.equ I_FLE      62
.equ I_FGE      63
.equ I_FEQ      64
.equ I_FNE      65

; symbol entry: 16 words
.equ SY_HASH    0
.equ SY_KIND    1
.equ SY_AUX     2
.equ SY_NP      3
.equ SY_NL      4
.equ SY_ENTRY   5
.equ SY_NAME    6
.equ SY_LEN     7
.equ SY_TYPE    8
.equ SY_ARG     9
.equ SY_OFF     10
.equ SY_SIZE    11
.equ SY_CLS     12
.equ SY_USED    13
.equ SY_SCOPE   14
.equ SYSZ       16

.equ SK_GLOBAL  1
.equ SK_LOCAL   2
.equ SK_FUNC    3
.equ SK_BUILTIN 4
.equ SK_ENUM    5
.equ SK_LABEL   6
.equ SK_TYPE    7
.equ SK_MEMBER  8

; ------------------------------------------------------------------ type kinds
.equ TY_VOID    0
.equ TY_INT     1
.equ TY_FLOAT   2
.equ TY_PTR     3
.equ TY_ARRAY   4
.equ TY_STRUCT  5
.equ TY_UNION   6
.equ TY_FUNC    7
.equ TY_ENUM    8

; type entry fields (8 words)
.equ TY_KIND    0
.equ TY_SIZE    1
.equ TY_ALIGN   2
.equ TY_BASE    3
.equ TY_COUNT   4
.equ TY_MEM     5
.equ TY_NMEM    6
.equ TY_SIGN    7
.equ TYSZ       8

; built-in type ids
.equ T_VOID     1
.equ T_CHAR     2
.equ T_UCHAR    3
.equ T_SHORT    4
.equ T_USHORT   5
.equ T_INT      6
.equ T_UINT     7
.equ T_LONG     8
.equ T_ULONG    9
.equ T_FLOAT    10
.equ T_DOUBLE   11

; load/store size codes
.equ SZ_8S      0
.equ SZ_8U      1
.equ SZ_16S     2
.equ SZ_16U     3
.equ SZ_32      4

; binary operator kinds
.equ BIN_ADD    1
.equ BIN_SUB    2
.equ BIN_MUL    3
.equ BIN_DIV    4
.equ BIN_MOD    5
.equ BIN_SHL    6
.equ BIN_SHR    7
.equ BIN_AND    8
.equ BIN_OR     9
.equ BIN_XOR    10
.equ BIN_LT     11
.equ BIN_GT     12
.equ BIN_LE     13
.equ BIN_GE     14
.equ BIN_EQ     15
.equ BIN_NE     16

; builtin ids
.equ B_PUTCHAR  1
.equ B_PRINTINT 2
.equ B_PUTS     3
.equ B_HEX      4
.equ B_PUTSTR   5
.equ B_PRINTF   6
.equ B_MALLOC   7
.equ B_FREE     8
.equ B_CALLOC   9
.equ B_REALLOC  10
.equ B_STRLEN   11
.equ B_STRCMP   12
.equ B_STRNCPY  13
.equ B_STRCPY   14
.equ B_STRCAT   15
.equ B_MEMCMP   16
.equ B_MEMCPY   17
.equ B_MEMSET   18
.equ B_ATOI     19
.equ B_ABS      20
.equ B_EXIT     21
.equ B_STRNCMP  22
.equ B_SIN     23
.equ B_COS     24

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
.equ W_ETYPE    60015
.equ W_LTYPE    60016
.equ W_SCLASS   60017
.equ W_TYPEN    60018
.equ W_GLOBP    60019
.equ W_LOCALB   60020
.equ W_FRAMEB   60021
.equ W_FUNCRET  60022
.equ W_PARAMP   60023
.equ W_MEMBP    60024
.equ W_STRUCTID 60025
.equ W_FUNCNP   60026
.equ W_FUNCARG  60027
.equ W_SW_N     60028
.equ W_SW_TAB   60032      ; 16 entries x 2 words (value, jmp-index)
.equ W_CASE_N   60029
.equ W_GOTO_N   60030
.equ W_DECLNAME 60040      ; saved declarator token: hash, len, text[8]
.equ W_TY_TMP   60052
.equ W_PP_N     60053
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
.equ W_TY_KIND  60920
.equ W_TY_SIZE  60921
.equ W_TY_ALIGN 60922
.equ W_TY_BASE  60923
.equ W_TY_COUNT 60924
.equ W_TY_MEM   60925
.equ W_TY_NMEM  60926
.equ W_TY_SIGN  60927
.equ W_TY_RET   60928
.equ W_TY_ID    60929
.equ W_TSIGN    60930
.equ W_TSHORT   60931
.equ W_TLONG    60932
.equ W_TCHAR    60933
.equ W_TVOID    60934
.equ W_TFLOAT   60935
.equ W_TAGSYM   60936
.equ W_ARRDIM   60937      ; 8 dimensions
.equ W_ARRND    60945
.equ W_SW_PATCH  60946
.equ W_GOTO_PATCH 60947
.equ W_GOTO_NAME 60948
.equ W_PP_ACTIVE 60949
.equ W_ENUMVAL  60950
.equ W_SSIZE    60960
.equ W_SALIGN   60961
.equ W_SMEM     60962
.equ W_SNMEM    60963
.equ W_STAG     60964
.equ W_SOFF     60965
.equ W_STYPE    60966
.equ W_STMP     60967
.equ W_STRUCTKIND    60968
.equ W_MSIZE    60969
.equ W_TSEEN    60970
.equ W_BRET     60981
.equ W_HEAP     60982
.equ W_TAILHALT 60983
.equ W_PTRV     60984
.equ W_PTRC     60985
.equ W_PF_FMT   60986
.equ W_PF_IDX   60987
.equ W_PF_ARGC  60988
.equ W_PF_CASE  60991
.equ W_PF_W     60992
.equ W_PF_FLAGS 60993
.equ W_PF_VAL   60994
.equ W_PF_LEN   60995
.equ W_PF_PAD   60996
.equ W_PF_NEG   60997
.equ W_PF_TMP   60998
.equ W_TKPTR    60990
.equ W_CASEBASE 60971
.equ W_DEFSET   60972
.equ W_DEFTGT   60973
.equ W_SWDISP   60974
.equ W_SWFALL   60975
.equ W_SWTMP    60976
.equ W_SWNO     60977
.equ W_SWEND    60978
.equ W_SWI      60979
.equ W_TMP3     60980
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

; ================================================================== PREPROCESSOR
; Minimal C89 line preprocessor: object-like #define/#undef, #ifdef/#ifndef,
; #if 0|1|defined(X), #else/#elif, #endif; #include and #pragma are skipped.
; Output is 4 bytes/word at byte address QPOUT; returns its word address.
.equ QPOUTB    7840000
.equ QPOUTMAX  100000
.equ QPNAMEB   7940000
.equ QPNAMEMAX 16000
.equ QPLINEB   7956000
.equ QPLINEMAX 512
.equ QPIDB     7956512
.equ QPMACW    1990000
.equ QPMACMAX  128
.equ QPCONDW   1991100
.equ WQ_WP     61200
.equ WQ_BI     61201
.equ WQ_OUT    61202
.equ WQ_ACT    61203
.equ WQ_DEPTH  61204
.equ WQ_NAMEP  61205
.equ WQ_MACN   61206
.equ WQ_HASH   61207
.equ WQ_ILEN   61208
.equ WQ_LEN    61209
.equ WQ_T0     61210
.equ WQ_T1     61211
.equ WQ_T2     61212
.equ WQ_T3     61213
.equ WQ_Q      61214
.equ WQ_ESC    61215
.equ WQ_CMT    61216
.equ WQ_P0     61217

qpp_getc:
LD r2,r0,#WQ_WP
LD r1,r2,0
LD r3,r0,#WQ_BI
qgc_l:
CMP r3,r0
JMP[EQ] @qgc_d
SHR r1,r1,8
SUB r3,r3,r13
JMP @qgc_l
qgc_d:
MOVI r2,255
BOOL.8 r1,r1,r2
LD r2,r0,#WQ_BI
ADD r2,r2,r13
MOVI r3,4
CMP r2,r3
JMP[LT] @qgc_s
MOVI r2,0
LD r3,r0,#WQ_WP
ADD r3,r3,r13
ST r3,r0,#WQ_WP
qgc_s:
ST r2,r0,#WQ_BI
RET

qpp_peek:
LD r2,r0,#WQ_WP
LD r1,r2,0
LD r3,r0,#WQ_BI
qpk_l:
CMP r3,r0
JMP[EQ] @qpk_d
SHR r1,r1,8
SUB r3,r3,r13
JMP @qpk_l
qpk_d:
MOVI r2,255
BOOL.8 r1,r1,r2
RET

qpp_putc:
LD r2,r0,#WQ_OUT
LA r3,#QPOUTMAX
CMP r2,r3
JMP[LT] @qpw_room
MOVI r1,80
JMP @ncc_err
qpw_room:
LA r3,#QPOUTB
ADD r3,r3,r2
STB r1,r3,0
ADD r2,r2,r13
ST r2,r0,#WQ_OUT
RET

qpp_readline:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#WQ_LEN
qrl_l:
CALL @qpp_getc
CMP r1,r0
JMP[EQ] @qrl_d
MOVI r4,10
CMP r1,r4
JMP[EQ] @qrl_d
MOVI r4,13
CMP r1,r4
JMP[EQ] @qrl_l
LD r3,r0,#WQ_LEN
MOVI r4,510
CMP r3,r4
JMP[GE] @qrl_l
LA r4,#QPLINEB
ADD r4,r4,r3
STB r1,r4,0
ADD r3,r3,r13
ST r3,r0,#WQ_LEN
JMP @qrl_l
qrl_d:
LD r3,r0,#WQ_LEN
CMP r3,r0
JMP[NE] @qrl_have
; no bytes before the terminator: EOF unless it was an empty line
CMP r1,r0
JMP[EQ] @qrl_eof
qrl_have:
LA r4,#QPLINEB
ADD r4,r4,r3
STB r0,r4,0
ADDI r1,r3,1
SUB r14,r14,r13
LD r15,r14,0
RET
qrl_eof:
MOVI r1,0
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_streq: r1,r2 byte ptr -> 1/0
qpp_streq:
qsq_l:
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @qsq_n
CMP r3,r0
JMP[EQ] @qsq_y
ADD r1,r1,r13
ADD r2,r2,r13
JMP @qsq_l
qsq_y:
MOVI r1,1
RET
qsq_n:
MOVI r1,0
RET

; qpp_isid0: r3=char -> r1
qpp_isid0:
MOVI r4,95
CMP r3,r4
JMP[EQ] @qi0_y
MOVI r4,65
CMP r3,r4
JMP[LT] @qi0_l
MOVI r4,91
CMP r3,r4
JMP[LT] @qi0_y
qi0_l:
MOVI r4,97
CMP r3,r4
JMP[LT] @qi0_n
MOVI r4,123
CMP r3,r4
JMP[LT] @qi0_y
qi0_n:
MOVI r1,0
RET
qi0_y:
MOVI r1,1
RET

; qpp_isidc: r3=char -> r1
qpp_isidc:
ST r3,r0,#WQ_T3
CALL @qpp_isid0
CMP r1,r0
JMP[NE] @qic_y
LD r3,r0,#WQ_T3
MOVI r4,48
CMP r3,r4
JMP[LT] @qic_n
MOVI r4,58
CMP r3,r4
JMP[LT] @qic_y
qic_n:
MOVI r1,0
RET
qic_y:
MOVI r1,1
RET

; qpp_scanid: r2=byte ptr -> r1=len (0 none), r2 advanced, QPID/hash filled
qpp_scanid:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#WQ_T0
ST r0,r0,#WQ_ILEN
ST r0,r0,#WQ_HASH
qsid_l:
LD r2,r0,#WQ_T0
LDB r3,r2,0
LD r4,r0,#WQ_ILEN
CMP r4,r0
JMP[NE] @qsid_c
CALL @qpp_isid0
JMP @qsid_t
qsid_c:
CALL @qpp_isidc
qsid_t:
CMP r1,r0
JMP[EQ] @qsid_d
LD r4,r0,#WQ_ILEN
MOVI r5,250
CMP r4,r5
JMP[GE] @qsid_d
LA r5,#QPIDB
ADD r5,r5,r4
STB r3,r5,0
; FNV-1a
LD r6,r0,#WQ_HASH
CMP r6,r0
JMP[NE] @qsid_hashed
LA r6,0x811C9DC5
qsid_hashed:
LA r7,0x01000193
BOOL.6 r8,r6,r3
MUL r8,r8,r7
ADD r6,r8,r0
ST r6,r0,#WQ_HASH
ADD r4,r4,r13
ST r4,r0,#WQ_ILEN
LD r2,r0,#WQ_T0
ADD r2,r2,r13
ST r2,r0,#WQ_T0
JMP @qsid_l
qsid_d:
LD r4,r0,#WQ_ILEN
LA r5,#QPIDB
ADD r5,r5,r4
STB r0,r5,0
LD r2,r0,#WQ_T0
LD r1,r0,#WQ_ILEN
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_name_store: QPID -> name pool; r1=offset
qpp_name_store:
LD r2,r0,#WQ_NAMEP
ST r2,r0,#WQ_T0
LA r3,#QPNAMEB
ADD r3,r3,r2
LA r4,#QPIDB
qns_l:
LDB r5,r4,0
STB r5,r3,0
CMP r5,r0
JMP[EQ] @qns_d
ADD r4,r4,r13
ADD r3,r3,r13
ADD r2,r2,r13
JMP @qns_l
qns_d:
ADD r2,r2,r13
LA r5,#QPNAMEMAX
CMP r2,r5
JMP[LT] @qns_ok
MOVI r1,84
CALL @ncc_err
qns_ok:
ST r2,r0,#WQ_NAMEP
LD r1,r0,#WQ_T0
RET

; qpp_rest_store: r2=src -> r1=(len<<16)|offset, stores into name pool
qpp_rest_store:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#WQ_T0
LD r3,r0,#WQ_NAMEP
ST r3,r0,#WQ_T1
LA r4,#QPNAMEB
ADD r4,r4,r3
MOVI r5,0
qrs_l:
LD r2,r0,#WQ_T0
LDB r6,r2,0
CMP r6,r0
JMP[EQ] @qrs_d
CMP r5,r0
JMP[NE] @qrs_ok
; skip leading spaces on the replacement
MOVI r7,32
CMP r6,r7
JMP[EQ] @qrs_next
MOVI r7,9
CMP r6,r7
JMP[EQ] @qrs_next
qrs_ok:
STB r6,r4,0
ADD r4,r4,r13
ADD r3,r3,r13
ADD r5,r5,r13
qrs_next:
LD r2,r0,#WQ_T0
ADD r2,r2,r13
ST r2,r0,#WQ_T0
JMP @qrs_l
qrs_d:
STB r0,r4,0
ADD r3,r3,r13
ST r3,r0,#WQ_NAMEP
LD r1,r0,#WQ_T1
SHL r5,r5,16
BOOL.14 r1,r1,r5
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_find: QPID/hash/len -> r1=entry or 0
qpp_find:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,0
qpf_l:
LD r3,r0,#WQ_MACN
CMP r2,r3
JMP[GE] @qpf_n
SHL r3,r2,3
LA r4,#QPMACW
ADD r4,r4,r3
LD r5,r4,5
CMP r5,r0
JMP[EQ] @qpf_next
LD r5,r4,0
LD r6,r0,#WQ_HASH
CMP r5,r6
JMP[NE] @qpf_next
LD r5,r4,1
LD r6,r0,#WQ_ILEN
CMP r5,r6
JMP[NE] @qpf_next
LA r5,#QPIDB
LD r6,r4,2
LA r7,#QPNAMEB
ADD r6,r6,r7
qpf_c:
LDB r7,r5,0
LDB r8,r6,0
CMP r7,r8
JMP[NE] @qpf_next
CMP r7,r0
JMP[EQ] @qpf_hit
ADD r5,r5,r13
ADD r6,r6,r13
JMP @qpf_c
qpf_hit:
ADD r1,r4,r0
JMP @qpf_d
qpf_next:
ADD r2,r2,r13
JMP @qpf_l
qpf_n:
MOVI r1,0
qpf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; conditional stack helpers
qpp_cond_push: ; r1=cond
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#WQ_DEPTH
MOVI r3,32
CMP r2,r3
JMP[LT] @qcp_room
MOVI r1,82
CALL @ncc_err
qcp_room:
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#QPCONDW
ADD r3,r3,r2
LD r4,r0,#WQ_ACT
ST r4,r3,0
ST r1,r3,1
ST r1,r3,2
BOOL.8 r4,r4,r1
ST r4,r0,#WQ_ACT
LD r2,r0,#WQ_DEPTH
ADD r2,r2,r13
ST r2,r0,#WQ_DEPTH
SUB r14,r14,r13
LD r15,r14,0
RET

qpp_cond_else:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#WQ_DEPTH
CMP r2,r0
JMP[EQ] @qce_d
SUB r2,r2,r13
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#QPCONDW
ADD r3,r3,r2
LD r4,r3,0
LD r5,r3,2
CMP r5,r0
JMP[NE] @qce_off
MOVI r6,1
BOOL.8 r4,r4,r6
ST r4,r0,#WQ_ACT
MOVI r4,1
ST r4,r3,2
JMP @qce_d
qce_off:
ST r0,r0,#WQ_ACT
qce_d:
SUB r14,r14,r13
LD r15,r14,0
RET

qpp_cond_pop:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#WQ_DEPTH
CMP r2,r0
JMP[EQ] @qpop_d
SUB r2,r2,r13
ST r2,r0,#WQ_DEPTH
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#QPCONDW
ADD r3,r3,r2
LD r1,r3,0
ST r1,r0,#WQ_ACT
qpop_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_cond_eval: r1=byte ptr to expression -> r1=0/1 (0/1/defined)
qpp_cond_eval:
ST r15,r14,0
ADD r14,r14,r13
qcev_ws:
LDB r3,r1,0
MOVI r4,32
CMP r3,r4
JMP[NE] @qcev_t
ADD r1,r1,r13
JMP @qcev_ws
qcev_t:
MOVI r4,49
CMP r3,r4
JMP[EQ] @qcev_one
MOVI r4,48
CMP r3,r4
JMP[EQ] @qcev_zero
MOVI r4,100
CMP r3,r4
JMP[NE] @qcev_zero
; defined(...)
ADD r1,r1,r13
ADD r1,r1,r13
ADD r1,r1,r13
ADD r1,r1,r13
ADD r1,r1,r13
ADD r1,r1,r13
ADD r1,r1,r13
qcev_dws:
LDB r3,r1,0
MOVI r4,32
CMP r3,r4
JMP[NE] @qcev_dp
ADD r1,r1,r13
JMP @qcev_dws
qcev_dp:
MOVI r4,40
CMP r3,r4
JMP[NE] @qcev_dn
ADD r1,r1,r13
qcev_dn:
ST r1,r0,#WQ_T0
MOVI r1,#SK_TYPE
MOVI r2,0
; use a generic scan on text with qpp_scanid
LD r2,r0,#WQ_T0
CALL @qpp_scanid
CMP r1,r0
JMP[EQ] @qcev_zero
CALL @qpp_find
CMP r1,r0
JMP[EQ] @qcev_zero
MOVI r1,1
JMP @qcev_d
qcev_one:
MOVI r1,1
JMP @qcev_d
qcev_zero:
MOVI r1,0
qcev_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_define: parse rest after directive name (WQ_T1)
qpp_define:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#WQ_T1
qdf_ws:
LDB r3,r2,0
MOVI r4,32
CMP r3,r4
JMP[NE] @qdf_n
ADD r2,r2,r13
JMP @qdf_ws
qdf_n:
CALL @qpp_scanid
CMP r1,r0
JMP[EQ] @qdf_d
LD r2,r0,#WQ_T1
LD r3,r0,#WQ_ILEN
ADD r2,r2,r3
; function-like macro: skip it
LDB r3,r2,0
MOVI r4,40
CMP r3,r4
JMP[EQ] @qdf_d
CALL @qpp_name_store
ST r1,r0,#WQ_T2
LD r2,r0,#WQ_T1
LD r3,r0,#WQ_ILEN
ADD r2,r2,r3
CALL @qpp_rest_store
ST r1,r0,#WQ_T3
LD r2,r0,#WQ_MACN
MOVI r3,#QPMACMAX
CMP r2,r3
JMP[LT] @qdf_room
MOVI r1,81
CALL @ncc_err
qdf_room:
SHL r2,r2,3
LA r3,#QPMACW
ADD r3,r3,r2
LD r4,r0,#WQ_HASH
ST r4,r3,0
LD r4,r0,#WQ_ILEN
ST r4,r3,1
LD r4,r0,#WQ_T2
ST r4,r3,2
LD r4,r0,#WQ_T3
SHR r5,r4,16
ST r5,r3,3
MOVI r5,0xFFFF
BOOL.8 r4,r4,r5
ST r4,r3,4
MOVI r5,1
ST r5,r3,5
ST r0,r3,6
ST r0,r3,7
LD r2,r0,#WQ_MACN
ADD r2,r2,r13
ST r2,r0,#WQ_MACN
qdf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

qpp_undef:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#WQ_T1
CALL @qpp_scanid
CMP r1,r0
JMP[EQ] @qud_d
CALL @qpp_find
CMP r1,r0
JMP[EQ] @qud_d
ST r0,r1,5
qud_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_putid: output QPID
qpp_putid:
ST r15,r14,0
ADD r14,r14,r13
LA r2,#QPIDB
qpi_l:
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @qpi_d
ADD r1,r3,r0
CALL @qpp_putc
ADD r2,r2,r13
JMP @qpi_l
qpi_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_emit_rep: entry r1 -> output replacement
qpp_emit_rep:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r1,3
LD r3,r1,4
LA r4,#QPNAMEB
ADD r4,r4,r3
qer_l:
CMP r2,r0
JMP[EQ] @qer_d
LDB r1,r4,0
ST r2,r0,#WQ_T2
ST r4,r0,#WQ_T0
CALL @qpp_putc
LD r2,r0,#WQ_T2
LD r4,r0,#WQ_T0
ADD r4,r4,r13
SUB r2,r2,r13
JMP @qer_l
qer_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_expand: expand QPLINE to output
qpp_expand:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#WQ_Q
ST r0,r0,#WQ_ESC
qex_l:
LD r2,r0,#WQ_P0
LA r3,#QPLINEB
ADD r2,r3,r2
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @qex_d
; block comment state
LD r4,r0,#WQ_CMT
CMP r4,r0
JMP[EQ] @qex_nc
; inside block comment: look for */
MOVI r5,42
CMP r3,r5
JMP[NE] @qex_cout
LA r4,#QPLINEB
LD r5,r0,#WQ_P0
ADD r4,r4,r5
ADDI r4,r4,1
LDB r6,r4,0
MOVI r7,47
CMP r6,r7
JMP[NE] @qex_cout
; consumed */
ADD r5,r5,r13
ADD r5,r5,r13
ST r5,r0,#WQ_P0
ST r0,r0,#WQ_CMT
JMP @qex_l
qex_cout:
ADD r1,r3,r0
CALL @qpp_putc
LD r2,r0,#WQ_P0
ADD r2,r2,r13
ST r2,r0,#WQ_P0
JMP @qex_l
qex_nc:
; quoted?
LD r4,r0,#WQ_Q
CMP r4,r0
JMP[EQ] @qex_unq
LD r5,r0,#WQ_ESC
CMP r5,r0
JMP[EQ] @qex_qesc
ST r0,r0,#WQ_ESC
JMP @qex_qout
qex_qesc:
MOVI r5,92
CMP r3,r5
JMP[NE] @qex_qclose
MOVI r5,1
ST r5,r0,#WQ_ESC
JMP @qex_qout
qex_qclose:
CMP r3,r4
JMP[NE] @qex_qout
ST r0,r0,#WQ_Q
qex_qout:
ADD r1,r3,r0
CALL @qpp_putc
LD r2,r0,#WQ_P0
ADD r2,r2,r13
ST r2,r0,#WQ_P0
JMP @qex_l
qex_unq:
MOVI r4,34
CMP r3,r4
JMP[EQ] @qex_qset
MOVI r4,39
CMP r3,r4
JMP[EQ] @qex_qset
MOVI r4,47
CMP r3,r4
JMP[NE] @qex_id
; comment start?
LA r4,#QPLINEB
LD r5,r0,#WQ_P0
ADD r4,r4,r5
ADDI r4,r4,1
LDB r6,r4,0
MOVI r7,47
CMP r6,r7
JMP[EQ] @qex_linecmt
MOVI r7,42
CMP r6,r7
JMP[EQ] @qex_blkcmt
JMP @qex_id
qex_linecmt:
; copy the rest verbatim
LD r2,r0,#WQ_P0
LA r4,#QPLINEB
ADD r2,r4,r2
qex_lc:
LDB r3,r2,0
CMP r3,r0
JMP[EQ] @qex_d
ADD r1,r3,r0
CALL @qpp_putc
ADD r2,r2,r13
JMP @qex_lc
qex_blkcmt:
MOVI r1,1
ST r1,r0,#WQ_CMT
JMP @qex_qout
qex_qset:
ST r3,r0,#WQ_Q
JMP @qex_qout
qex_id:
CALL @qpp_isid0
CMP r1,r0
JMP[EQ] @qex_ch
LD r2,r0,#WQ_P0
LA r4,#QPLINEB
ADD r2,r4,r2
CALL @qpp_scanid
CMP r1,r0
JMP[EQ] @qex_d
LD r2,r0,#WQ_ILEN
LD r3,r0,#WQ_P0
ADD r3,r3,r2
ST r3,r0,#WQ_P0
CALL @qpp_find
CMP r1,r0
JMP[EQ] @qex_keep
CALL @qpp_emit_rep
JMP @qex_l
qex_keep:
CALL @qpp_putid
JMP @qex_l
qex_ch:
LD r2,r0,#WQ_P0
LA r4,#QPLINEB
ADD r2,r4,r2
LDB r3,r2,0
ADD r1,r3,r0
CALL @qpp_putc
LD r2,r0,#WQ_P0
ADD r2,r2,r13
ST r2,r0,#WQ_P0
JMP @qex_l
qex_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_directive: line at QPLINE, after leading '#'
qpp_directive:
ST r15,r14,0
ADD r14,r14,r13
LA r2,#QPLINEB
LD r3,r0,#WQ_P0
ADD r2,r2,r3
qdv_ws:
LDB r3,r2,0
MOVI r4,32
CMP r3,r4
JMP[EQ] @qdv_ws2
MOVI r4,9
CMP r3,r4
JMP[NE] @qdv_name
qdv_ws2:
ADD r2,r2,r13
JMP @qdv_ws
qdv_name:
ST r2,r0,#WQ_T1
CALL @qpp_scanid
CMP r1,r0
JMP[EQ] @qdv_d
ST r2,r0,#WQ_T1
CALL @qpp_name_store
ST r1,r0,#WQ_T2
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_define
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_define
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_undef
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_undef
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_ifdef
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_ifdef
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_ifndef
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_ifndef
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_if
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_if
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_else
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_else
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_elif
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_elif
LA r1,#QPNAMEB
LD r2,r0,#WQ_T2
ADD r1,r1,r2
LA r2,@qds_endif
CALL @qpp_streq
CMP r1,r0
JMP[NE] @qdv_endif
JMP @qdv_d
qdv_define:
LD r1,r0,#WQ_ACT
CMP r1,r0
JMP[EQ] @qdv_d
CALL @qpp_define
JMP @qdv_d
qdv_undef:
LD r1,r0,#WQ_ACT
CMP r1,r0
JMP[EQ] @qdv_d
CALL @qpp_undef
JMP @qdv_d
qdv_ifdef:
LD r2,r0,#WQ_T1
CALL @qpp_cond_name
JMP @qdv_d
qdv_ifndef:
LD r2,r0,#WQ_T1
MOVI r3,1
CALL @qpp_cond_name_inv
JMP @qdv_d
qdv_if:
LD r1,r0,#WQ_ACT
CMP r1,r0
JMP[EQ] @qdv_ifoff
LD r1,r0,#WQ_T1
CALL @qpp_cond_eval
CALL @qpp_cond_push
JMP @qdv_d
qdv_ifoff:
MOVI r1,0
CALL @qpp_cond_push
JMP @qdv_d
qdv_else:
CALL @qpp_cond_else
JMP @qdv_d
qdv_elif:
LD r1,r0,#WQ_T1
CALL @qpp_cond_eval
CALL @qpp_cond_elif
JMP @qdv_d
qdv_endif:
CALL @qpp_cond_pop
qdv_d:
SUB r14,r14,r13
LD r15,r14,0
RET

qpp_cond_name:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#WQ_T0
ST r0,r0,#WQ_T1
qcn_l:
LD r2,r0,#WQ_T0
LDB r3,r2,0
MOVI r4,32
CMP r3,r4
JMP[EQ] @qcn_skip
MOVI r4,9
CMP r3,r4
JMP[NE] @qcn_s
qcn_skip:
ADD r2,r2,r13
ST r2,r0,#WQ_T0
JMP @qcn_l
qcn_s:
CALL @qpp_scanid
CMP r1,r0
JMP[EQ] @qcn_zero
CALL @qpp_find
CMP r1,r0
JMP[EQ] @qcn_zero
MOVI r1,1
JMP @qcn_go
qcn_zero:
MOVI r1,0
qcn_go:
CALL @qpp_cond_push
SUB r14,r14,r13
LD r15,r14,0
RET

qpp_cond_name_inv:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#WQ_T0
qci_l:
LD r2,r0,#WQ_T0
LDB r3,r2,0
MOVI r4,32
CMP r3,r4
JMP[EQ] @qci_skip
MOVI r4,9
CMP r3,r4
JMP[NE] @qci_s
qci_skip:
ADD r2,r2,r13
ST r2,r0,#WQ_T0
JMP @qci_l
qci_s:
CALL @qpp_scanid
CMP r1,r0
JMP[EQ] @qci_zero
CALL @qpp_find
CMP r1,r0
JMP[EQ] @qci_zero
MOVI r1,1
JMP @qci_go
qci_zero:
MOVI r1,0
qci_go:
MOVI r2,1
SUB r1,r2,r1
CALL @qpp_cond_push
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_cond_elif: r1=cond (only if not taken)
qpp_cond_elif:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#WQ_T2
LD r2,r0,#WQ_DEPTH
CMP r2,r0
JMP[EQ] @qel_d
SUB r2,r2,r13
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#QPCONDW
ADD r3,r3,r2
LD r4,r3,2
CMP r4,r0
JMP[NE] @qel_off
LD r5,r3,0
LD r1,r0,#WQ_T2
BOOL.8 r5,r5,r1
ST r5,r0,#WQ_ACT
ST r1,r3,2
JMP @qel_d
qel_off:
ST r0,r0,#WQ_ACT
qel_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; qpp_run: r1=source word ptr -> r1=output word ptr
qpp_run:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#WQ_WP
ST r0,r0,#WQ_BI
ST r0,r0,#WQ_OUT
ST r0,r0,#WQ_DEPTH
ST r0,r0,#WQ_NAMEP
ST r0,r0,#WQ_MACN
ST r0,r0,#WQ_CMT
MOVI r1,1
ST r1,r0,#WQ_ACT
qpr_l:
CALL @qpp_readline
CMP r1,r0
JMP[EQ] @qpr_done
; find first non-space
ST r0,r0,#WQ_P0
qpr_ws:
LA r2,#QPLINEB
LD r3,r0,#WQ_P0
ADD r2,r2,r3
LDB r4,r2,0
MOVI r5,32
CMP r4,r5
JMP[EQ] @qpr_wsn
MOVI r5,9
CMP r4,r5
JMP[NE] @qpr_chk
qpr_wsn:
ADD r3,r3,r13
ST r3,r0,#WQ_P0
JMP @qpr_ws
qpr_chk:
MOVI r5,35
CMP r4,r5
JMP[NE] @qpr_text
ADD r3,r3,r13
ST r3,r0,#WQ_P0
CALL @qpp_directive
JMP @qpr_l
qpr_text:
LD r1,r0,#WQ_ACT
CMP r1,r0
JMP[EQ] @qpr_nl
CALL @qpp_expand
qpr_nl:
MOVI r1,10
CALL @qpp_putc
JMP @qpr_l
qpr_done:
MOVI r1,0
CALL @qpp_putc
LA r1,#QPOUTB
SHR r1,r1,2
SUB r14,r14,r13
LD r15,r14,0
RET

qds_define:
.str "define"
qds_undef:
.str "undef"
qds_ifdef:
.str "ifdef"
qds_ifndef:
.str "ifndef"
qds_if:
.str "if"
qds_else:
.str "else"
qds_elif:
.str "elif"
qds_endif:
.str "endif"

; ================================================================== MINI PREPROCESSOR
; Lexer-integrated C89 preprocessor subset:
;   #define NAME number   (object-like, numeric replacement)
;   #undef NAME
;   #ifdef / #ifndef / #if 0|1|defined(NAME) / #else / #elif / #endif
;   #include is skipped (the runtime library is built in)
; Macro values are delivered as integer tokens by scan_ident.
.equ Q2MAC      2000000
.equ Q2MACMAX   256
.equ Q2COND     2001024
.equ Q2BUF      8020000
.equ W_Q2N      61300
.equ W_Q2SKIP   61301
.equ W_Q2DEPTH  61302
.equ W_Q2HASH   61303
.equ W_Q2LEN    61304
.equ W_Q2VAL    61305
.equ W_Q2T0     61306
.equ W_Q2SIGN   61307
.equ W_Q2PTR    61308
.equ W_SCOPEID 61310
.equ W_FORCENEW 61311
.equ W_NEXTSCOPE 61312
.equ W_IDXTYPE 61341
.equ W_SCOPEPAR 2001200

; q2_skipsp: consume spaces and tabs
q2_skipsp:
ST r15,r14,0
ADD r14,r14,r13
q2ss_l:
CALL @lx_peek
MOVI r2,32
CMP r1,r2
JMP[EQ] @q2ss_c
MOVI r2,9
CMP r1,r2
JMP[NE] @q2ss_d
q2ss_c:
CALL @lx_get
JMP @q2ss_l
q2ss_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_eat: consume the rest of the line (including the newline)
q2_eat:
ST r15,r14,0
ADD r14,r14,r13
q2eat_l:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @q2eat_d
MOVI r2,10
CMP r1,r2
JMP[EQ] @q2eat_nl
CALL @lx_get
JMP @q2eat_l
q2eat_nl:
CALL @lx_get
q2eat_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_word: scan identifier into Q2BUF; W_Q2HASH/W_Q2LEN set; r1=len
q2_word:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_Q2LEN
ST r0,r0,#W_Q2HASH
LA r2,#Q2BUF
ST r2,r0,#W_Q2T0
q2w_l:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @q2w_d
MOVI r2,32
CMP r1,r2
JMP[EQ] @q2w_d
MOVI r2,9
CMP r1,r2
JMP[EQ] @q2w_d
MOVI r2,10
CMP r1,r2
JMP[EQ] @q2w_d
LD r3,r0,#W_Q2LEN
CMP r3,r0
JMP[NE] @q2w_c
CALL @ident0
JMP @q2w_t
q2w_c:
CALL @identc
q2w_t:
CMP r1,r0
JMP[EQ] @q2w_d
CALL @lx_get
ST r1,r0,#L_CH
LD r3,r0,#W_Q2LEN
MOVI r4,120
CMP r3,r4
JMP[GE] @q2w_next
LD r5,r0,#W_Q2T0
ADD r5,r5,r3
STB r1,r5,0
q2w_next:
LD r5,r0,#W_Q2HASH
CMP r5,r0
JMP[NE] @q2w_hashed
LA r5,0x811C9DC5
q2w_hashed:
LA r6,0x01000193
ST r1,r0,#L_CH
BOOL.6 r7,r5,r1
MUL r7,r7,r6
ADD r5,r7,r0
ST r5,r0,#W_Q2HASH
ADD r3,r3,r13
ST r3,r0,#W_Q2LEN
JMP @q2w_l
q2w_d:
LD r3,r0,#W_Q2LEN
LD r5,r0,#W_Q2T0
ADD r5,r5,r3
STB r0,r5,0
ADD r1,r3,r0
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_find: hash/len in W_Q2* -> r1=entry addr or 0
q2_find:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,0
q2f_l:
LD r3,r0,#W_Q2N
CMP r2,r3
JMP[GE] @q2f_n
SHL r3,r2,2
LA r4,#Q2MAC
ADD r4,r4,r3
LD r5,r4,0
LD r6,r0,#W_Q2HASH
CMP r5,r6
JMP[NE] @q2f_next
LD r5,r4,1
LD r6,r0,#W_Q2LEN
CMP r5,r6
JMP[NE] @q2f_next
ADD r1,r4,r0
JMP @q2f_d
q2f_next:
ADD r2,r2,r13
JMP @q2f_l
q2f_n:
MOVI r1,0
q2f_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_macro: r1=hash r2=len -> r1=value, r2=1 if an active macro
q2_macro:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_Q2HASH
ST r2,r0,#W_Q2LEN
CALL @q2_find
CMP r1,r0
JMP[EQ] @q2m_n
LD r2,r1,3
CMP r2,r0
JMP[EQ] @q2m_n
LD r1,r1,2
MOVI r2,1
JMP @q2m_d
q2m_n:
MOVI r1,0
MOVI r2,0
q2m_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_bufeq: r1=C string -> 1 if Q2BUF equals it
q2_bufeq:
SHL r1,r1,2
LA r2,#Q2BUF
q2be_l:
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @q2be_n
CMP r3,r0
JMP[EQ] @q2be_y
ADD r1,r1,r13
ADD r2,r2,r13
JMP @q2be_l
q2be_y:
MOVI r1,1
RET
q2be_n:
MOVI r1,0
RET

; q2_num: parse an integer constant from the source -> W_Q2VAL
q2_num:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,1
ST r1,r0,#W_Q2SIGN
CALL @q2_skipsp
CALL @lx_peek
MOVI r2,45
CMP r1,r2
JMP[NE] @q2n_plus
LA r2,0xFFFFFFFF
ST r2,r0,#W_Q2SIGN
CALL @lx_get
JMP @q2n_go
q2n_plus:
MOVI r2,43
CMP r1,r2
JMP[NE] @q2n_go
CALL @lx_get
q2n_go:
CALL @q2_skipsp
MOVI r2,10
ST r2,r0,#W_Q2T0
CALL @lx_peek
MOVI r2,48
CMP r1,r2
JMP[NE] @q2n_loop
MOVI r10,1
CALL @peekn
MOVI r2,120
CMP r1,r2
JMP[EQ] @q2n_hex
MOVI r2,88
CMP r1,r2
JMP[NE] @q2n_loop
q2n_hex:
MOVI r2,16
ST r2,r0,#W_Q2T0
CALL @lx_get
CALL @lx_get
q2n_loop:
MOVI r1,0
ST r1,r0,#W_Q2HASH
q2n_l:
CALL @lx_peek
LD r2,r0,#W_Q2T0
CALL @digitv
MOVI r2,255
CMP r1,r2
JMP[EQ] @q2n_done
ST r1,r0,#W_Q2LEN
CALL @lx_get
LD r2,r0,#W_Q2HASH
LD r3,r0,#W_Q2T0
MUL r2,r2,r3
LD r3,r0,#W_Q2LEN
ADD r2,r2,r3
ST r2,r0,#W_Q2HASH
JMP @q2n_l
q2n_done:
LD r1,r0,#W_Q2HASH
LD r2,r0,#W_Q2SIGN
CMPS r2,r0
JMP[GE] @q2n_store
SUB r1,r0,r1
q2n_store:
ST r1,r0,#W_Q2VAL
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_defined: after optional spaces and "defined"; sets r1=0/1
q2_defined:
ST r15,r14,0
ADD r14,r14,r13
CALL @q2_skipsp
CALL @lx_peek
MOVI r2,40
CMP r1,r2
JMP[NE] @q2df_word
CALL @lx_get
q2df_word:
CALL @q2_word
CALL @q2_find
CMP r1,r0
JMP[EQ] @q2df_n
LD r2,r1,3
CMP r2,r0
JMP[EQ] @q2df_n
MOVI r1,1
JMP @q2df_d
q2df_n:
MOVI r1,0
q2df_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_cond_push: r1=condition
q2_cond_push:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_Q2T0
LD r2,r0,#W_Q2DEPTH
MOVI r3,16
CMP r2,r3
JMP[LT] @q2cp_room
MOVI r1,82
CALL @ncc_err
q2cp_room:
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#Q2COND
ADD r3,r3,r2
LD r4,r0,#W_Q2SKIP
ST r4,r3,0
ADD r7,r4,r0
LD r4,r0,#W_Q2T0
ST r4,r3,1
ST r4,r3,2
MOVI r5,1
SUB r5,r5,r4
; skip = parent | !cond
BOOL.14 r6,r7,r5
ST r6,r0,#W_Q2SKIP
LD r2,r0,#W_Q2DEPTH
ADD r2,r2,r13
ST r2,r0,#W_Q2DEPTH
SUB r14,r14,r13
LD r15,r14,0
RET

q2_cond_else:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_Q2DEPTH
CMP r2,r0
JMP[EQ] @q2ce_d
SUB r2,r2,r13
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#Q2COND
ADD r3,r3,r2
LD r4,r3,2
CMP r4,r0
JMP[NE] @q2ce_off
LD r5,r3,0
ST r5,r0,#W_Q2SKIP
MOVI r4,1
ST r4,r3,2
JMP @q2ce_d
q2ce_off:
MOVI r5,1
ST r5,r0,#W_Q2SKIP
q2ce_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_cond_elif: r1=condition
q2_cond_elif:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_Q2T0
LD r2,r0,#W_Q2DEPTH
CMP r2,r0
JMP[EQ] @q2ci_d
SUB r2,r2,r13
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#Q2COND
ADD r3,r3,r2
LD r4,r3,2
CMP r4,r0
JMP[NE] @q2ci_off
LD r5,r3,0
LD r1,r0,#W_Q2T0
MOVI r6,1
SUB r6,r6,r1
BOOL.14 r5,r5,r6
ST r5,r0,#W_Q2SKIP
ST r1,r3,2
JMP @q2ci_d
q2ci_off:
MOVI r5,1
ST r5,r0,#W_Q2SKIP
q2ci_d:
SUB r14,r14,r13
LD r15,r14,0
RET

q2_cond_pop:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_Q2DEPTH
CMP r2,r0
JMP[EQ] @q2cx_d
SUB r2,r2,r13
ST r2,r0,#W_Q2DEPTH
SHL r2,r2,1
ADD r2,r2,r2
LA r3,#Q2COND
ADD r3,r3,r2
LD r1,r3,0
ST r1,r0,#W_Q2SKIP
q2cx_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; q2_directive: called after '#'; processes one directive line
q2_directive:
ST r15,r14,0
ADD r14,r14,r13
CALL @q2_skipsp
CALL @q2_word
CMP r1,r0
JMP[EQ] @q2dir_eat
LA r1,@q2s_define
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_define
LA r1,@q2s_undef
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_undef
LA r1,@q2s_ifdef
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_ifdef
LA r1,@q2s_ifndef
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_ifndef
LA r1,@q2s_if
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_if
LA r1,@q2s_elif
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_elif
LA r1,@q2s_else
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_else
LA r1,@q2s_endif
CALL @q2_bufeq
CMP r1,r0
JMP[NE] @q2dir_endif
JMP @q2dir_eat
q2dir_define:
LD r1,r0,#W_Q2SKIP
CMP r1,r0
JMP[NE] @q2dir_eat
CALL @q2_skipsp
CALL @q2_word
CMP r1,r0
JMP[EQ] @q2dir_eat
LD r1,r0,#W_Q2HASH
ST r1,r0,#W_Q2HASH
LD r2,r0,#W_Q2LEN
ST r2,r0,#W_Q2T0
CALL @q2_find
CMP r1,r0
JMP[NE] @q2dd_have
LD r1,r0,#W_Q2N
MOVI r2,#Q2MACMAX
CMP r1,r2
JMP[LT] @q2dd_room
MOVI r1,85
CALL @ncc_err
q2dd_room:
SHL r2,r1,2
LA r3,#Q2MAC
ADD r3,r3,r2
LD r2,r0,#W_Q2HASH
ST r2,r3,0
LD r2,r0,#W_Q2T0
ST r2,r3,1
ADD r1,r1,r13
ST r1,r0,#W_Q2N
ST r3,r0,#W_Q2PTR
JMP @q2dd_val
q2dd_have:
ST r1,r0,#W_Q2PTR
q2dd_val:
CALL @q2_num
LD r1,r0,#W_Q2VAL
LD r2,r0,#W_Q2PTR
ST r1,r2,2
MOVI r1,1
ST r1,r2,3
JMP @q2dir_eat
q2dir_undef:
LD r1,r0,#W_Q2SKIP
CMP r1,r0
JMP[NE] @q2dir_eat
CALL @q2_skipsp
CALL @q2_word
CALL @q2_find
CMP r1,r0
JMP[EQ] @q2dir_eat
ST r0,r1,3
JMP @q2dir_eat
q2dir_ifdef:
CALL @q2_skipsp
CALL @q2_word
CALL @q2_find
CMP r1,r0
JMP[EQ] @q2di_zero
LD r2,r1,3
CMP r2,r0
JMP[EQ] @q2di_zero
MOVI r1,1
JMP @q2di_push
q2di_zero:
MOVI r1,0
q2di_push:
CALL @q2_cond_push
JMP @q2dir_eat
q2dir_ifndef:
CALL @q2_skipsp
CALL @q2_word
CALL @q2_find
CMP r1,r0
JMP[EQ] @q2dn_zero
LD r2,r1,3
CMP r2,r0
JMP[EQ] @q2dn_zero
MOVI r1,1
JMP @q2dn_inv
q2dn_zero:
MOVI r1,0
q2dn_inv:
MOVI r2,1
SUB r1,r2,r1
CALL @q2_cond_push
JMP @q2dir_eat
q2dir_if:
LD r1,r0,#W_Q2SKIP
CMP r1,r0
JMP[EQ] @q2dif_eval
; still track nesting
MOVI r1,0
CALL @q2_cond_push
JMP @q2dir_eat
q2dif_eval:
CALL @q2_skipsp
CALL @lx_peek
MOVI r2,100
CMP r1,r2
JMP[NE] @q2dif_num
; skip "defined"
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @q2_defined
JMP @q2dif_push
q2dif_num:
MOVI r2,48
CMP r1,r2
JMP[EQ] @q2dif_zero
MOVI r2,49
CMP r1,r2
JMP[EQ] @q2dif_one
; #if NAME -> defined(NAME)
CALL @q2_word
CALL @q2_find
CMP r1,r0
JMP[EQ] @q2dif_zero
LD r2,r1,3
CMP r2,r0
JMP[EQ] @q2dif_zero
MOVI r1,1
JMP @q2dif_push
q2dif_zero:
MOVI r1,0
JMP @q2dif_push
q2dif_one:
MOVI r1,1
q2dif_push:
CALL @q2_cond_push
JMP @q2dir_eat
q2dir_elif:
CALL @q2_skipsp
CALL @lx_peek
MOVI r2,100
CMP r1,r2
JMP[NE] @q2del_num
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @lx_get
CALL @q2_defined
JMP @q2del_go
q2del_num:
MOVI r2,48
CMP r1,r2
JMP[EQ] @q2del_zero
MOVI r2,49
CMP r1,r2
JMP[EQ] @q2del_one
CALL @q2_word
CALL @q2_find
CMP r1,r0
JMP[EQ] @q2del_zero
LD r2,r1,3
CMP r2,r0
JMP[EQ] @q2del_zero
MOVI r1,1
JMP @q2del_go
q2del_zero:
MOVI r1,0
JMP @q2del_go
q2del_one:
MOVI r1,1
q2del_go:
CALL @q2_cond_elif
JMP @q2dir_eat
q2dir_else:
CALL @q2_cond_else
JMP @q2dir_eat
q2dir_endif:
CALL @q2_cond_pop
q2dir_eat:
CALL @q2_eat
SUB r14,r14,r13
LD r15,r14,0
RET

q2s_define:
.str "define"
q2s_undef:
.str "undef"
q2s_ifdef:
.str "ifdef"
q2s_ifndef:
.str "ifndef"
q2s_if:
.str "if"
q2s_elif:
.str "elif"
q2s_else:
.str "else"
q2s_endif:
.str "endif"


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
ST r0,r0,#W_Q2N
ST r0,r0,#W_Q2SKIP
ST r0,r0,#W_Q2DEPTH
ST r0,r0,#W_FUNCSYM
ST r0,r0,#W_LOOPN
ST r0,r0,#W_SCOPEID
MOVI r1,1
ST r1,r0,#W_NEXTSCOPE
LA r1,#NCC_IRB
ST r1,r0,#W_IRPC
ST r0,r0,#W_SYMUSED
ST r0,r0,#W_NAMEP
ST r0,r0,#W_HAVE
ST r0,r0,#W_BRK_N
ST r0,r0,#W_CNT_N
ST r0,r0,#W_SW_N
ST r0,r0,#W_CASE_N
ST r0,r0,#W_GOTO_N
ST r0,r0,#W_PP_N
LA r1,#C_GLOB
ST r1,r0,#W_GLOBP
LA r1,#C_RODATA
ST r1,r0,#W_STRP
LA r1,#C_HEAP
ST r1,r0,#W_HEAP
LA r1,#NCC_PARM
ST r1,r0,#W_PARAMP
LA r1,#NCC_MEMB
ST r1,r0,#W_MEMBP
MOVI r1,16
ST r1,r0,#W_LOCALB
ST r1,r0,#W_FRAMEB
CALL @ncc_types_init
CALL @ncc_builtins
CALL @np_init
CALL @p_tu
CALL @sym_find_main
ADD r2,r1,r0
LA r1,#I_CALL
CALL @ir_emit
LD r2,r0,#W_IRPC
ST r2,r0,#W_TAILHALT
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
LA r1,#C_STACK
ST r1,r0,#R_FP
LA r1,#NCC_IRB
ST r1,r0,#R_IP
LA r2,#C_STACK
SHR r2,r2,2
ADDI r2,r2,3
ST r0,r2,0
ADDI r2,r2,-3
ST r0,r2,0
CALL @ncc_ir_loop
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
MOVI r1,58
CALL @ncc_putc
LD r5,r0,#W_TKA+2
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
puthex1l:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,10
CMP r1,r2
JMP[LT] @phxl_d
ADDI r1,r1,87
CALL @ncc_putc
JMP @phxl_e
phxl_d:
ADDI r1,r1,48
CALL @ncc_putc
phxl_e:
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

; ================================================================== TYPES
ncc_types_init:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,16
ST r1,r0,#W_TYPEN
; 1 void
MOVI r1,1
MOVI r2,#TY_VOID
MOVI r3,0
MOVI r4,1
MOVI r5,0
MOVI r6,0
CALL @ty_set
; 2 char, 3 uchar
MOVI r1,2
MOVI r2,#TY_INT
MOVI r3,1
MOVI r4,1
MOVI r5,1
MOVI r6,0
CALL @ty_set
MOVI r1,3
MOVI r2,#TY_INT
MOVI r3,1
MOVI r4,1
MOVI r5,0
MOVI r6,0
CALL @ty_set
; 4 short, 5 ushort
MOVI r1,4
MOVI r2,#TY_INT
MOVI r3,2
MOVI r4,2
MOVI r5,1
MOVI r6,0
CALL @ty_set
MOVI r1,5
MOVI r2,#TY_INT
MOVI r3,2
MOVI r4,2
MOVI r5,0
MOVI r6,0
CALL @ty_set
; 6 int, 7 uint
MOVI r1,6
MOVI r2,#TY_INT
MOVI r3,4
MOVI r4,4
MOVI r5,1
MOVI r6,0
CALL @ty_set
MOVI r1,7
MOVI r2,#TY_INT
MOVI r3,4
MOVI r4,4
MOVI r5,0
MOVI r6,0
CALL @ty_set
; 8 long, 9 ulong
MOVI r1,8
MOVI r2,#TY_INT
MOVI r3,4
MOVI r4,4
MOVI r5,1
MOVI r6,0
CALL @ty_set
MOVI r1,9
MOVI r2,#TY_INT
MOVI r3,4
MOVI r4,4
MOVI r5,0
MOVI r6,0
CALL @ty_set
; 10 float, 11 double (32-bit payload representation)
MOVI r1,10
MOVI r2,#TY_FLOAT
MOVI r3,4
MOVI r4,4
MOVI r5,1
MOVI r6,0
CALL @ty_set
MOVI r1,11
MOVI r2,#TY_FLOAT
MOVI r3,4
MOVI r4,4
MOVI r5,1
MOVI r6,0
CALL @ty_set
SUB r14,r14,r13
LD r15,r14,0
RET
; ty_set: r1=id r2=kind r3=size r4=align r5=sign r6=base
ty_set:
SHL r1,r1,3
LA r7,#NCC_TYPEB
ADD r1,r1,r7
ST r2,r1,#TY_KIND
ST r3,r1,#TY_SIZE
ST r4,r1,#TY_ALIGN
ST r6,r1,#TY_BASE
ST r0,r1,#TY_COUNT
ST r0,r1,#TY_MEM
ST r0,r1,#TY_NMEM
ST r5,r1,#TY_SIGN
RET

ty_addr:
SHL r1,r1,3
LA r2,#NCC_TYPEB
ADD r1,r1,r2
RET
ty_size:
SHL r1,r1,3
LA r2,#NCC_TYPEB
ADD r1,r1,r2
LD r1,r1,#TY_SIZE
RET
ty_align:
SHL r1,r1,3
LA r2,#NCC_TYPEB
ADD r1,r1,r2
LD r1,r1,#TY_ALIGN
RET
ty_kind:
SHL r1,r1,3
LA r2,#NCC_TYPEB
ADD r1,r1,r2
LD r1,r1,#TY_KIND
RET
ty_base:
SHL r1,r1,3
LA r2,#NCC_TYPEB
ADD r1,r1,r2
LD r1,r1,#TY_BASE
RET
ty_count:
SHL r1,r1,3
LA r2,#NCC_TYPEB
ADD r1,r1,r2
LD r1,r1,#TY_COUNT
RET
ty_sign:
SHL r1,r1,3
LA r2,#NCC_TYPEB
ADD r1,r1,r2
LD r1,r1,#TY_SIGN
RET

; ty_new: allocate from W_TY_* fields, returns id
ty_new:
LD r1,r0,#W_TYPEN
LA r2,#NCC_TYPEMAX
CMP r1,r2
JMP[LT] @tyn_room
MOVI r1,60
JMP @ncc_err
tyn_room:
SHL r2,r1,3
LA r3,#NCC_TYPEB
ADD r3,r3,r2
LD r4,r0,#W_TY_KIND
ST r4,r3,#TY_KIND
LD r4,r0,#W_TY_SIZE
ST r4,r3,#TY_SIZE
LD r4,r0,#W_TY_ALIGN
ST r4,r3,#TY_ALIGN
LD r4,r0,#W_TY_BASE
ST r4,r3,#TY_BASE
LD r4,r0,#W_TY_COUNT
ST r4,r3,#TY_COUNT
LD r4,r0,#W_TY_MEM
ST r4,r3,#TY_MEM
LD r4,r0,#W_TY_NMEM
ST r4,r3,#TY_NMEM
LD r4,r0,#W_TY_SIGN
ST r4,r3,#TY_SIGN
ADD r1,r1,r13
ST r1,r0,#W_TYPEN
SUB r1,r1,r13
RET

; ty_ptr: r1=base -> pointer type id
ty_ptr:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
MOVI r2,16
pty_l:
LD r3,r0,#W_TYPEN
CMP r2,r3
JMP[GE] @pty_new
SHL r3,r2,3
LA r4,#NCC_TYPEB
ADD r3,r3,r4
LD r4,r3,#TY_KIND
MOVI r5,#TY_PTR
CMP r4,r5
JMP[NE] @pty_next
LD r4,r3,#TY_BASE
LD r5,r0,#W_TY_TMP
CMP r4,r5
JMP[NE] @pty_next
ADD r1,r2,r0
JMP @pty_d
pty_next:
ADD r2,r2,r13
JMP @pty_l
pty_new:
MOVI r1,#TY_PTR
ST r1,r0,#W_TY_KIND
MOVI r1,4
ST r1,r0,#W_TY_SIZE
ST r1,r0,#W_TY_ALIGN
LD r1,r0,#W_TY_TMP
ST r1,r0,#W_TY_BASE
ST r0,r0,#W_TY_COUNT
ST r0,r0,#W_TY_MEM
ST r0,r0,#W_TY_NMEM
ST r0,r0,#W_TY_SIGN
CALL @ty_new
pty_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ty_array: r1=base, r2=count -> array type id
ty_array:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
ST r2,r0,#W_TY_COUNT
MOVI r1,#TY_ARRAY
ST r1,r0,#W_TY_KIND
LD r1,r0,#W_TY_TMP
CALL @ty_size
LD r2,r0,#W_TY_COUNT
MUL r1,r1,r2
ST r1,r0,#W_TY_SIZE
LD r1,r0,#W_TY_TMP
CALL @ty_align
ST r1,r0,#W_TY_ALIGN
LD r1,r0,#W_TY_TMP
ST r1,r0,#W_TY_BASE
ST r0,r0,#W_TY_MEM
ST r0,r0,#W_TY_NMEM
ST r0,r0,#W_TY_SIGN
CALL @ty_new
SUB r14,r14,r13
LD r15,r14,0
RET

; ty_func: r1=return type, r2=nparams -> function type id
ty_func:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#W_TY_COUNT
MOVI r3,#TY_FUNC
ST r3,r0,#W_TY_KIND
ST r0,r0,#W_TY_SIZE
MOVI r3,1
ST r3,r0,#W_TY_ALIGN
ST r1,r0,#W_TY_BASE
ST r0,r0,#W_TY_MEM
ST r0,r0,#W_TY_NMEM
ST r0,r0,#W_TY_SIGN
CALL @ty_new
SUB r14,r14,r13
LD r15,r14,0
RET

; ty_struct: r1=5 struct / 6 union -> new type id
ty_struct:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_KIND
ST r0,r0,#W_TY_SIZE
MOVI r2,1
ST r2,r0,#W_TY_ALIGN
ST r0,r0,#W_TY_BASE
ST r0,r0,#W_TY_COUNT
LD r2,r0,#W_MEMBP
ST r2,r0,#W_TY_MEM
ST r0,r0,#W_TY_NMEM
ST r0,r0,#W_TY_SIGN
CALL @ty_new
SUB r14,r14,r13
LD r15,r14,0
RET

; ty_common: r1=a r2=b -> C usual arithmetic type
ty_common:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
ST r2,r0,#W_TY_ID
CALL @ty_kind
MOVI r3,#TY_FLOAT
CMP r1,r3
JMP[EQ] @tyc_float
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r3,#TY_FLOAT
CMP r1,r3
JMP[EQ] @tyc_float
LD r1,r0,#W_TY_TMP
CALL @ty_size
LD r2,r0,#W_TY_ID
ST r1,r0,#W_TY_SIZE
ADD r1,r2,r0
CALL @ty_size
LD r2,r0,#W_TY_SIZE
CMP r2,r1
JMP[GE] @tyc_have
ADD r2,r1,r0
tyc_have:
MOVI r1,4
CMP r2,r1
JMP[LT] @tyc_int
LD r1,r0,#W_TY_TMP
CALL @ty_sign
ST r1,r0,#W_TY_SIGN
LD r1,r0,#W_TY_ID
CALL @ty_sign
LD r2,r0,#W_TY_SIGN
BOOL.8 r1,r1,r2
CMP r1,r0
JMP[EQ] @tyc_uint
MOVI r1,#T_INT
JMP @tyc_d
tyc_uint:
MOVI r1,#T_UINT
JMP @tyc_d
tyc_int:
MOVI r1,#T_INT
JMP @tyc_d
tyc_float:
MOVI r1,#T_FLOAT
tyc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ty_store_code: r1=type -> load/store size code
ty_store_code:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
CALL @ty_size
MOVI r2,1
CMP r1,r2
JMP[EQ] @tsc_8
MOVI r2,2
CMP r1,r2
JMP[EQ] @tsc_16
MOVI r1,#SZ_32
JMP @tsc_d
tsc_8:
LD r1,r0,#W_TY_TMP
CALL @ty_sign
CMP r1,r0
JMP[NE] @tsc_8s
MOVI r1,#SZ_8U
JMP @tsc_d
tsc_8s:
MOVI r1,#SZ_8S
JMP @tsc_d
tsc_16:
LD r1,r0,#W_TY_TMP
CALL @ty_sign
CMP r1,r0
JMP[NE] @tsc_16s
MOVI r1,#SZ_16U
JMP @tsc_d
tsc_16s:
MOVI r1,#SZ_16S
tsc_d:
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
LD r1,r0,#W_Q2SKIP
CMP r1,r0
JMP[NE] @sw_skip
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
MOVI r2,35
CMP r1,r2
JMP[EQ] @sw_dir
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
MOVI r2,35
CMP r1,r2
JMP[EQ] @sw_dir
JMP @sw_d
sw_dir:
CALL @lx_get
CALL @q2_directive
JMP @sw_l
sw_skip:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @sw_d
MOVI r2,10
CMP r1,r2
JMP[EQ] @sw_skip_nl
CALL @lx_get
JMP @sw_skip
sw_skip_nl:
CALL @lx_get
sw_skip_ws:
CALL @lx_peek
MOVI r2,32
CMP r1,r2
JMP[EQ] @sw_skip_adv
MOVI r2,9
CMP r1,r2
JMP[EQ] @sw_skip_adv
MOVI r2,35
CMP r1,r2
JMP[EQ] @sw_skip_dir
JMP @sw_skip
sw_skip_adv:
CALL @lx_get
JMP @sw_skip_ws
sw_skip_dir:
CALL @lx_get
CALL @q2_directive
JMP @sw_l
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
CALL @lx_peek
MOVI r2,46
CMP r1,r2
JMP[NE] @sn_int
MOVI r10,1
CALL @peekn
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[EQ] @sn_int
CALL @scan_float
JMP @sn_done
sn_int:
MOVI r1,2
ST r1,r0,#L_KIND
sn_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; scan_float: integer part in L_VAL, cursor at '.', consume fraction.
scan_float:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#L_TMP1
MOVI r1,1
ST r1,r0,#L_TMP2
CALL @lx_get
sf_l:
CALL @lx_peek
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[EQ] @sf_done
LD r3,r0,#L_TMP1
MOVI r4,10
MUL r3,r3,r4
ADD r3,r3,r1
ST r3,r0,#L_TMP1
LD r3,r0,#L_TMP2
MOVI r4,10
MUL r3,r3,r4
ST r3,r0,#L_TMP2
CALL @lx_get
JMP @sf_l
sf_done:
LD r1,r0,#L_VAL
CVTIF r2,r1
LD r1,r0,#L_TMP1
CVTIF r3,r1
LD r1,r0,#L_TMP2
CVTIF r4,r1
FDIV r3,r3,r4
FADD r2,r2,r3
ST r2,r0,#L_VAL
MOVI r1,9
ST r1,r0,#L_KIND
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
LD r2,r0,#L_LEN
CALL @q2_macro
CMP r2,r0
JMP[EQ] @si_kw
ST r1,r0,#L_VAL
MOVI r1,2
ST r1,r0,#L_KIND
JMP @si_d
si_kw:
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
ST r1,r0,#L_TMP1
CALL @lx_get
LD r1,r0,#L_TMP1
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
MOVI r2,46
CMP r1,r2
JMP[EQ] @sp_dot
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
JMP @sp_one
sp_dot:
MOVI r1,46
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

p_is_type:
LA r1,#W_TKA
JMP @p_tok_is_type

p_tok_is_type:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TKPTR
LD r2,r1,#TK_KIND
MOVI r3,#K_KEYWORD
CMP r2,r3
JMP[NE] @ptit_ident
LD r1,r1,#TK_VAL
CALL @kw_is_type
JMP @ptit_d
ptit_ident:
MOVI r3,#K_IDENT
CMP r2,r3
JMP[NE] @ptit_n
MOVI r1,#SK_TYPE
LD r2,r0,#W_TKPTR
CALL @sym_find_tok
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @ptit_n
MOVI r1,1
JMP @ptit_d
ptit_n:
MOVI r1,0
ptit_d:
SUB r14,r14,r13
LD r15,r14,0
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
MOVI r2,1
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,11
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,25
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,27
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,28
CMP r1,r2
JMP[EQ] @kit_y
MOVI r1,0
RET
kit_y:
MOVI r1,1
RET

; p_typespec: parse declaration specifiers -> r1 = type id, W_SCLASS set
p_typespec:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_SCLASS
ST r0,r0,#W_TSIGN
ST r0,r0,#W_TSHORT
ST r0,r0,#W_TLONG
ST r0,r0,#W_TCHAR
ST r0,r0,#W_TVOID
ST r0,r0,#W_TFLOAT
ST r0,r0,#W_TSEEN
pts_l:
LD r1,r0,#W_TKA
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @pts_ident
LD r1,r0,#W_TKA+1
MOVI r2,#KW_AUTO
CMP r1,r2
JMP[EQ] @pts_auto
MOVI r2,#KW_REGISTER
CMP r1,r2
JMP[EQ] @pts_auto
MOVI r2,#KW_STATIC
CMP r1,r2
JMP[EQ] @pts_static
MOVI r2,#KW_EXTERN
CMP r1,r2
JMP[EQ] @pts_extern
MOVI r2,#KW_TYPEDEF
CMP r1,r2
JMP[EQ] @pts_typedef
MOVI r2,#KW_CONST
CMP r1,r2
JMP[EQ] @pts_qual
MOVI r2,#KW_VOLATILE
CMP r1,r2
JMP[EQ] @pts_qual
MOVI r2,#KW_SIGNED
CMP r1,r2
JMP[EQ] @pts_signed
MOVI r2,#KW_UNSIGNED
CMP r1,r2
JMP[EQ] @pts_unsigned
MOVI r2,#KW_CHAR
CMP r1,r2
JMP[EQ] @pts_char
MOVI r2,#KW_SHORT
CMP r1,r2
JMP[EQ] @pts_short
MOVI r2,#KW_LONG
CMP r1,r2
JMP[EQ] @pts_long
MOVI r2,#KW_INT
CMP r1,r2
JMP[EQ] @pts_int
MOVI r2,#KW_FLOAT
CMP r1,r2
JMP[EQ] @pts_float
MOVI r2,#KW_DOUBLE
CMP r1,r2
JMP[EQ] @pts_double
MOVI r2,#KW_VOID
CMP r1,r2
JMP[EQ] @pts_void
MOVI r2,#KW_ENUM
CMP r1,r2
JMP[EQ] @pts_enum
MOVI r2,#KW_STRUCT
CMP r1,r2
JMP[EQ] @pts_struct
MOVI r2,#KW_UNION
CMP r1,r2
JMP[EQ] @pts_union
JMP @pts_choose
pts_auto:
MOVI r1,4
ST r1,r0,#W_SCLASS
JMP @pts_skip
pts_static:
MOVI r1,1
ST r1,r0,#W_SCLASS
JMP @pts_skip
pts_extern:
MOVI r1,2
ST r1,r0,#W_SCLASS
JMP @pts_skip
pts_typedef:
MOVI r1,3
ST r1,r0,#W_SCLASS
JMP @pts_skip
pts_qual:
JMP @pts_skip
pts_signed:
MOVI r1,1
ST r1,r0,#W_TSIGN
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_unsigned:
MOVI r1,2
ST r1,r0,#W_TSIGN
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_int:
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_char:
MOVI r1,1
ST r1,r0,#W_TCHAR
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_short:
MOVI r1,1
ST r1,r0,#W_TSHORT
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_long:
MOVI r1,1
ST r1,r0,#W_TLONG
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_float:
MOVI r1,1
ST r1,r0,#W_TFLOAT
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_double:
MOVI r1,2
ST r1,r0,#W_TFLOAT
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_void:
MOVI r1,1
ST r1,r0,#W_TVOID
MOVI r1,1
ST r1,r0,#W_TSEEN
JMP @pts_skip
pts_enum:
CALL @p_enum_spec
JMP @pts_ret
pts_struct:
MOVI r1,#TY_STRUCT
CALL @p_struct_spec
JMP @pts_ret
pts_union:
MOVI r1,#TY_UNION
CALL @p_struct_spec
JMP @pts_ret
pts_skip:
CALL @p_adv
JMP @pts_l
pts_ident:
LD r1,r0,#W_TSEEN
CMP r1,r0
JMP[NE] @pts_choose
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pts_choose
MOVI r1,#SK_TYPE
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @pts_choose
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_TY_ID
CALL @p_adv
LD r1,r0,#W_TY_ID
JMP @pts_ret
pts_choose:
LD r1,r0,#W_TVOID
CMP r1,r0
JMP[EQ] @pts_notvoid
MOVI r1,#T_VOID
JMP @pts_ret
pts_notvoid:
LD r1,r0,#W_TFLOAT
MOVI r2,1
CMP r1,r2
JMP[NE] @pts_notf1
MOVI r1,#T_FLOAT
JMP @pts_ret
pts_notf1:
MOVI r2,2
CMP r1,r2
JMP[NE] @pts_notf2
MOVI r1,#T_DOUBLE
JMP @pts_ret
pts_notf2:
LD r1,r0,#W_TCHAR
CMP r1,r0
JMP[EQ] @pts_notchar
LD r1,r0,#W_TSIGN
MOVI r2,2
CMP r1,r2
JMP[EQ] @pts_uchar
MOVI r1,#T_CHAR
JMP @pts_ret
pts_uchar:
MOVI r1,#T_UCHAR
JMP @pts_ret
pts_notchar:
LD r1,r0,#W_TSHORT
CMP r1,r0
JMP[EQ] @pts_notshort
LD r1,r0,#W_TSIGN
MOVI r2,2
CMP r1,r2
JMP[EQ] @pts_ushort
MOVI r1,#T_SHORT
JMP @pts_ret
pts_ushort:
MOVI r1,#T_USHORT
JMP @pts_ret
pts_notshort:
LD r1,r0,#W_TLONG
CMP r1,r0
JMP[EQ] @pts_notlong
LD r1,r0,#W_TSIGN
MOVI r2,2
CMP r1,r2
JMP[EQ] @pts_ulong
MOVI r1,#T_LONG
JMP @pts_ret
pts_ulong:
MOVI r1,#T_ULONG
JMP @pts_ret
pts_notlong:
LD r1,r0,#W_TSIGN
MOVI r2,2
CMP r1,r2
JMP[EQ] @pts_uint
MOVI r1,#T_INT
JMP @pts_ret
pts_uint:
MOVI r1,#T_UINT
pts_ret:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_ptr_suffix: r1=base -> type with all leading '*' applied
p_ptr_suffix:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
pps_l:
MOVI r1,#P_STAR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pps_d
CALL @p_adv
pps_q:
MOVI r1,#KW_CONST
CALL @p_at_k
CMP r1,r0
JMP[NE] @pps_qadv
MOVI r1,#KW_VOLATILE
CALL @p_at_k
CMP r1,r0
JMP[EQ] @pps_go
pps_qadv:
CALL @p_adv
JMP @pps_q
pps_go:
LD r1,r0,#R_T0
CALL @ty_ptr
ST r1,r0,#R_T0
JMP @pps_l
pps_d:
LD r1,r0,#R_T0
SUB r14,r14,r13
LD r15,r14,0
RET

; p_enum_spec
p_enum_spec:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pes_body
CALL @p_adv
pes_body:
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pes_done
CALL @p_adv
ST r0,r0,#W_ENUMVAL
pes_l:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pes_name
MOVI r1,63
CALL @p_err
pes_name:
MOVI r1,#SK_ENUM
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_ENUMVAL
ST r1,r0,#W_TY_ID
MOVI r1,#P_ASSIGN
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pes_noval
CALL @p_cexpr
ST r1,r0,#W_TY_ID
JMP @pes_set
pes_noval:
LD r1,r0,#W_TY_ID
ADD r1,r1,r13
ST r1,r0,#W_TY_ID
pes_set:
LD r1,r0,#W_TY_ID
ST r1,r0,#W_ENUMVAL
SUB r14,r14,r13
LD r1,r14,0
CALL @sym_entry
LD r2,r0,#W_TY_ID
ST r2,r1,#SY_AUX
MOVI r2,#T_INT
ST r2,r1,#SY_TYPE
MOVI r2,4
ST r2,r1,#SY_SIZE
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pes_l
MOVI r1,#P_RBRACE
MOVI r2,64
CALL @p_expect_p
pes_done:
MOVI r1,#T_INT
SUB r14,r14,r13
LD r15,r14,0
RET

; p_struct_spec: r1=TY_STRUCT/TY_UNION -> type id (full parser below)
; p_struct_spec: r1=TY_STRUCT/TY_UNION -> type id
; p_struct_spec: r1=TY_STRUCT/TY_UNION -> type id
p_struct_spec:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_STRUCTKIND
ST r0,r0,#W_STRUCTID
ST r0,r0,#W_STAG
CALL @p_adv
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pss_tag_done
MOVI r1,#SK_TYPE
CALL @sym_get_cur
ST r1,r0,#W_STAG
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_STRUCTID
CALL @p_adv
pss_tag_done:
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pss_no_body
; create the type if the tag did not already have one
LD r1,r0,#W_STRUCTID
CMP r1,r0
JMP[NE] @pss_have_type
LD r1,r0,#W_STRUCTKIND
CALL @ty_struct
ST r1,r0,#W_STRUCTID
LD r2,r0,#W_STAG
CMP r2,r0
JMP[EQ] @pss_have_type
ADD r1,r2,r0
CALL @sym_entry
LD r2,r0,#W_STRUCTID
ST r2,r1,#SY_TYPE
pss_have_type:
LD r1,r0,#W_STRUCTID
CALL @ty_addr
ST r0,r1,#TY_SIZE
MOVI r2,1
ST r2,r1,#TY_ALIGN
LD r2,r0,#W_MEMBP
ST r2,r1,#TY_MEM
ST r0,r1,#TY_NMEM
ST r0,r0,#W_SSIZE
MOVI r2,1
ST r2,r0,#W_SALIGN
LD r1,r0,#W_MEMBP
ST r1,r0,#W_SMEM
ST r0,r0,#W_SNMEM
CALL @p_adv
pss_mem_l:
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pss_final
CALL @p_typespec
ST r1,r0,#W_STYPE
pss_mem_one:
LD r1,r0,#W_STYPE
CALL @p_ptr_suffix
ST r1,r0,#W_STYPE
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pss_mem_name
MOVI r1,23
CALL @p_err
pss_mem_name:
MOVI r1,#SK_MEMBER
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_STYPE
CALL @p_array_suffix
ST r1,r0,#W_STYPE
LD r1,r0,#W_STYPE
CALL @ty_size
ST r1,r0,#W_STMP
LD r1,r0,#W_STYPE
CALL @ty_align
ST r1,r0,#W_SOFF
LD r1,r0,#W_STRUCTKIND
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pss_union_mem
; struct: offset = align_up(size, align)
LD r1,r0,#W_SSIZE
LD r2,r0,#W_SOFF
CALL @px_align_up
ST r1,r0,#W_STMP
LD r1,r0,#W_STYPE
CALL @ty_size
ST r1,r0,#W_MSIZE
LD r1,r0,#W_STMP
LD r2,r0,#W_MSIZE
ADD r2,r1,r2
ST r2,r0,#W_SSIZE
; member offset is STMP
JMP @pss_mem_off
pss_union_mem:
MOVI r1,0
ST r1,r0,#W_STMP
LD r1,r0,#W_STYPE
CALL @ty_size
ST r1,r0,#W_MSIZE
LD r2,r0,#W_SSIZE
CMP r1,r2
JMP[LE] @pss_mem_off
ST r1,r0,#W_SSIZE
pss_mem_off:
; max alignment
LD r1,r0,#W_SOFF
LD r2,r0,#W_SALIGN
CMP r1,r2
JMP[LE] @pss_align_ok
ST r1,r0,#W_SALIGN
pss_align_ok:
; table entry [symidx, offset, type, 0]
LD r2,r0,#W_MEMBP
SUB r14,r14,r13
LD r1,r14,0
ST r1,r2,0
LD r1,r0,#W_STMP
ST r1,r2,1
LD r1,r0,#W_STYPE
ST r1,r2,2
ST r0,r2,3
ADDI r2,r2,4
ST r2,r0,#W_MEMBP
LD r1,r0,#W_SNMEM
ADD r1,r1,r13
ST r1,r0,#W_SNMEM
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pss_mem_one
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
JMP @pss_mem_l
pss_final:
CALL @p_adv
LD r1,r0,#W_SSIZE
LD r2,r0,#W_SALIGN
CALL @px_align_up
ST r1,r0,#W_SSIZE
LD r1,r0,#W_STRUCTID
CALL @ty_addr
LD r2,r0,#W_SSIZE
ST r2,r1,#TY_SIZE
LD r2,r0,#W_SALIGN
ST r2,r1,#TY_ALIGN
LD r2,r0,#W_SNMEM
ST r2,r1,#TY_NMEM
LD r1,r0,#W_STRUCTID
JMP @pss_d
pss_no_body:
LD r1,r0,#W_STRUCTID
CMP r1,r0
JMP[NE] @pss_d
LD r1,r0,#W_STRUCTKIND
CALL @ty_struct
ST r1,r0,#W_STRUCTID
LD r2,r0,#W_STAG
CMP r2,r0
JMP[EQ] @pss_d
ADD r1,r2,r0
CALL @sym_entry
LD r2,r0,#W_STRUCTID
ST r2,r1,#SY_TYPE
LD r1,r0,#W_STRUCTID
pss_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_member_lookup:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_ID
CALL @ty_addr
LD r3,r1,#TY_MEM
ST r3,r0,#W_TY_MEM
LD r4,r1,#TY_NMEM
ST r4,r0,#W_TY_COUNT
ST r0,r0,#W_TY_BASE
pml_l:
LD r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_COUNT
CMP r1,r2
JMP[GE] @pml_nf
LD r3,r0,#W_TY_MEM
SHL r4,r1,2
ADD r3,r3,r4
LD r4,r3,0
ST r4,r0,#W_TY_TMP
LD r5,r3,1
ST r5,r0,#W_TY_RET
LD r5,r3,2
ST r5,r0,#W_TY_KIND
LD r1,r0,#W_TY_TMP
CALL @sym_entry
LD r2,r1,#SY_HASH
LD r3,r0,#W_TKA+2
CMP r2,r3
JMP[NE] @pml_next
LD r2,r1,#SY_LEN
LD r3,r0,#W_TKA+3
CMP r2,r3
JMP[NE] @pml_next
LA r2,#W_TKA+#TK_TEXT
LD r3,r0,#W_TKA+3
CALL @sym_name_eq
CMP r1,r0
JMP[EQ] @pml_next
LD r1,r0,#W_TY_RET
LD r2,r0,#W_TY_KIND
ST r1,r0,#W_TY_TMP
ST r2,r0,#W_TY_RET
CALL @p_adv
LD r1,r0,#W_TY_TMP
LD r2,r0,#W_TY_RET
JMP @pml_d
pml_next:
LD r1,r0,#W_TY_BASE
ADD r1,r1,r13
ST r1,r0,#W_TY_BASE
JMP @pml_l
pml_nf:
MOVI r1,72
CALL @p_err
pml_d:
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

sym_find_tok:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_SKIND
ST r2,r0,#W_TKPTR
LD r1,r0,#W_SYMUSED
SUB r1,r1,r13
ST r1,r0,#W_SIDX
sft_l:
LD r2,r0,#W_SIDX
CMPS r2,r0
JMP[LT] @sft_n
SHL r3,r2,4
LA r4,#NCC_SYMB
ADD r3,r3,r4
LD r4,r3,#SY_KIND
LD r5,r0,#W_SKIND
CMP r4,r5
JMP[NE] @sft_next
MOVI r5,2
CMP r4,r5
JMP[NE] @sft_noscope
LD r5,r3,#SY_SCOPE
LD r6,r0,#W_SCOPEID
sft_walk:
CMP r5,r6
JMP[EQ] @sft_noscope
CMP r6,r0
JMP[EQ] @sft_next
LA r7,#W_SCOPEPAR
ADD r7,r7,r6
LD r6,r7,0
JMP @sft_walk
sft_noscope:
MOVI r5,2
CMP r4,r5
JMP[EQ] @sft_owner
MOVI r5,6
CMP r4,r5
JMP[NE] @sft_hash
sft_owner:
LD r4,r3,#SY_NP
LD r5,r0,#W_FUNCSYM
CMP r4,r5
JMP[NE] @sft_next
sft_hash:
LD r5,r0,#W_TKPTR
LD r4,r3,#SY_HASH
LD r6,r5,#TK_HASH
CMP r4,r6
JMP[NE] @sft_next
ADD r1,r3,r0
ADDI r2,r5,#TK_TEXT
LD r3,r5,#TK_LEN
CALL @sym_name_eq
CMP r1,r0
JMP[EQ] @sft_next
LD r1,r0,#W_SIDX
JMP @sft_d
sft_next:
LD r2,r0,#W_SIDX
SUB r2,r2,r13
ST r2,r0,#W_SIDX
JMP @sft_l
sft_n:
MOVI r1,0xFFFF
SHL r1,r1,16
ADDI r1,r1,-1
sft_d:
SUB r14,r14,r13
LD r15,r14,0
RET

sym_find_cur:
LA r2,#W_TKA
JMP @sym_find_tok

; sym_get_cur: r1=kind -> r1=index, creating the entry if missing.
sym_get_cur:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
LD r3,r0,#W_FORCENEW
CMP r3,r0
JMP[EQ] @sgc_find
ST r0,r0,#W_FORCENEW
JMP @sgc_create
sgc_find:
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @sgc_d
sgc_create:
; create
LD r1,r0,#W_SYMUSED
ST r1,r0,#R_T1
LA r2,#NCC_SYMENTRIES
CMP r1,r2
JMP[LT] @sgc_room
MOVI r1,2
JMP @ncc_err
sgc_room:
SHL r2,r1,4
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
ST r0,r3,#SY_TYPE
ST r0,r3,#SY_ARG
ST r0,r3,#SY_OFF
ST r0,r3,#SY_SIZE
ST r0,r3,#SY_CLS
ST r0,r3,#SY_USED
LD r4,r0,#W_SCOPEID
ST r4,r3,#SY_SCOPE
LD r4,r0,#R_T0
MOVI r5,2
CMP r4,r5
JMP[EQ] @sgc_own
MOVI r5,6
CMP r4,r5
JMP[NE] @sgc_noown
sgc_own:
LD r5,r0,#W_FUNCSYM
ST r5,r3,#SY_NP
sgc_noown:
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

; sym_new_cur: r1=kind -> always create a fresh entry
sym_new_cur:
MOVI r2,1
ST r2,r0,#W_FORCENEW
JMP @sym_get_cur

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
SHL r1,r1,4
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
SHL r3,r2,4
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
MOVI r1,#T_VOID
CALL @ty_ptr
ST r1,r0,#W_PTRV
MOVI r1,#T_CHAR
CALL @ty_ptr
ST r1,r0,#W_PTRC
; putchar
LA r1,0x15026602
LA r2,@ncc_s_putchar
MOVI r3,7
MOVI r4,#B_PUTCHAR
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; print_int
LA r1,0xE4983C0E
LA r2,@ncc_s_printint
MOVI r3,9
MOVI r4,#B_PRINTINT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; puts
LA r1,0x9C67D227
LA r2,@ncc_s_puts
MOVI r3,4
MOVI r4,#B_PUTS
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; print_hex
LA r1,0x4CC3F73A
LA r2,@ncc_s_printhex
MOVI r3,9
MOVI r4,#B_HEX
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; print_str
LA r1,0x70BB0C00
LA r2,@ncc_s_printstr
MOVI r3,9
MOVI r4,#B_PUTSTR
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; printf
LA r1,0xE76FB4AA
LA r2,@ncc_s_printf
MOVI r3,6
MOVI r4,#B_PRINTF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
; malloc
LA r1,0x558C274D
LA r2,@ncc_s_malloc
MOVI r3,6
MOVI r4,#B_MALLOC
MOVI r5,1
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; free
LA r1,0x99B3EEDB
LA r2,@ncc_s_free
MOVI r3,4
MOVI r4,#B_FREE
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; calloc
LA r1,0x73E20203
LA r2,@ncc_s_calloc
MOVI r3,6
MOVI r4,#B_CALLOC
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; realloc
LA r1,0xBF26B345
LA r2,@ncc_s_realloc
MOVI r3,7
MOVI r4,#B_REALLOC
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; strlen
LA r1,0x58BA3D97
LA r2,@ncc_s_strlen
MOVI r3,6
MOVI r4,#B_STRLEN
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; strcmp
LA r1,0x9D367094
LA r2,@ncc_s_strcmp
MOVI r3,6
MOVI r4,#B_STRCMP
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
; strncmp
LA r1,0x9DE3C256
LA r2,@ncc_s_strncmp
MOVI r3,7
MOVI r4,#B_STRNCMP
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
; strcpy
LA r1,0x926A3AA6
LA r2,@ncc_s_strcpy
MOVI r3,6
MOVI r4,#B_STRCPY
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
; strncpy
LA r1,0xA2C986B8
LA r2,@ncc_s_strncpy
MOVI r3,7
MOVI r4,#B_STRNCPY
MOVI r5,3
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
; strcat
LA r1,0x9940F7A4
LA r2,@ncc_s_strcat
MOVI r3,6
MOVI r4,#B_STRCAT
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
; memcpy
LA r1,0xA45CEC64
LA r2,@ncc_s_memcpy
MOVI r3,6
MOVI r4,#B_MEMCPY
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; memset
LA r1,0xCB80CC06
LA r2,@ncc_s_memset
MOVI r3,6
MOVI r4,#B_MEMSET
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; memcmp
LA r1,0xAF3CAA0A
LA r2,@ncc_s_memcmp
MOVI r3,6
MOVI r4,#B_MEMCMP
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
; atoi
LA r1,0x07744F24
LA r2,@ncc_s_atoi
MOVI r3,4
MOVI r4,#B_ATOI
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; abs
LA r1,0x2A48023B
LA r2,@ncc_s_abs
MOVI r3,3
MOVI r4,#B_ABS
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; sin
LA r1,0xE0302A4D
LA r2,@ncc_s_sin
MOVI r3,3
MOVI r4,#B_SIN
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; cos
LA r1,0xFB8DE29C
LA r2,@ncc_s_cos
MOVI r3,3
MOVI r4,#B_COS
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; exit
LA r1,0xCDED1A85
LA r2,@ncc_s_exit
MOVI r3,4
MOVI r4,#B_EXIT
MOVI r5,1
MOVI r6,#T_INT
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
ST r6,r0,#W_BRET
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
LD r5,r0,#W_BRET
ST r5,r1,#SY_TYPE
ST r0,r1,#SY_ARG
ST r0,r1,#SY_SIZE
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
ncc_s_printf:
.str "printf"
ncc_s_malloc:
.str "malloc"
ncc_s_free:
.str "free"
ncc_s_calloc:
.str "calloc"
ncc_s_realloc:
.str "realloc"
ncc_s_strlen:
.str "strlen"
ncc_s_strcmp:
.str "strcmp"
ncc_s_strncmp:
.str "strncmp"
ncc_s_strcpy:
.str "strcpy"
ncc_s_strncpy:
.str "strncpy"
ncc_s_strcat:
.str "strcat"
ncc_s_memcpy:
.str "memcpy"
ncc_s_memset:
.str "memset"
ncc_s_memcmp:
.str "memcmp"
ncc_s_atoi:
.str "atoi"
ncc_s_abs:
.str "abs"
ncc_s_exit:
.str "exit"
ncc_s_sin:
.str "sin"
ncc_s_cos:
.str "cos"

; ================================================================== STRING POOL
; str_add_cur: current K_STRING token -> r1 = byte address of a NUL-terminated
; C string in the read-only byte region (4 chars per NaN word).
str_add_cur:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_STRP
ST r2,r0,#R_T0
LD r3,r0,#W_TKA+3
ADD r3,r3,r13
ADD r4,r2,r3
LA r5,#C_ROEND
CMP r4,r5
JMP[LT] @sac_room
MOVI r1,4
JMP @ncc_err
sac_room:
LA r5,#W_TKA+#TK_TEXT
SHL r5,r5,2
LD r6,r0,#W_TKA+3
MOVI r7,0
sac_l:
CMP r7,r6
JMP[GE] @sac_end
LDB r1,r5,0
STB r1,r2,0
ADD r5,r5,r13
ADD r2,r2,r13
ADD r7,r7,r13
JMP @sac_l
sac_end:
STB r0,r2,0
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
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pcu_bad
MOVI r1,#SK_ENUM
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @pcu_bad
CALL @sym_entry
LD r2,r1,#SY_AUX
ST r2,r0,#W_TMP
CALL @p_adv
LD r1,r0,#W_TMP
JMP @pcu_d
pcu_bad:
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
; Lvalue convention: W_LVAL=1 means a byte address is on the eval stack and
; W_LTYPE is the object type. p_emit_rv loads it (or decays an array).
p_emit_rv:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[EQ] @per_done
LD r1,r0,#W_LTYPE
CALL @ty_kind
ST r1,r0,#W_TY_TMP
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @per_array
MOVI r2,#TY_FUNC
CMP r1,r2
JMP[EQ] @per_func
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @per_struct
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @per_struct
LD r1,r0,#W_LTYPE
CALL @px_emit_load
LD r1,r0,#W_LTYPE
CALL @px_promote
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @per_done
per_array:
LD r1,r0,#W_LTYPE
CALL @ty_base
CALL @ty_ptr
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @per_done
per_func:
LD r1,r0,#W_LTYPE
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @per_done
per_struct:
MOVI r1,65
CALL @p_err
per_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_emit_load: r1=type -> emit I_LOAD
px_emit_load:
ST r15,r14,0
ADD r14,r14,r13
CALL @ty_store_code
ADD r2,r1,r0
LA r1,#I_LOAD
CALL @ir_emit
SUB r14,r14,r13
LD r15,r14,0
RET
; px_emit_store: r1=type r2=keep -> emit I_STORE/I_STORE_K
px_emit_store:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#W_TY_COUNT
CALL @ty_store_code
ADD r2,r1,r0
LD r3,r0,#W_TY_COUNT
CMP r3,r0
JMP[EQ] @pxs_plain
LA r1,#I_STORE_K
JMP @pxs_go
pxs_plain:
LA r1,#I_STORE
pxs_go:
CALL @ir_emit
SUB r14,r14,r13
LD r15,r14,0
RET
; px_addr_g: r1=absolute byte address
px_addr_g:
ADD r2,r1,r0
LA r1,#I_GADDR
JMP @ir_emit
; px_addr_l: r1=byte offset from fp
px_addr_l:
ADD r2,r1,r0
LA r1,#I_LADDR
JMP @ir_emit

; px_promote: r1=type -> r1 promoted integer type
px_promote:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
CALL @ty_size
MOVI r2,4
CMP r1,r2
JMP[GE] @pxp_same
LD r1,r0,#W_TY_TMP
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pxp_uint
MOVI r1,#T_INT
JMP @pxp_d
pxp_uint:
MOVI r1,#T_UINT
JMP @pxp_d
pxp_same:
LD r1,r0,#W_TY_TMP
pxp_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_cast_code: r1=type -> r1=cast/load code
px_cast_code:
JMP @ty_store_code

; px_cast_stack: r1=target type, value on eval stack, W_ETYPE=source
px_cast_stack:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_ID
LD r2,r0,#W_ETYPE
CMP r1,r2
JMP[EQ] @pxc_done
LD r1,r0,#W_ETYPE
CALL @ty_kind
ST r1,r0,#W_TY_KIND
LD r1,r0,#W_TY_ID
CALL @ty_kind
ST r1,r0,#W_TY_BASE
MOVI r2,#TY_FLOAT
LD r1,r0,#W_TY_KIND
CMP r1,r2
JMP[NE] @pxc_notfromf
LD r1,r0,#W_TY_BASE
CMP r1,r2
JMP[EQ] @pxc_codes
MOVI r2,6
JMP @pxc_emit
pxc_notfromf:
LD r1,r0,#W_TY_BASE
CMP r1,r2
JMP[NE] @pxc_codes
MOVI r2,5
JMP @pxc_emit
pxc_codes:
LD r1,r0,#W_ETYPE
CALL @ty_store_code
ST r1,r0,#W_TY_KIND
LD r1,r0,#W_TY_ID
CALL @ty_store_code
LD r2,r0,#W_TY_KIND
CMP r1,r2
JMP[EQ] @pxc_done
ADD r2,r1,r0
pxc_emit:
LA r1,#I_CAST
CALL @ir_emit
pxc_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_step_size: r1=type -> increment size (pointer target size, else object size)
px_step_size:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[NE] @pxs_obj
LD r1,r0,#W_TY_TMP
CALL @ty_base
CALL @ty_size
JMP @pxs_d
pxs_obj:
LD r1,r0,#W_TY_TMP
CALL @ty_size
pxs_d:
SUB r14,r14,r13
LD r15,r14,0
RET
; px_inc_step: r1=type -> 1 for arithmetic, element size for pointers
px_inc_step:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[NE] @pxis_one
LD r1,r0,#W_TY_TMP
CALL @ty_base
CALL @ty_size
JMP @pxis_d
pxis_one:
MOVI r1,1
pxis_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ primary
p_primary:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_INT
CMP r1,r2
JMP[EQ] @pp_lit
MOVI r2,#K_CHAR
CMP r1,r2
JMP[EQ] @pp_lit
MOVI r2,#K_FLOAT
CMP r1,r2
JMP[EQ] @pp_flit
MOVI r2,#K_STRING
CMP r1,r2
JMP[EQ] @pp_string
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pp_ident
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[EQ] @pp_punct
MOVI r1,5
CALL @p_err
pp_lit:
LD r2,r0,#W_TKA+1
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_flit:
LD r2,r0,#W_TKA+1
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_FLOAT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_string:
CALL @str_add_cur
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_CHAR
CALL @ty_ptr
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_ident:
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pp_ident_var
LD r1,r0,#W_TKB+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pp_call
pp_ident_var:
MOVI r1,#SK_ENUM
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @pp_try_var
CALL @sym_entry
LD r2,r1,#SY_AUX
ADD r2,r2,r0
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_try_var:
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
LD r4,r1,#SY_TYPE
LD r5,r1,#SY_CLS
ST r4,r0,#W_LTYPE
ST r4,r0,#W_ETYPE
MOVI r6,#SK_GLOBAL
CMP r2,r6
JMP[EQ] @pp_var_global
MOVI r6,1
CMP r5,r6
JMP[EQ] @pp_var_global
ADD r1,r3,r0
CALL @px_addr_l
JMP @pp_var_set
pp_var_global:
ADD r1,r3,r0
CALL @px_addr_g
pp_var_set:
MOVI r1,1
ST r1,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_call:
MOVI r1,#SK_FUNC
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @pp_call_found
MOVI r1,#SK_BUILTIN
CALL @sym_find_cur
pp_call_found:
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
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
ST r0,r14,0
ADD r14,r14,r13
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
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_ETYPE
ADDI r14,r14,-2
ST r0,r0,#W_LVAL
JMP @pp_done
pp_punct:
LD r1,r0,#W_TKA+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pp_paren
MOVI r1,7
CALL @p_err
pp_paren:
CALL @p_peek
LA r1,#W_TKB
CALL @p_tok_is_type
CMP r1,r0
JMP[EQ] @pp_paren_expr
CALL @p_adv
CALL @p_typespec
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
ST r1,r0,#W_TY_SIGN
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
CALL @p_unary
CALL @p_emit_rv
LD r1,r0,#W_TY_SIGN
CALL @px_cast_stack
LD r1,r0,#W_TY_SIGN
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done
pp_paren_expr:
CALL @p_adv
CALL @p_expr
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
JMP @pp_done
pp_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ postfix
p_postfix:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_primary
pxf_loop:
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pxf_member
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[EQ] @pxf_idx_ok
MOVI r1,67
CALL @p_err
pxf_idx_ok:
LD r1,r0,#W_ETYPE
CALL @ty_base
ST r1,r0,#W_TY_ID
ST r1,r0,#W_IDXTYPE
CALL @p_adv
CALL @p_expr
CALL @p_emit_rv
MOVI r1,#P_RBRACK
MOVI r2,33
CALL @p_expect_p
LD r1,r0,#W_IDXTYPE
CALL @ty_size
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_MUL
CALL @ir_op
LA r1,#I_ADD
CALL @ir_op
LD r1,r0,#W_IDXTYPE
ST r1,r0,#W_LTYPE
ST r1,r0,#W_ETYPE
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pxf_loop
pxf_member:
MOVI r1,#P_DOT
CALL @p_at_p
CMP r1,r0
JMP[NE] @pxf_dot
MOVI r1,#P_ARROW
CALL @p_at_p
CMP r1,r0
JMP[NE] @pxf_arrow
JMP @pxf_inc
pxf_dot:
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pxf_dot_ok
MOVI r1,34
CALL @p_err
pxf_dot_ok:
CALL @p_adv
LD r1,r0,#W_LTYPE
CALL @p_member_lookup
ST r2,r0,#W_TY_ID
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_ADD
CALL @ir_op
LD r1,r0,#W_TY_ID
ST r1,r0,#W_LTYPE
ST r1,r0,#W_ETYPE
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pxf_loop
pxf_arrow:
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[EQ] @pxf_arrow_ok
MOVI r1,68
CALL @p_err
pxf_arrow_ok:
LD r1,r0,#W_ETYPE
CALL @ty_base
ST r1,r0,#W_TY_TMP
CALL @p_adv
LD r1,r0,#W_TY_TMP
CALL @p_member_lookup
ST r2,r0,#W_TY_ID
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_ADD
CALL @ir_op
LD r1,r0,#W_TY_ID
ST r1,r0,#W_LTYPE
ST r1,r0,#W_ETYPE
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pxf_loop
pxf_inc:
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[EQ] @pxf_done
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pxf_done
LD r1,r0,#W_TKA+1
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pxf_go
MOVI r2,#P_DEC
CMP r1,r2
JMP[NE] @pxf_done
pxf_go:
LD r1,r0,#W_TKA+1
ST r1,r0,#W_TY_RET
LD r1,r0,#W_LTYPE
ST r1,r0,#W_TY_ID
CALL @px_inc_step
ST r1,r0,#W_TY_COUNT
ADD r2,r1,r0
LA r1,#I_DUP
CALL @ir_op
LD r1,r0,#W_TY_ID
CALL @px_emit_load
LA r1,#I_PUSH
LD r2,r0,#W_TY_COUNT
CALL @ir_emit
LD r1,r0,#W_TY_RET
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pxf_add
LA r1,#I_SUB
JMP @pxf_op
pxf_add:
LA r1,#I_ADD
pxf_op:
CALL @ir_op
LD r1,r0,#W_TY_ID
MOVI r2,1
CALL @px_emit_store
; recover the old value from new
LA r1,#I_PUSH
LD r2,r0,#W_TY_COUNT
CALL @ir_emit
LD r1,r0,#W_TY_RET
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pxf_old
LA r1,#I_ADD
CALL @ir_op
JMP @pxf_old_done
pxf_old:
LA r1,#I_SUB
CALL @ir_op
pxf_old_done:
LD r1,r0,#W_TY_ID
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pxf_loop
pxf_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ unary
p_unary:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @pu_ptr
LD r1,r0,#W_TKA+1
MOVI r2,#KW_SIZEOF
CMP r1,r2
JMP[EQ] @pu_sizeof
JMP @pu_post
pu_ptr:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
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
LD r1,r0,#W_ETYPE
CALL @px_promote
ST r1,r0,#W_ETYPE
JMP @pu_done
pu_minus:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_FLOAT
CMP r1,r2
JMP[NE] @pu_minus_int
LA r1,#I_FNEG
CALL @ir_op
JMP @pu_done
pu_minus_int:
LD r1,r0,#W_ETYPE
CALL @px_promote
ST r1,r0,#W_ETYPE
LA r1,#I_NEG
CALL @ir_op
JMP @pu_done
pu_lnot:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
LA r1,#I_LNOT
CALL @ir_op
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
JMP @pu_done
pu_not:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @px_promote
ST r1,r0,#W_ETYPE
LA r1,#I_NOT
CALL @ir_op
JMP @pu_done
pu_addr:
CALL @p_adv
CALL @p_unary
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pu_addr_ok
MOVI r1,34
CALL @p_err
pu_addr_ok:
LD r1,r0,#W_LTYPE
CALL @ty_ptr
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pu_done
pu_deref:
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[EQ] @pu_deref_ok
MOVI r1,68
CALL @p_err
pu_deref_ok:
LD r1,r0,#W_ETYPE
CALL @ty_base
ST r1,r0,#W_LTYPE
ST r1,r0,#W_ETYPE
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pu_done
pu_sizeof:
CALL @p_adv
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pu_sz_simple
LD r1,r0,#W_TKA+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[NE] @pu_sz_simple
CALL @p_peek
LA r1,#W_TKB
CALL @p_tok_is_type
CMP r1,r0
JMP[EQ] @pu_sz_paren_name
CALL @p_adv
CALL @p_typespec
CALL @p_ptr_suffix
CALL @ty_size
ST r1,r0,#W_TY_ID
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
JMP @pu_sz_push
pu_sz_paren_name:
LD r1,r0,#W_TKB
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pu_sz_expr
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
CALL @p_sizeof_name
ST r1,r0,#W_TY_ID
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
JMP @pu_sz_push
pu_sz_paren_expr:
CALL @p_unary
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @ty_size
ST r1,r0,#W_TY_ID
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LA r1,#I_POP
CALL @ir_op
JMP @pu_sz_push
pu_sz_simple:
CALL @p_is_type
CMP r1,r0
JMP[EQ] @pu_sz_ident
CALL @p_typespec
CALL @p_ptr_suffix
CALL @ty_size
ST r1,r0,#W_TY_ID
JMP @pu_sz_push
pu_sz_ident:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pu_sz_expr
CALL @p_sizeof_name
ST r1,r0,#W_TY_ID
JMP @pu_sz_push
pu_sz_expr:
CALL @p_unary
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @ty_size
ST r1,r0,#W_TY_ID
LA r1,#I_POP
CALL @ir_op
pu_sz_push:
LD r2,r0,#W_TY_ID
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_UINT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pu_done

; p_sizeof_name: current identifier -> r1 = object type size; consumes it
p_sizeof_name:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @psn_one
CALL @sym_lookup_var
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @psn_one
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_size
ST r1,r0,#W_TY_ID
CALL @p_adv
LD r1,r0,#W_TY_ID
JMP @psn_d
psn_one:
MOVI r1,1
psn_d:
SUB r14,r14,r13
LD r15,r14,0
RET

pu_incdec:
CALL @p_adv
CALL @p_unary
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pu_inc_ok
MOVI r1,11
CALL @p_err
pu_inc_ok:
LD r1,r0,#W_TKA+1
ST r1,r0,#W_TY_RET
LD r1,r0,#W_LTYPE
ST r1,r0,#W_TY_ID
CALL @px_inc_step
ADD r2,r1,r0
LA r1,#I_DUP
CALL @ir_op
LD r1,r0,#W_TY_ID
CALL @px_emit_load
LA r1,#I_PUSH
LD r2,r0,#W_TY_COUNT
CALL @ir_emit
LD r1,r0,#W_TY_RET
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pu_inc_add
LA r1,#I_SUB
JMP @pu_inc_op
pu_inc_add:
LA r1,#I_ADD
pu_inc_op:
CALL @ir_op
LD r1,r0,#W_TY_ID
MOVI r2,1
CALL @px_emit_store
LD r1,r0,#W_TY_ID
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pu_done
pu_post:
CALL @p_postfix
pu_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ binary
; p_binop: r1=bin kind, r2=left type, r3=right type; stack [left,right].
p_binop:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ADD r14,r14,r13
ST r2,r14,0
ADD r14,r14,r13
ST r3,r14,0
ADD r14,r14,r13
ADDI r3,r14,-2
LD r1,r3,0
CALL @ty_kind
ST r1,r0,#W_TY_KIND
ADDI r3,r14,-1
LD r1,r3,0
CALL @ty_kind
ST r1,r0,#W_TY_COUNT
MOVI r2,#TY_PTR
LD r1,r0,#W_TY_KIND
CMP r1,r2
JMP[EQ] @pb_lptr
LD r1,r0,#W_TY_COUNT
CMP r1,r2
JMP[EQ] @pb_rptr
JMP @pb_scalar
pb_lptr:
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#BIN_ADD
CMP r1,r2
JMP[EQ] @pb_pl_add
MOVI r2,#BIN_SUB
CMP r1,r2
JMP[EQ] @pb_pl_sub
JMP @pb_cmp_emit
pb_pl_add:
ADDI r3,r14,-2
LD r1,r3,0
CALL @px_step_size
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_MUL
CALL @ir_op
LA r1,#I_ADD
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_pl_sub:
MOVI r2,#TY_PTR
LD r1,r0,#W_TY_COUNT
CMP r1,r2
JMP[EQ] @pb_pp_diff
ADDI r3,r14,-2
LD r1,r3,0
CALL @px_step_size
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_MUL
CALL @ir_op
LA r1,#I_SUB
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_pp_diff:
LA r1,#I_SUB
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
CALL @px_step_size
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_DIV
CALL @ir_op
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_rptr:
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#BIN_ADD
CMP r1,r2
JMP[EQ] @pb_rp_add
MOVI r1,69
CALL @p_err
pb_rp_add:
LA r1,#I_SWAP
CALL @ir_op
ADDI r3,r14,-1
LD r1,r3,0
CALL @px_step_size
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_MUL
CALL @ir_op
LA r1,#I_ADD
CALL @ir_op
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_scalar:
MOVI r2,#TY_FLOAT
LD r1,r0,#W_TY_KIND
CMP r1,r2
JMP[EQ] @pb_float
LD r1,r0,#W_TY_COUNT
CMP r1,r2
JMP[EQ] @pb_float
ADDI r3,r14,-2
LD r1,r3,0
ADDI r3,r14,-1
LD r2,r3,0
CALL @ty_common
ST r1,r0,#W_TY_RET
LA r1,#I_SWAP
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
ST r1,r0,#W_ETYPE
LD r1,r0,#W_TY_RET
CALL @px_cast_stack
LA r1,#I_SWAP
CALL @ir_op
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_ETYPE
LD r1,r0,#W_TY_RET
CALL @px_cast_stack
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#BIN_ADD
CMP r1,r2
JMP[EQ] @pb_i_add
MOVI r2,#BIN_SUB
CMP r1,r2
JMP[EQ] @pb_i_sub
MOVI r2,#BIN_MUL
CMP r1,r2
JMP[EQ] @pb_i_mul
MOVI r2,#BIN_DIV
CMP r1,r2
JMP[EQ] @pb_i_div
MOVI r2,#BIN_MOD
CMP r1,r2
JMP[EQ] @pb_i_mod
MOVI r2,#BIN_SHL
CMP r1,r2
JMP[EQ] @pb_i_shl
MOVI r2,#BIN_SHR
CMP r1,r2
JMP[EQ] @pb_i_shr
MOVI r2,#BIN_AND
CMP r1,r2
JMP[EQ] @pb_i_and
MOVI r2,#BIN_OR
CMP r1,r2
JMP[EQ] @pb_i_or
MOVI r2,#BIN_XOR
CMP r1,r2
JMP[EQ] @pb_i_xor
JMP @pb_cmp_emit
pb_i_add:
LA r1,#I_ADD
JMP @pb_i_emit
pb_i_sub:
LA r1,#I_SUB
JMP @pb_i_emit
pb_i_mul:
LA r1,#I_MUL
JMP @pb_i_emit
pb_i_div:
LD r1,r0,#W_TY_RET
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pb_i_divu
LA r1,#I_DIV
JMP @pb_i_emit
pb_i_divu:
LA r1,#I_DIVU
JMP @pb_i_emit
pb_i_mod:
LD r1,r0,#W_TY_RET
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pb_i_modu
LA r1,#I_MOD
JMP @pb_i_emit
pb_i_modu:
LA r1,#I_MODU
JMP @pb_i_emit
pb_i_shl:
LA r1,#I_SHL
JMP @pb_i_emit
pb_i_shr:
ADDI r3,r14,-2
LD r1,r3,0
CALL @px_promote
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pb_i_shru
LA r1,#I_SHR
JMP @pb_i_emit
pb_i_shru:
LA r1,#I_SHRU
JMP @pb_i_emit
pb_i_and:
LA r1,#I_AND
JMP @pb_i_emit
pb_i_or:
LA r1,#I_OR
JMP @pb_i_emit
pb_i_xor:
LA r1,#I_XOR
JMP @pb_i_emit
pb_i_emit:
CALL @ir_op
LD r1,r0,#W_TY_RET
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_cmp_emit:
MOVI r2,#BIN_EQ
CMP r1,r2
JMP[EQ] @pb_c_eq
MOVI r2,#BIN_NE
CMP r1,r2
JMP[EQ] @pb_c_ne
ADDI r3,r14,-2
LD r1,r3,0
CALL @ty_kind
ST r1,r0,#W_TY_KIND
ADDI r3,r14,-1
LD r1,r3,0
CALL @ty_kind
ST r1,r0,#W_TY_COUNT
MOVI r3,#TY_PTR
CMP r1,r3
JMP[EQ] @pb_c_unsigned
LD r2,r0,#W_TY_KIND
CMP r2,r3
JMP[EQ] @pb_c_unsigned
ADDI r3,r14,-2
LD r1,r3,0
ADDI r3,r14,-1
LD r2,r3,0
CALL @ty_common
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pb_c_unsigned
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#BIN_LT
CMP r1,r2
JMP[EQ] @pb_c_lt
MOVI r2,#BIN_GT
CMP r1,r2
JMP[EQ] @pb_c_gt
MOVI r2,#BIN_LE
CMP r1,r2
JMP[EQ] @pb_c_le
LA r1,#I_GE
JMP @pb_c_go
pb_c_unsigned:
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#BIN_LT
CMP r1,r2
JMP[EQ] @pb_c_ltu
MOVI r2,#BIN_GT
CMP r1,r2
JMP[EQ] @pb_c_gtu
MOVI r2,#BIN_LE
CMP r1,r2
JMP[EQ] @pb_c_leu
LA r1,#I_GEU
JMP @pb_c_go
pb_c_lt:
LA r1,#I_LT
JMP @pb_c_go
pb_c_gt:
LA r1,#I_GT
JMP @pb_c_go
pb_c_le:
LA r1,#I_LE
JMP @pb_c_go
pb_c_ltu:
LA r1,#I_LTU
JMP @pb_c_go
pb_c_gtu:
LA r1,#I_GTU
JMP @pb_c_go
pb_c_leu:
LA r1,#I_LEU
JMP @pb_c_go
pb_c_eq:
LA r1,#I_EQ
JMP @pb_c_go
pb_c_ne:
LA r1,#I_NE
pb_c_go:
CALL @ir_op
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_float:
LA r1,#I_SWAP
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
ST r1,r0,#W_ETYPE
MOVI r1,#T_FLOAT
CALL @px_cast_stack
LA r1,#I_SWAP
CALL @ir_op
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_ETYPE
MOVI r1,#T_FLOAT
CALL @px_cast_stack
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#BIN_ADD
CMP r1,r2
JMP[EQ] @pb_f_add
MOVI r2,#BIN_SUB
CMP r1,r2
JMP[EQ] @pb_f_sub
MOVI r2,#BIN_MUL
CMP r1,r2
JMP[EQ] @pb_f_mul
MOVI r2,#BIN_DIV
CMP r1,r2
JMP[EQ] @pb_f_div
MOVI r2,#BIN_LT
CMP r1,r2
JMP[EQ] @pb_f_lt
MOVI r2,#BIN_GT
CMP r1,r2
JMP[EQ] @pb_f_gt
MOVI r2,#BIN_LE
CMP r1,r2
JMP[EQ] @pb_f_le
MOVI r2,#BIN_GE
CMP r1,r2
JMP[EQ] @pb_f_ge
MOVI r2,#BIN_EQ
CMP r1,r2
JMP[EQ] @pb_f_eq
LA r1,#I_FNE
JMP @pb_f_go
pb_f_add:
LA r1,#I_FADD
JMP @pb_f_arith
pb_f_sub:
LA r1,#I_FSUB
JMP @pb_f_arith
pb_f_mul:
LA r1,#I_FMUL
JMP @pb_f_arith
pb_f_div:
LA r1,#I_FDIV
pb_f_arith:
CALL @ir_op
MOVI r1,#T_FLOAT
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_f_lt:
LA r1,#I_FLT
JMP @pb_f_go
pb_f_gt:
LA r1,#I_FGT
JMP @pb_f_go
pb_f_le:
LA r1,#I_FLE
JMP @pb_f_go
pb_f_ge:
LA r1,#I_FGE
JMP @pb_f_go
pb_f_eq:
LA r1,#I_FEQ
pb_f_go:
CALL @ir_op
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
pb_done:
ADDI r14,r14,-3
SUB r14,r14,r13
LD r15,r14,0
RET

; generic left-associative level macros are written out for clarity
p_mul:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_unary
pmul_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pmul_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_STAR
CMP r1,r2
JMP[EQ] @pml_star
MOVI r2,#P_SLASH
CMP r1,r2
JMP[EQ] @pml_slash
MOVI r2,#P_PCT
CMP r1,r2
JMP[EQ] @pml_pct
JMP @pmul_d
pml_star:
MOVI r1,#BIN_MUL
JMP @pml_go
pml_slash:
MOVI r1,#BIN_DIV
JMP @pml_go
pml_pct:
MOVI r1,#BIN_MOD
pml_go:
ST r1,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_unary
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @pmul_l
pmul_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_add:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_mul
pal_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pal_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_PLUS
CMP r1,r2
JMP[EQ] @pal_plus
MOVI r2,#P_MINUS
CMP r1,r2
JMP[EQ] @pal_minus
JMP @pal_d
pal_plus:
MOVI r1,#BIN_ADD
JMP @pal_go
pal_minus:
MOVI r1,#BIN_SUB
pal_go:
ST r1,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_mul
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @pal_l
pal_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_shift:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_add
psl_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @psl_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_SHL
CMP r1,r2
JMP[EQ] @psl_shl
MOVI r2,#P_SHR
CMP r1,r2
JMP[EQ] @psl_shr
JMP @psl_d
psl_shl:
MOVI r1,#BIN_SHL
JMP @psl_go
psl_shr:
MOVI r1,#BIN_SHR
psl_go:
ST r1,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_add
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @psl_l
psl_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_rel:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_shift
prl_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @prl_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_LT
CMP r1,r2
JMP[EQ] @prl_lt
MOVI r2,#P_GT
CMP r1,r2
JMP[EQ] @prl_gt
MOVI r2,#P_LE
CMP r1,r2
JMP[EQ] @prl_le
MOVI r2,#P_GE
CMP r1,r2
JMP[EQ] @prl_ge
JMP @prl_d
prl_lt:
MOVI r1,#BIN_LT
JMP @prl_go
prl_gt:
MOVI r1,#BIN_GT
JMP @prl_go
prl_le:
MOVI r1,#BIN_LE
JMP @prl_go
prl_ge:
MOVI r1,#BIN_GE
prl_go:
ST r1,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_shift
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @prl_l
prl_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_eq:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_rel
pel_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pel_d
LD r1,r0,#W_TKA+1
MOVI r2,#P_EQ
CMP r1,r2
JMP[EQ] @pel_eq
MOVI r2,#P_NE
CMP r1,r2
JMP[EQ] @pel_ne
JMP @pel_d
pel_eq:
MOVI r1,#BIN_EQ
JMP @pel_go
pel_ne:
MOVI r1,#BIN_NE
pel_go:
ST r1,r14,0
ADD r14,r14,r13
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_rel
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @pel_l
pel_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_band:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_eq
pbal_l:
MOVI r1,#P_AMP
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pbal_d
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
MOVI r1,#BIN_AND
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_eq
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @pbal_l
pbal_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_bxor:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_band
pbxl_l:
MOVI r1,#P_CARET
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pbxl_d
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
MOVI r1,#BIN_XOR
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_band
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @pbxl_l
pbxl_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_bor:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_bxor
pbol_l:
MOVI r1,#P_BAR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pbol_d
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
MOVI r1,#BIN_OR
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_bxor
CALL @p_emit_rv
ADDI r3,r14,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r14,r14,-2
JMP @pbol_l
pbol_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_land:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_bor
pll_l:
MOVI r1,#P_LAND
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pll_d
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
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pll_l
pll_d:
SUB r14,r14,r13
LD r15,r14,0
RET

p_lor:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_land
plol_l:
MOVI r1,#P_LOR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @plol_d
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
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @plol_l
plol_d:
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
LD r1,r0,#W_ETYPE
ST r1,r14,0
ADD r14,r14,r13
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
ADDI r3,r14,-3
LD r1,r3,0
ADD r2,r4,r0
CALL @ir_patch
CALL @p_cond
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[EQ] @pc_ptr
ADDI r3,r14,-2
LD r1,r3,0
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[EQ] @pc_ptr_from_mid
MOVI r1,#T_INT
JMP @pc_set_type
pc_ptr_from_mid:
ADDI r3,r14,-2
LD r1,r3,0
JMP @pc_set_type
pc_ptr:
LD r1,r0,#W_TY_ID
pc_set_type:
ST r1,r0,#W_ETYPE
CALL @ir_here
ADD r4,r1,r0
ADDI r3,r14,-1
LD r1,r3,0
ADD r2,r4,r0
CALL @ir_patch
ADDI r14,r14,-3
ST r0,r0,#W_LVAL
JMP @pc_d
pc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_compop: assignment punct -> BIN kind
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
MOVI r1,#BIN_XOR
RET
pco_add:
MOVI r1,#BIN_ADD
RET
pco_sub:
MOVI r1,#BIN_SUB
RET
pco_mul:
MOVI r1,#BIN_MUL
RET
pco_div:
MOVI r1,#BIN_DIV
RET
pco_mod:
MOVI r1,#BIN_MOD
RET
pco_shl:
MOVI r1,#BIN_SHL
RET
pco_shr:
MOVI r1,#BIN_SHR
RET
pco_and:
MOVI r1,#BIN_AND
RET
pco_or:
MOVI r1,#BIN_OR
RET

; assignment: the lvalue's byte address is on the eval stack
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
LD r1,r0,#W_LTYPE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA+1
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
ADDI r3,r14,-1
LD r1,r3,0
MOVI r2,#P_ASSIGN
CMP r1,r2
JMP[EQ] @pas_simple
; compound: duplicate address, load old, RHS, binop, cast, store-keep
LA r1,#I_DUP
CALL @ir_op
ADDI r3,r14,-2
LD r1,r3,0
CALL @px_emit_load
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-1
LD r1,r3,0
CALL @p_compop
ADDI r3,r14,-2
LD r2,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r3,r14,-2
LD r1,r3,0
CALL @px_cast_stack
ADDI r3,r14,-2
LD r1,r3,0
MOVI r2,1
CALL @px_emit_store
ADDI r14,r14,-2
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pas_d
pas_simple:
LD r1,r0,#W_LTYPE
ST r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pas_struct
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pas_struct
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-2
LD r1,r3,0
CALL @px_cast_stack
ADDI r3,r14,-2
LD r1,r3,0
MOVI r2,1
CALL @px_emit_store
ADDI r14,r14,-2
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pas_d
pas_struct:
ADDI r14,r14,-2
LD r1,r0,#W_TY_ID
CALL @ty_size
ST r1,r0,#W_TY_TMP
CALL @p_cond
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pas_struct_ok
MOVI r1,65
CALL @p_err
pas_struct_ok:
LA r1,#I_PUSH
LD r2,r0,#W_TY_TMP
CALL @ir_emit
LA r1,#I_MEMCPY
CALL @ir_op
LD r1,r0,#W_TY_ID
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pas_d
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
LD r1,r0,#W_SCOPEID
LD r2,r0,#W_NEXTSCOPE
LA r3,#W_SCOPEPAR
ADD r3,r3,r2
ST r1,r3,0
ST r2,r0,#W_SCOPEID
ADD r2,r2,r13
ST r2,r0,#W_NEXTSCOPE
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
LD r1,r0,#W_SCOPEID
LA r2,#W_SCOPEPAR
ADD r2,r2,r1
LD r1,r2,0
ST r1,r0,#W_SCOPEID
SUB r14,r14,r13
LD r15,r14,0
RET

; p_stmt
p_stmt:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pst_typeck
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pst_typeck
LD r1,r0,#W_TKB+1
MOVI r2,#P_COLON
CMP r1,r2
JMP[EQ] @pst_label
pst_typeck:
CALL @p_is_type
CMP r1,r0
JMP[NE] @pst_decl
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
MOVI r2,#KW_SWITCH
CMP r1,r2
JMP[EQ] @pst_switch
MOVI r2,#KW_CASE
CMP r1,r2
JMP[EQ] @pst_case
MOVI r2,#KW_DEFAULT
CMP r1,r2
JMP[EQ] @pst_default
MOVI r2,#KW_GOTO
CMP r1,r2
JMP[EQ] @pst_goto
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
pst_switch:
CALL @p_switch
JMP @pst_d
pst_case:
CALL @p_case
JMP @pst_d
pst_default:
CALL @p_default
JMP @pst_d
pst_goto:
CALL @p_goto
JMP @pst_d
pst_label:
CALL @p_label
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
; px_align_up: r1=value r2=align(1|2|4) -> r1 aligned up
px_align_up:
MOVI r3,1
CMP r2,r3
JMP[EQ] @pxa_d
MOVI r3,2
CMP r2,r3
JMP[EQ] @pxa_2
ADDI r1,r1,3
SHR r1,r1,2
SHL r1,r1,2
RET
pxa_2:
ADDI r1,r1,1
SHR r1,r1,1
SHL r1,r1,1
pxa_d:
RET

; p_array_suffix: r1=element type -> array type (multi-dimensional aware)
p_array_suffix:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
ST r0,r0,#W_ARRND
pasu_l:
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pasu_wrap
CALL @p_adv
MOVI r1,#P_RBRACK
CALL @p_at_p
CMP r1,r0
JMP[NE] @pasu_zero
CALL @p_cexpr
JMP @pasu_get
pasu_zero:
MOVI r1,0
pasu_get:
LD r2,r0,#W_ARRND
MOVI r3,8
CMP r2,r3
JMP[LT] @pasu_room
MOVI r1,70
CALL @p_err
pasu_room:
LA r3,#W_ARRDIM
ADD r3,r3,r2
ST r1,r3,0
ADD r2,r2,r13
ST r2,r0,#W_ARRND
MOVI r1,#P_RBRACK
MOVI r2,33
CALL @p_expect_p
JMP @pasu_l
pasu_wrap:
LD r3,r0,#W_ARRND
SUB r3,r3,r13
ST r3,r0,#W_ARRND
pasu_wl:
LD r3,r0,#W_ARRND
CMPS r3,r0
JMP[LT] @pasu_done
LA r4,#W_ARRDIM
ADD r4,r4,r3
LD r2,r4,0
LD r1,r0,#W_TY_TMP
CALL @ty_array
ST r1,r0,#W_TY_TMP
LD r3,r0,#W_ARRND
SUB r3,r3,r13
ST r3,r0,#W_ARRND
JMP @pasu_wl
pasu_done:
LD r1,r0,#W_TY_TMP
SUB r14,r14,r13
LD r15,r14,0
RET

; p_zero_range: r1=global? r2=address/offset r3=size
p_zero_range:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
ST r2,r0,#W_TY_ID
ST r3,r0,#W_TY_BASE
LD r1,r0,#W_TY_TMP
CMP r1,r0
JMP[EQ] @pzr_local
LD r1,r0,#W_TY_ID
CALL @px_addr_g
JMP @pzr_go
pzr_local:
LD r1,r0,#W_TY_ID
CALL @px_addr_l
pzr_go:
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LA r1,#I_PUSH
LD r2,r0,#W_TY_BASE
CALL @ir_emit
LA r1,#I_MEMSET
CALL @ir_op
SUB r14,r14,r13
LD r15,r14,0
RET

; emit scalar store for a declaration: r1=global? r2=address/offset r3=type
p_decl_store_addr:
ST r15,r14,0
ADD r14,r14,r13
ST r3,r0,#W_TY_ID
CMP r1,r0
JMP[EQ] @pdsa_local
ADD r1,r2,r0
CALL @px_addr_g
JMP @pdsa_go
pdsa_local:
ADD r1,r2,r0
CALL @px_addr_l
pdsa_go:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_struct_init: r1=global flag, r2=base address/offset, r3=type id.
; Current token is '{'. Initialises members in declaration order; unions
; initialise the first member only.
; p_str_init: r1=global flag, r2=base address/offset, r3=char array type,
; current token is a string literal. Zero-fill then copy string bytes.
p_str_init:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_SKIND
ST r2,r0,#W_SSIZE
ST r3,r0,#W_STRUCTID
LD r1,r0,#W_STRUCTID
CALL @ty_base
ST r1,r0,#W_STYPE
LD r1,r0,#W_STRUCTID
CALL @ty_size
ST r1,r0,#W_MSIZE
LD r1,r0,#W_SKIND
LD r2,r0,#W_SSIZE
LD r3,r0,#W_MSIZE
CALL @p_zero_range
LD r1,r0,#W_SKIND
LD r2,r0,#W_SSIZE
LD r3,r0,#W_STYPE
CALL @p_decl_store_addr
LD r1,r0,#W_TKA+3
ST r1,r0,#W_SOFF
CALL @str_add_cur
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LD r3,r0,#W_SOFF
ADD r3,r3,r13
LD r4,r0,#W_MSIZE
CMP r3,r4
JMP[LE] @psti_n
ADD r3,r4,r0
psti_n:
LA r1,#I_PUSH
ADD r2,r3,r0
CALL @ir_emit
LA r1,#I_MEMCPY
CALL @ir_op
CALL @p_adv
SUB r14,r14,r13
LD r15,r14,0
RET

p_struct_init:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_SKIND
ST r2,r0,#W_SSIZE
ST r3,r0,#W_STRUCTID
; zero the whole object first
LD r1,r0,#W_SKIND
LD r2,r0,#W_SSIZE
LD r3,r0,#W_STRUCTID
CALL @ty_size
ADD r3,r1,r0
CALL @p_zero_range
; member table
LD r1,r0,#W_STRUCTID
CALL @ty_addr
LD r2,r1,#TY_MEM
ST r2,r0,#W_SMEM
LD r2,r1,#TY_NMEM
ST r2,r0,#W_SNMEM
ST r0,r0,#W_SALIGN
CALL @p_adv
psi_l:
LD r1,r0,#W_SALIGN
LD r2,r0,#W_SNMEM
CMP r1,r2
JMP[GE] @psi_done
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @psi_done
; member entry: [symidx, offset, type, 0]
LD r2,r0,#W_SMEM
LD r1,r0,#W_SALIGN
SHL r1,r1,2
ADD r2,r2,r1
LD r3,r2,1
ST r3,r0,#W_SOFF
LD r3,r2,2
ST r3,r0,#W_STYPE
LD r2,r0,#W_SSIZE
LD r3,r0,#W_SOFF
ADD r2,r2,r3
LD r1,r0,#W_SKIND
LD r3,r0,#W_STYPE
CALL @p_decl_store_addr
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_STYPE
CALL @px_cast_stack
LD r1,r0,#W_STYPE
MOVI r2,0
CALL @px_emit_store
; union: stop after one member
LD r1,r0,#W_STRUCTID
CALL @ty_addr
LD r2,r1,#TY_KIND
MOVI r3,#TY_UNION
CMP r2,r3
JMP[EQ] @psi_union_done
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[EQ] @psi_done
LD r1,r0,#W_SALIGN
ADD r1,r1,r13
ST r1,r0,#W_SALIGN
JMP @psi_l
psi_union_done:
MOVI r1,#P_COMMA
CALL @p_take_p
psi_done:
MOVI r1,#P_RBRACE
MOVI r2,35
CALL @p_expect_p
SUB r14,r14,r13
LD r15,r14,0
RET


; p_infer_str_array: r1=type. If it is an unsized char array followed by
; '=' and a string literal, return a sized array type; else return r1.
p_infer_str_array:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pisa_orig
LD r1,r0,#W_TY_TMP
CALL @ty_count
CMP r1,r0
JMP[NE] @pisa_orig
MOVI r1,#P_ASSIGN
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pisa_orig
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_STRING
CMP r1,r2
JMP[NE] @pisa_orig
LD r1,r0,#W_TY_TMP
CALL @ty_base
ST r1,r0,#W_TY_ID
CALL @ty_size
MOVI r2,1
CMP r1,r2
JMP[NE] @pisa_orig
LD r2,r0,#W_TKB+3
ADD r2,r2,r13
LD r1,r0,#W_TY_ID
CALL @ty_array
JMP @pisa_d
pisa_orig:
LD r1,r0,#W_TY_TMP
pisa_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; local declarations
p_decl:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_typespec
ST r1,r0,#W_TY_RET
pd_one:
LD r1,r0,#W_TY_RET
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pd_ident
MOVI r1,23
CALL @p_err
pd_ident:
LD r1,r0,#W_SCLASS
MOVI r2,3
CMP r1,r2
JMP[EQ] @pd_typedef
MOVI r1,#SK_LOCAL
CALL @sym_new_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
CALL @p_infer_str_array
ST r1,r0,#W_TY_ID
ST r1,r0,#W_TY_BASE
CALL @ty_size
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_TY_ID
CALL @ty_align
ST r1,r0,#W_TY_COUNT
; allocate
LD r1,r0,#W_SCLASS
MOVI r2,2
CMP r1,r2
JMP[EQ] @pd_extern
MOVI r2,1
CMP r1,r2
JMP[EQ] @pd_static
; auto local
LD r1,r0,#W_LOCALB
LD r2,r0,#W_TY_COUNT
CALL @px_align_up
ST r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_TMP
ADD r2,r1,r2
ST r2,r0,#W_LOCALB
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_BASE
ST r2,r1,#SY_AUX
ST r0,r1,#SY_CLS
JMP @pd_allocd
pd_static:
LD r1,r0,#W_GLOBP
LD r2,r0,#W_TY_COUNT
CALL @px_align_up
ST r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_TMP
ADD r2,r1,r2
LA r3,#C_GLOBEND
CMP r2,r3
JMP[LT] @pd_sroom
MOVI r1,71
CALL @p_err
pd_sroom:
ST r2,r0,#W_GLOBP
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_BASE
ST r2,r1,#SY_AUX
MOVI r2,1
ST r2,r1,#SY_CLS
JMP @pd_allocd
pd_extern:
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
ST r0,r1,#SY_AUX
MOVI r2,2
ST r2,r1,#SY_CLS
pd_allocd:
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_ID
ST r2,r1,#SY_TYPE
LD r2,r0,#W_TY_TMP
ST r2,r1,#SY_SIZE
; initializer
MOVI r1,#P_ASSIGN
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pd_noinit
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pd_not_str
LD r1,r0,#W_TY_ID
CALL @ty_base
CALL @ty_size
MOVI r2,1
CMP r1,r2
JMP[NE] @pd_not_str
LD r1,r0,#W_TKA
MOVI r2,#K_STRING
CMP r1,r2
JMP[NE] @pd_not_str
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
MOVI r1,0
CALL @p_str_init
JMP @pd_afterinit
pd_not_str:
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pd_struct_init
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pd_struct_init
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pd_scalar_init
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pd_scalar_init
; zero the array then fill the brace list
LD r1,r0,#W_SCLASS
MOVI r2,1
CMP r1,r2
JMP[EQ] @pd_arr_static
ST r0,r0,#W_TY_SIGN
JMP @pd_arr_zero
pd_arr_static:
MOVI r1,1
ST r1,r0,#W_TY_SIGN
pd_arr_zero:
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_SIZE
LD r1,r0,#W_TY_SIGN
CALL @p_zero_range
CALL @p_adv
MOVI r1,0
ST r1,r14,0
ADD r14,r14,r13
pd_ai_l:
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pd_ai_done
; element type and size from the array symbol
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_RET
CALL @ty_size
ADDI r3,r14,-1
LD r4,r3,0
MUL r4,r4,r1
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
ADD r2,r2,r4
LD r1,r0,#W_SCLASS
MOVI r3,1
CMP r1,r3
JMP[EQ] @pd_ai_g
MOVI r1,0
CALL @p_decl_store_addr
JMP @pd_ai_val
pd_ai_g:
MOVI r1,1
CALL @p_decl_store_addr
pd_ai_val:
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_RET
LD r1,r0,#W_TY_RET
CALL @px_cast_stack
LD r1,r0,#W_TY_RET
MOVI r2,0
CALL @px_emit_store
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
pd_scalar_init:
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
ST r3,r0,#W_TY_ID
ST r3,r0,#W_TY_SIGN
LD r1,r0,#W_SCLASS
MOVI r3,1
CMP r1,r3
JMP[EQ] @pd_si_g
MOVI r1,0
CALL @p_decl_store_addr
JMP @pd_si_val
pd_si_g:
MOVI r1,1
CALL @p_decl_store_addr
pd_si_val:
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_TY_SIGN
CALL @px_cast_stack
LD r1,r0,#W_TY_SIGN
MOVI r2,0
CALL @px_emit_store
JMP @pd_afterinit
pd_noinit:
; C locals are uninitialised; static locals/globals are zeroed by the loader
JMP @pd_afterinit
pd_struct_init:
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pd_scalar_init
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
MOVI r1,0
CALL @p_struct_init
JMP @pd_afterinit
pd_afterinit:
ADDI r14,r14,-1
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
pd_typedef:
MOVI r1,#SK_TYPE
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
CALL @ty_size
ST r1,r0,#W_TY_TMP
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_ID
ST r2,r1,#SY_TYPE
LD r2,r0,#W_TY_TMP
ST r2,r1,#SY_SIZE
ST r0,r1,#SY_CLS
JMP @pd_afterinit

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

; ---- goto / labels ------------------------------------------------
p_label:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#SK_LABEL
CALL @sym_get_cur
ST r1,r0,#W_TMP
CALL @sym_entry
LD r2,r1,#SY_ENTRY
CMP r2,r0
JMP[EQ] @plb_new
MOVI r1,74
CALL @p_err
plb_new:
LD r1,r0,#W_TMP
CALL @sym_entry
ST r1,r0,#W_TMP2
LD r2,r0,#W_FUNCSYM
ST r2,r1,#SY_NP
MOVI r2,#T_VOID
ST r2,r1,#SY_TYPE
CALL @ir_here
LD r2,r0,#W_TMP2
ST r1,r2,#SY_ENTRY
CALL @p_adv
MOVI r1,#P_COLON
MOVI r2,12
CALL @p_expect_p
CALL @p_stmt
SUB r14,r14,r13
LD r15,r14,0
RET

p_goto:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pgo_name
MOVI r1,23
CALL @p_err
pgo_name:
MOVI r1,#SK_LABEL
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @sym_entry
LD r2,r0,#W_FUNCSYM
ST r2,r1,#SY_NP
CALL @p_adv
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_GOTO_N
LA r3,#NCC_GOTOMAX
CMP r2,r3
JMP[LT] @pgo_room
MOVI r1,75
CALL @p_err
pgo_room:
SHL r3,r2,1
LA r4,#NCC_GOTOB
ADD r4,r4,r3
SUB r14,r14,r13
LD r1,r14,0
ST r1,r4,0
LD r1,r0,#W_IRPC
ADDI r1,r1,-2
ST r1,r4,1
LD r1,r0,#W_GOTO_N
ADD r1,r1,r13
ST r1,r0,#W_GOTO_N
SUB r14,r14,r13
LD r15,r14,0
RET

; p_goto_resolve: called at the end of a function body
p_goto_resolve:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_TMP
pgr_l:
LD r1,r0,#W_TMP
LD r2,r0,#W_GOTO_N
CMP r1,r2
JMP[GE] @pgr_d
SHL r3,r1,1
LA r4,#NCC_GOTOB
ADD r4,r4,r3
LD r5,r4,0
LD r6,r4,1
ST r6,r0,#W_TMP2
ADD r1,r5,r0
CALL @sym_entry
LD r1,r1,#SY_ENTRY
CMP r1,r0
JMP[NE] @pgr_have
MOVI r1,76
CALL @p_err
pgr_have:
ST r1,r0,#W_TMP3
LD r1,r0,#W_TMP2
LD r2,r0,#W_TMP3
CALL @ir_patch
LD r1,r0,#W_TMP
ADD r1,r1,r13
ST r1,r0,#W_TMP
JMP @pgr_l
pgr_d:
ST r0,r0,#W_GOTO_N
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- switch --------------------------------------------------------
p_switch:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_expr
CALL @p_emit_rv
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
; reserve a 4-byte temporary in the current frame
LD r1,r0,#W_LOCALB
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_SWTMP
ADDI r2,r1,4
ST r2,r0,#W_LOCALB
; save the enclosing switch state
LD r1,r0,#W_CASEBASE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_DEFSET
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_DEFTGT
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_CASE_N
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_BRK_N
ST r1,r14,0
ADD r14,r14,r13
; evaluate value into the temporary
LD r1,r0,#W_SWTMP
CALL @px_addr_l
LA r1,#I_SWAP
CALL @ir_op
LA r1,#I_STORE
MOVI r2,#SZ_32
CALL @ir_emit
; new switch state
LD r1,r0,#W_CASE_N
ST r1,r0,#W_CASEBASE
ST r0,r0,#W_DEFSET
ST r0,r0,#W_DEFTGT
; jump over the body to the dispatch table
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r0,#W_SWDISP
CALL @p_stmt
; fallthrough jumps over the dispatch table
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r0,#W_SWFALL
; dispatch table starts here
CALL @ir_here
ST r1,r0,#W_SWNO
LD r1,r0,#W_SWDISP
LD r2,r0,#W_SWNO
CALL @ir_patch
LD r1,r0,#W_CASEBASE
ST r1,r0,#W_SWI
sw_disp_l:
LD r1,r0,#W_SWI
LD r2,r0,#W_CASE_N
CMP r1,r2
JMP[GE] @sw_disp_done
SHL r3,r1,1
LA r4,#NCC_CASEB
ADD r4,r4,r3
LD r5,r4,0
LD r6,r4,1
ST r5,r0,#W_TMP
ST r6,r0,#W_TMP2
LD r1,r0,#W_SWTMP
CALL @px_addr_l
LA r1,#I_LOAD
MOVI r2,#SZ_32
CALL @ir_emit
LA r1,#I_PUSH
LD r2,r0,#W_TMP
CALL @ir_emit
LA r1,#I_EQ
CALL @ir_op
LA r1,#I_JNZ
LD r2,r0,#W_TMP2
CALL @ir_emit
LD r1,r0,#W_SWI
ADD r1,r1,r13
ST r1,r0,#W_SWI
JMP @sw_disp_l
sw_disp_done:
LD r1,r0,#W_DEFSET
CMP r1,r0
JMP[EQ] @sw_nodef
LA r1,#I_JMP
LD r2,r0,#W_DEFTGT
CALL @ir_emit
JMP @sw_here
sw_nodef:
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r0,#W_SWEND
sw_here:
CALL @ir_here
ST r1,r0,#W_SWNO
LD r1,r0,#W_SWFALL
LD r2,r0,#W_SWNO
CALL @ir_patch
LD r1,r0,#W_DEFSET
CMP r1,r0
JMP[NE] @sw_patch_brk
LD r1,r0,#W_SWEND
LD r2,r0,#W_SWNO
CALL @ir_patch
sw_patch_brk:
; patch breaks belonging to this switch
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_TMP
sw_brk_l:
LD r1,r0,#W_TMP
LD r2,r0,#W_BRK_N
CMP r1,r2
JMP[GE] @sw_brk_done
LA r3,#W_BRK_TAB
ADD r3,r3,r1
LD r4,r3,0
LD r5,r0,#W_SWNO
ST r5,r0,#W_TMP2
ADD r1,r4,r0
LD r2,r0,#W_TMP2
CALL @ir_patch
LD r1,r0,#W_TMP
ADD r1,r1,r13
ST r1,r0,#W_TMP
JMP @sw_brk_l
sw_brk_done:
LD r1,r0,#W_TMP
ST r1,r0,#W_BRK_N
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_CASE_N
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_DEFTGT
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_DEFSET
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_CASEBASE
SUB r14,r14,r13
LD r15,r14,0
RET

p_case:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_cexpr
ST r1,r0,#W_TMP
MOVI r1,#P_COLON
MOVI r2,12
CALL @p_expect_p
CALL @ir_here
ST r1,r0,#W_TMP2
LD r1,r0,#W_CASE_N
LA r2,#NCC_CASEMAX
CMP r1,r2
JMP[LT] @pcs_room
MOVI r1,73
CALL @p_err
pcs_room:
SHL r2,r1,1
LA r3,#NCC_CASEB
ADD r3,r3,r2
LD r2,r0,#W_TMP
ST r2,r3,0
LD r2,r0,#W_TMP2
ST r2,r3,1
ADD r1,r1,r13
ST r1,r0,#W_CASE_N
CALL @p_stmt
SUB r14,r14,r13
LD r15,r14,0
RET

p_default:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_COLON
MOVI r2,12
CALL @p_expect_p
CALL @ir_here
ST r1,r0,#W_DEFTGT
MOVI r1,1
ST r1,r0,#W_DEFSET
CALL @p_stmt
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
LD r1,r0,#W_FUNCRET
CALL @ty_kind
CMP r1,r0
JMP[NE] @pret_cast
LA r1,#I_POP
CALL @ir_op
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
JMP @pret_go
pret_cast:
LD r1,r0,#W_FUNCRET
CALL @px_cast_stack
pret_go:
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
LA r1,#I_RET
CALL @ir_op
SUB r14,r14,r13
LD r15,r14,0
RET

; external declarations and function definitions
; p_decl_external: r1=base type, current token begins a declarator or name
p_decl_external:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_RET
MOVI r1,#P_SEMI
CALL @p_at_p
CMP r1,r0
JMP[NE] @pde_type_only
LD r1,r0,#W_SCLASS
MOVI r2,3
CMP r1,r2
JMP[EQ] @pde_typedef
pde_one:
LD r1,r0,#W_TY_RET
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pde_name
MOVI r1,23
CALL @p_err
pde_name:
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pde_var
LD r1,r0,#W_TKB+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pde_func
pde_var:
MOVI r1,#SK_GLOBAL
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
CALL @p_infer_str_array
ST r1,r0,#W_TY_ID
CALL @ty_size
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_TY_ID
CALL @ty_align
ST r1,r0,#W_TY_COUNT
LD r1,r0,#W_SCLASS
MOVI r2,2
CMP r1,r2
JMP[EQ] @pde_extern
; allocate in the byte globals region
LD r1,r0,#W_GLOBP
LD r2,r0,#W_TY_COUNT
CALL @px_align_up
ST r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_TMP
ADD r2,r1,r2
LA r3,#C_GLOBEND
CMP r2,r3
JMP[LT] @pde_room
MOVI r1,71
CALL @p_err
pde_room:
ST r2,r0,#W_GLOBP
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_BASE
ST r2,r1,#SY_AUX
JMP @pde_settype
pde_extern:
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
CMP r2,r0
JMP[NE] @pde_settype
ST r0,r1,#SY_AUX
pde_settype:
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_ID
ST r2,r1,#SY_TYPE
LD r2,r0,#W_TY_TMP
ST r2,r1,#SY_SIZE
MOVI r1,#P_ASSIGN
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pde_zero
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pde_not_str
LD r1,r0,#W_TY_ID
CALL @ty_base
CALL @ty_size
MOVI r2,1
CMP r1,r2
JMP[NE] @pde_not_str
LD r1,r0,#W_TKA
MOVI r2,#K_STRING
CMP r1,r2
JMP[NE] @pde_not_str
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
MOVI r1,1
CALL @p_str_init
JMP @pde_after
pde_not_str:
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pde_struct_init
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pde_struct_init
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pde_scalar
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pde_scalar
; zero + brace list
MOVI r1,1
ADDI r3,r14,-1
LD r2,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_SIZE
CALL @p_zero_range
CALL @p_adv
MOVI r1,0
ST r1,r14,0
ADD r14,r14,r13
pde_ai_l:
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pde_ai_done
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_COUNT
CALL @ty_size
ADDI r3,r14,-1
LD r4,r3,0
MUL r4,r4,r1
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
ADD r2,r2,r4
MOVI r1,1
CALL @p_decl_store_addr
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_COUNT
LD r1,r0,#W_TY_COUNT
CALL @px_cast_stack
LD r1,r0,#W_TY_COUNT
MOVI r2,0
CALL @px_emit_store
ADDI r3,r14,-1
LD r4,r3,0
ST r4,r0,#W_NLOC
ADD r4,r4,r13
ST r4,r3,0
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pde_ai_l
pde_ai_done:
MOVI r1,#P_RBRACE
MOVI r2,35
CALL @p_expect_p
ADDI r14,r14,-1
JMP @pde_after
pde_struct_init:
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pde_scalar
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
MOVI r1,1
CALL @p_struct_init
JMP @pde_after
pde_scalar:
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
ST r3,r0,#W_TY_ID
MOVI r1,1
CALL @p_decl_store_addr
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_TY_ID
LD r1,r0,#W_TY_ID
CALL @px_cast_stack
LD r1,r0,#W_TY_ID
MOVI r2,0
CALL @px_emit_store
JMP @pde_after
pde_zero:
; C zero-initialises file-scope storage
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_SIZE
CMP r2,r0
JMP[EQ] @pde_after
LD r2,r1,#SY_AUX
LD r3,r1,#SY_SIZE
MOVI r1,1
CALL @p_zero_range
pde_after:
ADDI r14,r14,-1
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pde_one
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
JMP @pde_d
pde_func:
LD r1,r0,#W_TY_ID
CALL @p_func
JMP @pde_d
pde_typedef:
LD r1,r0,#W_TY_RET
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pdt_name
MOVI r1,23
CALL @p_err
pdt_name:
MOVI r1,#SK_TYPE
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
CALL @ty_size
ST r1,r0,#W_TY_TMP
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_ID
ST r2,r1,#SY_TYPE
LD r2,r0,#W_TY_TMP
ST r2,r1,#SY_SIZE
ST r0,r1,#SY_CLS
ADDI r14,r14,-1
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pde_typedef
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
pde_d:
SUB r14,r14,r13
LD r15,r14,0
RET
pde_type_only:
CALL @p_adv
JMP @pde_d

; function definition/prototype; current token is the name, r1=return type
p_func:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_SCOPEID
MOVI r2,1
ST r2,r0,#W_NEXTSCOPE
ST r1,r0,#W_FUNCRET
MOVI r1,#SK_FUNC
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
ST r1,r0,#W_FUNCSYM
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,16
ST r1,r0,#W_LOCALB
ST r0,r0,#W_FUNCNP
LD r1,r0,#W_PARAMP
ST r1,r0,#W_FUNCARG
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pfu_done_params
MOVI r1,#KW_VOID
CALL @p_at_k
CMP r1,r0
JMP[EQ] @pfu_param_l
CALL @p_adv
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pfu_done_params
pfu_param_l:
CALL @p_typespec
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
MOVI r2,0
ST r2,r0,#W_TY_BASE
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pfu_no_name
MOVI r1,#SK_LOCAL
CALL @sym_new_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pfu_alloc
LD r1,r0,#W_TY_ID
CALL @ty_base
CALL @ty_ptr
ST r1,r0,#W_TY_ID
pfu_alloc:
LD r1,r0,#W_TY_ID
CALL @ty_size
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_TY_ID
CALL @ty_align
ST r1,r0,#W_TY_COUNT
LD r1,r0,#W_LOCALB
LD r2,r0,#W_TY_COUNT
CALL @px_align_up
ST r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_TMP
ADD r2,r1,r2
ST r2,r0,#W_LOCALB
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_TY_BASE
ST r2,r1,#SY_AUX
ST r0,r1,#SY_CLS
LD r2,r0,#W_TY_ID
ST r2,r1,#SY_TYPE
LD r2,r0,#W_TY_TMP
ST r2,r1,#SY_SIZE
ADDI r14,r14,-1
pfu_no_name:
LD r2,r0,#W_FUNCARG
LD r3,r0,#W_FUNCNP
MUL r3,r3,r13
ADD r3,r3,r3
ADD r2,r2,r3
LD r3,r0,#W_TY_BASE
CMP r3,r0
JMP[NE] @pfu_have_off
MOVI r3,0
pfu_have_off:
ST r3,r2,0
LD r3,r0,#W_TY_ID
ST r3,r2,1
ADDI r2,r2,2
ST r2,r0,#W_PARAMP
LD r3,r0,#W_FUNCNP
ADD r3,r3,r13
ST r3,r0,#W_FUNCNP
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pfu_param_l
pfu_done_params:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
; record the signature on the function symbol
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_FUNCRET
ST r2,r1,#SY_TYPE
LD r2,r0,#W_FUNCNP
ST r2,r1,#SY_NP
LD r2,r0,#W_FUNCARG
ST r2,r1,#SY_ARG
MOVI r1,#P_SEMI
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pfu_body
ADDI r14,r14,-1
JMP @pfu_d
pfu_body:
LA r1,#I_JMP
CALL @ir_op
LD r2,r0,#W_IRPC
ADDI r2,r2,-2
ST r2,r0,#W_FSKIP
CALL @ir_here
ST r1,r0,#W_FENTRY
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_FENTRY
ST r2,r1,#SY_ENTRY
ST r0,r0,#W_GOTO_N
CALL @p_block
CALL @p_goto_resolve
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
LD r1,r0,#W_LOCALB
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_FRAMEB
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r0,#W_FRAMEB
ST r2,r1,#SY_NL
ADDI r14,r14,-1
pfu_d:
ST r0,r0,#W_FUNCSYM
SUB r14,r14,r13
LD r15,r14,0
RET
; translation unit
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
JMP[NE] @ptu_type
CALL @p_adv
JMP @ptu_l
ptu_type:
CALL @p_is_type
CMP r1,r0
JMP[NE] @ptu_go
MOVI r1,30
CALL @p_err
ptu_go:
CALL @p_typespec
CALL @p_decl_external
JMP @ptu_l
ptu_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ================================================================== INTERPRETER
; Memory is byte-addressed; IR values are 32-bit. C frames live at C_STACK.
ni_push:
LD r2,r0,#R_SP
LA r3,#NCC_ESEND
CMP r2,r3
JMP[LT] @nip_ok
MOVI r1,43
JMP @ncc_err
nip_ok:
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

; ni_loadv: r1=byte address r2=code -> r1
ni_loadv:
MOVI r3,#SZ_8S
CMP r2,r3
JMP[EQ] @nilv_8s
MOVI r3,#SZ_8U
CMP r2,r3
JMP[EQ] @nilv_8u
MOVI r3,#SZ_16S
CMP r2,r3
JMP[EQ] @nilv_16s
MOVI r3,#SZ_16U
CMP r2,r3
JMP[EQ] @nilv_16u
; 32-bit
LDB r4,r1,0
ADDI r1,r1,1
LDB r5,r1,0
SHL r5,r5,8
BOOL.14 r4,r4,r5
ADDI r1,r1,1
LDB r5,r1,0
SHL r5,r5,16
BOOL.14 r4,r4,r5
ADDI r1,r1,1
LDB r5,r1,0
SHL r5,r5,24
BOOL.14 r1,r4,r5
RET
nilv_8s:
LDB r1,r1,0
SHL r1,r1,24
SAR r1,r1,24
RET
nilv_8u:
LDB r1,r1,0
RET
nilv_16s:
LDB r4,r1,0
ADDI r1,r1,1
LDB r5,r1,0
SHL r5,r5,8
BOOL.14 r4,r4,r5
SHL r4,r4,16
SAR r1,r4,16
RET
nilv_16u:
LDB r4,r1,0
ADDI r1,r1,1
LDB r5,r1,0
SHL r5,r5,8
BOOL.14 r1,r4,r5
RET

; ni_storev: r1=byte address r2=value r3=code
ni_storev:
MOVI r4,#SZ_8S
CMP r3,r4
JMP[EQ] @nisv_8
MOVI r4,#SZ_8U
CMP r3,r4
JMP[EQ] @nisv_8
MOVI r4,#SZ_16S
CMP r3,r4
JMP[EQ] @nisv_16
MOVI r4,#SZ_16U
CMP r3,r4
JMP[EQ] @nisv_16
; 32-bit
STB r2,r1,0
SHR r2,r2,8
ADDI r1,r1,1
STB r2,r1,0
SHR r2,r2,8
ADDI r1,r1,1
STB r2,r1,0
SHR r2,r2,8
ADDI r1,r1,1
STB r2,r1,0
RET
nisv_16:
STB r2,r1,0
SHR r2,r2,8
ADDI r1,r1,1
STB r2,r1,0
RET
nisv_8:
STB r2,r1,0
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
ni_shru:
MOVI r3,31
BOOL.8 r2,r2,r3
nsu_l:
CMP r2,r0
JMP[EQ] @nsu_d
SHR r1,r1,1
SUB r2,r2,r13
JMP @nsu_l
nsu_d:
RET

; ni_puts: r1=NUL-terminated byte string
ni_puts:
ST r15,r14,0
ADD r14,r14,r13
ni_puts_l:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @ni_puts_d
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

; ---- libc runtime -------------------------------------------------
putudec:
ST r15,r14,0
ADD r14,r14,r13
CMP r5,r0
JMP[NE] @pud_nz
MOVI r1,48
CALL @ncc_putc
JMP @pud_d
pud_nz:
MOVI r6,0
pud_l:
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
JMP[NE] @pud_l
pud_r:
SUB r6,r6,r13
LA r10,#W_DECBUF
ADD r10,r10,r6
LD r1,r10,0
ADDI r1,r1,48
CALL @ncc_putc
CMP r6,r0
JMP[NE] @pud_r
pud_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_arg: r1=i -> r1=argument i (0-based)
ni_arg:
LD r2,r0,#R_SP
LD r3,r0,#W_PF_ARGC
SUB r2,r2,r3
ADD r2,r2,r1
LD r1,r2,0
RET

; ni_hexdigits: r1=value -> r2=significant nibbles (>=1)
ni_hexdigits:
MOVI r2,1
ni_hd_l:
MOVI r3,16
CMP r1,r3
JMP[LT] @ni_hd_d
SHR r1,r1,4
ADD r2,r2,r13
JMP @ni_hd_l
ni_hd_d:
RET

; ni_hexmin: r1=value r2=case(0 lower,1 upper) -> print significant hex
ni_hexmin:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
ST r2,r0,#W_TY_COUNT
CALL @ni_hexdigits
ST r2,r0,#W_TY_ID
MOVI r4,8
SUB r4,r4,r2
SHL r4,r4,2
LD r1,r0,#W_TY_TMP
ADD r2,r4,r0
CALL @ni_shl
ST r1,r0,#W_TY_TMP
ni_hm_l:
LD r2,r0,#W_TY_ID
CMP r2,r0
JMP[EQ] @ni_hm_d
SUB r2,r2,r13
ST r2,r0,#W_TY_ID
LD r1,r0,#W_TY_TMP
SHR r1,r1,28
LD r2,r0,#W_TY_COUNT
CMP r2,r0
JMP[EQ] @ni_hm_low
CALL @puthex1
JMP @ni_hm_next
ni_hm_low:
CALL @puthex1l
ni_hm_next:
LD r1,r0,#W_TY_TMP
SHL r1,r1,4
ST r1,r0,#W_TY_TMP
JMP @ni_hm_l
ni_hm_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_sin: r1=float bits -> r1=sin(r1)
ni_sin:
ST r15,r14,0
ADD r14,r14,r13
; reduce by 2*pi
LA r2,0x40C90FDB
FDIV r3,r1,r2
CVTFI r3,r3
CVTIF r3,r3
FMUL r3,r3,r2
FSUB r1,r1,r3
; fold into [-pi,pi]
LA r2,0x40490FDB
FCMP r1,r2
JMP[GT] @ns_hi
LA r2,0xC0490FDB
FCMP r1,r2
JMP[LT] @ns_lo
JMP @ns_taylor
ns_hi:
LA r2,0x40C90FDB
FSUB r1,r1,r2
JMP @ns_taylor
ns_lo:
LA r2,0x40C90FDB
FADD r1,r1,r2
ns_taylor:
; fold into [-pi/2,pi/2] for Taylor accuracy
LA r2,0x3FC90FDB
FCMP r1,r2
JMP[LE] @ns_chkneg
LA r2,0x40490FDB
FSUB r1,r2,r1
JMP @ns_poly
ns_chkneg:
LA r2,0xBFC90FDB
FCMP r1,r2
JMP[GE] @ns_poly
LA r2,0xC0490FDB
FSUB r1,r2,r1
ns_poly:
ADD r5,r1,r0
FMUL r2,r5,r5
FMUL r3,r2,r5
LA r4,0x3E2AAAAB
FMUL r3,r3,r4
FSUB r6,r5,r3
FMUL r3,r2,r2
FMUL r3,r3,r5
LA r4,0x3C088889
FMUL r3,r3,r4
FADD r6,r6,r3
FMUL r3,r2,r2
FMUL r3,r3,r2
FMUL r3,r3,r5
LA r4,0x3951B717
FMUL r3,r3,r4
FSUB r6,r6,r3
ADD r1,r6,r0
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_cos: r1=float bits -> r1=cos(r1)
ni_cos:
LA r2,0x3FC90FDB
FADD r1,r1,r2
JMP @ni_sin

; ni_pad: r1=count r2=char -> emit count copies
ni_pad:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ADD r14,r14,r13
ST r2,r14,0
ADD r14,r14,r13
nip_l:
ADDI r3,r14,-2
LD r1,r3,0
CMP r1,r0
JMP[EQ] @nip_d
SUB r1,r1,r13
ST r1,r3,0
ADDI r3,r14,-1
LD r1,r3,0
CALL @ncc_putc
JMP @nip_l
nip_d:
ADDI r14,r14,-3
LD r15,r14,0
RET

; ni_field_pre: r1=len r2=width r3=padchar -> left padding
ni_field_pre:
ST r15,r14,0
ADD r14,r14,r13
CMP r2,r1
JMP[LE] @nfp_d
SUB r1,r2,r1
ADD r2,r3,r0
CALL @ni_pad
nfp_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_field_post: r1=len r2=width -> right padding with spaces
ni_field_post:
ST r15,r14,0
ADD r14,r14,r13
CMP r2,r1
JMP[LE] @nfo_d
SUB r1,r2,r1
MOVI r2,32
CALL @ni_pad
nfo_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_field_tail: r1=len r2=width -> pad spaces only when the '-' flag is set
ni_field_tail:
ST r15,r14,0
ADD r14,r14,r13
LD r3,r0,#W_PF_FLAGS
MOVI r4,1
BOOL.8 r3,r3,r4
CMP r3,r0
JMP[EQ] @nft_d
CMP r2,r1
JMP[LE] @nft_d
SUB r1,r2,r1
MOVI r2,32
CALL @ni_pad
nft_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_decdigits: r1=value (non-negative) -> r2=digits
ni_decdigits:
MOVI r2,1
nid_l:
MOVI r3,10
CMP r1,r3
JMP[LT] @nid_d
DIVU r1,r1,r3
ADD r2,r2,r13
JMP @nid_l
nid_d:
RET

ni_printf:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_PF_ARGC
ST r0,r0,#W_PF_IDX
MOVI r1,0
CALL @ni_arg
ST r1,r0,#W_PF_FMT
npf_l:
LD r1,r0,#W_PF_FMT
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @npf_done
MOVI r3,37
CMP r2,r3
JMP[EQ] @npf_pct
ADD r1,r2,r0
CALL @ncc_putc
LD r1,r0,#W_PF_FMT
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_l
npf_pct:
LD r1,r0,#W_PF_FMT
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
ST r0,r0,#W_PF_W
ST r0,r0,#W_PF_FLAGS
npf_flag_l:
LD r1,r0,#W_PF_FMT
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @npf_done
MOVI r3,45
CMP r2,r3
JMP[NE] @npf_flag_z
LD r3,r0,#W_PF_FLAGS
MOVI r4,1
BOOL.14 r3,r3,r4
ST r3,r0,#W_PF_FLAGS
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_flag_l
npf_flag_z:
MOVI r3,48
CMP r2,r3
JMP[NE] @npf_w_l
LD r3,r0,#W_PF_FLAGS
MOVI r4,2
BOOL.14 r3,r3,r4
ST r3,r0,#W_PF_FLAGS
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_flag_l
npf_w_l:
LD r1,r0,#W_PF_FMT
LDB r2,r1,0
MOVI r3,48
CMP r2,r3
JMP[LT] @npf_w_d
MOVI r3,58
CMP r2,r3
JMP[GE] @npf_w_d
LD r3,r0,#W_PF_W
MOVI r4,10
MUL r3,r3,r4
ADDI r2,r2,-48
ADD r3,r3,r2
ST r3,r0,#W_PF_W
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_w_l
npf_w_d:
LD r1,r0,#W_PF_FMT
LDB r2,r1,0
MOVI r3,108
CMP r2,r3
JMP[NE] @npf_fmt
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
LDB r2,r1,0
npf_fmt:
MOVI r3,100
CMP r2,r3
JMP[EQ] @npf_int
MOVI r3,105
CMP r2,r3
JMP[EQ] @npf_int
MOVI r3,117
CMP r2,r3
JMP[EQ] @npf_uint
MOVI r3,120
CMP r2,r3
JMP[EQ] @npf_hex_low
MOVI r3,88
CMP r2,r3
JMP[EQ] @npf_hex_up
MOVI r3,99
CMP r2,r3
JMP[EQ] @npf_char
MOVI r3,115
CMP r2,r3
JMP[EQ] @npf_str
MOVI r3,112
CMP r2,r3
JMP[EQ] @npf_hex_low
MOVI r3,37
CMP r2,r3
JMP[EQ] @npf_pctc
ADD r1,r2,r0
CALL @ncc_putc
JMP @npf_adv
npf_int:
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
ST r0,r0,#W_PF_NEG
CMPS r1,r0
JMP[GE] @npf_i_abs
MOVI r2,1
ST r2,r0,#W_PF_NEG
SUB r1,r0,r1
npf_i_abs:
ST r1,r0,#W_PF_TMP
CALL @ni_decdigits
LD r1,r0,#W_PF_NEG
ADD r2,r2,r1
ST r2,r0,#W_PF_LEN
MOVI r1,32
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @npf_i_pad
LD r2,r0,#W_PF_NEG
CMP r2,r0
JMP[NE] @npf_i_pad
MOVI r1,48
npf_i_pad:
ST r1,r0,#W_PF_PAD
; negative zero-padded: sign first, zeros, then magnitude
LD r2,r0,#W_PF_NEG
CMP r2,r0
JMP[EQ] @npf_i_normal
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @npf_i_normal
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_i_normal
MOVI r1,45
CALL @ncc_putc
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CMP r2,r1
JMP[LE] @npf_i_negmag
SUB r1,r2,r1
MOVI r2,48
CALL @ni_pad
npf_i_negmag:
LD r5,r0,#W_PF_TMP
CALL @putudec
JMP @npf_i_adv
npf_i_normal:
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_i_print
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
LD r3,r0,#W_PF_PAD
CALL @ni_field_pre
npf_i_print:
LD r5,r0,#W_PF_VAL
CALL @putdec
npf_i_adv:
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv
npf_uint:
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
CALL @ni_decdigits
ST r2,r0,#W_PF_LEN
MOVI r1,32
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @npf_u_pad
MOVI r1,48
npf_u_pad:
ST r1,r0,#W_PF_PAD
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_u_print
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
LD r3,r0,#W_PF_PAD
CALL @ni_field_pre
npf_u_print:
LD r5,r0,#W_PF_VAL
CALL @putudec
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv
npf_hex_low:
MOVI r2,0
ST r2,r0,#W_PF_CASE
JMP @npf_hex
npf_hex_up:
MOVI r2,1
ST r2,r0,#W_PF_CASE
npf_hex:
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
CALL @ni_hexdigits
ST r2,r0,#W_PF_LEN
MOVI r1,32
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @npf_h_pad
MOVI r1,48
npf_h_pad:
ST r1,r0,#W_PF_PAD
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_h_print
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
LD r3,r0,#W_PF_PAD
CALL @ni_field_pre
npf_h_print:
LD r1,r0,#W_PF_VAL
LD r2,r0,#W_PF_CASE
CALL @ni_hexmin
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv
npf_char:
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
MOVI r1,1
ST r1,r0,#W_PF_PAD
LD r1,r0,#W_PF_FLAGS
MOVI r2,1
BOOL.8 r1,r1,r2
CMP r1,r0
JMP[NE] @npf_c_print
MOVI r1,1
LD r2,r0,#W_PF_W
MOVI r3,32
CALL @ni_field_pre
npf_c_print:
LD r1,r0,#W_PF_VAL
MOVI r2,255
BOOL.8 r1,r1,r2
CALL @ncc_putc
MOVI r1,1
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv
npf_str:
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
CALL @ni_strlen
ST r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_s_print
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
MOVI r3,32
CALL @ni_field_pre
npf_s_print:
LD r1,r0,#W_PF_VAL
CALL @ni_puts
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv
npf_pctc:
MOVI r1,37
CALL @ncc_putc
npf_adv:
LD r1,r0,#W_PF_FMT
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_l
npf_done:
LD r1,r0,#W_PF_ARGC
LD r2,r0,#R_SP
SUB r2,r2,r1
ST r2,r0,#R_SP
MOVI r1,0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET


; byte helpers
ni_memcpy_raw: ; r1=dst r2=src r3=n
nmm_l:
CMP r3,r0
JMP[EQ] @nmm_d
LDB r4,r2,0
STB r4,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @nmm_l
nmm_d:
RET
ni_memset_raw: ; r1=dst r2=byte r3=n
nms_l:
CMP r3,r0
JMP[EQ] @nms_d
STB r2,r1,0
ADD r1,r1,r13
SUB r3,r3,r13
JMP @nms_l
nms_d:
RET

; malloc: r1=size -> r1=ptr
ni_malloc:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_HEAP
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_TY_BASE
LD r1,r0,#W_TY_TMP
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_TY_ID
LD r2,r0,#W_TY_BASE
ADDI r3,r1,4
ADD r3,r3,r2
LA r4,#C_HEAP_END
CMP r3,r4
JMP[LT] @nm_room
MOVI r1,83
CALL @ncc_err
nm_room:
LD r1,r0,#W_TY_BASE
SHR r2,r1,2
LD r3,r0,#W_TY_ID
ST r3,r2,0
LD r2,r0,#W_TY_BASE
ADDI r3,r3,4
ADD r2,r2,r3
ST r2,r0,#W_HEAP
ADDI r1,r1,4
SUB r14,r14,r13
LD r15,r14,0
RET

ni_calloc:
; r1=n r2=size
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#W_TY_TMP
MUL r1,r1,r2
ST r1,r0,#W_TY_COUNT
CALL @ni_malloc
ST r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_COUNT
MOVI r3,0
CALL @ni_memset_raw
LD r1,r0,#W_TY_BASE
SUB r14,r14,r13
LD r15,r14,0
RET

ni_realloc:
; r1=oldptr r2=newsize
ST r15,r14,0
ADD r14,r14,r13
CMP r1,r0
JMP[NE] @nr_old
ADD r1,r2,r0
CALL @ni_malloc
JMP @nr_d
nr_old:
ST r1,r0,#W_TY_SIGN
ST r2,r0,#W_TY_ALIGN
ADDI r3,r1,-4
SHR r3,r3,2
LD r3,r3,0
ST r3,r0,#W_TY_COUNT
ADD r1,r2,r0
CALL @ni_malloc
ST r1,r0,#W_TY_RET
LD r1,r0,#W_TY_RET
LD r2,r0,#W_TY_SIGN
LD r3,r0,#W_TY_COUNT
LD r4,r0,#W_TY_ALIGN
CMP r3,r4
JMP[LE] @nr_copy
ADD r3,r4,r0
nr_copy:
CALL @ni_memcpy_raw
LD r1,r0,#W_TY_RET
nr_d:
SUB r14,r14,r13
LD r15,r14,0
RET

ni_strlen:
; r1=ptr -> r1=len
ST r1,r0,#W_TY_TMP
MOVI r2,0
nsl_l:
LDB r3,r1,0
CMP r3,r0
JMP[EQ] @nsl_d
ADD r1,r1,r13
ADD r2,r2,r13
JMP @nsl_l
nsl_d:
ADD r1,r2,r0
RET

ni_strcmp:
; r1=a r2=b
nsc_l:
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @nsc_ne
CMP r3,r0
JMP[EQ] @nsc_eq
ADD r1,r1,r13
ADD r2,r2,r13
JMP @nsc_l
nsc_eq:
MOVI r1,0
RET
nsc_ne:
CMP r3,r4
MOVI r1,1
MOVI[LT] r1,-1
RET

ni_strncmp:
; r1=a r2=b r3=n
snc_l:
CMP r3,r0
JMP[EQ] @snc_eq
LDB r4,r1,0
LDB r5,r2,0
CMP r4,r5
JMP[NE] @snc_ne
CMP r4,r0
JMP[EQ] @snc_eq
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @snc_l
snc_eq:
MOVI r1,0
RET
snc_ne:
CMP r4,r5
MOVI r1,1
MOVI[LT] r1,-1
RET

ni_strcpy:
; r1=dst r2=src -> dst
ST r1,r0,#W_TY_TMP
nscp_l:
LDB r3,r2,0
STB r3,r1,0
CMP r3,r0
JMP[EQ] @nscp_d
ADD r1,r1,r13
ADD r2,r2,r13
JMP @nscp_l
nscp_d:
LD r1,r0,#W_TY_TMP
RET

ni_strncpy:
; r1=dst r2=src r3=n
ST r1,r0,#W_TY_TMP
sncp_l:
CMP r3,r0
JMP[EQ] @sncp_d
LDB r4,r2,0
STB r4,r1,0
CMP r4,r0
JMP[EQ] @sncp_pad
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @sncp_l
sncp_pad:
; pad the remainder with zeros
ADD r1,r1,r13
SUB r3,r3,r13
sncp_pl:
CMP r3,r0
JMP[EQ] @sncp_d
STB r0,r1,0
ADD r1,r1,r13
SUB r3,r3,r13
JMP @sncp_pl
sncp_d:
LD r1,r0,#W_TY_TMP
RET

ni_strcat:
; r1=dst r2=src -> dst
ST r1,r0,#W_TY_TMP
scat_l:
LDB r3,r1,0
CMP r3,r0
JMP[EQ] @scat_go
ADD r1,r1,r13
JMP @scat_l
scat_go:
LDB r3,r2,0
STB r3,r1,0
CMP r3,r0
JMP[EQ] @scat_d
ADD r1,r1,r13
ADD r2,r2,r13
JMP @scat_go
scat_d:
LD r1,r0,#W_TY_TMP
RET

ni_memcmp:
; r1=a r2=b r3=n
nmc_l:
CMP r3,r0
JMP[EQ] @nmc_eq
LDB r4,r1,0
LDB r5,r2,0
CMP r4,r5
JMP[NE] @nmc_ne
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @nmc_l
nmc_eq:
MOVI r1,0
RET
nmc_ne:
CMP r4,r5
MOVI r1,1
MOVI[LT] r1,-1
RET

ni_atoi:
; r1=ptr
MOVI r2,0
MOVI r3,0
LDB r4,r1,0
MOVI r5,45
CMP r4,r5
JMP[NE] @nai_l
MOVI r3,1
ADD r1,r1,r13
nai_l:
LDB r4,r1,0
MOVI r5,48
CMP r4,r5
JMP[LT] @nai_d
MOVI r5,58
CMP r4,r5
JMP[GE] @nai_d
MOVI r5,10
MUL r2,r2,r5
ADDI r4,r4,-48
ADD r2,r2,r4
ADD r1,r1,r13
JMP @nai_l
nai_d:
CMP r3,r0
JMP[EQ] @nai_r
SUB r2,r0,r2
nai_r:
ADD r1,r2,r0
RET

ni_builtin:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#R_T0
ST r2,r0,#R_T1
LD r1,r0,#R_T0
MOVI r2,#B_PUTCHAR
CMP r1,r2
JMP[EQ] @nbi_putc
MOVI r2,#B_PRINTINT
CMP r1,r2
JMP[EQ] @nbi_pint
MOVI r2,#B_PUTS
CMP r1,r2
JMP[EQ] @nbi_puts
MOVI r2,#B_HEX
CMP r1,r2
JMP[EQ] @nbi_hex
MOVI r2,#B_PUTSTR
CMP r1,r2
JMP[EQ] @nbi_pstr
MOVI r2,#B_PRINTF
CMP r1,r2
JMP[EQ] @nbi_printf
MOVI r2,#B_MALLOC
CMP r1,r2
JMP[EQ] @nbi_malloc
MOVI r2,#B_FREE
CMP r1,r2
JMP[EQ] @nbi_free
MOVI r2,#B_CALLOC
CMP r1,r2
JMP[EQ] @nbi_calloc
MOVI r2,#B_REALLOC
CMP r1,r2
JMP[EQ] @nbi_realloc
MOVI r2,#B_STRLEN
CMP r1,r2
JMP[EQ] @nbi_strlen
MOVI r2,#B_STRCMP
CMP r1,r2
JMP[EQ] @nbi_strcmp
MOVI r2,#B_STRNCMP
CMP r1,r2
JMP[EQ] @nbi_strncmp
MOVI r2,#B_STRCPY
CMP r1,r2
JMP[EQ] @nbi_strcpy
MOVI r2,#B_STRNCPY
CMP r1,r2
JMP[EQ] @nbi_strncpy
MOVI r2,#B_STRCAT
CMP r1,r2
JMP[EQ] @nbi_strcat
MOVI r2,#B_MEMCPY
CMP r1,r2
JMP[EQ] @nbi_memcpy
MOVI r2,#B_MEMSET
CMP r1,r2
JMP[EQ] @nbi_memset
MOVI r2,#B_MEMCMP
CMP r1,r2
JMP[EQ] @nbi_memcmp
MOVI r2,#B_ATOI
CMP r1,r2
JMP[EQ] @nbi_atoi
MOVI r2,#B_ABS
CMP r1,r2
JMP[EQ] @nbi_abs
MOVI r2,#B_SIN
CMP r1,r2
JMP[EQ] @nbi_sin
MOVI r2,#B_COS
CMP r1,r2
JMP[EQ] @nbi_cos
MOVI r2,#B_EXIT
CMP r1,r2
JMP[EQ] @nbi_exit
JMP @nbi_zero
nbi_putc:
CALL @ni_pop
ST r1,r0,#R_T2
MOVI r2,255
BOOL.8 r1,r1,r2
CALL @ncc_putc
LD r1,r0,#R_T2
CALL @ni_push
JMP @nbi_d
nbi_pint:
CALL @ni_pop
ADD r5,r1,r0
CALL @putdec
JMP @nbi_zero
nbi_puts:
CALL @ni_pop
CALL @ni_puts
MOVI r1,10
CALL @ncc_putc
JMP @nbi_zero
nbi_hex:
CALL @ni_pop
ADD r5,r1,r0
CALL @puthex8
JMP @nbi_zero
nbi_pstr:
CALL @ni_pop
CALL @ni_puts
JMP @nbi_zero
nbi_printf:
LD r1,r0,#R_T1
CALL @ni_printf
JMP @nbi_d
nbi_malloc:
CALL @ni_pop
CALL @ni_malloc
CALL @ni_push
JMP @nbi_d
nbi_free:
CALL @ni_pop
JMP @nbi_zero
nbi_calloc:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
CALL @ni_calloc
CALL @ni_push
JMP @nbi_d
nbi_realloc:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
CALL @ni_realloc
CALL @ni_push
JMP @nbi_d
nbi_strlen:
CALL @ni_pop
CALL @ni_strlen
CALL @ni_push
JMP @nbi_d
nbi_strcmp:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
CALL @ni_strcmp
CALL @ni_push
JMP @nbi_d
nbi_strncmp:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
ST r1,r0,#R_T0
CALL @ni_pop
LD r2,r0,#R_T0
LD r3,r0,#R_T2
CALL @ni_strncmp
CALL @ni_push
JMP @nbi_d
nbi_strcpy:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
CALL @ni_strcpy
CALL @ni_push
JMP @nbi_d
nbi_strncpy:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
ST r1,r0,#R_T0
CALL @ni_pop
LD r2,r0,#R_T0
LD r3,r0,#R_T2
CALL @ni_strncpy
CALL @ni_push
JMP @nbi_d
nbi_strcat:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
CALL @ni_strcat
CALL @ni_push
JMP @nbi_d
nbi_memcpy:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
ST r1,r0,#R_T0
CALL @ni_pop
ST r1,r0,#R_T1
LD r1,r0,#R_T1
LD r2,r0,#R_T0
LD r3,r0,#R_T2
CALL @ni_memcpy_raw
LD r1,r0,#R_T1
CALL @ni_push
JMP @nbi_d
nbi_memset:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
ST r1,r0,#R_T0
CALL @ni_pop
ST r1,r0,#R_T1
LD r1,r0,#R_T1
LD r2,r0,#R_T0
LD r3,r0,#R_T2
CALL @ni_memset_raw
LD r1,r0,#R_T1
CALL @ni_push
JMP @nbi_d
nbi_memcmp:
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
ST r1,r0,#R_T0
CALL @ni_pop
LD r2,r0,#R_T0
LD r3,r0,#R_T2
CALL @ni_memcmp
CALL @ni_push
JMP @nbi_d
nbi_atoi:
CALL @ni_pop
CALL @ni_atoi
CALL @ni_push
JMP @nbi_d
nbi_abs:
CALL @ni_pop
CMPS r1,r0
JMP[GE] @nbi_abs_p
SUB r1,r0,r1
nbi_abs_p:
CALL @ni_push
JMP @nbi_d
nbi_sin:
CALL @ni_pop
CALL @ni_sin
CALL @ni_push
JMP @nbi_d
nbi_cos:
CALL @ni_pop
CALL @ni_cos
CALL @ni_push
JMP @nbi_d
nbi_exit:
CALL @ni_pop
LD r2,r0,#W_TAILHALT
ST r2,r0,#R_IP
JMP @nbi_d
nbi_zero:
MOVI r1,0
CALL @ni_push
nbi_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_call: operand in R_T0
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
MOVI r4,0xFFFF
CMP r5,r4
JMP[EQ] @ncl_bok
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
LD r6,r1,#SY_ARG
ST r4,r0,#W_TY_COUNT
ST r6,r0,#W_TY_BASE
ST r5,r0,#W_TY_RET
; header setup
LD r7,r0,#R_FP
SHR r8,r7,2
ADDI r9,r8,3
LD r10,r9,0
; old frame size = word at old fp + 12
ADD r10,r7,r10
; new fp = old fp + old frame size
ST r10,r0,#W_TY_ID
LA r9,#C_STACK_END
ADD r11,r10,r5
CMP r11,r9
JMP[LE] @ncl_room
MOVI r1,42
CALL @ncc_err
ncl_room:
SHR r12,r10,2
ST r7,r12,0
ADDI r12,r12,1
LD r1,r0,#R_IP
ST r1,r12,0
ADDI r12,r12,1
LD r1,r0,#R_SP
LD r2,r0,#R_T1
SUB r1,r1,r2
ST r1,r12,0
ST r1,r14,0
ADD r14,r14,r13
ADDI r12,r12,1
ST r5,r12,0
; copy args
ST r0,r0,#W_TY_KIND
ncl_copy:
LD r1,r0,#W_TY_KIND
LD r2,r0,#R_T1
CMP r1,r2
JMP[GE] @ncl_copy_d
LD r3,r0,#W_TY_BASE
SHL r4,r1,1
ADD r4,r3,r4
LD r5,r4,0
ADDI r4,r4,1
LD r6,r4,0
ST r5,r0,#W_TY_ALIGN
ST r6,r0,#W_TY_RET
ADD r1,r6,r0
CALL @ty_store_code
ST r1,r0,#W_TY_SIGN
LD r1,r0,#W_TY_ID
LD r2,r0,#W_TY_ALIGN
ADD r1,r1,r2
LD r2,r0,#R_SP
LD r3,r0,#R_T1
SUB r2,r2,r3
LD r3,r0,#W_TY_KIND
ADD r2,r2,r3
LD r2,r2,0
LD r3,r0,#W_TY_SIGN
CALL @ni_storev
LD r1,r0,#W_TY_KIND
ADD r1,r1,r13
ST r1,r0,#W_TY_KIND
JMP @ncl_copy
ncl_copy_d:
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#R_SP
LD r1,r0,#W_TY_ID
ST r1,r0,#R_FP
LD r1,r0,#W_TY_COUNT
ST r1,r0,#R_IP
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
SHR r2,r2,2
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
SHR r2,r2,2
LD r1,r2,1
ST r1,r0,#R_IP
LD r1,r2,0
ST r1,r0,#R_FP
SUB r14,r14,r13
LD r15,r14,0
RET

ncc_ir_loop:
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
MOVI r2,#I_GADDR
CMP r1,r2
JMP[EQ] @nil_gaddr
MOVI r2,#I_STORE_K
CMP r1,r2
JMP[EQ] @nil_storek
MOVI r2,#I_LADDR
CMP r1,r2
JMP[EQ] @nil_laddr
MOVI r2,#I_LOAD
CMP r1,r2
JMP[EQ] @nil_load
MOVI r2,#I_STORE
CMP r1,r2
JMP[EQ] @nil_store
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
MOVI r2,#I_MEMSET
CMP r1,r2
JMP[EQ] @nil_memset
MOVI r2,#I_MEMCPY
CMP r1,r2
JMP[EQ] @nil_memcpy
MOVI r2,#I_CAST
CMP r1,r2
JMP[EQ] @nil_cast
MOVI r2,#I_DIVU
CMP r1,r2
JMP[EQ] @nil_divu
MOVI r2,#I_MODU
CMP r1,r2
JMP[EQ] @nil_modu
MOVI r2,#I_SHRU
CMP r1,r2
JMP[EQ] @nil_shru
MOVI r2,#I_LTU
CMP r1,r2
JMP[EQ] @nil_ltu
MOVI r2,#I_GTU
CMP r1,r2
JMP[EQ] @nil_gtu
MOVI r2,#I_LEU
CMP r1,r2
JMP[EQ] @nil_leu
MOVI r2,#I_GEU
CMP r1,r2
JMP[EQ] @nil_geu
MOVI r2,#I_FADD
CMP r1,r2
JMP[EQ] @nil_fadd
MOVI r2,#I_FSUB
CMP r1,r2
JMP[EQ] @nil_fsub
MOVI r2,#I_FMUL
CMP r1,r2
JMP[EQ] @nil_fmul
MOVI r2,#I_FDIV
CMP r1,r2
JMP[EQ] @nil_fdiv
MOVI r2,#I_FNEG
CMP r1,r2
JMP[EQ] @nil_fneg
MOVI r2,#I_FLT
CMP r1,r2
JMP[EQ] @nil_flt
MOVI r2,#I_FGT
CMP r1,r2
JMP[EQ] @nil_fgt
MOVI r2,#I_FLE
CMP r1,r2
JMP[EQ] @nil_fle
MOVI r2,#I_FGE
CMP r1,r2
JMP[EQ] @nil_fge
MOVI r2,#I_FEQ
CMP r1,r2
JMP[EQ] @nil_feq
MOVI r2,#I_FNE
CMP r1,r2
JMP[EQ] @nil_fne
MOVI r2,#I_EXIT
CMP r1,r2
JMP[EQ] @nil_halt
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
nil_gaddr:
LD r1,r0,#R_T0
CALL @ni_push
JMP @nil_again
nil_laddr:
LD r1,r0,#R_FP
LD r2,r0,#R_T0
ADD r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_load:
CALL @ni_pop
LD r2,r0,#R_T0
CALL @ni_loadv
CALL @ni_push
JMP @nil_again
nil_store:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
LD r3,r0,#R_T0
CALL @ni_storev
JMP @nil_again
nil_storek:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
LD r3,r0,#R_T0
CALL @ni_storev
LD r1,r0,#R_T1
CALL @ni_push
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
nil_divu:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
DIVU r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_modu:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
MODU r1,r1,r2
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
nil_shru:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CALL @ni_shru
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
nil_ltu:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMP r1,r2
MOVI r3,0
MOVI[LT] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_gtu:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMP r1,r2
MOVI r3,0
MOVI[GT] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_leu:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMP r1,r2
MOVI r3,0
MOVI[LE] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_geu:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
CMP r1,r2
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
nil_cast:
CALL @ni_pop
LD r2,r0,#R_T0
MOVI r3,#SZ_8S
CMP r2,r3
JMP[EQ] @nilc_8s
MOVI r3,#SZ_8U
CMP r2,r3
JMP[EQ] @nilc_8u
MOVI r3,#SZ_16S
CMP r2,r3
JMP[EQ] @nilc_16s
MOVI r3,#SZ_16U
CMP r2,r3
JMP[EQ] @nilc_16u
MOVI r3,5
CMP r2,r3
JMP[EQ] @nilc_itof
MOVI r3,6
CMP r2,r3
JMP[EQ] @nilc_ftoi
JMP @nilc_push
nilc_8s:
SHL r1,r1,24
SAR r1,r1,24
JMP @nilc_push
nilc_8u:
MOVI r2,255
BOOL.8 r1,r1,r2
JMP @nilc_push
nilc_16s:
SHL r1,r1,16
SAR r1,r1,16
JMP @nilc_push
nilc_16u:
MOVI r2,0xFFFF
BOOL.8 r1,r1,r2
JMP @nilc_push
nilc_itof:
CVTIF r1,r1
JMP @nilc_push
nilc_ftoi:
CVTFI r1,r1
nilc_push:
CALL @ni_push
JMP @nil_again
nil_memset:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
LD r3,r0,#R_T1
nilms_l:
CMP r3,r0
JMP[EQ] @nil_again
STB r2,r1,0
ADD r1,r1,r13
SUB r3,r3,r13
JMP @nilms_l
nil_memcpy:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
LD r3,r0,#R_T1
nilmc_l:
CMP r3,r0
JMP[EQ] @nil_again
LDB r4,r2,0
STB r4,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @nilmc_l
nil_fadd:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FADD r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_fsub:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FSUB r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_fmul:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FMUL r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_fdiv:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FDIV r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_fneg:
CALL @ni_pop
LA r2,0x80000000
BOOL.6 r1,r1,r2
CALL @ni_push
JMP @nil_again
nil_flt:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FCMP r1,r2
MOVI r3,0
MOVI[LT] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_fgt:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FCMP r1,r2
MOVI r3,0
MOVI[GT] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_fle:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FCMP r1,r2
MOVI r3,0
MOVI[LE] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_fge:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FCMP r1,r2
MOVI r3,0
MOVI[GE] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_feq:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FCMP r1,r2
MOVI r3,0
MOVI[EQ] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_fne:
CALL @ni_pop
ST r1,r0,#R_T1
CALL @ni_pop
LD r2,r0,#R_T1
FCMP r1,r2
MOVI r3,0
MOVI[NE] r3,1
ADD r1,r3,r0
CALL @ni_push
JMP @nil_again
nil_bad:
MOVI r1,46
JMP @ncc_err
