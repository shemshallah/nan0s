
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

.include "mpp.nas"

; ------------------------------------------------------------------ memory map
; Low scratch ABI: words 0xF0000.., above the 64K GUI cartridge.
; Shared preprocessor and NFS scratch use the same relocated address block.
.equ NCC_IRB    1000000      ; IR: 2 words per instruction (byte 4 MB)
.equ NCC_IRMAX  400000
.equ NCC_IREND  1400000
.equ NCC_NAME   1760000      ; identifier spelling pool (4 chars/word)
.equ NCC_NAMEMAX 50000
.equ NCC_STRB   1780000      ; scratch / preprocessor text
.equ NCC_STRMAX 50000
.equ NCC_SYMB   1800000      ; 4096 entries x 16 words
.equ NCC_SYMMAX 65536
.equ NCC_SYMENTRIES 4096
.equ NCC_TYPEB  1870000      ; 4096 type entries x 8 words
.equ NCC_TYPEMAX 32768
.equ NCC_PARM   1910000      ; function parameter descriptor tables
.equ NCC_PARMMAX 32768
.equ NCC_MEMB   1950000      ; struct/union member tables
.equ NCC_MEMBMAX 32768
.equ NCC_CASEB  1990000      ; switch case table: 2048 x (value,target)
.equ NCC_CASEMAX 4096
.equ NCC_GOTOB  2000000      ; pending goto patches: 2048 x (label-sym,jmp-index)
.equ NCC_GOTOMAX 4096
.equ NCC_ESB    1400000      ; expression stack (words; byte 5.6 MB)
.equ NCC_ESMAX  200000
.equ NCC_ESEND  1600000
.equ NCC_PS     1600000      ; compiler/interpreter call stack (words; byte 6.4 MB)
; C program memory is byte-addressed: 4 payload bytes per NaN word.
.equ C_RODATA   500000       ; string literals and const data
.equ C_ROEND    1000000
.equ C_GLOB     1000000      ; globals and static locals
.equ C_GLOBEND  1500000
.equ C_HEAP     8100000      ; growable malloc arena (base)
; The heap ceiling and the C call stack are runtime values: ncc_mem_setup
; asks the VM (CPUID leaf 0x4E4D00FF) for its word count, places an 8 MiB
; stack at the top of the guest C payload (1 MiB on a 16 MiB VM), and makes
; the heap fill everything between C_HEAP and the stack guard.

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
.equ K_WSTRING  10

; token structure: 8 fields + 64 words of packed text
.equ TK_KIND    0
.equ TK_VAL     1
.equ TK_HASH    2
.equ TK_LEN     3
.equ TK_LINE    4
.equ TK_AUX     5
.equ TK_AUXHI   6
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
.equ KW_INLINE   33
.equ KW_RESTRICT 34
.equ KW_BOOL     35
; C11 keywords
.equ KW_STATIC_ASSERT 36
.equ KW_ALIGNOF  37
.equ KW_ALIGNAS  38
.equ KW_GENERIC  39
.equ KW_NORETURN 40
.equ KW_ATOMIC   41
.equ KW_THREAD_LOCAL 42

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
.equ I_CALLI    66
.equ I_CALLB    67
.equ I_RETSTRUCT 68
.equ I_VAARG    69
.equ I_LLEXT    70
.equ I_LLTRUNC  71
.equ I_LLOP     72
.equ I_LLOAD    73
.equ I_LLSTORE  74
.equ I_WORDS    75
.equ I_LLF2I   76
.equ I_LLI2F   77
.equ I_LLBOOL  78
.equ I_LLNEG   79
.equ I_BITSTORE 80
.equ CALB_SCRATCH 2700000

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
.equ TY_BOOL    9
.equ TY_LL      10

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
.equ T_BOOL     12
.equ T_LONGLONG 13
.equ T_ULONGLONG 14

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
.equ B_SQRT 25
.equ B_FABS 26
.equ B_POW 27
.equ B_EXP 28
.equ B_LOG 29
.equ B_LOG10 30
.equ B_TANH 31
.equ B_FLOOR 32
.equ B_CEIL 33
.equ B_FMOD 34
.equ B_FMIN 35
.equ B_FMAX 36
.equ B_TAN 37
.equ B_STRCHR 38
.equ B_STRSTR 39
.equ B_STRDUP 40
.equ B_ISDIGIT 41
.equ B_ISALPHA 42
.equ B_ISSPACE 43
.equ B_ISUPPER 44
.equ B_ISLOWER 45
.equ B_TOUPPER 46
.equ B_TOLOWER 47
.equ B_RAND 48
.equ B_SRAND 49
.equ B_LABS 50
.equ B_MEMMOVE 51
.equ B_SPRINTF 52
.equ B_SNPRINTF 53
.equ B_TIME     54
.equ B_CLOCK    55
.equ B_DIFFTIME 56
.equ B_MKTIME   57
.equ B_LOCALTIME 58
.equ B_GMTIME   59
.equ B_ASCTIME  60
.equ B_CTIME    61
.equ B_SETLOCALE 62
.equ B_LOCALECONV 63
.equ B_SIGNAL   64
.equ B_RAISE    65
.equ B_ATOF     66
.equ B_STRTOD   67
.equ B_FOPEN    68
.equ B_FCLOSE   69
.equ B_FGETC    70
.equ B_FPUTC    71
.equ B_FGETS    72
.equ B_FPUTS    73
.equ B_FREAD    74
.equ B_FWRITE   75
.equ B_FPRINTF  76
.equ B_FSEEK    77
.equ B_FTELL    78
.equ B_REWIND   79
.equ B_FEOF     80
.equ B_FERROR   81
.equ B_FFLUSH   82
.equ B_REMOVE   83
.equ B_RENAME   84
.equ B_SCANF    85
.equ B_FSCANF   86
.equ B_SSCANF   87
.equ B_QSORT    88
.equ B_BSEARCH  89
.equ B_SETJMP   90
.equ B_LONGJMP  91
.equ B_STRFTIME 92
.equ B_TMPNAM   93
.equ B_TMPFILE  94
.equ B_WCSLEN   95
.equ B_WCSCMP   96
.equ B_WCSCPY   97
.equ B_WCSCAT   98
.equ B_ALARM    99
.equ B_STRSPN   100
.equ B_STRCSPN  101
.equ B_STRPBRK  102
.equ B_STRTOK   103
.equ B_GETENV   104
.equ B_SYSTEM   105
.equ B_MEMCHR   106
.equ B_STRCOLL  107
.equ B_STRXFRM  108
.equ B_STRERROR 109
.equ B_PERROR   110
.equ B_WPRINTF  111
.equ B_WSCANF   112
.equ B_STRTOL   113
.equ B_STRTOUL  114
.equ B_STRTOLL  115
.equ B_STRTOULL 116
.equ B_STRRCHR  118
.equ B_STRNDUP  119
.equ B_STPCPY   120
.equ B_MEMCCPY  121
.equ B_GETCHAR  122
.equ B_GETC     123
.equ B_UNGETC   124
.equ B_PUTC     125
.equ B_CLEARERR 126
.equ B_SETVBUF  127
.equ B_VPRINTF  128
.equ B_VFPRINTF 129
.equ B_VSPRINTF 130
.equ B_VSNPRINTF 131
.equ B_ISALNUM  132
.equ B_ISCNTRL  133
.equ B_ISGRAPH  134
.equ B_ISPRINT  135
.equ B_ISPUNCT  136
.equ B_ISXDIGIT 137
.equ B_ATOL     138
.equ B_ATOLL    139
.equ B_ABORT    140
.equ B_SETBUF   141
.equ B_WCSCHR   142
.equ B_WCSRCHR  143
.equ B_WCSNCMP  144
.equ B_WCSNCPY  145
.equ B_WCSNCAT  146
.equ B_WCSSPN   147
.equ B_WCSCSPN  148
.equ B_WCSPBRK  149
.equ B_WCSSTR   150
.equ B_WCSTOK   151
.equ B_WMEMCHR  152
.equ B_WMEMCMP  153
.equ B_WMEMCPY  154
.equ B_WMEMMOVE 155
.equ B_WMEMSET  156
.equ B_BTOWC    157
.equ B_WCTOB    158
.equ B_MBLEN    159
.equ B_MBTOWC   160
.equ B_WCTOMB   161
.equ B_MBSTOWCS 162
.equ B_WCSTOMBS 163
.equ B_EXP2 164
.equ B_LOG2 165
.equ B_LOG1P 166
.equ B_EXPM1 167
.equ B_HYPOT 168
.equ B_CBRT 169
.equ B_SINH 170
.equ B_COSH 171
.equ B_ASINH 172
.equ B_ACOSH 173
.equ B_ATANH 174
.equ B_TRUNC 175
.equ B_ROUND 176
.equ B_RINT 177
.equ B_NEARBYINT 178
.equ B_COPYSIGN 179
.equ B_NAN 180
.equ B_FDIM 181
.equ B_FMA 182
.equ B_DP4B 310
.equ B_ALIGNED_ALLOC 311
.equ B_MODF 183
.equ B_LDEXP 184
.equ B_SCALBN 185
.equ B_REMAINDER 186
.equ B_ATAN     187
.equ B_ATAN2    188
.equ B_ASIN     189
.equ B_ACOS     190
.equ B_ATEXIT   191
.equ B__EXIT    192
.equ B_VSCANF   193
.equ B_VFSCANF  194
.equ B_VSSCANF  195
.equ B_FGETPOS  196
.equ B_FSETPOS  197
.equ B_FREOPEN  198
.equ B_FREXP    199
.equ B_NEXTAFTER 200
.equ B_WCSTOL   201
.equ B_WCSTOUL  202
.equ B_WCSTOLL  203
.equ B_WCSTOULL 204
.equ B_WCSTOD   205
.equ B_WCSTOF   206
.equ B_WCSTOLD  207
.equ B_WCSCOLL  208
.equ B_WCSXFRM  209
.equ B_ERF      210
.equ B_ERFC     211
.equ B_TGAMMA   212
.equ B_LGAMMA   213
.equ B_IFVER    214
.equ B_DIV      215
.equ B_LDIV     216
.equ B_LLDIV    217
.equ B_SETITIMER 218
.equ B_GETITIMER 219
.equ B_STRTOF   220
.equ B_STRTOLD  221
.equ B_LLABS    222
.equ B_STRNCAT  223
.equ B_REMQUO   224
.equ B_MBSINIT  225
.equ B_MBRLEN   226
.equ B_MBRTOWC  227
.equ B_WCRTOMB  228
.equ B_MBSRTOWCS 229
.equ B_WCSRTOMBS 230
.equ B_WCTYPE   231
.equ B_ISWCTYPE 232
.equ B_WCTRANS  233
.equ B_TOWCTRANS 234
.equ B_ASSERT   235
.equ B_FWIDE    236
.equ B_MBRTOC16 237
.equ B_C16RTOMB 238
.equ B_MBRTOC32 239
.equ B_C32RTOMB 240
.equ B_FWPRINTF 241
.equ B_FWSCANF  242
.equ B_SWPRINTF 243
.equ B_VSWPRINTF 244
.equ B_VFWPRINTF 245
.equ B_VFWSCANF 246
.equ B_VSWSCANF 247
.equ B_SWSCANF  248
.equ B_ATOMIC_INIT 249
.equ B_ATOMIC_LOAD 250
.equ B_ATOMIC_STORE 251
.equ B_ATOMIC_EXCH 252
.equ B_ATOMIC_CAS  253
.equ B_ATOMIC_FADD 254
.equ B_ATOMIC_FSUB 255
.equ B_ATOMIC_FOR  256
.equ B_ATOMIC_FXOR 257
.equ B_ATOMIC_FAND 258
.equ B_ATOMIC_FLAG_TAS 259
.equ B_ATOMIC_FLAG_CLR 260
.equ B_ATOMIC_FENCE 261
.equ B_ATOMIC_ISLF 262
.equ B_ATOMIC_LOAD_EX 263
.equ B_ATOMIC_STORE_EX 264
.equ B_ATOMIC_EXCH_EX 265
.equ B_ATOMIC_CAS_EX 266
.equ B_ATOMIC_FADD_EX 267
.equ B_ATOMIC_FSUB_EX 268
.equ B_ATOMIC_FOR_EX 269
.equ B_ATOMIC_FXOR_EX 270
.equ B_ATOMIC_FAND_EX 271
.equ B_ATOMIC_FLAG_TAS_EX 272
.equ B_ATOMIC_FLAG_CLR_EX 273
.equ B_FEGETROUND 274
.equ B_FESETROUND 275
.equ B_FECLEAREXCEPT 276
.equ B_FERAISEEXCEPT 277
.equ B_FETESTEXCEPT 278
.equ B_FEGETENV 279
.equ B_FESETENV 280
.equ B_FEHOLDEXCEPT 281
.equ B_FEUPDATEENV 282
.equ B_FEGETEXCEPTFLAG 283
.equ B_FESETEXCEPTFLAG 284
.equ B_THRD_CREATE 285
.equ B_THRD_JOIN 286
.equ B_THRD_CURRENT 287
.equ B_THRD_EQUAL 288
.equ B_THRD_SLEEP 289
.equ B_THRD_YIELD 290
.equ B_THRD_EXIT 291
.equ B_THRD_DETACH 292
.equ B_MTX_INIT 293
.equ B_MTX_LOCK 294
.equ B_MTX_TRYLOCK 295
.equ B_MTX_TIMEDLOCK 296
.equ B_MTX_UNLOCK 297
.equ B_MTX_DESTROY 298
.equ B_CND_INIT 299
.equ B_CND_SIGNAL 300
.equ B_CND_BROADCAST 301
.equ B_CND_WAIT 302
.equ B_CND_TIMEDWAIT 303
.equ B_CND_DESTROY 304
.equ B_TSS_CREATE 305
.equ B_TSS_GET 306
.equ B_TSS_SET 307
.equ B_TSS_DELETE 308
.equ B_CALL_ONCE 309

; ------------------------------------------------------------------ compiler state
; Kept below word 65536 so ST/LD can use the 16-bit immediate form directly.
.equ W_IRPC     0xF0000
.equ W_SYMUSED  0xF0001
.equ W_GLOBUSED 0xF0002
.equ W_NAMEP    0xF0003
.equ W_STRP     0xF0004
.equ W_FUNCSYM  0xF0005
.equ W_NLOC     0xF0006
.equ W_NPAR     0xF0007
.equ W_LVAL     0xF0008
.equ W_LKIND    0xF0009
.equ W_LADDR    0xF000A
.equ W_HAVE     0xF000B
.equ W_ERRCODE  0xF000C
.equ W_BRK_N    0xF000D
.equ W_CNT_N    0xF000E
.equ W_ETYPE    0xF000F
.equ W_LTYPE    0xF0010
.equ W_SCLASS   0xF0011
.equ W_TYPEN    0xF0012
.equ W_GLOBP    0xF0013
.equ W_LOCALB   0xF0014
.equ W_FRAMEB   0xF0015
.equ W_FUNCRET  0xF0016
.equ W_PARAMP   0xF0017
.equ W_MEMBP    0xF0018
.equ W_STRUCTID 0xF0019
.equ W_FUNCNP   0xF001A
.equ W_FUNCARG  0xF001B
.equ W_SW_N     0xF001C
.equ W_SW_TAB   0xF0020      ; 16 entries x 2 words (value, jmp-index)
.equ W_CASE_N   0xF001D
.equ W_GOTO_N   0xF001E
.equ W_DECLNAME 0xF0028      ; saved declarator token: hash, len, text[8]
.equ W_TY_TMP   0xF0034
.equ W_PP_N     0xF0035
.equ W_BRK_TAB  0xF0040      ; 64 entries
.equ W_CNT_TAB  0xF0080      ; 64 entries
.equ W_LOOPN    0xF0258
.equ W_LOOPS    0xF0260      ; 32 contexts x 8 words
.equ W_SIDX     0xF0384
.equ W_SKIND    0xF0385
.equ W_MIDX     0xF0386
.equ W_BID      0xF0387
.equ W_BNP      0xF0388
.equ W_TMP2     0xF0389
.equ W_PSAVE    0xF038A
.equ W_PSAVE2   0xF038B
.equ W_FSKIP    0xF038C
.equ W_FENTRY   0xF038D
.equ W_TY_KIND  0xF0398
.equ W_TY_SIZE  0xF0399
.equ W_TY_ALIGN 0xF039A
.equ W_TY_BASE  0xF039B
.equ W_TY_COUNT 0xF039C
.equ W_TY_MEM   0xF039D
.equ W_TY_NMEM  0xF039E
.equ W_TY_SIGN  0xF039F
.equ W_TY_RET   0xF03A0
.equ W_TY_ID    0xF03A1
.equ W_TSIGN    0xF03A2
.equ W_TSHORT   0xF03A3
.equ W_TLONG    0xF03A4
.equ W_TLL      0xF0628
.equ W_CALLWORDS 0xF0635
.equ W_SRCOFF  0xF0638
.equ W_CALLSYM 0xF0639
.equ W_ARGIDX  0xF063A
.equ W_CASTTYPE 0xF063B
.equ W_FPSTART  0xF063C
.equ W_CALLFTYPE 0xF063D
.equ W_FPTMP   0xF063E
.equ W_DECL_CONST 0xF0664
.equ W_DECL_HASH  0xF0665
.equ W_LCONST     0xF0666
.equ W_TCONST     0xF0668
.equ W_MARK_CONST 0xF0669
.equ W_CONSTSYM 0xF066A
.equ W_MEMIDX  0xF0672
.equ W_DESIDX  0xF0673
.equ W_DESOFF  0xF0674
.equ W_DESTYPE 0xF0675
.equ W_ELEMSZ  0xF0676
.equ W_EL_ELEM 0xF0677
.equ W_EL_COUNT 0xF0678
.equ W_EL_BASE 0xF0679
.equ W_EL_GLB 0xF067A
.equ W_EL_FIRST 0xF067B
.equ W_EL_I 0xF067C
.equ W_EL_M 0xF067D
.equ W_EL_ESIZE 0xF067E
.equ W_EL_MEM 0xF067F
.equ W_EL_NMEM 0xF0680
.equ W_EL_OFF 0xF0681
.equ W_EL_MTYPE 0xF0682
.equ W_ARRMAX 0xF0698
.equ W_ELT_TYPE 0xF06AE
.equ W_ELT_ELEM 0xF06AF
.equ W_ELT_ESZ  0xF06B0
.equ W_ELT_N    0xF06B1
.equ W_ELT_I    0xF06B2
.equ W_ELT_MEM  0xF06B3
.equ W_ELT_NMEM 0xF06B4
.equ W_ELT_KIND 0xF06B5
.equ W_ELT_OFF  0xF06B6
.equ W_ELT_MT   0xF06B7
.equ W_ELT_TMP  0xF06B8
.equ W_SIGLB    0xF06B9
.equ W_FPOFF   0xF066B
.equ W_FPNP1   0xF066C
.equ W_FPDEF   0xF066E
.equ W_OUTER   0xF066D
.equ W_CN_N       0xF0667
.equ NCTAB        2300000
.equ W_IRYSTOP 0xF0641
.equ W_ALARM   0xF0671
.equ W_CMPFP   0xF0642
.equ W_CMPA    0xF0643
.equ W_CMPB    0xF0644
.equ W_CMPOLD  0xF0645
.equ QS_BASE   0xF0646
.equ QS_N      0xF0647
.equ QS_SIZE   0xF0648
.equ QS_CMP    0xF0649
.equ QS_I      0xF064A
.equ QS_J      0xF064B
.equ QS_P1     0xF064C
.equ QS_P2     0xF064D
.equ QS_KEY    0xF064E
.equ W_CALLENTRY 0xF064F
.equ W_DECLTYPE 0xF0650
.equ W_TCHAR    0xF03A5
.equ W_TVOID    0xF03A6
.equ W_TFLOAT   0xF03A7
.equ W_TAGSYM   0xF03A8
.equ W_ARRDIM   0xF03A9      ; 8 dimensions
.equ W_ARRND    0xF03B1
.equ W_SW_PATCH  0xF03B2
.equ W_GOTO_PATCH 0xF03B3
.equ W_GOTO_NAME 0xF03B4
.equ W_PP_ACTIVE 0xF03B5
.equ W_ENUMVAL  0xF03B6
.equ W_SSIZE    0xF03C0
.equ W_SALIGN   0xF03C1
.equ W_SMEM     0xF03C2
.equ W_SNMEM    0xF03C3
.equ W_MEMTOP   0xF03F1
.equ W_SSDEPTH  0xF03F2
.equ W_SDOWN    0xF03F3
.equ W_SANON    0xF03F4
.equ W_ML_SOFT  0xF03F5
.equ W_ANON_TY  0xF03F6
.equ W_ANON_OFF 0xF03F7
.equ W_SSPKIND  0xF0401
.equ W_STAG     0xF03C4
.equ W_SOFF     0xF03C5
.equ W_STYPE    0xF03C6
.equ W_STMP     0xF03C7
.equ W_STRUCTKIND    0xF03C8
.equ W_MSIZE    0xF03C9
.equ W_TSEEN    0xF03CA
.equ W_BRET     0xF03D5
.equ W_HEAP     0xF03D6
.equ W_TAILHALT 0xF03D7
.equ W_PTRV     0xF03D8
.equ W_PTRC     0xF03D9
.equ W_PF_FMT   0xF03DA
.equ W_PF_IDX   0xF03DB
.equ W_PF_ARGC  0xF03DC
.equ W_PF_OFF   0xF03DD
.equ W_PF_LL    0xF03DE
.equ W_PF_CASE  0xF03DF
.equ W_PF_W     0xF03E0
.equ W_PF_FLAGS 0xF03E1
.equ W_PF_VAL   0xF03E2
.equ W_PF_LEN   0xF03E3
.equ W_PF_PAD   0xF03E4
.equ W_PF_NEG   0xF03E5
.equ W_PF_TMP   0xF03E6
.equ W_PF_PREC  0xF03E7
.equ W_F2V      0xF03E8
.equ W_F2P      0xF03E9
.equ W_F2NEG    0xF03EA
.equ W_F2S      0xF03EB
.equ W_F2I      0xF03EC
.equ W_F2F      0xF03ED
.equ W_F2L      0xF03EE
.equ W_F2BIG    0xF03EF
.equ W_PF_LSTR   0xF03F0
; libm soft-double scratch (ni_sin/ni_cos range reduction and kernels)
.equ W_LM_X     0xF076C
.equ W_LM_AX    0xF076D
.equ W_LM_N     0xF076E
.equ W_LM_ND    0xF076F
.equ W_LM_Q     0xF0770
.equ W_LM_RH    0xF0771
.equ W_LM_RL    0xF0772
.equ W_LM_ZH    0xF0773
.equ W_LM_ZL    0xF0774
.equ W_LM_AH    0xF0775
.equ W_LM_AL    0xF0776
.equ W_LM_PH    0xF0777
.equ W_LM_PL    0xF0778
.equ W_LM_TH    0xF0779
.equ W_LM_TL    0xF077A
.equ W_LM_C     0xF077B
.equ W_LM_SG    0xF077C
.equ W_EXITCODE  0xF0474      ; last main()/exit() status, returned by ncc_run
.equ W_INCSTEP   0xF0475      ; ++/-- step preserved across px_emit_store
.equ W_PARM_SAVE 0xF0476      ; saved W_PARAMP across member funcptr params
.equ W_BUILTIN_IDX 0xF0477    ; builtin shadowed by a prototype, or -1
.equ W_EXISTFUNC 0xF0478      ; existing function/prototype with same name, or -1
.equ W_SWSAVE   0xF0479      ; switch break-count saved across break patching
.equ W_DECLBASE 0xF047A      ; unsuffixed base type for a declarator list
.equ W_DECLFLAG 0xF047B      ; first declarator's pointer suffix already consumed
.equ W_BITUNIT   0xF0708
.equ W_BITUSED   0xF0709
.equ W_MEMBIT    0xF070A
.equ W_LBIT      0xF070B
.equ W_BF_ADDR   0xF070C
.equ W_BF_VAL    0xF070D
.equ W_BF_MASK   0xF070E
.equ W_BF_FIELD  0xF070F
.equ W_BF_UNIT   0xF0710
.equ W_BF_BITS   0xF0711
.equ W_BF_OFF    0xF0712
.equ W_BITS_W    0xF0713
.equ W_STBIT     0xF0714
.equ W_ELT_BIT   0xF0715
.equ W_EX_A      0xF0716
.equ W_EX_B      0xF0717
.equ W_RAND_INIT 0xF0718
.equ W_HEAP_INIT 0xF0719
.equ W_FREELIST  0xF071A
.equ W_ALLOC_NEED 0xF071B
.equ W_ALLOC_BLK 0xF071D
.equ W_ALLOC_SIZE 0xF071E
.equ W_ALLOC_A   0xF071F
.equ W_ALLOC_B   0xF0720
.equ W_ALLOC_OLD 0xF0721
.equ W_ALLOC_NEW 0xF0722
.equ W_AGHI     0xF0723
.equ W_HEAP_LIMIT 0xF0730
.equ W_MEM_WORDS  0xF0734
.equ W_C_STACK    0xF0735
.equ W_C_STACK_END 0xF0736
.equ W_HEAP_END   0xF0737
.equ W_ALIGN      0xF0738
.equ W_ERRNO     0xF0703
.equ W_FWIDE_STD 0xF0704
.equ W_STDPB     0xF071C
.equ W_DK_I      0xF0726
.equ W_DK_N      0xF0727
.equ W_ATEXIT_N 0xF0762
.equ W_ATEXIT_I 0xF0763
.equ W_ATEXIT_SYM 0xF0764
.equ W_ATEXIT_OLD 0xF0765
.equ W_ATEXIT_SKIP 0xF0766
.equ W_GM_X     0xF075C
.equ W_GM_SIGN  0xF075D
.equ W_GM_S     0xF075E
.equ W_SIGNGAM  0xF075F
.equ W_GM_A     0xF0760
.equ W_GM_P     0xF0761
.equ W_DIVTYPE  0xF0768
.equ W_LDIVTYPE 0xF0769
.equ W_LLDIVTYPE 0xF076A
.equ W_IT_INTERVAL 0xF076B
.equ W_ATEXIT_RUN 0xF0767
.equ W_VARNP    0xF056E
.equ W_VARFLAG  0xF056F
.equ W_VARCNT   0xF0571
.equ W_ITYPE    0xF058C
.equ W_INOFF    0xF058D
.equ W_INTYPE   0xF058E
.equ W_INMEM    0xF058F
.equ W_INNMEM   0xF0590
.equ W_INUM     0xF0591
.equ W_II       0xF0592
.equ W_IELEM    0xF0593
.equ W_IESZ     0xF0594
.equ W_INNUM    0xF0595
.equ W_BITW     0xF0596
.equ W_SBASE    0xF059A
.equ W_RAND     0xF059B
.equ W_SNOUT    0xF059C
.equ W_SNLIM    0xF059D
.equ W_SNPOS    0xF059E
.equ W_SNTMP1   0xF059F
.equ W_SNTMP2   0xF05A0
.equ W_SNTMP3   0xF05A1
.equ W_SNREG1   0xF05A2
.equ W_SNREG2   0xF05A3
.equ W_SNREG3   0xF05A4
.equ W_F2EXP    0xF05A5
.equ W_F2SIGN2  0xF05A6
.equ W_F2TMP    0xF05A7
.equ W_AGVAL    0xF05F4
.equ W_AGSYM    0xF05F5
.equ W_AMTYP    0xF05F6
.equ W_AMOFF    0xF05F7
.equ W_AMHASH   0xF05F8
.equ W_AMNAME   0xF05F9
.equ W_AMLEN    0xF05FA
.equ W_TMTYPE   0xF05FB
.equ W_TM0      0xF05FC
.equ W_TM1      0xF05FD
.equ W_TM2      0xF05FE
.equ W_TM3      0xF05FF
.equ W_TM4      0xF0600
.equ W_TM5      0xF0601
.equ W_TM6      0xF0602
.equ W_TM7      0xF0603
.equ W_TM8      0xF0604
.equ W_TA       0xF0605
.equ W_TB       0xF0606
.equ W_TC       0xF0607
.equ W_TD       0xF0608
.equ W_TE       0xF0609
.equ W_TF       0xF060A
.equ W_TKPTR    0xF03DE
.equ W_CASEBASE 0xF03CB
.equ W_DEFSET   0xF03CC
.equ W_DEFTGT   0xF03CD
.equ W_SWDISP   0xF03CE
.equ W_SWFALL   0xF03CF
.equ W_SWTMP    0xF03D0
.equ W_SWNO     0xF03D1
.equ W_SWEND    0xF03D2
.equ W_SWI      0xF03D3
.equ W_TMP3     0xF03D4
; C11 language helpers
.equ W_ALIGNAS  0xF06F6
.equ W_CNST_START 0xF06F7
.equ W_CNST_SAVE 0xF06F8
.equ W_CNST_FP  0xF06EA
.equ W_CNST_STOP 0xF06EB
.equ W_CNST_ALARM 0xF06EC
.equ W_GEN_TYPE 0xF06F9
.equ W_GEN_DONE 0xF06FA
.equ W_GEN_TMP  0xF06FB
.equ W_SCAN_DEPTH 0xF06FC
.equ W_ISO_TMP  0xF06FD
.equ W_CPLX_BASE 0xF06ED
.equ W_CPLX_TYPE 0xF06EE
.equ W_CPLX_LOCAL 0xF06EF
.equ W_CPLX_N   0xF06F0
.equ W_LEXWIDE  0xF06DF
.equ ISO_SAVE   960000      ; free words between MP buffers and IR
.equ W_TKA      0xF00C8
.equ W_TKB      0xF0110
.equ W_TMP      0xF0190
.equ W_DECBUF   0xF0192      ; 10 words

; lexer globals (absolute words)
.equ L_WP       0xF01C2
.equ L_BI       0xF01C3
.equ L_LINE     0xF01C4
.equ L_CH       0xF01C5
.equ L_TOKP     0xF01C6
.equ L_TADDR    0xF01C7
.equ L_TCNT     0xF01C8
.equ L_TMP0     0xF01C9
.equ L_TMP1     0xF01CA
.equ L_TMP2     0xF01CB
.equ L_TMP3     0xF01CC
.equ L_TMP4     0xF01CD
.equ L_TMP5     0xF01CE
.equ L_KIND     0xF01CF
.equ L_VAL      0xF01D0
.equ L_LL       0xF01D5
.equ L_UNS      0xF01D6
.equ L_VALH     0xF01D7
.equ L_HASH     0xF01D1
.equ L_LEN      0xF01D2
.equ L_TLINE    0xF01D3
.equ L_TCAP     0xF01D4

; parser/interpreter globals
.equ R_PC       0xF01F4
.equ R_SP       0xF01F5
.equ R_FP       0xF01F6
.equ R_RETV     0xF01F7
.equ R_IP       0xF01F8
.equ R_T0       0xF01F9
.equ R_T1       0xF01FA
.equ R_T2       0xF01FB

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
.equ WQ_WP     0xF04B0
.equ WQ_BI     0xF04B1
.equ WQ_OUT    0xF04B2
.equ WQ_ACT    0xF04B3
.equ WQ_DEPTH  0xF04B4
.equ WQ_NAMEP  0xF04B5
.equ WQ_MACN   0xF04B6
.equ WQ_HASH   0xF04B7
.equ WQ_ILEN   0xF04B8
.equ WQ_LEN    0xF04B9
.equ WQ_T0     0xF04BA
.equ WQ_T1     0xF04BB
.equ WQ_T2     0xF04BC
.equ WQ_T3     0xF04BD
.equ WQ_Q      0xF04BE
.equ WQ_ESC    0xF04BF
.equ WQ_CMT    0xF04C0
.equ WQ_P0     0xF04C1

.equ Q2MAC      2000000
.equ Q2MACMAX   256
.equ Q2COND     2001024
.equ Q2BUF      8020000
.equ W_Q2N      0xF0514
.equ W_Q2SKIP   0xF0515
.equ W_Q2DEPTH  0xF0516
.equ W_Q2HASH   0xF0517
.equ W_Q2LEN    0xF0518
.equ W_Q2VAL    0xF0519
.equ W_Q2T0     0xF051A
.equ W_Q2SIGN   0xF051B
.equ W_Q2PTR    0xF051C
.equ W_SCOPEID 0xF051E
.equ W_FORCENEW 0xF051F
.equ W_NEXTSCOPE 0xF0520
.equ W_IDXTYPE 0xF053D
.equ W_CALLV    0xF0546
.equ W_FPSYM    0xF0547
.equ W_FPTR_TYPE 0xF0548
.equ W_FPGLOBAL 0xF0549
.equ W_FPRET    0xF054A
.equ W_FPNP     0xF054B
.equ W_SCOPEPAR 2001200
.include "timeb.nas"
.include "ata.nas"
.include "bare.nas"
.include "nfs2.nas"
.include "stdio.nas"
.include "vprintf.nas"
.include "vscanf.nas"
.include "scanf.nas"
.include "ll.nas"
.include "qsort.nas"
.include "setjmp.nas"
.include "libcx.nas"
.include "strx.nas"
.include "wide.nas"
.include "wide2.nas"
.include "mathx.nas"
.include "wcsto.nas"
.include "strtox.nas"
.include "mbs.nas"
.include "extra.nas"
.include "iso.nas"
.include "headers.nas"

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
LA r1,@q2s_include
CALL @q2_bufeq
CMP r1,r0
JMP[EQ] @q2dir_notinc
CALL @q2dir_include
JMP @q2dir_ret
q2dir_notinc:
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
; still track nesting, but do not evaluate the expression
MOVI r1,0
CALL @q2_cond_push
JMP @q2dir_eat
q2dif_eval:
CALL @ppe_expr_eval
CALL @q2_cond_push
JMP @q2dir_eat
q2dir_elif:
CALL @ppe_expr_eval
CALL @q2_cond_elif
JMP @q2dir_eat
q2dir_else:
CALL @q2_cond_else
JMP @q2dir_eat
q2dir_endif:
CALL @q2_cond_pop
q2dir_eat:
CALL @q2_eat
q2dir_ret:
SUB r14,r14,r13
LD r15,r14,0
RET

q2s_define:
.str "define"
q2s_undef:
.str "undef"
q2s_include:
.str "include"
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

.include "ppexpr.nas"
.include "nccinc.nas"

; ------------------------------------------------------------------ entry points
ncc_compile:
ST r14,r0,@ncc_recover_sp
ST r15,r0,@ncc_recover_lr
ST r14,r0,#W_PSAVE
LA r14,#NCC_PS
ST r15,r14,0
ADD r14,r14,r13
CALL @mp_preprocess
ST r1,r0,#L_WP
ST r0,r0,#L_BI
MOVI r1,1
ST r1,r0,#L_LINE
CALL @inc_init
ST r0,r0,#W_Q2N
ST r0,r0,#W_Q2SKIP
ST r0,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
LA r1,0xFFFFFFFF
ST r1,r0,#W_SNLIM
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
LA r2,#NCC_MEMBMAX
ADD r1,r1,r2
ST r1,r0,#W_MEMTOP
ST r0,r0,#W_SSDEPTH
ST r0,r0,#W_SDOWN
MOVI r1,16
ST r1,r0,#W_LOCALB
ST r1,r0,#W_FRAMEB
CALL @ncc_types_init
CALL @ncc_builtins
CALL @iso_register_all
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
MOVI r1,0
RET

; ncc_mem_setup: size the C heap and stack from the VM's actual memory.
; CPUID 0x4E4D00FF: 0=mask 1=words 2=flags 3=payload bytes.  An older VM
; (or unrelated CPUID) leaves the historical 4M-word/16 MiB layout.
ncc_mem_setup:
ST r15,r14,0
ADD r14,r14,r13
LA r1,0x4E4D00FF
MOVI r2,2
CPUID r3,r1,r2
LA r4,0xFFFF0000
BOOL.8 r5,r3,r4
LA r4,0x4E160000
CMP r5,r4
JMP[NE] @nms_default
MOVI r2,1
CPUID r3,r1,r2
CMP r3,r0
JMP[NE] @nms_have
nms_default:
LA r3,0x400000      ; 4M words = 16 MiB payload
nms_have:
LA r4,0x10000000    ; cap at the 2^28-word flat-memory limit
CMP r3,r4
JMP[LE] @nms_words
ADD r3,r4,r0
nms_words:
ST r3,r0,#W_MEM_WORDS
SHL r4,r3,2         ; payload bytes
SHR r5,r4,4         ; stack = 1/16 of payload
LA r6,0x100000      ; at least 1 MiB
CMP r5,r6
JMP[GE] @nms_stk_lo
ADD r5,r6,r0
nms_stk_lo:
LA r6,0x800000      ; at most 8 MiB
CMP r5,r6
JMP[LE] @nms_stk_hi
ADD r5,r6,r0
nms_stk_hi:
SHR r5,r5,2
SHL r5,r5,2
SUB r4,r4,r5        ; heap ceiling = payload - stack
SHR r4,r4,2
SHL r4,r4,2
LA r6,#C_HEAP
CMP r4,r6
JMP[GE] @nms_heap
ADD r4,r6,r0
nms_heap:
ST r4,r0,#W_HEAP_END
ST r4,r0,#W_C_STACK
SHL r5,r3,2
ST r5,r0,#W_C_STACK_END
SUB r14,r14,r13
LD r15,r14,0
RET

ncc_run:
ST r14,r0,@ncc_recover_sp
ST r15,r0,@ncc_recover_lr
ST r14,r0,#W_PSAVE2
LA r14,#NCC_PS
ST r15,r14,0
ADD r14,r14,r13
CALL @ncc_mem_setup
ST r0,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
; fresh C heap for this run: discard compiler-side allocations and start
; with one free block spanning C_HEAP..C_HEAP_END
ST r0,r0,#W_HEAP_INIT
ST r0,r0,#W_FREELIST
ST r0,r0,#W_HEAP_LIMIT
LA r1,#NCC_ESB
ST r1,r0,#R_SP
ST r0,r0,#W_IRYSTOP
ST r0,r0,#W_ALARM
ST r0,r0,#W_ATEXIT_RUN
ST r0,r0,#W_ATEXIT_N
LA r1,0xFFFFFFFF
ST r1,r0,#W_EXITCODE
LD r1,r0,#W_C_STACK
ST r1,r0,#R_FP
LA r1,#NCC_IRB
ST r1,r0,#R_IP
LD r2,r0,#W_C_STACK
SHR r2,r2,2
ADDI r2,r2,3
ST r0,r2,0
ADDI r2,r2,-3
ST r0,r2,0
CALL @ncc_ir_loop
; The compiler tail is CALL main; HALT, so a normal fall-through leaves
; main's return value on top of the expression stack. exit()/_Exit()/abort()
; record their own status before halting. Capture the status only here, after
; the outermost loop; nested callback loops (qsort/bsearch/atexit) must not
; consume their return values from the expression stack.
LD r1,r0,#W_EXITCODE
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @nrun_status_done
LD r1,r0,#R_SP
LA r2,#NCC_ESB
CMP r1,r2
JMP[LE] @nrun_status_zero
SUB r1,r1,r13
ST r1,r0,#R_SP
LD r2,r1,0
ST r2,r0,#W_EXITCODE
JMP @nrun_status_done
nrun_status_zero:
ST r0,r0,#W_EXITCODE
nrun_status_done:
LD r1,r0,#W_EXITCODE
SUB r14,r14,r13
LD r15,r14,0
LD r14,r0,#W_PSAVE2
RET

; ------------------------------------------------------------------ output
; Every character the compiler/runtime prints goes through ncc_putc.
; ncc_out = 0 -> COM1; otherwise it is a guest function pointer called with
; r1=char and must preserve r2..r12 (the GUI terminal hook does).
ncc_putc:
LD r2,r0,#W_SNOUT
CMP r2,r0
JMP[NE] @npc_buf
LD r2,r0,@ncc_out
CMP r2,r0
JMP[EQ] @npc_serial
ST r15,r14,0
ADD r14,r14,r13
CALLR r2
SUB r14,r14,r13
LD r15,r14,0
RET
npc_buf:
ST r2,r0,#W_SNREG1
ST r3,r0,#W_SNREG2
ST r4,r0,#W_SNREG3
LD r3,r0,#W_SNPOS
LD r4,r0,#W_SNLIM
CMP r3,r4
JMP[GE] @npc_buf_skip
ADD r2,r2,r3
STB r1,r2,0
npc_buf_skip:
ADD r3,r3,r13
ST r3,r0,#W_SNPOS
LD r2,r0,#W_SNREG1
LD r3,r0,#W_SNREG2
LD r4,r0,#W_SNREG3
RET
npc_serial:
ST r15,r14,0
ADD r14,r14,r13
LA r2,@bare_table
LD r2,r2,1
CALLR r2
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ fatal errors
; ncc_err: r1=code. Prints !Cxxxx@yyyy and halts.
ncc_err:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ERRCODE
LD r2,r0,@ncc_recover
CMP r2,r0
JMP[EQ] @nerr_report
ST r0,r0,#W_SNOUT
nerr_report:
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
LD r2,r0,@ncc_recover
CMP r2,r0
JMP[EQ] @nerr_halt
; Recover to top-level compile/run caller, not a nested parser frame.
LD r1,r0,#W_ERRCODE
LD r14,r0,@ncc_recover_sp
LD r15,r0,@ncc_recover_lr
RET
nerr_halt:
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
; 12 _Bool
MOVI r1,12
MOVI r2,#TY_BOOL
MOVI r3,1
MOVI r4,1
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
; 13 long long, 14 unsigned long long
MOVI r1,13
MOVI r2,#TY_LL
MOVI r3,8
MOVI r4,8
MOVI r5,1
MOVI r6,0
CALL @ty_set
MOVI r1,14
MOVI r2,#TY_LL
MOVI r3,8
MOVI r4,8
MOVI r5,0
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

; ty_func_set_params: r1=func type, r2=param type array ptr, r3=count
ty_func_set_params:
SHL r1,r1,3
LA r4,#NCC_TYPEB
ADD r1,r1,r4
ST r2,r1,#TY_MEM
ST r3,r1,#TY_NMEM
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

; ty_bitfield: r1=base integer type, r2=width -> bitfield type id
; The field occupies the base type's full storage; reads/writes are masked.
ty_bitfield:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
ST r2,r0,#W_BITW
LD r1,r0,#W_TY_TMP
CALL @ty_addr
LD r3,r1,#TY_KIND
ST r3,r0,#W_TY_KIND
LD r3,r1,#TY_SIZE
ST r3,r0,#W_TY_SIZE
LD r3,r1,#TY_ALIGN
ST r3,r0,#W_TY_ALIGN
LD r3,r0,#W_TY_TMP
ST r3,r0,#W_TY_BASE
LD r3,r0,#W_BITW
ST r3,r0,#W_TY_COUNT
ST r0,r0,#W_TY_MEM
ST r0,r0,#W_TY_NMEM
LD r1,r0,#W_TY_TMP
CALL @ty_addr
LD r3,r1,#TY_SIGN
ST r3,r0,#W_TY_SIGN
CALL @ty_new
SUB r14,r14,r13
LD r15,r14,0
RET

; ty_bitwidth: r1=type -> r2=bit width (0 if not a bit-field type)
ty_bitwidth:
SHL r1,r1,3
LA r3,#NCC_TYPEB
ADD r1,r1,r3
LD r2,r1,#TY_KIND
MOVI r3,#TY_INT
CMP r2,r3
JMP[EQ] @tbw_int
MOVI r3,#TY_ENUM
CMP r2,r3
JMP[NE] @tbw_none
tbw_int:
LD r2,r1,#TY_COUNT
CMP r2,r0
JMP[EQ] @tbw_none
MOVI r3,32
CMP r2,r3
JMP[GE] @tbw_none
RET
tbw_none:
MOVI r2,0
RET

; ty_common: r1=a r2=b -> C usual arithmetic type
ty_common:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
ST r2,r0,#W_TY_ID
CALL @ty_kind
MOVI r3,#TY_LL
CMP r1,r3
JMP[EQ] @tyc_ll
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r3,#TY_LL
CMP r1,r3
JMP[EQ] @tyc_ll
LD r1,r0,#W_TY_TMP
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
tyc_ll:
LD r1,r0,#W_TY_TMP
CALL @ty_sign
ST r1,r0,#W_TY_SIGN
LD r1,r0,#W_TY_ID
CALL @ty_sign
LD r2,r0,#W_TY_SIGN
BOOL.8 r1,r1,r2
CMP r1,r0
JMP[EQ] @tyc_ull
MOVI r1,#T_LONGLONG
JMP @tyc_d
tyc_ull:
MOVI r1,#T_ULONGLONG
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
; wide string literal L"..."
MOVI r2,76
CMP r1,r2
JMP[NE] @lx_not_wide
MOVI r10,1
CALL @peekn
MOVI r2,34
CMP r1,r2
JMP[NE] @lx_not_wstr
CALL @lx_get
MOVI r1,1
ST r1,r0,#W_LEXWIDE
CALL @scan_string
JMP @lx_fin
lx_not_wstr:
MOVI r2,39
CMP r1,r2
JMP[NE] @lx_not_wide
CALL @lx_get
CALL @scan_char
JMP @lx_fin
lx_not_wide:
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
LD r1,r0,#L_KIND
MOVI r3,#K_INT
CMP r1,r3
JMP[NE] @lxf_auxd
LD r1,r0,#L_LL
LD r3,r0,#L_UNS
SHL r3,r3,1
BOOL.14 r1,r1,r3
ST r1,r2,#TK_AUX
LD r1,r0,#L_VALH
ST r1,r2,#TK_AUXHI
lxf_auxd:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- cursor -------------------------------------------------------
lx_peek:
LD r2,r0,#W_INC_SYNTH
CMP r2,r0
JMP[EQ] @lpk_nosynth
MOVI r1,10
RET
lpk_nosynth:
LD r2,r0,#L_WP
lpk_top:
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
CMP r1,r0
JMP[NE] @lpk_ret
; end of an included file: resume the including file transparently
LD r3,r0,#W_INC_DEPTH
CMP r3,r0
JMP[EQ] @lpk_ret
ST r15,r0,#W_INC_RET
CALL @inc_pop
LD r15,r0,#W_INC_RET
JMP @lx_peek
lpk_ret:
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
LD r2,r0,#W_INC_SYNTH
CMP r2,r0
JMP[EQ] @lgt_normal
ST r0,r0,#W_INC_SYNTH
MOVI r1,10
ST r1,r0,#L_CH
LD r2,r0,#L_LINE
ADD r2,r2,r13
ST r2,r0,#L_LINE
LD r1,r0,#L_CH
JMP @lgt_d
lgt_normal:
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
JMP[NE] @sw_skip_ws
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
ST r0,r0,#L_LL
ST r0,r0,#L_UNS
CALL @lx_get
MOVI r1,1
ST r1,r0,#L_LEN
MOVI r1,0
ST r1,r0,#L_VAL
ST r1,r0,#L_VALH
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
ST r0,r0,#L_VALH
sn_loop:
CALL @lx_peek
LD r2,r0,#L_TMP0
CALL @digitv
MOVI r2,255
CMP r1,r2
JMP[EQ] @sn_fin
ADD r8,r1,r0
LD r3,r0,#L_VAL
LD r4,r0,#L_TMP0
MUL r5,r3,r4
MULHU r6,r3,r4
LD r3,r0,#L_VALH
MUL r7,r3,r4
ADD r6,r6,r7
ADD r5,r5,r8
MOVI r9,0
CMP r5,r8
JMP[GE] @sn_noc
MOVI r9,1
sn_noc:
ADD r6,r6,r9
ST r5,r0,#L_VAL
ST r6,r0,#L_VALH
LD r3,r0,#L_LEN
ADD r3,r3,r13
ST r3,r0,#L_LEN
CALL @lx_get
JMP @sn_loop
sn_fin:
CALL @lx_peek
MOVI r2,46
CMP r1,r2
JMP[NE] @sn_expchk
MOVI r10,1
CALL @peekn
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[EQ] @sn_int
CALL @scan_float
CALL @scan_flt_suf
JMP @sn_done
sn_expchk:
MOVI r2,101
CMP r1,r2
JMP[EQ] @sn_int_exp
MOVI r2,69
CMP r1,r2
JMP[EQ] @sn_int_exp
JMP @sn_int
sn_int_exp:
LD r1,r0,#L_VAL
CVTIF r2,r1
ST r2,r0,#L_VAL
CALL @scan_exp
CALL @scan_flt_suf
MOVI r1,9
ST r1,r0,#L_KIND
JMP @sn_done
sn_int:
; integer suffix: LL / ULL (single L is left as 32-bit long)
sn_suf:
CALL @lx_peek
MOVI r2,108
CMP r1,r2
JMP[EQ] @sn_suf_l
MOVI r2,76
CMP r1,r2
JMP[EQ] @sn_suf_l
MOVI r2,117
CMP r1,r2
JMP[EQ] @sn_suf_u
MOVI r2,85
CMP r1,r2
JMP[EQ] @sn_suf_u
JMP @sn_int_plain
sn_suf_l:
CALL @lx_get
LD r1,r0,#L_LL
ADD r1,r1,r13
ST r1,r0,#L_LL
JMP @sn_suf
sn_suf_u:
CALL @lx_get
MOVI r1,1
ST r1,r0,#L_UNS
JMP @sn_suf
sn_int_plain:
LD r1,r0,#L_LL
MOVI r2,2
CMP r1,r2
JMP[GE] @sn_ll
LD r1,r0,#L_VALH
CMP r1,r0
JMP[EQ] @sn_int_kind
sn_ll:
MOVI r2,1
ST r2,r0,#L_LL
sn_int_kind:
MOVI r1,2
ST r1,r0,#L_KIND
sn_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; scan_exp: optional e/E exponent; L_VAL is a float.  r1=1 if consumed.
scan_exp:
ST r15,r14,0
ADD r14,r14,r13
CALL @lx_peek
MOVI r2,101
CMP r1,r2
JMP[EQ] @se_go
MOVI r2,69
CMP r1,r2
JMP[NE] @se_no
se_go:
CALL @lx_get
MOVI r1,1
ST r1,r0,#L_TMP3
CALL @lx_peek
MOVI r2,45
CMP r1,r2
JMP[NE] @se_plus
LA r2,0xFFFFFFFF
ST r2,r0,#L_TMP3
CALL @lx_get
JMP @se_digits
se_plus:
MOVI r2,43
CMP r1,r2
JMP[NE] @se_digits
CALL @lx_get
se_digits:
ST r0,r0,#L_TMP2
se_dl:
CALL @lx_peek
CALL @digit10
MOVI r2,255
CMP r1,r2
JMP[EQ] @se_pow
LD r3,r0,#L_TMP2
MOVI r4,10
MUL r3,r3,r4
ADD r3,r3,r1
ST r3,r0,#L_TMP2
CALL @lx_get
JMP @se_dl
se_pow:
LD r1,r0,#L_VAL
LD r2,r0,#L_TMP2
LD r3,r0,#L_TMP3
LA r4,0x41200000
se_pl:
CMP r2,r0
JMP[EQ] @se_pd
CMPS r3,r0
JMP[LT] @se_div
FMUL r1,r1,r4
JMP @se_pn
se_div:
FDIV r1,r1,r4
se_pn:
SUB r2,r2,r13
JMP @se_pl
se_pd:
ST r1,r0,#L_VAL
MOVI r1,1
JMP @se_ret
se_no:
MOVI r1,0
se_ret:
SUB r14,r14,r13
LD r15,r14,0
RET

; scan_float: integer part in L_VAL, cursor at '.', consume fraction.
; scan_flt_suf: consume float suffix f/F/l/L
scan_flt_suf:
ST r15,r14,0
ADD r14,r14,r13
CALL @lx_peek
MOVI r2,102
CMP r1,r2
JMP[EQ] @sfs_go
MOVI r2,70
CMP r1,r2
JMP[EQ] @sfs_go
MOVI r2,108
CMP r1,r2
JMP[EQ] @sfs_go
MOVI r2,76
CMP r1,r2
JMP[NE] @sfs_d
sfs_go:
CALL @lx_get
sfs_d:
SUB r14,r14,r13
LD r15,r14,0
RET

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
LD r2,r0,#L_VALH
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
CALL @ll_pair_to_f
ADD r2,r1,r0
LD r1,r0,#L_TMP1
CVTIF r3,r1
LD r1,r0,#L_TMP2
CVTIF r4,r1
FDIV r3,r3,r4
FADD r2,r2,r3
ST r2,r0,#L_VAL
CALL @scan_exp
sf_kind:
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
LD r2,r0,#W_LEXWIDE
CMP r2,r0
JMP[EQ] @ss_kind
MOVI r1,#K_WSTRING
ST r0,r0,#W_LEXWIDE
ss_kind:
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
ncc_recover:
.word 0
ncc_recover_sp:
.word 0
ncc_recover_lr:
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
.word 0xC2CB5034, 33
.word 0xFDD57AE5, 34
.word 0xAE76E4A2, 35
.word 0x505E61EF, 36
.word 0x4D81E832, 37
.word 0x6AA4A81B, 38
.word 0x10D4792F, 39
.word 0x3974EFA7, 40
.word 0xFF2BDAB7, 41
.word 0x1D0E8DBE, 42
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
MOVI r2,33
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,34
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,35
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
; C11: _Alignas, _Noreturn, _Atomic, _Thread_local start declarations
MOVI r2,#KW_ALIGNAS
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,#KW_NORETURN
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,#KW_ATOMIC
CMP r1,r2
JMP[EQ] @kit_y
MOVI r2,#KW_THREAD_LOCAL
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
ST r0,r0,#W_TLL
ST r0,r0,#W_TCHAR
ST r0,r0,#W_TVOID
ST r0,r0,#W_TFLOAT
ST r0,r0,#W_TSEEN
ST r0,r0,#W_TCONST
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
JMP[EQ] @pts_const
MOVI r2,#KW_VOLATILE
CMP r1,r2
JMP[EQ] @pts_qual
MOVI r2,#KW_INLINE
CMP r1,r2
JMP[EQ] @pts_qual
MOVI r2,#KW_RESTRICT
CMP r1,r2
JMP[EQ] @pts_qual
MOVI r2,#KW_BOOL
CMP r1,r2
JMP[EQ] @pts_bool
MOVI r2,#KW_NORETURN
CMP r1,r2
JMP[EQ] @pts_qual
MOVI r2,#KW_THREAD_LOCAL
CMP r1,r2
JMP[EQ] @pts_static
MOVI r2,#KW_ATOMIC
CMP r1,r2
JMP[EQ] @pts_atomic
MOVI r2,#KW_ALIGNAS
CMP r1,r2
JMP[EQ] @pts_alignas
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
pts_atomic:
CALL @p_adv
MOVI r1,#P_LPAREN
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pts_l
CALL @p_adv
CALL @p_typespec
CALL @p_ptr_suffix
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
JMP @pts_ret
pts_alignas:
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
LD r1,r0,#W_ALIGNAS
ST r1,r14,0
ADD r14,r14,r13
CALL @p_is_type
CMP r1,r0
JMP[EQ] @pta_expr
CALL @p_typespec
CALL @p_ptr_suffix
CALL @ty_align
JMP @pta_have
pta_expr:
CALL @p_cexpr
pta_have:
ST r1,r0,#W_TMP
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r2,r0,#W_TMP
SUB r14,r14,r13
LD r1,r14,0
CMP r2,r1
JMP[LE] @pta_keep
ST r2,r0,#W_ALIGNAS
JMP @pts_l
pta_keep:
ST r1,r0,#W_ALIGNAS
JMP @pts_l
pts_const:
MOVI r1,1
ST r1,r0,#W_TCONST
JMP @pts_skip
pts_bool:
CALL @p_adv
MOVI r1,#T_BOOL
JMP @pts_ret
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
LD r2,r0,#W_TLONG
CMP r2,r0
JMP[EQ] @pts_long1
MOVI r2,1
ST r2,r0,#W_TLL
pts_long1:
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
LD r1,r0,#W_TLL
CMP r1,r0
JMP[NE] @pts_ll
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
pts_ll:
LD r1,r0,#W_TSIGN
MOVI r2,2
CMP r1,r2
JMP[EQ] @pts_ull
MOVI r1,#T_LONGLONG
JMP @pts_ret
pts_ull:
MOVI r1,#T_ULONGLONG
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
JMP[NE] @pps_qadv
MOVI r1,#KW_RESTRICT
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
; C99 permits a trailing comma before the closing brace
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pes_rbrace
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
LD r1,r0,#W_ENUMVAL
ST r1,r0,#W_TY_ID
pes_set:
; the symbol takes this enumerator's value; the next implicit value is +1
LD r1,r0,#W_TY_ID
ADD r2,r1,r13
ST r2,r0,#W_ENUMVAL
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
pes_rbrace:
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
; a definition body always gets a fresh complete type; update the tag
pss_have_type:
LD r1,r0,#W_STRUCTKIND
CALL @ty_struct
ST r1,r0,#W_STRUCTID
LD r2,r0,#W_STAG
CMP r2,r0
JMP[EQ] @pss_type_ok
ADD r1,r2,r0
CALL @sym_entry
LD r2,r0,#W_STRUCTID
ST r2,r1,#SY_TYPE
pss_type_ok:
; save the parent table state, then this definition's type/kind/class.
; Parent state is pushed first so pss_final can pop type/kind/class first.
LD r1,r0,#W_SSIZE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_SALIGN
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_SSPKIND
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MEMBP
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_SMEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_SNMEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_SDOWN
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_STRUCTID
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_STRUCTKIND
ST r1,r14,0
ADD r14,r14,r13
; member declarations run p_typespec recursively, which clears W_SCLASS;
; preserve the outer storage class so "typedef struct {...} name;" works
LD r1,r0,#W_SCLASS
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_STRUCTKIND
ST r1,r0,#W_SSPKIND
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
; outermost definitions grow up from NCC_MEMB; nested definitions grow
; down from W_MEMTOP so the parent table stays contiguous.
LD r1,r0,#W_SSDEPTH
CMP r1,r0
JMP[NE] @pss_nested_arena
MOVI r1,0
ST r1,r0,#W_SDOWN
LD r1,r0,#W_MEMBP
ST r1,r0,#W_SMEM
ST r0,r0,#W_SNMEM
JMP @pss_arena_ready
pss_nested_arena:
MOVI r1,1
ST r1,r0,#W_SDOWN
LD r1,r0,#W_MEMTOP
ST r1,r0,#W_MEMBP
ST r0,r0,#W_SMEM
ST r0,r0,#W_SNMEM
LD r1,r0,#W_STRUCTID
CALL @ty_addr
ST r0,r1,#TY_MEM
ST r0,r1,#TY_NMEM
pss_arena_ready:
LD r1,r0,#W_SSDEPTH
ADD r1,r1,r13
ST r1,r0,#W_SSDEPTH
LA r1,0xFFFFFFFF
ST r1,r0,#W_BITUNIT
ST r0,r0,#W_BITUSED
CALL @p_adv
pss_mem_l:
ST r0,r0,#W_SANON
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pss_final
LD r1,r0,#W_TKA
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @pss_mem_go
LD r1,r0,#W_TKA+1
MOVI r2,#KW_STATIC_ASSERT
CMP r1,r2
JMP[NE] @pss_mem_go
CALL @p_static_assert
JMP @pss_mem_l
pss_mem_go:
CALL @p_typespec
ST r1,r0,#W_STYPE
ST r1,r0,#W_SBASE
pss_mem_one:
LD r1,r0,#W_SBASE
ST r1,r0,#W_STYPE
LD r1,r0,#W_STYPE
CALL @p_ptr_suffix
ST r1,r0,#W_STYPE
CALL @p_at_funcptr_decl
CMP r1,r0
JMP[EQ] @pss_mem_normal_decl
; function-pointer member: RET (*name)(params)
LD r1,r0,#W_STYPE
ST r1,r0,#W_FPRET
LD r1,r0,#W_PARAMP
ST r1,r0,#W_PARM_SAVE
ST r1,r0,#W_FPSTART
ST r0,r0,#W_FPNP
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,#P_STAR
MOVI r2,36
CALL @p_expect_p
pssfp_stars:
MOVI r1,#P_STAR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pssfp_name
CALL @p_adv
JMP @pssfp_stars
pssfp_name:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pssfp_nm
MOVI r1,23
CALL @p_err
pssfp_nm:
MOVI r1,#SK_MEMBER
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
pssfp_param_start:
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pssfp_params_done
MOVI r1,#KW_VOID
CALL @p_at_k
CMP r1,r0
JMP[EQ] @pssfp_param_l
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pssfp_param_l
LD r1,r0,#W_TKB+1
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[NE] @pssfp_param_l
CALL @p_adv
JMP @pssfp_params_done
pssfp_param_l:
CALL @p_typespec
CALL @p_ptr_suffix
ST r1,r0,#W_FPTMP
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pssfp_noid
CALL @p_adv
pssfp_noid:
LD r2,r0,#W_PARAMP
ADD r3,r2,r0
LD r1,r0,#W_FPTMP
ST r1,r3,0
ADD r2,r2,r13
ST r2,r0,#W_PARAMP
LD r1,r0,#W_FPNP
ADD r1,r1,r13
ST r1,r0,#W_FPNP
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pssfp_param_l
pssfp_params_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r1,r0,#W_FPRET
LD r2,r0,#W_FPNP
CALL @ty_func
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_FPSTART
LD r2,r0,#W_FPNP
CALL @ty_func_set_params
LD r1,r0,#W_TY_TMP
CALL @ty_ptr
ST r1,r0,#W_STYPE
LD r1,r0,#W_PARM_SAVE
ST r1,r0,#W_PARAMP
JMP @pss_mem_sized
pss_mem_normal_decl:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pss_mem_name
; anonymous struct/union member: type ';'
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pss_bad_name
LD r1,r0,#W_TKA+1
MOVI r2,#P_SEMI
CMP r1,r2
JMP[EQ] @pss_mem_anon
; anonymous bit-field: type ':' width
LD r1,r0,#W_TKA+1
MOVI r2,#P_COLON
CMP r1,r2
JMP[NE] @pss_bad_name
CALL @p_adv
CALL @p_cexpr
ST r1,r0,#W_BITW
CMP r1,r0
JMP[EQ] @pss_anon_zero
LD r1,r0,#W_BITW
CALL @p_ss_bits
JMP @pss_anon_done
pss_anon_zero:
CALL @p_ss_bits_zero
pss_anon_done:
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pss_mem_one
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
JMP @pss_mem_l
pss_mem_anon:
LD r1,r0,#W_STYPE
CALL @ty_kind
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pss_anon_ok
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pss_anon_ok
MOVI r1,23
CALL @p_err
pss_anon_ok:
MOVI r1,1
ST r1,r0,#W_SANON
LA r1,0x80000000
ST r1,r0,#W_STBIT
JMP @pss_mem_plain
pss_bad_name:
MOVI r1,23
CALL @p_err
pss_mem_name:
MOVI r1,#SK_MEMBER
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
; bit-field width?
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pss_mem_nobit
LD r1,r0,#W_TKA+1
MOVI r2,#P_COLON
CMP r1,r2
JMP[NE] @pss_mem_nobit
CALL @p_adv
CALL @p_cexpr
ST r1,r0,#W_BITW
LD r1,r0,#W_STYPE
LD r2,r0,#W_BITW
CALL @ty_bitfield
ST r1,r0,#W_STYPE
JMP @pss_mem_sized
pss_mem_nobit:
LD r1,r0,#W_STYPE
CALL @p_array_suffix
ST r1,r0,#W_STYPE
pss_mem_sized:
LD r1,r0,#W_STYPE
CALL @ty_bitwidth
CMP r2,r0
JMP[EQ] @pss_mem_plain
LD r1,r0,#W_STYPE
CALL @ty_bitwidth
CMP r2,r0
JMP[EQ] @pss_named_zero
ST r2,r0,#W_BITS_W
LD r1,r0,#W_BITS_W
CALL @p_ss_bits
ST r1,r0,#W_STMP
ST r2,r0,#W_STBIT
JMP @pss_mem_entry
pss_named_zero:
CALL @p_ss_bits_zero
JMP @pss_anon_done
pss_mem_plain:
LD r1,r0,#W_SANON
CMP r1,r0
JMP[NE] @pss_mem_plain_go
ST r0,r0,#W_STBIT
pss_mem_plain_go:
LD r1,r0,#W_STYPE
CALL @ty_size
ST r1,r0,#W_STMP
LD r1,r0,#W_STYPE
CALL @ty_align
ST r1,r0,#W_SOFF
LD r1,r0,#W_SSPKIND
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
LA r1,0xFFFFFFFF
ST r1,r0,#W_BITUNIT
ST r0,r0,#W_BITUSED
; max alignment
LD r1,r0,#W_SOFF
LD r2,r0,#W_SALIGN
CMP r1,r2
JMP[LE] @pss_align_ok
ST r1,r0,#W_SALIGN
pss_align_ok:
pss_mem_entry:
; anonymous members get a marker entry [0, offset, type, 0x80000000];
; the outermost type promotes them after its table is complete.
LD r2,r0,#W_MEMBP
LD r3,r0,#W_SDOWN
CMP r3,r0
JMP[EQ] @pme_up
ADDI r2,r2,-4
ST r2,r0,#W_MEMBP
JMP @pme_store
pme_up:
;pme_up keeps r2 as the append slot
pme_store:
LD r4,r0,#W_SANON
CMP r4,r0
JMP[EQ] @pme_pop_sym
MOVI r1,0
JMP @pme_have_sym
pme_pop_sym:
SUB r14,r14,r13
LD r1,r14,0
pme_have_sym:
ST r1,r2,0
LD r1,r0,#W_STMP
ST r1,r2,1
LD r1,r0,#W_STYPE
ST r1,r2,2
LD r1,r0,#W_STBIT
ST r1,r2,3
LD r3,r0,#W_SDOWN
CMP r3,r0
JMP[NE] @pme_noinc
ADDI r2,r2,4
ST r2,r0,#W_MEMBP
pme_noinc:
LD r1,r0,#W_SNMEM
ADD r1,r1,r13
ST r1,r0,#W_SNMEM
pme_after:
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
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_SCLASS
ADDI r3,r3,-1
LD r2,r3,0
ADDI r3,r3,-1
LD r1,r3,0
ST r1,r0,#W_STRUCTID
ST r2,r0,#W_STRUCTKIND
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
; down-arena table: entries were written from high to low, so reverse them
LD r3,r0,#W_SDOWN
CMP r3,r0
JMP[EQ] @pssf_up
LD r1,r0,#W_MEMBP
LD r2,r0,#W_SNMEM
CALL @mem_rev
LD r1,r0,#W_STRUCTID
CALL @ty_addr
LD r2,r0,#W_MEMBP
ST r2,r1,#TY_MEM
ST r2,r0,#W_MEMTOP
pssf_up:
LD r1,r0,#W_STRUCTID
CALL @ty_addr
LD r2,r0,#W_SNMEM
ST r2,r1,#TY_NMEM
; Anonymous members are stored as markers in the parent table and
; resolved recursively by p_member_lookup, so no post-pass is needed.
LD r1,r0,#W_SSDEPTH
SUB r1,r1,r13
ST r1,r0,#W_SSDEPTH
; nested scopes restore the parent table state; outermost scopes keep
; their end pointer so later top-level structs append after them.
; The three type/kind/class words are on top; drop them first.
LD r3,r0,#W_SDOWN
CMP r3,r0
JMP[EQ] @pssf_drop_all
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_SDOWN
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_SNMEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_SMEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ANON_OFF
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_SSPKIND
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_SALIGN
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_SSIZE
; an up-arena parent resumes at its saved pointer; a down-arena parent
; must resume below the nested table just allocated.
LD r2,r0,#W_SDOWN
CMP r2,r0
JMP[NE] @pssf_parent_down
LD r1,r0,#W_ANON_OFF
ST r1,r0,#W_MEMBP
JMP @pssf_done
pssf_parent_down:
LD r1,r0,#W_MEMTOP
ST r1,r0,#W_MEMBP
JMP @pssf_done
pssf_drop_all:
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
SUB r14,r14,r13
pssf_done:
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

; p_ss_bits_zero: start a fresh 32-bit bit-field unit
p_ss_bits_zero:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_SSIZE
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_SSIZE
LA r2,0xFFFFFFFF
ST r2,r0,#W_BITUNIT
ST r0,r0,#W_BITUSED
LD r2,r0,#W_SALIGN
MOVI r3,4
CMP r2,r3
JMP[GE] @psbz_d
ST r3,r0,#W_SALIGN
psbz_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_ss_bits: r1=width -> r1=unit offset r2=bit offset (packs into 32-bit units)
p_ss_bits:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BITS_W
LD r2,r0,#W_BITUNIT
LA r3,0xFFFFFFFF
CMP r2,r3
JMP[EQ] @psb_new
LD r4,r0,#W_BITUSED
LD r5,r0,#W_BITS_W
ADD r4,r4,r5
MOVI r5,32
CMP r4,r5
JMP[GT] @psb_new
JMP @psb_use
psb_new:
LD r1,r0,#W_SSIZE
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_BITUNIT
ADDI r2,r1,4
ST r2,r0,#W_SSIZE
ST r0,r0,#W_BITUSED
psb_use:
LD r1,r0,#W_BITUNIT
LD r2,r0,#W_BITUSED
LD r3,r0,#W_BITUSED
LD r4,r0,#W_BITS_W
ADD r3,r3,r4
ST r3,r0,#W_BITUSED
LD r3,r0,#W_SALIGN
MOVI r4,4
CMP r3,r4
JMP[GE] @psb_ok
ST r4,r0,#W_SALIGN
psb_ok:
SUB r14,r14,r13
LD r15,r14,0
RET


; mem_rev: r1=base r2=count; reverse count 4-word member entries in place.
mem_rev:
MOVI r3,0
SUB r4,r2,r13
mr_l:
CMP r3,r4
JMP[GE] @mr_d
SHL r5,r3,2
ADD r5,r1,r5
SHL r6,r4,2
ADD r6,r1,r6
LD r7,r5,0
LD r8,r6,0
ST r8,r5,0
ST r7,r6,0
LD r7,r5,1
LD r8,r6,1
ST r8,r5,1
ST r7,r6,1
LD r7,r5,2
LD r8,r6,2
ST r8,r5,2
ST r7,r6,2
LD r7,r5,3
LD r8,r6,3
ST r8,r5,3
ST r7,r6,3
ADDI r3,r3,1
SUB r4,r4,r13
JMP @mr_l
mr_d:
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
LD r6,r3,3
LA r7,0x80000000
CMP r6,r7
JMP[NE] @pml_named
; anonymous member: recursively search its type and add its offset
LD r1,r3,2
ST r1,r0,#W_ANON_TY
LD r1,r3,1
ST r1,r0,#W_ANON_OFF
LD r1,r0,#W_TY_MEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TY_COUNT
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TY_BASE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ML_SOFT
ST r1,r14,0
ADD r14,r14,r13
MOVI r1,1
ST r1,r0,#W_ML_SOFT
LD r1,r0,#W_ANON_TY
CALL @p_member_lookup
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ML_SOFT
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_TY_BASE
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_TY_COUNT
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_TY_MEM
CMP r2,r0
JMP[EQ] @pml_next
LD r3,r0,#W_ANON_OFF
ADD r1,r1,r3
JMP @pml_d
pml_named:
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
LD r5,r0,#W_TY_BASE
ST r5,r0,#W_MEMIDX
LD r1,r0,#W_TY_MEM
LD r2,r0,#W_TY_BASE
SHL r2,r2,2
ADD r1,r1,r2
LD r1,r1,3
ST r1,r0,#W_MEMBIT
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
LD r1,r0,#W_ML_SOFT
CMP r1,r0
JMP[NE] @pml_soft_nf
MOVI r1,72
CALL @p_err
pml_soft_nf:
MOVI r1,0
MOVI r2,0
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
; sqrt
LA r1,0x7DEE3BCF
LA r2,@ncc_s_sqrt
MOVI r3,4
MOVI r4,#B_SQRT
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; fabs
LA r1,0x176942B7
LA r2,@ncc_s_fabs
MOVI r3,4
MOVI r4,#B_FABS
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; pow
LA r1,0x58336AD5
LA r2,@ncc_s_pow
MOVI r3,3
MOVI r4,#B_POW
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; exp
LA r1,0x72A68728
LA r2,@ncc_s_exp
MOVI r3,3
MOVI r4,#B_EXP
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; log
LA r1,0x3F515151
LA r2,@ncc_s_log
MOVI r3,3
MOVI r4,#B_LOG
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; log10
LA r1,0x8BE20730
LA r2,@ncc_s_log10
MOVI r3,5
MOVI r4,#B_LOG10
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; tanh
LA r1,0x092855D0
LA r2,@ncc_s_tanh
MOVI r3,4
MOVI r4,#B_TANH
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; floor
LA r1,0xB8E70C1D
LA r2,@ncc_s_floor
MOVI r3,5
MOVI r4,#B_FLOOR
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; ceil
LA r1,0x62E4E208
LA r2,@ncc_s_ceil
MOVI r3,4
MOVI r4,#B_CEIL
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; fmod
LA r1,0x508F8797
LA r2,@ncc_s_fmod
MOVI r3,4
MOVI r4,#B_FMOD
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; fmin
LA r1,0x4A93FB53
LA r2,@ncc_s_fmin
MOVI r3,4
MOVI r4,#B_FMIN
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; fmax
LA r1,0x60A7A5AD
LA r2,@ncc_s_fmax
MOVI r3,4
MOVI r4,#B_FMAX
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; dp4b: four signed i8 lanes in each u32, dot product
LA r1,0x9601018F
LA r2,@ncc_s_dp4b
MOVI r3,4
MOVI r4,#B_DP4B
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
; aligned_alloc: S0 heap block whose payload is alignment-aligned
LA r1,0x4F171A15
LA r2,@ncc_s_aligned_alloc
MOVI r3,13
MOVI r4,#B_ALIGNED_ALLOC
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; tan
LA r1,0x9CF73498
LA r2,@ncc_s_tan
MOVI r3,3
MOVI r4,#B_TAN
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
; strchr
LA r1,0x892F9553
LA r2,@ncc_s_strchr
MOVI r3,6
MOVI r4,#B_STRCHR
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
; strstr
LA r1,0xC17CDDBF
LA r2,@ncc_s_strstr
MOVI r3,6
MOVI r4,#B_STRSTR
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
; strdup
LA r1,0x07FAD6E1
LA r2,@ncc_s_strdup
MOVI r3,6
MOVI r4,#B_STRDUP
MOVI r5,1
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
; isdigit
LA r1,0xF75E7926
LA r2,@ncc_s_isdigit
MOVI r3,7
MOVI r4,#B_ISDIGIT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; isalpha
LA r1,0x64F4097B
LA r2,@ncc_s_isalpha
MOVI r3,7
MOVI r4,#B_ISALPHA
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; isspace
LA r1,0xAE5C87B5
LA r2,@ncc_s_isspace
MOVI r3,7
MOVI r4,#B_ISSPACE
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; isupper
LA r1,0x1CCFD077
LA r2,@ncc_s_isupper
MOVI r3,7
MOVI r4,#B_ISUPPER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; islower
LA r1,0x70E42DEA
LA r2,@ncc_s_islower
MOVI r3,7
MOVI r4,#B_ISLOWER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; toupper
LA r1,0xDC0F32D8
LA r2,@ncc_s_toupper
MOVI r3,7
MOVI r4,#B_TOUPPER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; tolower
LA r1,0x3E2397F1
LA r2,@ncc_s_tolower
MOVI r3,7
MOVI r4,#B_TOLOWER
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; rand
LA r1,0xA19B8CD6
LA r2,@ncc_s_rand
MOVI r3,4
MOVI r4,#B_RAND
MOVI r5,0
MOVI r6,#T_INT
CALL @ncc_add_builtin
; srand
LA r1,0x1BBF4029
LA r2,@ncc_s_srand
MOVI r3,5
MOVI r4,#B_SRAND
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; labs
LA r1,0x6506AA85
LA r2,@ncc_s_labs
MOVI r3,4
MOVI r4,#B_LABS
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; memmove
LA r1,0x01081B8B
LA r2,@ncc_s_memmove
MOVI r3,7
MOVI r4,#B_MEMMOVE
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; sprintf
LA r1,0x70E2D349
LA r2,@ncc_s_sprintf
MOVI r3,7
MOVI r4,#B_SPRINTF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
; snprintf
LA r1,0x3FD5EB6F
LA r2,@ncc_s_snprintf
MOVI r3,8
MOVI r4,#B_SNPRINTF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
; exit
LA r1,0xCDED1A85
LA r2,@ncc_s_exit
MOVI r3,4
MOVI r4,#B_EXIT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; va_list typedef = char *
LA r1,0xF232A721
LA r2,@ncc_s_va_list
MOVI r3,7
LD r4,r0,#W_PTRC
CALL @ncc_add_typedef
; bool typedef and true/false constants (stdbool.h is skipped)
LA r1,0xC894953D
LA r2,@ncc_s_bool
MOVI r3,4
MOVI r4,#T_BOOL
CALL @ncc_add_typedef
LA r1,0x4DB211E5
LA r2,@ncc_s_true
MOVI r3,4
MOVI r4,1
CALL @ncc_add_enum_const
LA r1,0x0B069958
LA r2,@ncc_s_false
MOVI r3,5
MOVI r4,0
CALL @ncc_add_enum_const
; standard typedefs
LA r1,0x7C6A8FB7
LA r2,@ncc_s_size_t
MOVI r3,6
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0xA90DDA0D
LA r2,@ncc_s_ptrdiff_t
MOVI r3,9
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xDF8EE2E3
LA r2,@ncc_s_intptr_t
MOVI r3,8
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xC4AA654E
LA r2,@ncc_s_uintptr_t
MOVI r3,9
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0xCD88860F
LA r2,@ncc_s_time_t
MOVI r3,6
MOVI r4,#T_LONG
CALL @ncc_add_typedef
LA r1,0xA5756116
LA r2,@ncc_s_clock_t
MOVI r3,7
MOVI r4,#T_LONG
CALL @ncc_add_typedef
LA r1,0xA83DBA83
LA r2,@ncc_s_FILE
MOVI r3,4
MOVI r4,#T_VOID
CALL @ncc_add_typedef
LA r1,0x5BEBDD29
LA r2,@ncc_s_sig_atomic_t
MOVI r3,12
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xC523B9F1
LA r2,@ncc_s_wchar_t
MOVI r3,7
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xCE53BB04
LA r2,@ncc_s_wint_t
MOVI r3,6
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0x18172F90
LA r2,@ncc_s_mbstate_t
MOVI r3,9
MOVI r4,#T_INT
CALL @ncc_add_typedef
; C11 <uchar.h> character types
LA r1,0x801A266D
LA r2,@ncc_s_char16_t
MOVI r3,8
MOVI r4,#T_USHORT
CALL @ncc_add_typedef
LA r1,0xA846FC93
LA r2,@ncc_s_char32_t
MOVI r3,8
MOVI r4,#T_UINT
CALL @ncc_add_typedef
CALL @ncc_add_tm
CALL @ncc_add_lconv
; stdio handles as FILE* globals
LA r1,0xA4DB129D
LA r2,@ncc_s_stdin
MOVI r3,5
LD r4,r0,#W_PTRV
MOVI r5,1
CALL @ncc_add_global
LA r1,0x3B7F5CA6
LA r2,@ncc_s_stdout
MOVI r3,6
LD r4,r0,#W_PTRV
MOVI r5,2
CALL @ncc_add_global
LA r1,0xB1DA39F5
LA r2,@ncc_s_stderr
MOVI r3,6
LD r4,r0,#W_PTRV
MOVI r5,3
CALL @ncc_add_global
LA r1,0xD237B23F
LA r2,@ncc_s_signgam
MOVI r3,7
MOVI r4,#T_INT
MOVI r5,1
CALL @ncc_add_global
LD r1,r0,#W_AGSYM
LD r1,r1,#SY_AUX
ST r1,r0,#W_SIGNGAM
; div_t { int quot; int rem; }
MOVI r1,#TY_STRUCT
CALL @ty_struct
ST r1,r0,#W_DIVTYPE
CALL @ty_addr
LD r2,r0,#W_MEMBP
ST r2,r1,#TY_MEM
ST r0,r1,#TY_NMEM
MOVI r2,8
ST r2,r1,#TY_SIZE
MOVI r2,4
ST r2,r1,#TY_ALIGN
LD r1,r0,#W_DIVTYPE
ST r1,r0,#W_TMTYPE
MOVI r1,#T_INT
MOVI r2,0
LA r3,0x538C1748
LA r4,@ncc_s_quot
MOVI r5,4
CALL @ncc_add_member
MOVI r1,#T_INT
MOVI r2,4
LA r3,0x49F48F07
LA r4,@ncc_s_rem
MOVI r5,3
CALL @ncc_add_member
LA r1,0xE72F3553
LA r2,@ncc_s_div_t
MOVI r3,5
LD r4,r0,#W_DIVTYPE
CALL @ncc_add_typedef
; ldiv_t { long quot; long rem; }
MOVI r1,#TY_STRUCT
CALL @ty_struct
ST r1,r0,#W_LDIVTYPE
CALL @ty_addr
LD r2,r0,#W_MEMBP
ST r2,r1,#TY_MEM
ST r0,r1,#TY_NMEM
MOVI r2,8
ST r2,r1,#TY_SIZE
MOVI r2,4
ST r2,r1,#TY_ALIGN
LD r1,r0,#W_LDIVTYPE
ST r1,r0,#W_TMTYPE
MOVI r1,#T_LONG
MOVI r2,0
LA r3,0x538C1748
LA r4,@ncc_s_quot
MOVI r5,4
CALL @ncc_add_member
MOVI r1,#T_LONG
MOVI r2,4
LA r3,0x49F48F07
LA r4,@ncc_s_rem
MOVI r5,3
CALL @ncc_add_member
LA r1,0xE918C705
LA r2,@ncc_s_ldiv_t
MOVI r3,6
LD r4,r0,#W_LDIVTYPE
CALL @ncc_add_typedef
; lldiv_t { long long quot; long long rem; }
MOVI r1,#TY_STRUCT
CALL @ty_struct
ST r1,r0,#W_LLDIVTYPE
CALL @ty_addr
LD r2,r0,#W_MEMBP
ST r2,r1,#TY_MEM
ST r0,r1,#TY_NMEM
MOVI r2,16
ST r2,r1,#TY_SIZE
MOVI r2,4
ST r2,r1,#TY_ALIGN
LD r1,r0,#W_LLDIVTYPE
ST r1,r0,#W_TMTYPE
MOVI r1,#T_LONGLONG
MOVI r2,0
LA r3,0x538C1748
LA r4,@ncc_s_quot
MOVI r5,4
CALL @ncc_add_member
MOVI r1,#T_LONGLONG
MOVI r2,8
LA r3,0x49F48F07
LA r4,@ncc_s_rem
MOVI r5,3
CALL @ncc_add_member
LA r1,0x40A32AF3
LA r2,@ncc_s_lldiv_t
MOVI r3,7
LD r4,r0,#W_LLDIVTYPE
CALL @ncc_add_typedef
; imaxdiv_t = lldiv_t
LA r1,0xCF8B962E
LA r2,@ncc_s_imaxdiv_t
MOVI r3,9
LD r4,r0,#W_LLDIVTYPE
CALL @ncc_add_typedef
LA r1,0x396FDE24
LA r2,@ncc_s_c_NULL
MOVI r3,4
LA r4,0x0
CALL @ncc_add_enum_const
LA r1,0xCF460301
LA r2,@ncc_s_c_EOF
MOVI r3,3
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0x112FDC09
LA r2,@ncc_s_c_EXIT_SUCCESS
MOVI r3,12
LA r4,0x0
CALL @ncc_add_enum_const
LA r1,0xED53D244
LA r2,@ncc_s_c_EXIT_FAILURE
MOVI r3,12
LA r4,0x1
CALL @ncc_add_enum_const
LA r1,0x0DBDF58A
LA r2,@ncc_s_c_SEEK_SET
MOVI r3,8
LA r4,0x0
CALL @ncc_add_enum_const
LA r1,0x797A5DF8
LA r2,@ncc_s_c_SEEK_CUR
MOVI r3,8
LA r4,0x1
CALL @ncc_add_enum_const
LA r1,0xB95DA1F7
LA r2,@ncc_s_c_SEEK_END
MOVI r3,8
LA r4,0x2
CALL @ncc_add_enum_const
LA r1,0x405F4E14
LA r2,@ncc_s_c_CLOCKS_PER_SEC
MOVI r3,14
LA r4,0x3E8
CALL @ncc_add_enum_const
LA r1,0xF0C120A3
LA r2,@ncc_s_c_RAND_MAX
MOVI r3,8
LA r4,0x7FFF
CALL @ncc_add_enum_const
LA r1,0xF139BD5B
LA r2,@ncc_s_c_INT_MAX
MOVI r3,7
LA r4,0x7FFFFFFF
CALL @ncc_add_enum_const
LA r1,0x27268AA5
LA r2,@ncc_s_c_INT_MIN
MOVI r3,7
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0xE1DE5BCC
LA r2,@ncc_s_c_UINT_MAX
MOVI r3,8
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0xFEEF7AD2
LA r2,@ncc_s_c_LONG_MAX
MOVI r3,8
LA r4,0x7FFFFFFF
CALL @ncc_add_enum_const
LA r1,0xE8DBD078
LA r2,@ncc_s_c_LONG_MIN
MOVI r3,8
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0xA006B5AB
LA r2,@ncc_s_c_ULONG_MAX
MOVI r3,9
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0x3F380271
LA r2,@ncc_s_c_CHAR_BIT
MOVI r3,8
LA r4,0x8
CALL @ncc_add_enum_const
LA r1,0xA0D164BD
LA r2,@ncc_s_c_SCHAR_MIN
MOVI r3,9
LA r4,0xFFFFFF80
CALL @ncc_add_enum_const
LA r1,0x6ABD8803
LA r2,@ncc_s_c_SCHAR_MAX
MOVI r3,9
LA r4,0x7F
CALL @ncc_add_enum_const
LA r1,0x252DE85D
LA r2,@ncc_s_c_UCHAR_MAX
MOVI r3,9
LA r4,0xFF
CALL @ncc_add_enum_const
LA r1,0x61B330EF
LA r2,@ncc_s_c_SHRT_MIN
MOVI r3,8
LA r4,0xFFFF8000
CALL @ncc_add_enum_const
LA r1,0x4F9F8CE1
LA r2,@ncc_s_c_SHRT_MAX
MOVI r3,8
LA r4,0x7FFF
CALL @ncc_add_enum_const
LA r1,0x869F80E0
LA r2,@ncc_s_c_USHRT_MAX
MOVI r3,9
LA r4,0xFFFF
CALL @ncc_add_enum_const
LA r1,0x21922AED
LA r2,@ncc_s_c_SIZE_MAX
MOVI r3,8
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0xA7BAD29B
LA r2,@ncc_s_c_SIGINT
MOVI r3,6
LA r4,0x2
CALL @ncc_add_enum_const
LA r1,0xD3B507B1
LA r2,@ncc_s_c_SIGILL
MOVI r3,6
LA r4,0x4
CALL @ncc_add_enum_const
LA r1,0x755EE927
LA r2,@ncc_s_c_SIGABRT
MOVI r3,7
LA r4,0x6
CALL @ncc_add_enum_const
LA r1,0xD2ED7A7E
LA r2,@ncc_s_c_SIGALRM
MOVI r3,7
LA r4,0xE
CALL @ncc_add_enum_const
LA r1,0xAC6FFF43
LA r2,@ncc_s_c_SIGFPE
MOVI r3,6
LA r4,0x8
CALL @ncc_add_enum_const
LA r1,0xC72376FB
LA r2,@ncc_s_c_SIGSEGV
MOVI r3,7
LA r4,0xB
CALL @ncc_add_enum_const
LA r1,0x945C6008
LA r2,@ncc_s_c_SIGTERM
MOVI r3,7
LA r4,0xF
CALL @ncc_add_enum_const
LA r1,0xB9952BD3
LA r2,@ncc_s_c_SIG_DFL
MOVI r3,7
LA r4,0x0
CALL @ncc_add_enum_const
LA r1,0x883988DB
LA r2,@ncc_s_c_SIG_IGN
MOVI r3,7
LA r4,0x1
CALL @ncc_add_enum_const
LA r1,0xD3EF3BB2
LA r2,@ncc_s_f_M_PI
MOVI r3,4
MOVI r4,#T_DOUBLE
LA r5,0x40490FDB
CALL @ncc_add_global
LA r1,0x032C4B80
LA r2,@ncc_s_f_M_E
MOVI r3,3
MOVI r4,#T_DOUBLE
LA r5,0x402DF854
CALL @ncc_add_global
LA r1,0x525E4F07
LA r2,@ncc_s_f_M_SQRT2
MOVI r3,6
MOVI r4,#T_DOUBLE
LA r5,0x3FB504F3
CALL @ncc_add_global
LA r1,0xA0D1B237
LA r2,@ncc_s_f_M_LN2
MOVI r3,5
MOVI r4,#T_DOUBLE
LA r5,0x3F317218
CALL @ncc_add_global
LA r1,0xB71E528E
LA r2,@ncc_s_f_M_LN10
MOVI r3,6
MOVI r4,#T_DOUBLE
LA r5,0x40135D8E
CALL @ncc_add_global
LA r1,0xE23BF8B4
LA r2,@ncc_s_f_M_LOG2E
MOVI r3,7
MOVI r4,#T_DOUBLE
LA r5,0x3FB8AA3B
CALL @ncc_add_global
LA r1,0x8E85C04F
LA r2,@ncc_s_f_M_LOG10E
MOVI r3,8
MOVI r4,#T_DOUBLE
LA r5,0x3EDE5BD9
CALL @ncc_add_global
LA r1,0xA3889C3F
LA r2,@ncc_s_f_M_PI_2
MOVI r3,6
MOVI r4,#T_DOUBLE
LA r5,0x3FC90FDB
CALL @ncc_add_global
LA r1,0xA1889919
LA r2,@ncc_s_f_M_PI_4
MOVI r3,6
MOVI r4,#T_DOUBLE
LA r5,0x3F490FDB
CALL @ncc_add_global
LA r1,0xFB309866
LA r2,@ncc_s_f_M_1_PI
MOVI r3,6
MOVI r4,#T_DOUBLE
LA r5,0x3EA2F983
CALL @ncc_add_global
LA r1,0xEC36B5D9
LA r2,@ncc_s_f_M_2_PI
MOVI r3,6
MOVI r4,#T_DOUBLE
LA r5,0x3F22F983
CALL @ncc_add_global
LA r1,0xEDED4517
LA r2,@ncc_s_f_M_2_SQRTPI
MOVI r3,10
MOVI r4,#T_DOUBLE
LA r5,0x3F906EBB
CALL @ncc_add_global
LA r1,0x11B718D7
LA r2,@ncc_s_f_M_SQRT1_2
MOVI r3,9
MOVI r4,#T_DOUBLE
LA r5,0x3F3504F3
CALL @ncc_add_global
LA r1,0xF8A0BF5E
LA r2,@ncc_s_f_HUGE_VAL
MOVI r3,8
MOVI r4,#T_DOUBLE
LA r5,0x7F800000
CALL @ncc_add_global
LA r1,0x870B68B9
LA r2,@ncc_s_f_INFINITY
MOVI r3,8
MOVI r4,#T_DOUBLE
LA r5,0x7F800000
CALL @ncc_add_global
LA r1,0xB1CBBEDA
LA r2,@ncc_s_f_NAN
MOVI r3,3
MOVI r4,#T_DOUBLE
LA r5,0x7FC00000
CALL @ncc_add_global
; time.h
LA r1,0x5D3C9BE4
LA r2,@ncc_s_time
MOVI r3,4
MOVI r4,#B_TIME
MOVI r5,1
MOVI r6,#T_LONG
CALL @ncc_add_builtin
LA r1,0x15A40F5D
LA r2,@ncc_s_clock
MOVI r3,5
MOVI r4,#B_CLOCK
MOVI r5,0
MOVI r6,#T_LONG
CALL @ncc_add_builtin
LA r1,0xEDBEA49B
LA r2,@ncc_s_difftime
MOVI r3,8
MOVI r4,#B_DIFFTIME
MOVI r5,2
MOVI r6,#T_DOUBLE
CALL @ncc_add_builtin
LA r1,0x3A665C80
LA r2,@ncc_s_mktime
MOVI r3,6
MOVI r4,#B_MKTIME
MOVI r5,1
MOVI r6,#T_LONG
CALL @ncc_add_builtin
LA r1,0xE14DCFC1
LA r2,@ncc_s_localtime
MOVI r3,9
MOVI r4,#B_LOCALTIME
MOVI r5,1
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x4426E788
LA r2,@ncc_s_gmtime
MOVI r3,6
MOVI r4,#B_GMTIME
MOVI r5,1
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x69DC410B
LA r2,@ncc_s_asctime
MOVI r3,7
MOVI r4,#B_ASCTIME
MOVI r5,1
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0x13A6EC13
LA r2,@ncc_s_ctime
MOVI r3,5
MOVI r4,#B_CTIME
MOVI r5,1
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
; locale.h
LA r1,0xD6B7F315
LA r2,@ncc_s_setlocale
MOVI r3,9
MOVI r4,#B_SETLOCALE
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0xA28515A9
LA r2,@ncc_s_localeconv
MOVI r3,10
MOVI r4,#B_LOCALECONV
MOVI r5,0
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; signal.h
LA r1,0xBD7BBA09
LA r2,@ncc_s_signal
MOVI r3,6
MOVI r4,#B_SIGNAL
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x5EF9ED23
LA r2,@ncc_s_raise
MOVI r3,5
MOVI r4,#B_RAISE
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
; stdlib conversions
LA r1,0xFE7440F9
LA r2,@ncc_s_atof
MOVI r3,4
MOVI r4,#B_ATOF
MOVI r5,1
MOVI r6,#T_DOUBLE
CALL @ncc_add_builtin
LA r1,0x47CCED67
LA r2,@ncc_s_strtod
MOVI r3,6
MOVI r4,#B_STRTOD
MOVI r5,2
MOVI r6,#T_DOUBLE
CALL @ncc_add_builtin
; stdio streams
LA r1,0x4DC909C5
LA r2,@ncc_s_fopen
MOVI r3,5
MOVI r4,#B_FOPEN
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0xC3DEBAF7
LA r2,@ncc_s_fclose
MOVI r3,6
MOVI r4,#B_FCLOSE
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x9466DD68
LA r2,@ncc_s_fgetc
MOVI r3,5
MOVI r4,#B_FGETC
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x23C63DEB
LA r2,@ncc_s_fputc
MOVI r3,5
MOVI r4,#B_FPUTC
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x8466C438
LA r2,@ncc_s_fgets
MOVI r3,5
MOVI r4,#B_FGETS
MOVI r5,3
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0x33C6571B
LA r2,@ncc_s_fputs
MOVI r3,5
MOVI r4,#B_FPUTS
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xAE94BD2F
LA r2,@ncc_s_getchar
MOVI r3,7
MOVI r4,#B_GETCHAR
MOVI r5,0
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x83EB36DC
LA r2,@ncc_s_getc
MOVI r3,4
MOVI r4,#B_GETC
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x96183D4F
LA r2,@ncc_s_ungetc
MOVI r3,6
MOVI r4,#B_UNGETC
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x8C67B8F7
LA r2,@ncc_s_putc
MOVI r3,4
MOVI r4,#B_PUTC
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xE6AECF25
LA r2,@ncc_s_clearerr
MOVI r3,8
MOVI r4,#B_CLEARERR
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x36ACEE80
LA r2,@ncc_s_setvbuf
MOVI r3,7
MOVI r4,#B_SETVBUF
MOVI r5,4
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x7E011206
LA r2,@ncc_s_vprintf
MOVI r3,7
MOVI r4,#B_VPRINTF
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x01BE7C82
LA r2,@ncc_s_vfprintf
MOVI r3,8
MOVI r4,#B_VFPRINTF
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xCA35402D
LA r2,@ncc_s_vsprintf
MOVI r3,8
MOVI r4,#B_VSPRINTF
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xA4383EF3
LA r2,@ncc_s_vsnprintf
MOVI r3,9
MOVI r4,#B_VSNPRINTF
MOVI r5,4
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x25A94A70
LA r2,@ncc_s_isalnum
MOVI r3,7
MOVI r4,#B_ISALNUM
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x61D09D1E
LA r2,@ncc_s_iscntrl
MOVI r3,7
MOVI r4,#B_ISCNTRL
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x3A2097F7
LA r2,@ncc_s_isgraph
MOVI r3,7
MOVI r4,#B_ISGRAPH
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xC41553D8
LA r2,@ncc_s_isprint
MOVI r3,7
MOVI r4,#B_ISPRINT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x1AD615A7
LA r2,@ncc_s_ispunct
MOVI r3,7
MOVI r4,#B_ISPUNCT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x00A52190
LA r2,@ncc_s_isxdigit
MOVI r3,8
MOVI r4,#B_ISXDIGIT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x04744A6B
LA r2,@ncc_s_atol
MOVI r3,4
MOVI r4,#B_ATOL
MOVI r5,1
MOVI r6,#T_LONG
CALL @ncc_add_builtin
LA r1,0x0A108905
LA r2,@ncc_s_atoll
MOVI r3,5
MOVI r4,#B_ATOLL
MOVI r5,1
MOVI r6,#T_LONGLONG
CALL @ncc_add_builtin
LA r1,0xA52BCAF9
LA r2,@ncc_s_abort
MOVI r3,5
MOVI r4,#B_ABORT
MOVI r5,0
MOVI r6,#T_VOID
CALL @ncc_add_builtin
LA r1,0x6AED47BC
LA r2,@ncc_s_setbuf
MOVI r3,6
MOVI r4,#B_SETBUF
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x24A29F8F
LA r2,@ncc_s_wcschr
MOVI r3,6
MOVI r4,#B_WCSCHR
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0xED2AE2F9
LA r2,@ncc_s_wcsrchr
MOVI r3,7
MOVI r4,#B_WCSRCHR
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x8FF437BA
LA r2,@ncc_s_wcsncmp
MOVI r3,7
MOVI r4,#B_WCSNCMP
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x84C65B34
LA r2,@ncc_s_wcsncpy
MOVI r3,7
MOVI r4,#B_WCSNCPY
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x7BEB1DE2
LA r2,@ncc_s_wcsncat
MOVI r3,7
MOVI r4,#B_WCSNCAT
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x4AEA75D3
LA r2,@ncc_s_wcsspn
MOVI r3,6
MOVI r4,#B_WCSSPN
MOVI r5,2
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0xC3395A98
LA r2,@ncc_s_wcscspn
MOVI r3,7
MOVI r4,#B_WCSCSPN
MOVI r5,2
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0xEFA33F19
LA r2,@ncc_s_wcspbrk
MOVI r3,7
MOVI r4,#B_WCSPBRK
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x4EDFEEC3
LA r2,@ncc_s_wcsstr
MOVI r3,6
MOVI r4,#B_WCSSTR
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x73991F62
LA r2,@ncc_s_wcstok
MOVI r3,6
MOVI r4,#B_WCSTOK
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0xF866346E
LA r2,@ncc_s_wmemchr
MOVI r3,7
MOVI r4,#B_WMEMCHR
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0xF472FA15
LA r2,@ncc_s_wmemcmp
MOVI r3,7
MOVI r4,#B_WMEMCMP
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xEF2B8F1B
LA r2,@ncc_s_wmemcpy
MOVI r3,7
MOVI r4,#B_WMEMCPY
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0xDBC2DE5A
LA r2,@ncc_s_wmemmove
MOVI r3,8
MOVI r4,#B_WMEMMOVE
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x3017EAB1
LA r2,@ncc_s_wmemset
MOVI r3,7
MOVI r4,#B_WMEMSET
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x300D481E
LA r2,@ncc_s_btowc
MOVI r3,5
MOVI r4,#B_BTOWC
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xAA2F01B8
LA r2,@ncc_s_wctob
MOVI r3,5
MOVI r4,#B_WCTOB
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x03D226B5
LA r2,@ncc_s_mblen
MOVI r3,5
MOVI r4,#B_MBLEN
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x8B57371D
LA r2,@ncc_s_mbtowc
MOVI r3,6
MOVI r4,#B_MBTOWC
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x9BFD6FC5
LA r2,@ncc_s_wctomb
MOVI r3,6
MOVI r4,#B_WCTOMB
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xC0176FC5
LA r2,@ncc_s_mbstowcs
MOVI r3,8
MOVI r4,#B_MBSTOWCS
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x8E351FBF
LA r2,@ncc_s_wcstombs
MOVI r3,8
MOVI r4,#B_WCSTOMBS
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x9626ADEE
LA r2,@ncc_s_exp2
MOVI r3,4
MOVI r4,#B_EXP2
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x10031ED9
LA r2,@ncc_s_log2
MOVI r3,4
MOVI r4,#B_LOG2
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xCBE26BF0
LA r2,@ncc_s_log1p
MOVI r3,5
MOVI r4,#B_LOG1P
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xBE4E74EA
LA r2,@ncc_s_expm1
MOVI r3,5
MOVI r4,#B_EXPM1
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x18265A25
LA r2,@ncc_s_hypot
MOVI r3,5
MOVI r4,#B_HYPOT
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x54619836
LA r2,@ncc_s_cbrt
MOVI r3,4
MOVI r4,#B_CBRT
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x10D2583F
LA r2,@ncc_s_sinh
MOVI r3,4
MOVI r4,#B_SINH
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xF45C461C
LA r2,@ncc_s_cosh
MOVI r3,4
MOVI r4,#B_COSH
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xBAB19E4A
LA r2,@ncc_s_asinh
MOVI r3,5
MOVI r4,#B_ASINH
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xEDF2C855
LA r2,@ncc_s_acosh
MOVI r3,5
MOVI r4,#B_ACOSH
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x07275075
LA r2,@ncc_s_atanh
MOVI r3,5
MOVI r4,#B_ATANH
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xD55E61E5
LA r2,@ncc_s_trunc
MOVI r3,5
MOVI r4,#B_TRUNC
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x4F0BE23B
LA r2,@ncc_s_round
MOVI r3,5
MOVI r4,#B_ROUND
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x085B162E
LA r2,@ncc_s_rint
MOVI r3,4
MOVI r4,#B_RINT
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xEB53FAD3
LA r2,@ncc_s_nearbyint
MOVI r3,9
MOVI r4,#B_NEARBYINT
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x0BC83BC5
LA r2,@ncc_s_copysign
MOVI r3,8
MOVI r4,#B_COPYSIGN
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x2F8F13BA
LA r2,@ncc_s_nan
MOVI r3,3
MOVI r4,#B_NAN
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x1E950E05
LA r2,@ncc_s_fdim
MOVI r3,4
MOVI r4,#B_FDIM
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xD3EF43C7
LA r2,@ncc_s_fma
MOVI r3,3
MOVI r4,#B_FMA
MOVI r5,3
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xEB6EDE7F
LA r2,@ncc_s_modf
MOVI r3,4
MOVI r4,#B_MODF
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x8C63F160
LA r2,@ncc_s_ldexp
MOVI r3,5
MOVI r4,#B_LDEXP
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x90E4E0DE
LA r2,@ncc_s_scalbn
MOVI r3,6
MOVI r4,#B_SCALBN
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x348D7A98
LA r2,@ncc_s_remainder
MOVI r3,9
MOVI r4,#B_REMAINDER
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x0678CABF
LA r2,@ncc_s_atan
MOVI r3,4
MOVI r4,#B_ATAN
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xBD26DBF7
LA r2,@ncc_s_atan2
MOVI r3,5
MOVI r4,#B_ATAN2
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xFEAE7EA6
LA r2,@ncc_s_asin
MOVI r3,4
MOVI r4,#B_ASIN
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x3C01DF1F
LA r2,@ncc_s_acos
MOVI r3,4
MOVI r4,#B_ACOS
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xD41E7BD8
LA r2,@ncc_s_atexit
MOVI r3,6
MOVI r4,#B_ATEXIT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xB3002016
LA r2,@ncc_s__Exit
MOVI r3,5
MOVI r4,#B__EXIT
MOVI r5,1
MOVI r6,#T_VOID
CALL @ncc_add_builtin
LA r1,0x4734E946
LA r2,@ncc_s_vscanf
MOVI r3,6
MOVI r4,#B_VSCANF
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x0C5FFD02
LA r2,@ncc_s_vfscanf
MOVI r3,7
MOVI r4,#B_VFSCANF
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xD391E587
LA r2,@ncc_s_vsscanf
MOVI r3,7
MOVI r4,#B_VSSCANF
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x98FFAC6B
LA r2,@ncc_s_fgetpos
MOVI r3,7
MOVI r4,#B_FGETPOS
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x84EBA0CF
LA r2,@ncc_s_fsetpos
MOVI r3,7
MOVI r4,#B_FSETPOS
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xFD13491C
LA r2,@ncc_s_freopen
MOVI r3,7
MOVI r4,#B_FREOPEN
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xA30CDEF4
LA r2,@ncc_s_frexp
MOVI r3,5
MOVI r4,#B_FREXP
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x26789F12
LA r2,@ncc_s_nextafter
MOVI r3,9
MOVI r4,#B_NEXTAFTER
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x6E991783
LA r2,@ncc_s_wcstol
MOVI r3,6
MOVI r4,#B_WCSTOL
MOVI r5,3
MOVI r6,#T_LONG
CALL @ncc_add_builtin
LA r1,0x23E97CDC
LA r2,@ncc_s_wcstoul
MOVI r3,7
MOVI r4,#B_WCSTOUL
MOVI r5,3
MOVI r6,#T_ULONG
CALL @ncc_add_builtin
LA r1,0x0A00AD3D
LA r2,@ncc_s_wcstoll
MOVI r3,7
MOVI r4,#B_WCSTOLL
MOVI r5,3
MOVI r6,#T_LONGLONG
CALL @ncc_add_builtin
LA r1,0x388F4910
LA r2,@ncc_s_wcstoull
MOVI r3,8
MOVI r4,#B_WCSTOULL
MOVI r5,3
MOVI r6,#T_ULONGLONG
CALL @ncc_add_builtin
LA r1,0x7699241B
LA r2,@ncc_s_wcstod
MOVI r3,6
MOVI r4,#B_WCSTOD
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x78992741
LA r2,@ncc_s_wcstof
MOVI r3,6
MOVI r4,#B_WCSTOF
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x0200A0A5
LA r2,@ncc_s_wcstold
MOVI r3,7
MOVI r4,#B_WCSTOLD
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x4749493E
LA r2,@ncc_s_wcscoll
MOVI r3,7
MOVI r4,#B_WCSCOLL
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xF6FB2783
LA r2,@ncc_s_wcsxfrm
MOVI r3,7
MOVI r4,#B_WCSXFRM
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x78978610
LA r2,@ncc_s_erf
MOVI r3,3
MOVI r4,#B_ERF
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x4988A709
LA r2,@ncc_s_erfc
MOVI r3,4
MOVI r4,#B_ERFC
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x161E14A8
LA r2,@ncc_s_tgamma
MOVI r3,6
MOVI r4,#B_TGAMMA
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0xE0B8A600
LA r2,@ncc_s_lgamma
MOVI r3,6
MOVI r4,#B_LGAMMA
MOVI r5,1
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x1750BD42
LA r2,@ncc_s_iface_version
MOVI r3,13
MOVI r4,#B_IFVER
MOVI r5,0
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xE562AB48
LA r2,@ncc_s_div
MOVI r3,3
MOVI r4,#B_DIV
MOVI r5,2
LD r6,r0,#W_DIVTYPE
CALL @ncc_add_builtin
LA r1,0x91162DFE
LA r2,@ncc_s_ldiv
MOVI r3,4
MOVI r4,#B_LDIV
MOVI r5,2
LD r6,r0,#W_LDIVTYPE
CALL @ncc_add_builtin
LA r1,0x3CA92628
LA r2,@ncc_s_lldiv
MOVI r3,5
MOVI r4,#B_LLDIV
MOVI r5,2
LD r6,r0,#W_LLDIVTYPE
CALL @ncc_add_builtin
LA r1,0x23F04D1F
LA r2,@ncc_s_setitimer
MOVI r3,9
MOVI r4,#B_SETITIMER
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xD27CD00B
LA r2,@ncc_s_getitimer
MOVI r3,9
MOVI r4,#B_GETITIMER
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
; remaining standard C library names
LA r1,0x49CCF08D
LA r2,@ncc_s_strtof
MOVI r3,6
MOVI r4,#B_STRTOF
MOVI r5,2
MOVI r6,#T_FLOAT
CALL @ncc_add_builtin
LA r1,0x1A85AD31
LA r2,@ncc_s_strtold
MOVI r3,7
MOVI r4,#B_STRTOLD
MOVI r5,2
MOVI r6,#T_DOUBLE
CALL @ncc_add_builtin
LA r1,0x818E7D1B
LA r2,@ncc_s_llabs
MOVI r3,5
MOVI r4,#B_LLABS
MOVI r5,1
MOVI r6,#T_LONGLONG
CALL @ncc_add_builtin
LA r1,0xB1EE6F2E
LA r2,@ncc_s_strncat
MOVI r3,7
MOVI r4,#B_STRNCAT
MOVI r5,3
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0xE5DEE60E
LA r2,@ncc_s_remquo
MOVI r3,6
MOVI r4,#B_REMQUO
MOVI r5,3
MOVI r6,#T_DOUBLE
CALL @ncc_add_builtin
LA r1,0x38BD9BF1
LA r2,@ncc_s_mbsinit
MOVI r3,7
MOVI r4,#B_MBSINIT
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xFB5DD55B
LA r2,@ncc_s_mbrlen
MOVI r3,6
MOVI r4,#B_MBRLEN
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x3558C047
LA r2,@ncc_s_mbrtowc
MOVI r3,7
MOVI r4,#B_MBRTOWC
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x7801D91D
LA r2,@ncc_s_wcrtomb
MOVI r3,7
MOVI r4,#B_WCRTOMB
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x4138EC8D
LA r2,@ncc_s_mbsrtowcs
MOVI r3,9
MOVI r4,#B_MBSRTOWCS
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x42583425
LA r2,@ncc_s_wcsrtombs
MOVI r3,9
MOVI r4,#B_WCSRTOMBS
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin


LA r1,0x854B1879
LA r2,@ncc_s_fread
MOVI r3,5
MOVI r4,#B_FREAD
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x8AF06C60
LA r2,@ncc_s_fwrite
MOVI r3,6
MOVI r4,#B_FWRITE
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x937D1EF6
LA r2,@ncc_s_fprintf
MOVI r3,7
MOVI r4,#B_FPRINTF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x806806E5
LA r2,@ncc_s_fseek
MOVI r3,5
MOVI r4,#B_FSEEK
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x457B0DA6
LA r2,@ncc_s_ftell
MOVI r3,5
MOVI r4,#B_FTELL
MOVI r5,1
MOVI r6,#T_LONG
CALL @ncc_add_builtin
LA r1,0xDA112EAE
LA r2,@ncc_s_rewind
MOVI r3,6
MOVI r4,#B_REWIND
MOVI r5,1
MOVI r6,#T_VOID
CALL @ncc_add_builtin
LA r1,0xA94D67E5
LA r2,@ncc_s_feof
MOVI r3,4
MOVI r4,#B_FEOF
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x6E4CC81D
LA r2,@ncc_s_ferror
MOVI r3,6
MOVI r4,#B_FERROR
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x9798BBC1
LA r2,@ncc_s_fflush
MOVI r3,6
MOVI r4,#B_FFLUSH
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xDB9215FD
LA r2,@ncc_s_remove
MOVI r3,6
MOVI r4,#B_REMOVE
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x81F2B7D3
LA r2,@ncc_s_rename
MOVI r3,6
MOVI r4,#B_RENAME
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
; scanf family
LA r1,0x7F91078A
LA r2,@ncc_s_scanf
MOVI r3,5
MOVI r4,#B_SCANF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x33E99396
LA r2,@ncc_s_fscanf
MOVI r3,6
MOVI r4,#B_FSCANF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x03AB1E13
LA r2,@ncc_s_sscanf
MOVI r3,6
MOVI r4,#B_SSCANF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
SUB r14,r14,r13
LD r15,r14,0
RET

; ncc_add_global: r1=hash r2=name r3=len r4=type r5=value
ncc_add_global:
ST r15,r14,0
ADD r14,r14,r13
ST r4,r0,#W_BRET
ST r5,r0,#W_AGVAL
ST r1,r0,#W_TKA+2
ST r3,r0,#W_TKA+3
ST r0,r0,#W_TKA
ST r0,r0,#W_TKA+1
LA r6,#W_TKA+#TK_TEXT
MOVI r7,3
ADD r7,r7,r3
SHR r7,r7,2
BCOPY r6,r2,r7
MOVI r1,#SK_GLOBAL
CALL @sym_get_cur
CALL @sym_entry
ST r1,r0,#W_AGSYM
LD r1,r0,#W_BRET
CALL @ty_size
ST r1,r0,#W_TMTYPE
LD r1,r0,#W_BRET
CALL @ty_align
ST r1,r0,#W_AMOFF
LD r1,r0,#W_GLOBP
LD r2,r0,#W_AMOFF
CALL @px_align_up
ST r1,r0,#W_GLOBP
LD r3,r0,#W_AGSYM
ST r1,r3,#SY_AUX
LD r2,r0,#W_BRET
ST r2,r3,#SY_TYPE
LD r2,r0,#W_TMTYPE
ST r2,r3,#SY_SIZE
MOVI r2,1
ST r2,r3,#SY_CLS
LD r2,r0,#W_TMTYPE
ADD r2,r2,r1
ST r2,r0,#W_GLOBP
LD r2,r0,#W_AGVAL
MOVI r3,4
CALL @ni_storev
SUB r14,r14,r13
LD r15,r14,0
RET

; ncc_add_global64: r1=hash r2=name r3=len r4=type r5=lo r6=hi
ncc_add_global64:
ST r15,r14,0
ADD r14,r14,r13
ST r6,r0,#W_AGHI
CALL @ncc_add_global
LD r6,r0,#W_AGHI
LD r1,r0,#W_AGSYM
LD r1,r1,#SY_AUX
ADDI r1,r1,4
ADD r2,r6,r0
MOVI r3,4
CALL @ni_storev
SUB r14,r14,r13
LD r15,r14,0
RET

; ncc_add_member: r1=struct type r2=offset r3=hash r4=name r5=len
ncc_add_member:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_AMTYP
ST r2,r0,#W_AMOFF
ST r3,r0,#W_TKA+2
ST r5,r0,#W_TKA+3
ST r0,r0,#W_TKA
ST r0,r0,#W_TKA+1
LA r6,#W_TKA+#TK_TEXT
MOVI r7,3
ADD r7,r7,r5
SHR r7,r7,2
BCOPY r6,r4,r7
MOVI r1,#SK_MEMBER
CALL @sym_get_cur
ST r1,r0,#W_AGSYM
LD r2,r0,#W_MEMBP
ST r1,r2,0
LD r1,r0,#W_AMOFF
ST r1,r2,1
LD r1,r0,#W_AMTYP
ST r1,r2,2
ST r0,r2,3
ADDI r2,r2,4
ST r2,r0,#W_MEMBP
LD r1,r0,#W_TMTYPE
CALL @ty_addr
LD r2,r1,#TY_NMEM
ADD r2,r2,r13
ST r2,r1,#TY_NMEM
SUB r14,r14,r13
LD r15,r14,0
RET

; ncc_add_tm: built-in struct tm with nine int members
ncc_add_tm:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#TY_STRUCT
CALL @ty_struct
ST r1,r0,#W_TMTYPE
CALL @ty_addr
LD r2,r0,#W_MEMBP
ST r2,r1,#TY_MEM
ST r0,r1,#TY_NMEM
MOVI r2,0
LA r3,0x8132EEA0
LA r4,@ncc_s_tm_sec
MOVI r5,6
CALL @ncc_add_mem9
MOVI r2,4
LA r3,0x9E42A269
LA r4,@ncc_s_tm_min
MOVI r5,6
CALL @ncc_add_mem9
MOVI r2,8
LA r3,0x56BE5619
LA r4,@ncc_s_tm_hour
MOVI r5,7
CALL @ncc_add_mem9
MOVI r2,12
LA r3,0xB525F854
LA r4,@ncc_s_tm_mday
MOVI r5,7
CALL @ncc_add_mem9
MOVI r2,16
LA r3,0x7E34F87F
LA r4,@ncc_s_tm_mon
MOVI r5,6
CALL @ncc_add_mem9
MOVI r2,20
LA r3,0x1BD6031A
LA r4,@ncc_s_tm_year
MOVI r5,7
CALL @ncc_add_mem9
MOVI r2,24
LA r3,0xE49FAC52
LA r4,@ncc_s_tm_wday
MOVI r5,7
CALL @ncc_add_mem9
MOVI r2,28
LA r3,0x9E92CD90
LA r4,@ncc_s_tm_yday
MOVI r5,7
CALL @ncc_add_mem9
MOVI r2,32
LA r3,0x8EAE9CF2
LA r4,@ncc_s_tm_isdst
MOVI r5,8
CALL @ncc_add_mem9
LD r1,r0,#W_TMTYPE
CALL @ty_addr
MOVI r2,36
ST r2,r1,#TY_SIZE
MOVI r2,4
ST r2,r1,#TY_ALIGN
LA r1,0x44454B4A
LA r2,@ncc_s_tm
MOVI r3,2
LD r4,r0,#W_TMTYPE
CALL @ncc_add_typedef
SUB r14,r14,r13
LD r15,r14,0
RET
ncc_add_mem9:
MOVI r1,#T_INT
JMP @ncc_add_member

; ncc_add_lconv: built-in struct lconv (glibc field order)
ncc_add_lconv:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#TY_STRUCT
CALL @ty_struct
ST r1,r0,#W_TMTYPE
CALL @ty_addr
LD r2,r0,#W_MEMBP
ST r2,r1,#TY_MEM
ST r0,r1,#TY_NMEM
MOVI r2,0
LD r1,r0,#W_PTRC
LA r3,0x19841EA5
LA r4,@ncc_s_lc_decimal_point
MOVI r5,13
CALL @ncc_add_member
MOVI r2,4
LD r1,r0,#W_PTRC
LA r3,0x1B9379BF
LA r4,@ncc_s_lc_thousands_sep
MOVI r5,13
CALL @ncc_add_member
MOVI r2,8
LD r1,r0,#W_PTRC
LA r3,0x3F83622C
LA r4,@ncc_s_lc_grouping
MOVI r5,8
CALL @ncc_add_member
MOVI r2,12
LD r1,r0,#W_PTRC
LA r3,0x73D02314
LA r4,@ncc_s_lc_int_curr_symbol
MOVI r5,16
CALL @ncc_add_member
MOVI r2,16
LD r1,r0,#W_PTRC
LA r3,0xAF93D07B
LA r4,@ncc_s_lc_currency_symbol
MOVI r5,15
CALL @ncc_add_member
MOVI r2,20
LD r1,r0,#W_PTRC
LA r3,0x959100DC
LA r4,@ncc_s_lc_mon_decimal_point
MOVI r5,17
CALL @ncc_add_member
MOVI r2,24
LD r1,r0,#W_PTRC
LA r3,0x11EE1F0A
LA r4,@ncc_s_lc_mon_thousands_sep
MOVI r5,18
CALL @ncc_add_member
MOVI r2,28
LD r1,r0,#W_PTRC
LA r3,0xD6149C73
LA r4,@ncc_s_lc_mon_grouping
MOVI r5,12
CALL @ncc_add_member
MOVI r2,32
LD r1,r0,#W_PTRC
LA r3,0x5C182B3A
LA r4,@ncc_s_lc_positive_sign
MOVI r5,13
CALL @ncc_add_member
MOVI r2,36
LD r1,r0,#W_PTRC
LA r3,0x9D4226FA
LA r4,@ncc_s_lc_negative_sign
MOVI r5,13
CALL @ncc_add_member
MOVI r2,40
MOVI r1,#T_CHAR
LA r3,0x53EB030E
LA r4,@ncc_s_lc_int_frac_digits
MOVI r5,15
CALL @ncc_add_member
MOVI r2,41
MOVI r1,#T_CHAR
LA r3,0xD50A76D4
LA r4,@ncc_s_lc_frac_digits
MOVI r5,11
CALL @ncc_add_member
MOVI r2,42
MOVI r1,#T_CHAR
LA r3,0x3756EE40
LA r4,@ncc_s_lc_p_cs_precedes
MOVI r5,13
CALL @ncc_add_member
MOVI r2,43
MOVI r1,#T_CHAR
LA r3,0xC8010025
LA r4,@ncc_s_lc_p_sep_by_space
MOVI r5,15
CALL @ncc_add_member
MOVI r2,44
MOVI r1,#T_CHAR
LA r3,0xC22385E6
LA r4,@ncc_s_lc_n_cs_precedes
MOVI r5,13
CALL @ncc_add_member
MOVI r2,45
MOVI r1,#T_CHAR
LA r3,0x2AAA6ECF
LA r4,@ncc_s_lc_n_sep_by_space
MOVI r5,15
CALL @ncc_add_member
MOVI r2,46
MOVI r1,#T_CHAR
LA r3,0x660ECA3A
LA r4,@ncc_s_lc_p_sign_posn
MOVI r5,11
CALL @ncc_add_member
MOVI r2,47
MOVI r1,#T_CHAR
LA r3,0xDEE62094
LA r4,@ncc_s_lc_n_sign_posn
MOVI r5,11
CALL @ncc_add_member
MOVI r2,48
MOVI r1,#T_CHAR
LA r3,0x2638486E
LA r4,@ncc_s_lc_int_p_cs_precedes
MOVI r5,17
CALL @ncc_add_member
MOVI r2,49
MOVI r1,#T_CHAR
LA r3,0x5596DDE7
LA r4,@ncc_s_lc_int_p_sep_by_space
MOVI r5,19
CALL @ncc_add_member
MOVI r2,50
MOVI r1,#T_CHAR
LA r3,0xFC2BA1F8
LA r4,@ncc_s_lc_int_n_cs_precedes
MOVI r5,17
CALL @ncc_add_member
MOVI r2,51
MOVI r1,#T_CHAR
LA r3,0x8FDD14CD
LA r4,@ncc_s_lc_int_n_sep_by_space
MOVI r5,19
CALL @ncc_add_member
MOVI r2,52
MOVI r1,#T_CHAR
LA r3,0x5B04609C
LA r4,@ncc_s_lc_int_p_sign_posn
MOVI r5,15
CALL @ncc_add_member
MOVI r2,53
MOVI r1,#T_CHAR
LA r3,0x6A100872
LA r4,@ncc_s_lc_int_n_sign_posn
MOVI r5,15
CALL @ncc_add_member
LD r1,r0,#W_TMTYPE
CALL @ty_addr
MOVI r2,56
ST r2,r1,#TY_SIZE
MOVI r2,4
ST r2,r1,#TY_ALIGN
LA r1,0x2EE946D5
LA r2,@ncc_s_lconv
MOVI r3,5
LD r4,r0,#W_TMTYPE
CALL @ncc_add_typedef
; qsort(base,n,size,cmp)
LA r1,0xBE456288
LA r2,@ncc_s_qsort
MOVI r3,5
MOVI r4,#B_QSORT
MOVI r5,4
MOVI r6,#T_VOID
CALL @ncc_add_builtin
; bsearch(key,base,n,size,cmp)
LA r1,0xE039B2C9
LA r2,@ncc_s_bsearch
MOVI r3,7
MOVI r4,#B_BSEARCH
MOVI r5,5
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; setjmp/longjmp
LA r1,0xBF979A06
LA r2,@ncc_s_setjmp
MOVI r3,6
MOVI r4,#B_SETJMP
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xC8F2ABD6
LA r2,@ncc_s_longjmp
MOVI r3,7
MOVI r4,#B_LONGJMP
MOVI r5,2
MOVI r6,#T_VOID
CALL @ncc_add_builtin
LA r1,0x12CFF05A
LA r2,@ncc_s_jmp_buf
MOVI r3,7
LD r4,r0,#W_PTRV
CALL @ncc_add_typedef
; strftime
LA r1,0x0B30AAE3
LA r2,@ncc_s_strftime
MOVI r3,8
MOVI r4,#B_STRFTIME
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin
; tmpnam/tmpfile
LA r1,0xA6B648DA
LA r2,@ncc_s_tmpnam
MOVI r3,6
MOVI r4,#B_TMPNAM
MOVI r5,1
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0x94E5B448
LA r2,@ncc_s_tmpfile
MOVI r3,7
MOVI r4,#B_TMPFILE
MOVI r5,0
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
; wide strings
LA r1,0xA4E39B3B
LA r2,@ncc_s_wcslen
MOVI r3,6
MOVI r4,#B_WCSLEN
MOVI r5,1
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x28976CE8
LA r2,@ncc_s_wcscmp
MOVI r3,6
MOVI r4,#B_WCSCMP
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x2D681692
LA r2,@ncc_s_wcscpy
MOVI r3,6
MOVI r4,#B_WCSCPY
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x2C8CE5D8
LA r2,@ncc_s_wcscat
MOVI r3,6
MOVI r4,#B_WCSCAT
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x19EBECDA
LA r2,@ncc_s_alarm
MOVI r3,5
MOVI r4,#B_ALARM
MOVI r5,1
MOVI r6,#T_UINT
CALL @ncc_add_builtin
; extra string helpers
LA r1,0xB573D07F
LA r2,@ncc_s_strspn
MOVI r3,6
MOVI r4,#B_STRSPN
MOVI r5,2
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0xD462345C
LA r2,@ncc_s_strcspn
MOVI r3,7
MOVI r4,#B_STRCSPN
MOVI r5,2
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x6B070B35
LA r2,@ncc_s_strpbrk
MOVI r3,7
MOVI r4,#B_STRPBRK
MOVI r5,2
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x3CCCDC16
LA r2,@ncc_s_strtok
MOVI r3,6
MOVI r4,#B_STRTOK
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0x4DDDED5A
LA r2,@ncc_s_getenv
MOVI r3,6
MOVI r4,#B_GETENV
MOVI r5,1
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0x491E0A9C
LA r2,@ncc_s_system
MOVI r3,6
MOVI r4,#B_SYSTEM
MOVI r5,1
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xAF4975FD
LA r2,@ncc_s_memchr
MOVI r3,6
MOVI r4,#B_MEMCHR
MOVI r5,3
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
LA r1,0x54524C02
LA r2,@ncc_s_strcoll
MOVI r3,7
MOVI r4,#B_STRCOLL
MOVI r5,2
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xE9B5B52F
LA r2,@ncc_s_strxfrm
MOVI r3,7
MOVI r4,#B_STRXFRM
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x76A5D196
LA r2,@ncc_s_strerror
MOVI r3,8
MOVI r4,#B_STRERROR
MOVI r5,1
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0x74BFD75F
LA r2,@ncc_s_perror
MOVI r3,6
MOVI r4,#B_PERROR
MOVI r5,1
MOVI r6,#T_VOID
CALL @ncc_add_builtin
LA r1,0x9C5BBF15
LA r2,@ncc_s_wprintf
MOVI r3,7
MOVI r4,#B_WPRINTF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xF240C78F
LA r2,@ncc_s_wscanf
MOVI r3,6
MOVI r4,#B_WSCANF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
; C11 <uchar.h>
LA r1,0x6CFB2385
LA r2,@ncc_s_mbrtoc16
MOVI r3,8
MOVI r4,#B_MBRTOC16
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x7E1763E3
LA r2,@ncc_s_c16rtomb
MOVI r3,8
MOVI r4,#B_C16RTOMB
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x78F6B93B
LA r2,@ncc_s_mbrtoc32
MOVI r3,8
MOVI r4,#B_MBRTOC32
MOVI r5,4
MOVI r6,#T_UINT
CALL @ncc_add_builtin
LA r1,0x3E381171
LA r2,@ncc_s_c32rtomb
MOVI r3,8
MOVI r4,#B_C32RTOMB
MOVI r5,3
MOVI r6,#T_UINT
CALL @ncc_add_builtin
; wide stdio f/s/v variants
LA r1,0xCDB17C91
LA r2,@ncc_s_fwprintf
MOVI r3,8
MOVI r4,#B_FWPRINTF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x12CD01FB
LA r2,@ncc_s_fwscanf
MOVI r3,7
MOVI r4,#B_FWSCANF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xDB2DD230
LA r2,@ncc_s_swprintf
MOVI r3,8
MOVI r4,#B_SWPRINTF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x9C9DEE30
LA r2,@ncc_s_swscanf
MOVI r3,7
MOVI r4,#B_SWSCANF
MOVI r5,0xFFFF
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x1CB2FBBD
LA r2,@ncc_s_vfwprintf
MOVI r3,9
MOVI r4,#B_VFWPRINTF
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x5EA48BE4
LA r2,@ncc_s_vswprintf
MOVI r3,9
MOVI r4,#B_VSWPRINTF
MOVI r5,4
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0xE163A3B7
LA r2,@ncc_s_vfwscanf
MOVI r3,8
MOVI r4,#B_VFWSCANF
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x6A1D5624
LA r2,@ncc_s_vswscanf
MOVI r3,8
MOVI r4,#B_VSWSCANF
MOVI r5,3
MOVI r6,#T_INT
CALL @ncc_add_builtin
LA r1,0x3FCCE0CF
LA r2,@ncc_s_strtol
MOVI r3,6
MOVI r4,#B_STRTOL
MOVI r5,3
MOVI r6,#T_LONG
CALL @ncc_add_builtin
LA r1,0xC6FD0D8
LA r2,@ncc_s_strtoul
MOVI r3,7
MOVI r4,#B_STRTOUL
MOVI r5,3
MOVI r6,#T_ULONG
CALL @ncc_add_builtin
LA r1,0x1285A099
LA r2,@ncc_s_strtoll
MOVI r3,7
MOVI r4,#B_STRTOLL
MOVI r5,3
MOVI r6,#T_LONGLONG
CALL @ncc_add_builtin
LA r1,0x48058B5C
LA r2,@ncc_s_strtoull
MOVI r3,8
MOVI r4,#B_STRTOULL
MOVI r5,3
MOVI r6,#T_ULONGLONG
CALL @ncc_add_builtin
LA r1,0x49053E05
LA r2,@ncc_s_strrchr
MOVI r3,7
MOVI r4,#B_STRRCHR
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0xD4F595B7
LA r2,@ncc_s_strndup
MOVI r3,7
MOVI r4,#B_STRNDUP
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0x1C3EE03C
LA r2,@ncc_s_stpcpy
MOVI r3,6
MOVI r4,#B_STPCPY
MOVI r5,2
LD r6,r0,#W_PTRC
CALL @ncc_add_builtin
LA r1,0xC842BD37
LA r2,@ncc_s_memccpy
MOVI r3,7
MOVI r4,#B_MEMCCPY
MOVI r5,4
LD r6,r0,#W_PTRV
CALL @ncc_add_builtin
CALL @ncc_extra_types
CALL @ncc_extra_builtins
CALL @ncc_headers_init
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
LD r4,r0,#W_TKA+2
ST r4,r1,#SY_HASH
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

; ncc_add_typedef: r1=hash r2=name(word addr) r3=len r4=type
ncc_add_typedef:
ST r15,r14,0
ADD r14,r14,r13
ST r4,r0,#W_BRET
ST r1,r0,#W_TKA+2
ST r3,r0,#W_TKA+3
ST r0,r0,#W_TKA
ST r0,r0,#W_TKA+1
LA r6,#W_TKA+#TK_TEXT
MOVI r7,3
ADD r7,r7,r3
SHR r7,r7,2
BCOPY r6,r2,r7
MOVI r1,#SK_TYPE
CALL @sym_get_cur
CALL @sym_entry
LD r4,r0,#W_BRET
ST r4,r1,#SY_TYPE
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_BRET
CALL @ty_size
LD r4,r0,#W_TY_TMP
ST r1,r4,#SY_SIZE
ST r0,r4,#SY_CLS
SUB r14,r14,r13
LD r15,r14,0
RET

; ncc_add_enum_const: r1=hash r2=name r3=len r4=value
ncc_add_enum_const:
ST r15,r14,0
ADD r14,r14,r13
ST r4,r0,#W_BRET
ST r1,r0,#W_TKA+2
ST r3,r0,#W_TKA+3
ST r0,r0,#W_TKA
ST r0,r0,#W_TKA+1
LA r6,#W_TKA+#TK_TEXT
MOVI r7,3
ADD r7,r7,r3
SHR r7,r7,2
BCOPY r6,r2,r7
MOVI r1,#SK_ENUM
CALL @sym_get_cur
CALL @sym_entry
LD r4,r0,#W_BRET
ST r4,r1,#SY_AUX
MOVI r4,#T_INT
ST r4,r1,#SY_TYPE
MOVI r4,4
ST r4,r1,#SY_SIZE
ST r0,r1,#SY_CLS
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
ncc_s_va_start:
.str "va_start"
ncc_s_va_arg:
.str "va_arg"
ncc_s_va_end:
.str "va_end"
ncc_s_size_t:
.str "size_t"
ncc_s_ptrdiff_t:
.str "ptrdiff_t"
ncc_s_intptr_t:
.str "intptr_t"
ncc_s_uintptr_t:
.str "uintptr_t"
ncc_s_time_t:
.str "time_t"
ncc_s_clock_t:
.str "clock_t"
ncc_s_FILE:
.str "FILE"
ncc_s_sig_atomic_t:
.str "sig_atomic_t"
ncc_s_wchar_t:
.str "wchar_t"
ncc_s_wint_t:
.str "wint_t"
ncc_s_mbstate_t:
.str "mbstate_t"
ncc_s_stdin:
.str "stdin"
ncc_s_stdout:
.str "stdout"
ncc_s_stderr:
.str "stderr"
ncc_s_tm:
.str "tm"
ncc_s_tm_sec:
.str "tm_sec"
ncc_s_tm_min:
.str "tm_min"
ncc_s_tm_hour:
.str "tm_hour"
ncc_s_tm_mday:
.str "tm_mday"
ncc_s_tm_mon:
.str "tm_mon"
ncc_s_tm_year:
.str "tm_year"
ncc_s_tm_wday:
.str "tm_wday"
ncc_s_tm_yday:
.str "tm_yday"
ncc_s_tm_isdst:
.str "tm_isdst"
ncc_s_c_NULL:
.str "NULL"
ncc_s_c_EOF:
.str "EOF"
ncc_s_c_EXIT_SUCCESS:
.str "EXIT_SUCCESS"
ncc_s_c_EXIT_FAILURE:
.str "EXIT_FAILURE"
ncc_s_c_SEEK_SET:
.str "SEEK_SET"
ncc_s_c_SEEK_CUR:
.str "SEEK_CUR"
ncc_s_c_SEEK_END:
.str "SEEK_END"
ncc_s_c_CLOCKS_PER_SEC:
.str "CLOCKS_PER_SEC"
ncc_s_c_RAND_MAX:
.str "RAND_MAX"
ncc_s_c_INT_MAX:
.str "INT_MAX"
ncc_s_c_INT_MIN:
.str "INT_MIN"
ncc_s_c_UINT_MAX:
.str "UINT_MAX"
ncc_s_c_LONG_MAX:
.str "LONG_MAX"
ncc_s_c_LONG_MIN:
.str "LONG_MIN"
ncc_s_c_ULONG_MAX:
.str "ULONG_MAX"
ncc_s_c_CHAR_BIT:
.str "CHAR_BIT"
ncc_s_c_SCHAR_MIN:
.str "SCHAR_MIN"
ncc_s_c_SCHAR_MAX:
.str "SCHAR_MAX"
ncc_s_c_UCHAR_MAX:
.str "UCHAR_MAX"
ncc_s_c_SHRT_MIN:
.str "SHRT_MIN"
ncc_s_c_SHRT_MAX:
.str "SHRT_MAX"
ncc_s_c_USHRT_MAX:
.str "USHRT_MAX"
ncc_s_c_SIZE_MAX:
.str "SIZE_MAX"
ncc_s_c_SIGINT:
.str "SIGINT"
ncc_s_c_SIGILL:
.str "SIGILL"
ncc_s_c_SIGABRT:
.str "SIGABRT"
ncc_s_c_SIGFPE:
.str "SIGFPE"
ncc_s_c_SIGSEGV:
.str "SIGSEGV"
ncc_s_c_SIGTERM:
.str "SIGTERM"
ncc_s_c_SIG_DFL:
.str "SIG_DFL"
ncc_s_c_SIG_IGN:
.str "SIG_IGN"
ncc_s_f_M_PI:
.str "M_PI"
ncc_s_f_M_E:
.str "M_E"
ncc_s_f_M_SQRT2:
.str "M_SQRT2"
ncc_s_f_M_LN2:
.str "M_LN2"
ncc_s_f_M_LN10:
.str "M_LN10"
ncc_s_f_M_LOG2E:
.str "M_LOG2E"
ncc_s_f_M_LOG10E:
.str "M_LOG10E"
ncc_s_f_M_PI_2:
.str "M_PI_2"
ncc_s_f_M_PI_4:
.str "M_PI_4"
ncc_s_f_M_1_PI:
.str "M_1_PI"
ncc_s_f_M_2_PI:
.str "M_2_PI"
ncc_s_f_M_2_SQRTPI:
.str "M_2_SQRTPI"
ncc_s_f_M_SQRT1_2:
.str "M_SQRT1_2"
ncc_s_f_HUGE_VAL:
.str "HUGE_VAL"
ncc_s_f_INFINITY:
.str "INFINITY"
ncc_s_f_NAN:
.str "NAN"
ncc_s_time:
.str "time"
ncc_s_clock:
.str "clock"
ncc_s_difftime:
.str "difftime"
ncc_s_mktime:
.str "mktime"
ncc_s_localtime:
.str "localtime"
ncc_s_gmtime:
.str "gmtime"
ncc_s_asctime:
.str "asctime"
ncc_s_ctime:
.str "ctime"
ncc_s_setlocale:
.str "setlocale"
ncc_s_localeconv:
.str "localeconv"
ncc_s_signal:
.str "signal"
ncc_s_raise:
.str "raise"
ncc_s_atof:
.str "atof"
ncc_s_strtod:
.str "strtod"
ncc_s_lconv:
.str "lconv"
ncc_s_lc_decimal_point:
.str "decimal_point"
ncc_s_lc_thousands_sep:
.str "thousands_sep"
ncc_s_lc_grouping:
.str "grouping"
ncc_s_lc_int_curr_symbol:
.str "int_curr_symbol"
ncc_s_lc_currency_symbol:
.str "currency_symbol"
ncc_s_lc_mon_decimal_point:
.str "mon_decimal_point"
ncc_s_lc_mon_thousands_sep:
.str "mon_thousands_sep"
ncc_s_lc_mon_grouping:
.str "mon_grouping"
ncc_s_lc_positive_sign:
.str "positive_sign"
ncc_s_lc_negative_sign:
.str "negative_sign"
ncc_s_lc_int_frac_digits:
.str "int_frac_digits"
ncc_s_lc_frac_digits:
.str "frac_digits"
ncc_s_lc_p_cs_precedes:
.str "p_cs_precedes"
ncc_s_lc_p_sep_by_space:
.str "p_sep_by_space"
ncc_s_lc_n_cs_precedes:
.str "n_cs_precedes"
ncc_s_lc_n_sep_by_space:
.str "n_sep_by_space"
ncc_s_lc_p_sign_posn:
.str "p_sign_posn"
ncc_s_lc_n_sign_posn:
.str "n_sign_posn"
ncc_s_lc_int_p_cs_precedes:
.str "int_p_cs_precedes"
ncc_s_lc_int_p_sep_by_space:
.str "int_p_sep_by_space"
ncc_s_lc_int_n_cs_precedes:
.str "int_n_cs_precedes"
ncc_s_lc_int_n_sep_by_space:
.str "int_n_sep_by_space"
ncc_s_lc_int_p_sign_posn:
.str "int_p_sign_posn"
ncc_s_lc_int_n_sign_posn:
.str "int_n_sign_posn"
ncc_s_fopen:
.str "fopen"
ncc_s_fclose:
.str "fclose"
ncc_s_fgetc:
.str "fgetc"
ncc_s_fputc:
.str "fputc"
ncc_s_fgets:
.str "fgets"
ncc_s_fputs:
.str "fputs"
ncc_s_fread:
.str "fread"
ncc_s_fwrite:
.str "fwrite"
ncc_s_fprintf:
.str "fprintf"
ncc_s_fseek:
.str "fseek"
ncc_s_ftell:
.str "ftell"
ncc_s_rewind:
.str "rewind"
ncc_s_feof:
.str "feof"
ncc_s_ferror:
.str "ferror"
ncc_s_fflush:
.str "fflush"
ncc_s_remove:
.str "remove"
ncc_s_rename:
.str "rename"
ncc_s_scanf:
.str "scanf"
ncc_s_fscanf:
.str "fscanf"
ncc_s_sscanf:
.str "sscanf"
ncc_s_va_list:
.str "va_list"
ncc_s_bool:
.str "bool"
ncc_s_true:
.str "true"
ncc_s_false:
.str "false"
ncc_s_sprintf:
.str "sprintf"
ncc_s_snprintf:
.str "snprintf"
ncc_s_sin:
.str "sin"
ncc_s_cos:
.str "cos"
ncc_s_sqrt:
.str "sqrt"
ncc_s_fabs:
.str "fabs"
ncc_s_pow:
.str "pow"
ncc_s_exp:
.str "exp"
ncc_s_log:
.str "log"
ncc_s_log10:
.str "log10"
ncc_s_tanh:
.str "tanh"
ncc_s_floor:
.str "floor"
ncc_s_ceil:
.str "ceil"
ncc_s_fmod:
.str "fmod"
ncc_s_fmin:
.str "fmin"
ncc_s_fmax:
.str "fmax"
ncc_s_dp4b:
.str "dp4b"
ncc_s_aligned_alloc:
.str "aligned_alloc"
ncc_s_tan:
.str "tan"
ncc_s_strchr:
.str "strchr"
ncc_s_strstr:
.str "strstr"
ncc_s_strdup:
.str "strdup"
ncc_s_isdigit:
.str "isdigit"
ncc_s_isalpha:
.str "isalpha"
ncc_s_isspace:
.str "isspace"
ncc_s_isupper:
.str "isupper"
ncc_s_islower:
.str "islower"
ncc_s_toupper:
.str "toupper"
ncc_s_tolower:
.str "tolower"
ncc_s_rand:
.str "rand"
ncc_s_srand:
.str "srand"
ncc_s_labs:
.str "labs"
ncc_s_memmove:
.str "memmove"

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

; str_add_cur_wide: like str_add_cur but emits 4-byte wide characters.
str_add_cur_wide:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_STRP
ST r2,r0,#R_T0
LD r3,r0,#W_TKA+3
ADD r3,r3,r13
SHL r3,r3,2
ADD r4,r2,r3
LA r5,#C_ROEND
CMP r4,r5
JMP[LT] @sacw_room
MOVI r1,4
JMP @ncc_err
sacw_room:
LA r5,#W_TKA+#TK_TEXT
SHL r5,r5,2
LD r6,r0,#W_TKA+3
MOVI r7,0
sacw_l:
CMP r7,r6
JMP[GE] @sacw_end
LDB r1,r5,0
STB r1,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
ADD r5,r5,r13
ADD r7,r7,r13
JMP @sacw_l
sacw_end:
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
STB r0,r2,0
ADDI r2,r2,1
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
; struct/union values are represented by their byte address
JMP @per_done
per_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_discard: pop an expression result (two words for long long)
px_discard:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[NE] @pxd_one
LA r1,#I_POP
CALL @ir_op
pxd_one:
LA r1,#I_POP
CALL @ir_op
SUB r14,r14,r13
LD r15,r14,0
RET

; px_emit_load: r1=type -> emit I_LOAD
px_emit_load:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[NE] @pxl_notll
LA r1,#I_LLOAD
CALL @ir_op
JMP @pxl_d
pxl_notll:
LD r1,r0,#W_TY_ID
CALL @ty_store_code
ADD r2,r1,r0
LA r1,#I_LOAD
CALL @ir_emit
LD r1,r0,#W_TY_ID
CALL @ty_bitwidth
CMP r2,r0
JMP[EQ] @pxl_d
ST r2,r0,#W_BITW
LD r1,r0,#W_LBIT
CMP r1,r0
JMP[EQ] @pxl_noshift
LA r1,#I_PUSH
LD r2,r0,#W_LBIT
CALL @ir_emit
LA r1,#I_SHR
CALL @ir_op
pxl_noshift:
LD r2,r0,#W_BITW
MOVI r1,1
CALL @ni_shl
ADDI r1,r1,-1
ST r1,r0,#W_TY_TMP
LA r1,#I_PUSH
LD r2,r0,#W_TY_TMP
CALL @ir_emit
LA r1,#I_AND
CALL @ir_op
LD r1,r0,#W_TY_ID
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pxl_d
LD r2,r0,#W_BITW
MOVI r3,32
SUB r3,r3,r2
CMP r3,r0
JMP[EQ] @pxl_d
LA r1,#I_PUSH
LD r2,r0,#W_BITW
MOVI r3,32
SUB r2,r3,r2
CALL @ir_emit
LA r1,#I_SHL
CALL @ir_op
LA r1,#I_PUSH
LD r2,r0,#W_BITW
MOVI r3,32
SUB r2,r3,r2
CALL @ir_emit
LA r1,#I_SHR
CALL @ir_op
pxl_d:
SUB r14,r14,r13
LD r15,r14,0
RET
; px_emit_store: r1=type r2=keep -> emit I_STORE/I_STORE_K
px_emit_store:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_ID
ST r2,r0,#W_TY_COUNT
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r3,#TY_LL
CMP r1,r3
JMP[NE] @pxs_notll
LA r1,#I_LLSTORE
LD r2,r0,#W_TY_COUNT
CALL @ir_emit
JMP @pxs_d
pxs_notll:
LD r1,r0,#W_TY_ID
CALL @ty_bitwidth
CMP r2,r0
JMP[EQ] @pxs_nomask
ST r2,r0,#W_BITW
LD r2,r0,#W_BITW
SHL r2,r2,8
LD r3,r0,#W_LBIT
BOOL.14 r2,r2,r3
LA r1,#I_BITSTORE
CALL @ir_emit
JMP @pxs_d
pxs_plainmask:
MOVI r1,1
CALL @ni_shl
ADDI r1,r1,-1
ST r1,r0,#W_TY_TMP
LA r1,#I_PUSH
LD r2,r0,#W_TY_TMP
CALL @ir_emit
LA r1,#I_AND
CALL @ir_op
pxs_nomask:
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_BOOL
CMP r1,r2
JMP[NE] @pxs_notbool
LA r1,#I_LNOT
CALL @ir_op
LA r1,#I_LNOT
CALL @ir_op
pxs_notbool:
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pxs_agg
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pxs_agg
LD r1,r0,#W_TY_ID
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
pxs_agg:
LD r1,r0,#W_TY_ID
CALL @ty_size
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_MEMCPY
CALL @ir_op
SUB r14,r14,r13
LD r15,r14,0
RET
; px_addr_g: r1=absolute byte address
px_addr_g:
ST r0,r0,#W_LBIT
ADD r2,r1,r0
LA r1,#I_GADDR
JMP @ir_emit
; px_addr_l: r1=byte offset from fp
px_addr_l:
ST r0,r0,#W_LBIT
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
MOVI r2,#TY_LL
LD r1,r0,#W_TY_BASE
CMP r1,r2
JMP[NE] @pxc_not_lldst
LD r1,r0,#W_TY_KIND
CMP r1,r2
JMP[EQ] @pxc_done
JMP @pxc_to_ll
pxc_not_lldst:
LD r1,r0,#W_TY_KIND
MOVI r2,#TY_LL
CMP r1,r2
JMP[EQ] @pxc_from_ll
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
JMP @pxc_done
pxc_to_ll:
LD r1,r0,#W_TY_KIND
MOVI r2,#TY_FLOAT
CMP r1,r2
JMP[NE] @pxc_to_ll_int
LD r1,r0,#W_TY_ID
CALL @ty_sign
MOVI r2,0
CMP r1,r0
JMP[NE] @pxc_f2i_u
MOVI r2,1
pxc_f2i_u:
LA r1,#I_LLF2I
CALL @ir_emit
JMP @pxc_done
pxc_to_ll_int:
LD r1,r0,#W_ETYPE
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pxc_ll_uns
MOVI r2,0
JMP @pxc_ll_go
pxc_ll_uns:
LA r2,0x10000
pxc_ll_go:
LA r1,#I_LLEXT
CALL @ir_emit
JMP @pxc_done
pxc_from_ll:
LD r1,r0,#W_TY_BASE
MOVI r2,#TY_FLOAT
CMP r1,r2
JMP[NE] @pxc_from_ll_i
LA r1,#I_LLI2F
MOVI r2,0
CALL @ir_emit
JMP @pxc_done
pxc_from_ll_i:
LA r1,#I_LLTRUNC
MOVI r2,0
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
MOVI r2,#K_WSTRING
CMP r1,r2
JMP[EQ] @pp_wstring
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pp_ident
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[EQ] @pp_punct
MOVI r1,5
CALL @p_err
pp_lit:
LD r1,r0,#W_TKA+5
MOVI r2,1
BOOL.8 r3,r1,r2
CMP r3,r0
JMP[EQ] @pp_lit_int
; long long literal: low word then high word
LD r2,r0,#W_TKA+1
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_PUSH
LD r2,r0,#W_TKA+6
CALL @ir_emit
LD r1,r0,#W_TKA+5
MOVI r2,2
BOOL.8 r1,r1,r2
CMP r1,r0
JMP[NE] @pp_lit_ull
MOVI r1,#T_LONGLONG
JMP @pp_lit_set
pp_lit_ull:
MOVI r1,#T_ULONGLONG
pp_lit_set:
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_lit_int:
LD r2,r0,#W_TKA+1
LA r1,#I_PUSH
CALL @ir_emit
LD r1,r0,#W_TKA+5
MOVI r2,2
BOOL.8 r1,r1,r2
CMP r1,r0
JMP[NE] @pp_lit_uint
MOVI r1,#T_INT
JMP @pp_lit_tset
pp_lit_uint:
MOVI r1,#T_UINT
pp_lit_tset:
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
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
pstr_cat:
LD r1,r0,#W_TKA
MOVI r2,#K_STRING
CMP r1,r2
JMP[NE] @pstr_done
; adjacent string literals concatenate: drop the previous NUL and append
LD r1,r0,#W_STRP
SUB r1,r1,r13
ST r1,r0,#W_STRP
CALL @str_add_cur
CALL @p_adv
JMP @pstr_cat
pstr_done:
SUB r14,r14,r13
LD r1,r14,0
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_CHAR
CALL @ty_ptr
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done
pp_wstring:
CALL @str_add_cur_wide
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_INT
CALL @ty_ptr
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_ident:
LA r2,@ncc_s_va_start
CALL @tok_is_str
CMP r1,r0
JMP[NE] @pp_va_start
LA r2,@ncc_s_va_arg
CALL @tok_is_str
CMP r1,r0
JMP[NE] @pp_va_arg
LA r2,@ncc_s_va_end
CALL @tok_is_str
CMP r1,r0
JMP[NE] @pp_va_end
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
; function designator used as a value -> symbol index
MOVI r1,#SK_FUNC
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @pp_var_bad
ST r1,r0,#W_FPSYM
CALL @sym_entry
LD r1,r1,#SY_TYPE
LD r2,r1,#SY_NP
CALL @ty_func
CALL @ty_ptr
ST r1,r0,#W_ETYPE
LD r2,r0,#W_FPSYM
LA r1,#I_PUSH
CALL @ir_emit
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_var_bad:
; builtin function used as a value (callback)
MOVI r1,#SK_BUILTIN
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @pp_var_err
ST r1,r0,#W_FPSYM
CALL @sym_entry
LD r1,r1,#SY_TYPE
MOVI r2,0
CALL @ty_func
CALL @ty_ptr
ST r1,r0,#W_ETYPE
LD r2,r0,#W_FPSYM
LA r1,#I_PUSH
CALL @ir_emit
ST r0,r0,#W_LVAL
CALL @p_adv
JMP @pp_done
pp_var_err:
MOVI r1,6
CALL @p_err
pp_var_ok:
CALL @sym_entry
LD r2,r1,#SY_USED
LA r3,0x80000000
BOOL.8 r2,r2,r3
ST r2,r0,#W_LCONST
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
LD r1,r0,#W_TKA+2
LA r2,0xBF979A06
CMP r1,r2
JMP[EQ] @pp_setjmp
LA r2,0xC8F2ABD6
CMP r1,r2
JMP[EQ] @pp_longjmp
MOVI r1,#SK_FUNC
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @pp_call_normal
MOVI r1,#SK_BUILTIN
CALL @sym_find_cur
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[NE] @pp_call_normal
CALL @sym_lookup_var
MOVI r2,0xFFFF
SHL r2,r2,16
ADDI r2,r2,-1
CMP r1,r2
JMP[EQ] @pp_call_bad
ST r1,r0,#W_FPSYM
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_FPTR_TYPE
CALL @ty_is_funcptr
CMP r1,r0
JMP[EQ] @pp_call_bad
ST r0,r0,#W_CALLSYM
LD r1,r0,#W_FPTR_TYPE
CALL @ty_base
ST r1,r0,#W_CALLFTYPE
MOVI r1,1
ST r1,r14,0
ADD r14,r14,r13
JMP @pp_call_args
pp_call_normal:
ST r1,r0,#W_CALLSYM
ST r0,r0,#W_CALLFTYPE
ST r1,r14,0
ADD r14,r14,r13
ST r0,r14,0
ADD r14,r14,r13
JMP @pp_call_args
pp_call_bad:
MOVI r1,8
CALL @p_err
pp_call_args:
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
ST r0,r0,#W_ARGIDX
ST r0,r14,0
ADD r14,r14,r13
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pp_args_done
pp_args_l:
CALL @p_assign
CALL @p_emit_rv
CALL @px_arg_cast
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_LL
MOVI r3,1
CMP r1,r2
JMP[NE] @pp_w1
MOVI r3,2
pp_w1:
ADDI r1,r14,-1
LD r2,r1,0
ADD r2,r2,r3
ST r2,r1,0
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pp_args_l
pp_args_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
ADDI r3,r14,-2
LD r1,r3,0
CMP r1,r0
JMP[NE] @pp_callv_emit
ADDI r3,r14,-1
LD r2,r3,0
SHL r2,r2,16
ADDI r3,r3,-1
ADDI r3,r3,-1
LD r3,r3,0
BOOL.14 r2,r2,r3
LA r1,#I_CALL
CALL @ir_emit
ADDI r3,r14,-3
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_ETYPE
ADDI r14,r14,-3
CALL @p_set_call_result
JMP @pp_done
pp_callv_emit:
ADDI r3,r14,-1
LD r2,r3,0
ST r2,r0,#W_FPNP
ADDI r14,r14,-2
LD r1,r0,#W_FPSYM
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_CLS
LD r4,r1,#SY_KIND
MOVI r5,#SK_GLOBAL
CMP r4,r5
JMP[EQ] @ppcv_g
MOVI r5,1
CMP r3,r5
JMP[EQ] @ppcv_g
ADD r1,r2,r0
CALL @px_addr_l
JMP @ppcv_ld
ppcv_g:
ADD r1,r2,r0
CALL @px_addr_g
ppcv_ld:
LA r1,#I_LOAD
MOVI r2,#SZ_32
CALL @ir_emit
LA r1,#I_CALLI
LD r2,r0,#W_FPNP
CALL @ir_emit
LD r1,r0,#W_FPTR_TYPE
CALL @ty_funcptr_ret
ST r1,r0,#W_ETYPE
CALL @p_set_call_result
JMP @pp_done
pp_setjmp:
MOVI r1,#SK_BUILTIN
CALL @sym_find_cur
ST r1,r0,#W_CALLSYM
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_assign
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pp_sj_ok
MOVI r1,6
CALL @p_err
pp_sj_ok:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r2,r0,#W_CALLSYM
MOVI r3,1
SHL r3,r3,16
BOOL.14 r2,r2,r3
LA r1,#I_CALL
CALL @ir_emit
LD r1,r0,#W_CALLSYM
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done

pp_longjmp:
MOVI r1,#SK_BUILTIN
CALL @sym_find_cur
ST r1,r0,#W_CALLSYM
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_assign
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pp_lj_ok
MOVI r1,6
CALL @p_err
pp_lj_ok:
MOVI r1,#P_COMMA
MOVI r2,24
CALL @p_expect_p
CALL @p_assign
CALL @p_emit_rv
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r2,r0,#W_CALLSYM
MOVI r3,2
SHL r3,r3,16
BOOL.14 r2,r2,r3
LA r1,#I_CALL
CALL @ir_emit
MOVI r1,#T_VOID
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done

pp_va_start:
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_assign
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pvs_ok
MOVI r1,6
CALL @p_err
pvs_ok:
LA r1,#I_LADDR
MOVI r2,16
CALL @ir_emit
LA r1,#I_STORE
MOVI r2,#SZ_32
CALL @ir_emit
MOVI r1,#P_COMMA
MOVI r2,24
CALL @p_expect_p
CALL @p_assign
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done

pp_va_arg:
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_assign
MOVI r1,#P_COMMA
MOVI r2,24
CALL @p_expect_p
CALL @p_typespec
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_LL
MOVI r3,4
CMP r1,r2
JMP[NE] @pva_emit
MOVI r3,8
pva_emit:
ADD r2,r3,r0
LA r1,#I_VAARG
CALL @ir_emit
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pva_agg
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pva_agg
LD r1,r0,#W_TY_ID
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done
pva_agg:
LD r1,r0,#W_TY_ID
ST r1,r0,#W_ETYPE
ST r1,r0,#W_LTYPE
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pp_done

pp_va_end:
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_assign
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done

pp_punct:
LD r1,r0,#W_TKA+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pp_paren
MOVI r1,7
CALL @p_err
; p_cplx_push/pop: nest compound-literal state across nested initializers.
p_cplx_push:
LD r1,r0,#W_CPLX_N
MOVI r2,3
MUL r2,r1,r2
LA r3,#ISO_SAVE+200
ADD r3,r3,r2
LD r2,r0,#W_CPLX_TYPE
ST r2,r3,0
LD r2,r0,#W_CPLX_BASE
ST r2,r3,1
LD r2,r0,#W_CPLX_LOCAL
ST r2,r3,2
ADD r1,r1,r13
ST r1,r0,#W_CPLX_N
RET
p_cplx_pop:
LD r1,r0,#W_CPLX_N
SUB r1,r1,r13
ST r1,r0,#W_CPLX_N
MOVI r2,3
MUL r2,r1,r2
LA r3,#ISO_SAVE+200
ADD r3,r3,r2
LD r2,r3,0
ST r2,r0,#W_CPLX_TYPE
LD r2,r3,1
ST r2,r0,#W_CPLX_BASE
LD r2,r3,2
ST r2,r0,#W_CPLX_LOCAL
RET

pp_paren:
CALL @p_peek
LA r1,#W_TKB
CALL @p_tok_is_type
CMP r1,r0
JMP[EQ] @pp_paren_expr
CALL @p_adv
CALL @p_typespec
CALL @p_ptr_suffix
CALL @p_array_suffix
ST r1,r0,#W_CASTTYPE
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
; compound literal: (type){...}
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pp_compound
CALL @p_unary
CALL @p_emit_rv
LD r1,r0,#W_CASTTYPE
CALL @px_cast_stack
LD r1,r0,#W_CASTTYPE
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pp_done
pp_compound:
LD r1,r0,#W_CASTTYPE
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @ppc_sized
LD r1,r0,#W_CASTTYPE
CALL @ty_count
CMP r1,r0
JMP[NE] @ppc_sized
CALL @p_comp_count
ST r1,r0,#W_ISO_TMP
LD r1,r0,#W_CASTTYPE
CALL @ty_base
LD r2,r0,#W_ISO_TMP
CALL @ty_array
ST r1,r0,#W_CASTTYPE
ppc_sized:
LD r1,r0,#W_CASTTYPE
CALL @ty_size
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_CASTTYPE
CALL @ty_align
ST r1,r0,#W_TY_COUNT
LD r1,r0,#W_FUNCSYM
CMP r1,r0
JMP[EQ] @ppc_global
LD r1,r0,#W_LOCALB
LD r2,r0,#W_TY_COUNT
CALL @px_align_up
ST r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_TMP
ADD r2,r1,r2
ST r2,r0,#W_LOCALB
LD r1,r0,#W_CASTTYPE
ST r1,r0,#W_CPLX_TYPE
LD r1,r0,#W_TY_BASE
ST r1,r0,#W_CPLX_BASE
MOVI r1,1
ST r1,r0,#W_CPLX_LOCAL
CALL @p_cplx_push
JMP @ppc_init
ppc_global:
LD r1,r0,#W_GLOBP
LD r2,r0,#W_TY_COUNT
CALL @px_align_up
ST r1,r0,#W_TY_BASE
LD r2,r0,#W_TY_TMP
ADD r2,r1,r2
LA r3,#C_GLOBEND
CMP r2,r3
JMP[LT] @ppc_groom
MOVI r1,71
CALL @p_err
ppc_groom:
ST r2,r0,#W_GLOBP
LD r1,r0,#W_CASTTYPE
ST r1,r0,#W_CPLX_TYPE
LD r1,r0,#W_TY_BASE
ST r1,r0,#W_CPLX_BASE
ST r0,r0,#W_CPLX_LOCAL
CALL @p_cplx_push
ppc_init:
LD r1,r0,#R_SP
ST r1,r0,#W_GEN_TMP
LD r1,r0,#W_CPLX_LOCAL
CMP r1,r0
JMP[NE] @ppc_pa_l
LD r1,r0,#W_CPLX_BASE
CALL @px_addr_g
JMP @ppc_pa_d
ppc_pa_l:
LD r1,r0,#W_CPLX_BASE
CALL @px_addr_l
ppc_pa_d:
LD r1,r0,#W_CPLX_TYPE
CALL @p_init_braced
LD r1,r0,#W_GEN_TMP
ST r1,r0,#R_SP
CALL @p_cplx_pop
; re-push the object address as the lvalue result
LD r1,r0,#W_CPLX_LOCAL
CMP r1,r0
JMP[NE] @ppc_rl
LD r1,r0,#W_CPLX_BASE
CALL @px_addr_g
JMP @ppc_rd
ppc_rl:
LD r1,r0,#W_CPLX_BASE
CALL @px_addr_l
ppc_rd:
LD r1,r0,#W_CPLX_TYPE
ST r1,r0,#W_CASTTYPE
ST r1,r0,#W_ETYPE
ST r1,r0,#W_LTYPE
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pp_done
; p_lex_save / p_lex_restore: snapshot the one-token lookahead and the byte
; cursor so a lookahead count can run without consuming parser input.
p_lex_save:
ST r15,r14,0
ADD r14,r14,r13
LA r2,#ISO_SAVE
LD r1,r0,#L_WP
ST r1,r2,0
LD r1,r0,#L_BI
ST r1,r2,1
LD r1,r0,#L_LINE
ST r1,r2,2
LD r1,r0,#L_TOKP
ST r1,r2,3
LD r1,r0,#W_HAVE
ST r1,r2,4
MOVI r3,5
ADD r2,r2,r3
LA r1,#ISO_SAVE+5
LA r2,#W_TKA
MOVI r3,#TKSZ
CALL @tok_copy
LA r1,#ISO_SAVE+77
LA r2,#W_TKB
MOVI r3,#TKSZ
CALL @tok_copy
SUB r14,r14,r13
LD r15,r14,0
RET

p_lex_restore:
ST r15,r14,0
ADD r14,r14,r13
LA r2,#ISO_SAVE
LD r1,r2,0
ST r1,r0,#L_WP
LD r1,r2,1
ST r1,r0,#L_BI
LD r1,r2,2
ST r1,r0,#L_LINE
LD r1,r2,3
ST r1,r0,#L_TOKP
LD r1,r2,4
ST r1,r0,#W_HAVE
MOVI r3,5
ADD r2,r2,r3
LA r1,#W_TKA
LA r2,#ISO_SAVE+5
MOVI r3,#TKSZ
CALL @tok_copy
LA r1,#W_TKB
LA r2,#ISO_SAVE+77
MOVI r3,#TKSZ
CALL @tok_copy
SUB r14,r14,r13
LD r15,r14,0
RET

; p_comp_count: current token is '{'; return the number of top-level
; elements without consuming input. Nested braces count as one element.
p_comp_count:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_lex_save
MOVI r1,1
ST r1,r0,#W_SCAN_DEPTH
ST r0,r0,#W_GEN_TMP
MOVI r1,1
ST r1,r0,#W_ISO_TMP
CALL @p_adv
pcc_l:
LD r1,r0,#W_TKA
MOVI r2,#K_EOF
CMP r1,r2
JMP[EQ] @pcc_d
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pcc_plain
LD r1,r0,#W_TKA+1
MOVI r2,#P_LBRACE
CMP r1,r2
JMP[EQ] @pcc_open
MOVI r2,#P_RBRACE
CMP r1,r2
JMP[EQ] @pcc_close
LD r2,r0,#W_SCAN_DEPTH
MOVI r3,1
CMP r2,r3
JMP[NE] @pcc_plain
MOVI r2,#P_COMMA
CMP r1,r2
JMP[NE] @pcc_plain
MOVI r1,1
ST r1,r0,#W_ISO_TMP
JMP @pcc_adv
pcc_open:
LD r2,r0,#W_SCAN_DEPTH
MOVI r3,1
CMP r2,r3
JMP[NE] @pcc_open_n
LD r2,r0,#W_ISO_TMP
CMP r2,r0
JMP[EQ] @pcc_open_n
LD r2,r0,#W_GEN_TMP
ADD r2,r2,r13
ST r2,r0,#W_GEN_TMP
ST r0,r0,#W_ISO_TMP
pcc_open_n:
LD r2,r0,#W_SCAN_DEPTH
ADD r2,r2,r13
ST r2,r0,#W_SCAN_DEPTH
JMP @pcc_adv
pcc_close:
LD r2,r0,#W_SCAN_DEPTH
SUB r2,r2,r13
ST r2,r0,#W_SCAN_DEPTH
CMP r2,r0
JMP[EQ] @pcc_d
JMP @pcc_adv
pcc_plain:
LD r2,r0,#W_SCAN_DEPTH
MOVI r3,1
CMP r2,r3
JMP[NE] @pcc_adv
LD r2,r0,#W_ISO_TMP
CMP r2,r0
JMP[EQ] @pcc_adv
LD r2,r0,#W_GEN_TMP
ADD r2,r2,r13
ST r2,r0,#W_GEN_TMP
ST r0,r0,#W_ISO_TMP
pcc_adv:
CALL @p_adv
JMP @pcc_l
pcc_d:
CALL @p_lex_restore
LD r1,r0,#W_GEN_TMP
SUB r14,r14,r13
LD r15,r14,0
RET

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
; save the base type across the index expression: a nested subscript
; (e.g. lp[j][ls[j]-1]) would otherwise clobber W_IDXTYPE
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
CALL @p_expr
CALL @p_emit_rv
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_IDXTYPE
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
LD r1,r0,#W_MEMBIT
ST r1,r0,#W_LBIT
LD r1,r0,#W_MEMBIT
ST r1,r0,#W_LBIT
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
LD r1,r0,#W_MEMBIT
ST r1,r0,#W_LBIT
LD r1,r0,#W_TY_ID
ST r1,r0,#W_LTYPE
ST r1,r0,#W_ETYPE
MOVI r1,1
ST r1,r0,#W_LVAL
JMP @pxf_loop
pxf_inc:
MOVI r1,#P_LPAREN
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pxf_inc_orig
; call through a function-pointer expression
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
CALL @ty_is_funcptr
CMP r1,r0
JMP[EQ] @pxf_badcall
LD r1,r0,#W_ETYPE
CALL @ty_funcptr_ret
ST r1,r0,#W_FPRET
LD r1,r0,#W_ETYPE
CALL @ty_base
ST r1,r0,#W_CALLFTYPE
ST r0,r0,#W_CALLSYM
CALL @p_adv
ST r0,r0,#W_ARGIDX
ST r0,r14,0
ADD r14,r14,r13
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pxf_call_done
pxf_call_args:
CALL @p_assign
CALL @p_emit_rv
CALL @px_arg_cast
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_LL
MOVI r3,1
CMP r1,r2
JMP[NE] @pxf_w1
MOVI r3,2
pxf_w1:
ADDI r1,r14,-1
LD r2,r1,0
ADD r2,r2,r3
ST r2,r1,0
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pxf_call_args
pxf_call_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
ADDI r3,r14,-1
LD r2,r3,0
LA r1,#I_CALLB
CALL @ir_emit
ADDI r14,r14,-1
LD r1,r0,#W_FPRET
ST r1,r0,#W_ETYPE
CALL @p_set_call_result
JMP @pxf_loop
pxf_badcall:
MOVI r1,8
CALL @p_err
pxf_inc_orig:
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
ST r1,r0,#W_INCSTEP
ADD r2,r1,r0
LA r1,#I_DUP
CALL @ir_op
LD r1,r0,#W_TY_ID
CALL @px_emit_load
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[EQ] @pxf_ll
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
LD r2,r0,#W_INCSTEP
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
pxf_ll:
LA r1,#I_PUSH
LD r2,r0,#W_TY_COUNT
CALL @ir_emit
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LD r1,r0,#W_TY_RET
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pxf_ll_add
MOVI r2,#BIN_SUB
JMP @pxf_ll_op
pxf_ll_add:
MOVI r2,#BIN_ADD
pxf_ll_op:
LA r1,#I_LLOP
CALL @ir_emit
LD r1,r0,#W_TY_ID
MOVI r2,1
CALL @px_emit_store
LA r1,#I_PUSH
LD r2,r0,#W_INCSTEP
CALL @ir_emit
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LD r1,r0,#W_TY_RET
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pxf_ll_old
MOVI r2,#BIN_ADD
JMP @pxf_ll_oldop
pxf_ll_old:
MOVI r2,#BIN_SUB
pxf_ll_oldop:
LA r1,#I_LLOP
CALL @ir_emit
JMP @pxf_old_done
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
MOVI r2,#KW_ALIGNOF
CMP r1,r2
JMP[EQ] @pu_alignof
MOVI r2,#KW_GENERIC
CMP r1,r2
JMP[EQ] @pu_generic
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
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[NE] @pu_minus_i
LA r1,#I_LLNEG
MOVI r2,0
CALL @ir_emit
JMP @pu_done
pu_minus_i:
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
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[NE] @pu_lnot_i
LA r1,#I_LLBOOL
MOVI r2,0
CALL @ir_emit
pu_lnot_i:
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
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[NE] @pu_not_i
LA r1,#I_PUSH
LA r2,0xFFFFFFFF
CALL @ir_emit
LA r1,#I_PUSH
LA r2,0xFFFFFFFF
CALL @ir_emit
LA r1,#I_LLOP
MOVI r2,#BIN_XOR
CALL @ir_emit
JMP @pu_done
pu_not_i:
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
; &func: the function designator is already a pointer value
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[NE] @pu_addr_err
LD r1,r0,#W_ETYPE
CALL @ty_base
CALL @ty_kind
MOVI r2,#TY_FUNC
CMP r1,r2
JMP[EQ] @pu_addr_func
pu_addr_err:
MOVI r1,34
CALL @p_err
pu_addr_func:
ST r0,r0,#W_LVAL
JMP @pu_done
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
CALL @ty_is_funcptr
CMP r1,r0
JMP[NE] @pu_done
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
CALL @px_discard
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
CALL @px_discard
pu_sz_push:
LD r2,r0,#W_TY_ID
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_UINT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pu_done

; _Alignof(type-name): C11 alignment query. Returns size_t-compatible uint.
pu_alignof:
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_is_type
CMP r1,r0
JMP[NE] @pua_type
CALL @p_peek
LA r1,#W_TKB
CALL @p_tok_is_type
CMP r1,r0
JMP[EQ] @pua_bad
pua_type:
CALL @p_typespec
CALL @p_ptr_suffix
CALL @ty_align
ST r1,r0,#W_TY_ID
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r2,r0,#W_TY_ID
LA r1,#I_PUSH
CALL @ir_emit
MOVI r1,#T_UINT
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pu_done
pua_bad:
MOVI r1,79
CALL @p_err

; _Generic(controlling, type: expr, ..., default: expr)
; The controlling expression is parsed for its type but its IR is discarded,
; so it is not evaluated. Only the selected association is compiled.
pu_generic:
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
LD r1,r0,#W_IRPC
ST r1,r0,#W_GEN_TMP
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_ETYPE
ST r1,r0,#W_GEN_TYPE
LD r1,r0,#W_GEN_TMP
ST r1,r0,#W_IRPC
ST r0,r0,#W_LVAL
MOVI r1,#P_COMMA
MOVI r2,24
CALL @p_expect_p
ST r0,r0,#W_GEN_DONE
pug_l:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pug_assoc
LD r1,r0,#W_TKA+1
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[EQ] @pug_close
pug_assoc:
MOVI r1,#KW_DEFAULT
CALL @p_at_k
CMP r1,r0
JMP[NE] @pug_default
CALL @p_typespec
CALL @p_ptr_suffix
ST r1,r0,#W_ISO_TMP
MOVI r1,#P_COLON
MOVI r2,12
CALL @p_expect_p
LD r1,r0,#W_GEN_DONE
CMP r1,r0
JMP[NE] @pug_skip
LD r1,r0,#W_ISO_TMP
LD r2,r0,#W_GEN_TYPE
CMP r1,r2
JMP[NE] @pug_skip
CALL @p_assign
MOVI r1,1
ST r1,r0,#W_GEN_DONE
JMP @pug_after
pug_default:
CALL @p_adv
MOVI r1,#P_COLON
MOVI r2,12
CALL @p_expect_p
LD r1,r0,#W_GEN_DONE
CMP r1,r0
JMP[NE] @pug_skip
CALL @p_assign
MOVI r1,1
ST r1,r0,#W_GEN_DONE
JMP @pug_after
pug_skip:
CALL @p_skip_generic
pug_after:
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pug_syn
LD r1,r0,#W_TKA+1
MOVI r2,#P_COMMA
CMP r1,r2
JMP[NE] @pug_end_assoc
CALL @p_adv
JMP @pug_l
pug_end_assoc:
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[EQ] @pug_close
pug_syn:
MOVI r1,81
CALL @p_err
pug_close:
CALL @p_adv
LD r1,r0,#W_GEN_DONE
CMP r1,r0
JMP[NE] @pug_ok
MOVI r1,82
CALL @p_err
pug_ok:
JMP @pu_done

; p_skip_generic: skip a balanced token sequence, stopping BEFORE a top-level
; ',' or ')' (used for unselected _Generic associations).
p_skip_generic:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_SCAN_DEPTH
psg_l:
LD r1,r0,#W_TKA
MOVI r2,#K_EOF
CMP r1,r2
JMP[EQ] @psg_d
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @psg_adv
LD r1,r0,#W_TKA+1
LD r2,r0,#W_SCAN_DEPTH
CMP r2,r0
JMP[NE] @psg_nest
MOVI r2,#P_COMMA
CMP r1,r2
JMP[EQ] @psg_d
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[EQ] @psg_d
psg_nest:
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @psg_up
MOVI r2,#P_LBRACK
CMP r1,r2
JMP[EQ] @psg_up
MOVI r2,#P_LBRACE
CMP r1,r2
JMP[EQ] @psg_up
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[EQ] @psg_dn
MOVI r2,#P_RBRACK
CMP r1,r2
JMP[EQ] @psg_dn
MOVI r2,#P_RBRACE
CMP r1,r2
JMP[EQ] @psg_dn
JMP @psg_adv
psg_up:
LD r2,r0,#W_SCAN_DEPTH
ADD r2,r2,r13
ST r2,r0,#W_SCAN_DEPTH
JMP @psg_adv
psg_dn:
LD r2,r0,#W_SCAN_DEPTH
SUB r2,r2,r13
ST r2,r0,#W_SCAN_DEPTH
psg_adv:
CALL @p_adv
JMP @psg_l
psg_d:
SUB r14,r14,r13
LD r15,r14,0
RET

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
LD r1,r0,#W_TKA+1
ST r1,r0,#W_TY_RET
CALL @p_adv
CALL @p_unary
LD r1,r0,#W_LVAL
CMP r1,r0
JMP[NE] @pu_inc_ok
MOVI r1,11
CALL @p_err
pu_inc_ok:
LD r1,r0,#W_LTYPE
ST r1,r0,#W_TY_ID
CALL @px_inc_step
ST r1,r0,#W_TY_COUNT
ADD r2,r1,r0
LA r1,#I_DUP
CALL @ir_op
LD r1,r0,#W_TY_ID
CALL @px_emit_load
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[EQ] @pu_inc_ll
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
; NB: the prefix operator token was already consumed at entry; do not
; advance again or the following token (often ';') is swallowed.
JMP @pu_done
pu_inc_ll:
LA r1,#I_PUSH
LD r2,r0,#W_TY_COUNT
CALL @ir_emit
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LD r1,r0,#W_TY_RET
MOVI r2,#P_INC
CMP r1,r2
JMP[EQ] @pu_ll_add
MOVI r2,#BIN_SUB
JMP @pu_ll_op
pu_ll_add:
MOVI r2,#BIN_ADD
pu_ll_op:
LA r1,#I_LLOP
CALL @ir_emit
LD r1,r0,#W_TY_ID
MOVI r2,1
CALL @px_emit_store
LD r1,r0,#W_TY_ID
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
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
MOVI r2,#TY_LL
LD r1,r0,#W_TY_KIND
CMP r1,r2
JMP[EQ] @pb_ll
LD r1,r0,#W_TY_COUNT
CMP r1,r2
JMP[EQ] @pb_ll
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
; convert long long operands to float first (pair is two words)
MOVI r2,#TY_LL
LD r1,r0,#W_TY_KIND
CMP r1,r2
JMP[NE] @pbf_lnotll
LA r1,#I_LLI2F
MOVI r2,1
CALL @ir_emit
MOVI r1,#T_FLOAT
ADDI r3,r14,-2
ST r1,r3,0
JMP @pbf_both
pbf_lnotll:
MOVI r2,#TY_LL
LD r1,r0,#W_TY_COUNT
CMP r1,r2
JMP[NE] @pbf_both
LA r1,#I_LLI2F
MOVI r2,0
CALL @ir_emit
MOVI r1,#T_FLOAT
ADDI r3,r14,-1
ST r1,r3,0
pbf_both:
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
JMP @pb_done
pb_ll:
; widen the right operand if needed (depth 0)
LD r1,r0,#W_TY_COUNT
MOVI r2,#TY_LL
CMP r1,r2
JMP[EQ] @pb_ll_left
ADDI r3,r14,-1
LD r1,r3,0
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pb_ll_ru
MOVI r2,0
JMP @pb_ll_rg
pb_ll_ru:
LA r2,0x10000
pb_ll_rg:
LA r1,#I_LLEXT
CALL @ir_emit
pb_ll_left:
; widen the left operand if needed (depth 2)
LD r1,r0,#W_TY_KIND
MOVI r2,#TY_LL
CMP r1,r2
JMP[EQ] @pb_ll_op
ADDI r3,r14,-2
LD r1,r3,0
CALL @ty_sign
CMP r1,r0
JMP[EQ] @pb_ll_lu
MOVI r2,2
JMP @pb_ll_lg
pb_ll_lu:
LA r2,0x10002
pb_ll_lg:
LA r1,#I_LLEXT
CALL @ir_emit
pb_ll_op:
ADDI r3,r14,-2
LD r1,r3,0
ADDI r3,r14,-1
LD r2,r3,0
CALL @ty_common
ST r1,r0,#W_TY_RET
CALL @ty_sign
ST r1,r0,#W_TY_SIGN
ADDI r3,r14,-3
LD r1,r3,0
LD r2,r0,#W_TY_SIGN
CMP r2,r0
JMP[NE] @pb_ll_go2
MOVI r3,0x100
BOOL.14 r1,r1,r3
pb_ll_go2:
ADD r2,r1,r0
LA r1,#I_LLOP
CALL @ir_emit
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,#BIN_LT
CMP r1,r2
JMP[LT] @pb_ll_val
MOVI r1,#T_INT
ST r1,r0,#W_ETYPE
JMP @pb_done
pb_ll_val:
LD r1,r0,#W_TY_RET
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
MOVI r1,#BIN_AND
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ETYPE
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
MOVI r1,#BIN_XOR
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ETYPE
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
MOVI r1,#BIN_OR
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ETYPE
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
LD r2,r0,#W_LCONST
CMP r2,r0
JMP[EQ] @pas_ok
MOVI r1,11
CALL @p_err
pas_ok:
LD r1,r0,#W_LTYPE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_TKA+1
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_LBIT
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
ADDI r3,r14,-2
LD r1,r3,0
MOVI r2,#P_ASSIGN
CMP r1,r2
JMP[EQ] @pas_simple
; compound: duplicate address, load old, RHS, binop, cast, store-keep
LA r1,#I_DUP
CALL @ir_op
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_LBIT
ADDI r3,r14,-3
LD r1,r3,0
CALL @px_emit_load
CALL @p_assign
CALL @p_emit_rv
ADDI r3,r14,-2
LD r1,r3,0
CALL @p_compop
ADDI r3,r14,-3
LD r2,r3,0
LD r3,r0,#W_ETYPE
CALL @p_binop
ADDI r3,r14,-3
LD r1,r3,0
CALL @px_cast_stack
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_LBIT
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,1
CALL @px_emit_store
ADDI r14,r14,-3
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
ADDI r3,r14,-3
LD r1,r3,0
CALL @px_cast_stack
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_LBIT
ADDI r3,r14,-3
LD r1,r3,0
MOVI r2,1
CALL @px_emit_store
ADDI r14,r14,-3
ADDI r3,r14,-1
LD r1,r3,0
ST r1,r0,#W_ETYPE
ST r0,r0,#W_LVAL
JMP @pas_d
pas_struct:
ADDI r14,r14,-3
ST r0,r0,#W_LBIT
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
CALL @px_discard
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
MOVI r2,#KW_STATIC_ASSERT
CMP r1,r2
JMP[EQ] @pst_sa
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
pst_sa:
CALL @p_static_assert
JMP @pst_d
pst_decl:
CALL @p_decl
JMP @pst_d
pst_expr:
CALL @p_expr
CALL @p_emit_rv
CALL @px_discard
MOVI r1,#P_SEMI
MOVI r2,22
CALL @p_expect_p
pst_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_const_add: r1=name hash; record as const
px_const_add:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_DECL_CONST
LD r2,r0,#W_CN_N
MOVI r3,0
pxca_l:
CMP r3,r2
JMP[GE] @pxca_add
LA r4,#NCTAB
ADD r4,r4,r3
LD r5,r4,0
LD r6,r0,#W_DECL_CONST
CMP r5,r6
JMP[EQ] @pxca_d
ADD r3,r3,r13
JMP @pxca_l
pxca_add:
MOVI r6,64
CMP r2,r6
JMP[GE] @pxca_d
LA r4,#NCTAB
ADD r4,r4,r2
LD r6,r0,#W_DECL_CONST
ST r6,r4,0
ADD r2,r2,r13
ST r2,r0,#W_CN_N
pxca_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_const_sym: r1=symbol index; apply pending const mark
px_const_sym:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_MARK_CONST
CMP r2,r0
JMP[EQ] @pxcs_d
ST r0,r0,#W_MARK_CONST
ST r1,r0,#W_CONSTSYM
CALL @sym_entry
LD r2,r1,#SY_USED
LA r3,0x80000000
BOOL.14 r2,r2,r3
ST r2,r1,#SY_USED
LD r1,r0,#W_CONSTSYM
pxcs_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_decl_mark: if declaration was const and not pointer, record current identifier
px_decl_mark:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_DECL_CONST
CMP r2,r0
JMP[EQ] @pxdm_d
LD r2,r0,#W_TY_ID
ST r2,r0,#W_DECL_HASH
LD r1,r0,#W_DECL_HASH
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[EQ] @pxdm_d
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pxdm_d
MOVI r1,1
ST r1,r0,#W_MARK_CONST
pxdm_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_const_check: r1=name hash -> W_LCONST
px_const_check:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_LCONST
ST r1,r0,#W_DECL_HASH
LD r2,r0,#W_CN_N
MOVI r3,0
pxcc_l:
CMP r3,r2
JMP[GE] @pxcc_d
LA r4,#NCTAB
ADD r4,r4,r3
LD r5,r4,0
LD r6,r0,#W_DECL_HASH
CMP r5,r6
JMP[NE] @pxcc_n
MOVI r5,1
ST r5,r0,#W_LCONST
JMP @pxcc_d
pxcc_n:
ADD r3,r3,r13
JMP @pxcc_l
pxcc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_flat_agg: r1=type -> 1 if struct/union with only scalar members
p_flat_agg:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_EL_MTYPE
CALL @ty_kind
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pfa_go
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pfa_go
MOVI r1,0
JMP @pfa_d
pfa_go:
LD r1,r0,#W_EL_MTYPE
CALL @ty_addr
LD r2,r1,#TY_MEM
ST r2,r0,#W_EL_MEM
LD r2,r1,#TY_NMEM
ST r2,r0,#W_EL_NMEM
MOVI r1,0
ST r1,r0,#W_EL_M
pfa_l:
LD r1,r0,#W_EL_M
LD r2,r0,#W_EL_NMEM
CMP r1,r2
JMP[GE] @pfa_yes
LD r2,r0,#W_EL_MEM
SHL r3,r1,2
ADD r2,r2,r3
LD r1,r2,2
ST r1,r0,#W_EL_MTYPE
CALL @ty_bitwidth
CMP r2,r0
JMP[NE] @pfa_no
LD r1,r0,#W_EL_MTYPE
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @pfa_no
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pfa_no
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pfa_no
LD r1,r0,#W_EL_M
ADD r1,r1,r13
ST r1,r0,#W_EL_M
JMP @pfa_l
pfa_yes:
MOVI r1,1
JMP @pfa_d
pfa_no:
MOVI r1,0
pfa_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_elide_elems: r1=elem type r2=count r3=base offset r4=global
p_elide_elems:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_EL_ELEM
ST r2,r0,#W_EL_COUNT
ST r3,r0,#W_EL_BASE
ST r4,r0,#W_EL_GLB
MOVI r1,1
ST r1,r0,#W_EL_FIRST
LD r1,r0,#W_EL_ELEM
CALL @ty_size
ST r1,r0,#W_EL_ESIZE
LD r1,r0,#W_EL_ELEM
CALL @ty_addr
LD r2,r1,#TY_MEM
ST r2,r0,#W_EL_MEM
LD r2,r1,#TY_NMEM
ST r2,r0,#W_EL_NMEM
ST r0,r0,#W_EL_I
el_i:
LD r1,r0,#W_EL_I
LD r2,r0,#W_EL_COUNT
CMP r1,r2
JMP[GE] @el_done
ST r0,r0,#W_EL_M
el_m:
LD r1,r0,#W_EL_M
LD r2,r0,#W_EL_NMEM
CMP r1,r2
JMP[GE] @el_next_i
LD r2,r0,#W_EL_MEM
LD r1,r0,#W_EL_M
SHL r1,r1,2
ADD r2,r2,r1
LD r3,r2,1
LD r4,r2,2
ST r4,r0,#W_EL_MTYPE
LD r5,r0,#W_EL_I
LD r6,r0,#W_EL_ESIZE
MUL r5,r5,r6
ADD r5,r5,r3
LD r6,r0,#W_EL_BASE
ADD r5,r5,r6
ST r5,r0,#W_EL_OFF
LD r1,r0,#W_EL_FIRST
CMP r1,r0
JMP[NE] @el_nocomma
MOVI r1,#P_COMMA
MOVI r2,24
CALL @p_expect_p
el_nocomma:
LD r1,r0,#W_EL_GLB
LD r2,r0,#W_EL_OFF
LD r3,r0,#W_EL_MTYPE
CALL @p_decl_store_addr
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_EL_MTYPE
CALL @px_cast_stack
LD r2,r0,#W_EL_MEM
LD r1,r0,#W_EL_M
SHL r1,r1,2
ADD r2,r2,r1
LD r2,r2,3
ST r2,r0,#W_LBIT
LD r1,r0,#W_EL_MTYPE
MOVI r2,0
CALL @px_emit_store
ST r0,r0,#W_EL_FIRST
LD r1,r0,#W_EL_ELEM
CALL @ty_kind
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @el_next_i
LD r1,r0,#W_EL_M
ADD r1,r1,r13
ST r1,r0,#W_EL_M
JMP @el_m
el_next_i:
LD r1,r0,#W_EL_I
ADD r1,r1,r13
ST r1,r0,#W_EL_I
JMP @el_i
el_done:
MOVI r1,#P_COMMA
CALL @p_take_p
SUB r14,r14,r13
LD r15,r14,0
RET

; p_arr_pre: r1=array type; give an unsized array a provisional capacity
p_arr_pre:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_EL_ELEM
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pap_d
LD r1,r0,#W_EL_ELEM
CALL @ty_count
CMP r1,r0
JMP[NE] @pap_d
LD r1,r0,#W_EL_ELEM
CALL @ty_base
ST r1,r0,#W_EL_OFF
CALL @ty_size
ST r1,r0,#W_EL_ESIZE
MOVI r2,256
MUL r1,r1,r2
ST r1,r0,#W_EL_COUNT
LD r1,r0,#W_EL_ELEM
CALL @ty_addr
MOVI r2,256
ST r2,r1,#TY_COUNT
LD r2,r0,#W_EL_COUNT
ST r2,r1,#TY_SIZE
pap_d:
LD r1,r0,#W_EL_ELEM
SUB r14,r14,r13
LD r15,r14,0
RET

; p_arr_fix: r1=symbol index r2=actual element count; shrink an inferred array
p_arr_fix:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_EL_BASE
ST r2,r0,#W_EL_COUNT
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_EL_ELEM
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @paf_d
LD r1,r0,#W_EL_ELEM
CALL @ty_base
CALL @ty_size
ST r1,r0,#W_EL_ESIZE
LD r1,r0,#W_EL_ELEM
CALL @ty_addr
ST r1,r0,#W_EL_MEM
LD r2,r0,#W_EL_COUNT
ST r2,r1,#TY_COUNT
LD r1,r0,#W_EL_ESIZE
MUL r1,r1,r2
ST r1,r0,#W_EL_OFF
LD r2,r0,#W_EL_MEM
ST r1,r2,#TY_SIZE
LD r2,r0,#W_EL_BASE
CALL @sym_entry
LD r2,r0,#W_EL_OFF
ST r2,r1,#SY_SIZE
paf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_decl: local declarations (one or more declarators)
; px_align_up: r1=value r2=align(1|2|4) -> r1 aligned up
px_align_up:
MOVI r3,1
CMP r2,r3
JMP[EQ] @pxa_d
ADD r3,r1,r2
ADDI r3,r3,-1
DIVU r4,r3,r2
MUL r1,r4,r2
RET
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
; p_struct_init: r1=global flag, r2=base address/offset, r3=type id.
; Current token is '{'. Initialises members in declaration order; unions
; initialise the first member only.
; p_str_init: r1=global flag, r2=base address/offset, r3=char array type,
; current token is a string literal. Zero-fill then copy string bytes.
p_str_init:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_SIGLB
ST r2,r0,#W_SSIZE
ST r3,r0,#W_STRUCTID
LD r1,r0,#W_STRUCTID
CALL @ty_base
ST r1,r0,#W_STYPE
LD r1,r0,#W_STRUCTID
CALL @ty_size
ST r1,r0,#W_MSIZE
LD r1,r0,#W_SIGLB
LD r2,r0,#W_SSIZE
LD r3,r0,#W_MSIZE
CALL @p_zero_range
LD r1,r0,#W_SIGLB
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

p_wstr_init:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_SIGLB
ST r2,r0,#W_SSIZE
ST r3,r0,#W_STRUCTID
LD r1,r0,#W_STRUCTID
CALL @ty_base
ST r1,r0,#W_STYPE
LD r1,r0,#W_STRUCTID
CALL @ty_size
ST r1,r0,#W_MSIZE
LD r1,r0,#W_SIGLB
LD r2,r0,#W_SSIZE
LD r3,r0,#W_MSIZE
CALL @p_zero_range
LD r1,r0,#W_SIGLB
LD r2,r0,#W_SSIZE
LD r3,r0,#W_STYPE
CALL @p_decl_store_addr
LD r1,r0,#W_TKA+3
ADD r1,r1,r13
SHL r1,r1,2
ST r1,r0,#W_SOFF
CALL @str_add_cur_wide
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LD r3,r0,#W_SOFF
LD r4,r0,#W_MSIZE
CMP r3,r4
JMP[LE] @pwsti_n
ADD r3,r4,r0
pwsti_n:
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
ST r1,r0,#W_SIGLB
ST r2,r0,#W_SSIZE
ST r3,r0,#W_STRUCTID
; zero the whole object first
LD r1,r0,#W_SIGLB
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
MOVI r1,#P_DOT
CALL @p_at_p
CMP r1,r0
JMP[NE] @psi_desig
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @psi_normal
LD r1,r0,#W_STRUCTID
CALL @p_flat_agg
CMP r1,r0
JMP[EQ] @psi_normal
LD r1,r0,#W_STRUCTID
MOVI r2,1
LD r3,r0,#W_SSIZE
LD r4,r0,#W_SIGLB
CALL @p_elide_elems
JMP @psi_done
psi_normal:
LD r1,r0,#W_SALIGN
LD r2,r0,#W_SNMEM
CMP r1,r2
JMP[GE] @psi_done
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @psi_done
JMP @psi_load
psi_desig:
CALL @p_adv
LD r1,r0,#W_STRUCTID
CALL @p_member_lookup
LD r1,r0,#W_MEMIDX
ST r1,r0,#W_SALIGN
MOVI r1,#P_ASSIGN
MOVI r2,21
CALL @p_expect_p
psi_load:
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
LD r1,r0,#W_SIGLB
LD r3,r0,#W_STYPE
CALL @p_decl_store_addr
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @psi_mem_plain
LD r1,r0,#W_STYPE
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @psi_mem_nested
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @psi_mem_nested
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @psi_mem_nested
JMP @psi_mem_plain
psi_mem_nested:
LD r1,r0,#W_STYPE
CALL @p_init_braced
JMP @psi_mem_next
psi_mem_plain:
LD r1,r0,#W_STYPE
CALL @ty_bitwidth
CMP r2,r0
JMP[EQ] @psi_mem_norm
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_STYPE
CALL @px_cast_stack
LD r2,r0,#W_SMEM
LD r1,r0,#W_SALIGN
SHL r1,r1,2
ADD r2,r2,r1
LD r2,r2,3
ST r2,r0,#W_LBIT
LD r1,r0,#W_STYPE
MOVI r2,0
CALL @px_emit_store
JMP @psi_mem_next
psi_mem_norm:
LD r1,r0,#W_STYPE
CALL @p_init_value
psi_mem_next:
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


; ------------------------------------------------------------------ nested initializers

; p_tok_agg_match: r1=aggregate type -> 1 if the current identifier
; resolves to a variable or function of exactly that aggregate type.
p_tok_agg_match:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ELT_TYPE
ST r0,r0,#W_ELT_TMP
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pam_d
CALL @sym_lookup_var
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @pam_func
CALL @sym_entry
LD r1,r1,#SY_TYPE
LD r2,r0,#W_ELT_TYPE
CMP r1,r2
JMP[NE] @pam_d
MOVI r1,1
ST r1,r0,#W_ELT_TMP
JMP @pam_d
pam_func:
CALL @sym_lookup_func
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @pam_d
CALL @sym_entry
LD r1,r1,#SY_TYPE
LD r2,r0,#W_ELT_TYPE
CMP r1,r2
JMP[NE] @pam_d
MOVI r1,1
ST r1,r0,#W_ELT_TMP
pam_d:
LD r1,r0,#W_ELT_TMP
SUB r14,r14,r13
LD r15,r14,0
RET

; p_str_init_stack: r1=char array type; destination on the eval stack.
; Copies the current string literal into that destination.
p_str_init_stack:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ELT_TYPE
CALL @ty_size
ST r1,r0,#W_ELT_N
LA r1,#I_DUP
CALL @ir_op
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LA r1,#I_PUSH
LD r2,r0,#W_ELT_N
CALL @ir_emit
LA r1,#I_MEMSET
CALL @ir_op
LD r1,r0,#W_TKA+3
ST r1,r0,#W_ELT_OFF
CALL @str_add_cur
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LD r3,r0,#W_ELT_OFF
LD r4,r0,#W_ELT_N
CMP r3,r4
JMP[LE] @psis_n
ADD r3,r4,r0
psis_n:
LA r1,#I_PUSH
ADD r2,r3,r0
CALL @ir_emit
LA r1,#I_MEMCPY
CALL @ir_op
CALL @p_adv
SUB r14,r14,r13
LD r15,r14,0
RET

; p_elide_into: r1=aggregate type; destination address on the eval stack.
; Consumes the destination and parses comma-separated initializers for the
; object's scalar leaves, without consuming the comma that follows it.
p_elide_into:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ELT_TYPE
; a braced subobject may appear at any depth
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @elt_brace
LD r1,r0,#W_ELT_TYPE
CALL @ty_kind
ST r1,r0,#W_ELT_KIND
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @elt_arr
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @elt_str
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @elt_str
JMP @elt_scalar
elt_brace:
LD r1,r0,#W_ELT_TYPE
CALL @p_init_braced
JMP @elt_d
elt_scalar:
LD r1,r0,#W_ELT_TYPE
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_ELT_TYPE
CALL @px_cast_stack
LD r1,r0,#W_ELT_BIT
ST r1,r0,#W_LBIT
LD r1,r0,#W_ELT_TYPE
MOVI r2,0
CALL @px_emit_store
JMP @elt_d
elt_arr:
LD r1,r0,#W_ELT_TYPE
CALL @ty_base
ST r1,r0,#W_ELT_ELEM
CALL @ty_size
ST r1,r0,#W_ELT_ESZ
LD r1,r0,#W_ELT_TYPE
CALL @ty_count
ST r1,r0,#W_ELT_N
ST r0,r0,#W_ELT_I
elt_a_l:
LD r1,r0,#W_ELT_I
LD r2,r0,#W_ELT_N
CMP r1,r2
JMP[GE] @elt_pop
LD r1,r0,#W_ELT_I
CMP r1,r0
JMP[EQ] @elt_a_first
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[EQ] @elt_pop
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @elt_pop
elt_a_first:
ST r0,r0,#W_ELT_BIT
LA r1,#I_DUP
CALL @ir_op
LA r1,#I_PUSH
LD r2,r0,#W_ELT_I
LD r3,r0,#W_ELT_ESZ
MUL r2,r2,r3
CALL @ir_emit
LA r1,#I_ADD
CALL @ir_op
LD r1,r0,#W_ELT_TYPE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_ELEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_ESZ
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_N
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_I
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_ELEM
CALL @p_elide_into
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_I
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_N
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_ESZ
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_ELEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_TYPE
LD r1,r0,#W_ELT_I
ADD r1,r1,r13
ST r1,r0,#W_ELT_I
JMP @elt_a_l
elt_str:
LD r1,r0,#W_ELT_TYPE
CALL @ty_addr
LD r2,r1,#TY_MEM
ST r2,r0,#W_ELT_MEM
LD r2,r1,#TY_NMEM
ST r2,r0,#W_ELT_NMEM
ST r0,r0,#W_ELT_I
elt_s_l:
LD r1,r0,#W_ELT_I
LD r2,r0,#W_ELT_NMEM
CMP r1,r2
JMP[GE] @elt_pop
LD r1,r0,#W_ELT_I
CMP r1,r0
JMP[EQ] @elt_s_first
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[EQ] @elt_pop
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @elt_pop
elt_s_first:
LD r2,r0,#W_ELT_MEM
LD r1,r0,#W_ELT_I
SHL r1,r1,2
ADD r2,r2,r1
LD r3,r2,1
ST r3,r0,#W_ELT_OFF
LD r3,r2,2
ST r3,r0,#W_ELT_MT
LD r3,r2,3
ST r3,r0,#W_ELT_BIT
LA r1,#I_DUP
CALL @ir_op
LA r1,#I_PUSH
LD r2,r0,#W_ELT_OFF
CALL @ir_emit
LA r1,#I_ADD
CALL @ir_op
LD r1,r0,#W_ELT_TYPE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_MEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_NMEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_I
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_KIND
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ELT_MT
CALL @p_elide_into
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_KIND
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_I
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_NMEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_MEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ELT_TYPE
LD r1,r0,#W_ELT_KIND
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @elt_pop
LD r1,r0,#W_ELT_I
ADD r1,r1,r13
ST r1,r0,#W_ELT_I
JMP @elt_s_l
elt_pop:
LA r1,#I_POP
CALL @ir_op
elt_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_init_value: r1=type; destination address is on the eval stack.
; Parses a braced initializer or a scalar/aggregate expression, and consumes
; the destination address.
p_init_value:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ITYPE
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @piv_brace
LD r1,r0,#W_ITYPE
CALL @ty_kind
ST r1,r0,#W_ELT_KIND
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @piv_agg
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @piv_agg
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @piv_arr
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_ITYPE
CALL @px_cast_stack
LD r1,r0,#W_ITYPE
MOVI r2,0
CALL @px_emit_store
JMP @piv_d
piv_arr:
LD r1,r0,#W_TKA
MOVI r2,#K_STRING
CMP r1,r2
JMP[NE] @piv_arr_elide
LD r1,r0,#W_ITYPE
CALL @ty_base
CALL @ty_size
MOVI r2,1
CMP r1,r2
JMP[NE] @piv_arr_elide
LD r1,r0,#W_ITYPE
CALL @p_str_init_stack
JMP @piv_d
piv_arr_elide:
LD r1,r0,#W_ITYPE
CALL @p_elide_into
JMP @piv_d
piv_agg:
; an expression of the same aggregate type copies the whole object;
; otherwise a brace-elided list feeds its scalar leaves
LD r1,r0,#W_ITYPE
CALL @p_tok_agg_match
CMP r1,r0
JMP[EQ] @piv_agg_elide
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_ITYPE
CALL @ty_size
ADD r2,r1,r0
LA r1,#I_PUSH
CALL @ir_emit
LA r1,#I_MEMCPY
CALL @ir_op
JMP @piv_d
piv_agg_elide:
LD r1,r0,#W_ITYPE
CALL @p_elide_into
JMP @piv_d
piv_brace:
LD r1,r0,#W_ITYPE
CALL @p_init_braced
piv_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_init_braced: r1=aggregate type; destination address on the eval stack.
p_init_braced:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ITYPE
; zero the object (keep the base address on the stack)
CALL @ty_size
ST r1,r0,#W_INUM
LA r1,#I_DUP
CALL @ir_op
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
LA r1,#I_PUSH
LD r2,r0,#W_INUM
CALL @ir_emit
LA r1,#I_MEMSET
CALL @ir_op
MOVI r1,#P_LBRACE
MOVI r2,35
CALL @p_expect_p
LD r1,r0,#W_ITYPE
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @pib_array
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pib_struct
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pib_struct
; braced scalar: keep one copy of the object address for pib_close
LA r1,#I_DUP
CALL @ir_op
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_ITYPE
CALL @px_cast_stack
LD r1,r0,#W_ITYPE
MOVI r2,0
CALL @px_emit_store
JMP @pib_close
pib_struct:
LD r1,r0,#W_ITYPE
CALL @ty_addr
LD r2,r1,#TY_MEM
ST r2,r0,#W_INMEM
LD r2,r1,#TY_NMEM
ST r2,r0,#W_INNMEM
MOVI r1,0
ST r1,r0,#W_II
pib_s_l:
MOVI r1,#P_DOT
CALL @p_at_p
CMP r1,r0
JMP[NE] @pib_s_desig
LD r1,r0,#W_II
LD r2,r0,#W_INNMEM
CMP r1,r2
JMP[GE] @pib_close
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pib_close
JMP @pib_s_load
pib_s_desig:
CALL @p_adv
LD r1,r0,#W_ITYPE
CALL @p_member_lookup
LD r1,r0,#W_MEMIDX
ST r1,r0,#W_II
MOVI r1,#P_ASSIGN
MOVI r2,21
CALL @p_expect_p
pib_s_load:
LD r2,r0,#W_INMEM
LD r1,r0,#W_II
SHL r1,r1,2
ADD r2,r2,r1
LD r1,r2,1
ST r1,r0,#W_INOFF
LD r1,r2,2
ST r1,r0,#W_INTYPE
LA r1,#I_DUP
CALL @ir_op
LA r1,#I_PUSH
LD r2,r0,#W_INOFF
CALL @ir_emit
LA r1,#I_ADD
CALL @ir_op
; save this level's loop state across a nested initializer
LD r1,r0,#W_ITYPE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_INMEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_INNMEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_II
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_INTYPE
CALL @ty_bitwidth
CMP r2,r0
JMP[EQ] @pib_s_norm
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_INTYPE
CALL @px_cast_stack
LD r2,r0,#W_INMEM
LD r1,r0,#W_II
SHL r1,r1,2
ADD r2,r2,r1
LD r2,r2,3
ST r2,r0,#W_LBIT
LD r1,r0,#W_INTYPE
MOVI r2,0
CALL @px_emit_store
JMP @pib_s_norm2
pib_s_norm:
LD r1,r0,#W_INTYPE
CALL @p_init_value
pib_s_norm2:
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_II
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_INNMEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_INMEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ITYPE
LD r1,r0,#W_II
ADD r1,r1,r13
ST r1,r0,#W_II
; union: only the first member
LD r1,r0,#W_ITYPE
CALL @ty_kind
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pib_close
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pib_close
JMP @pib_s_l
pib_array:
LD r1,r0,#W_ITYPE
CALL @ty_count
ST r1,r0,#W_INNUM
LD r1,r0,#W_ITYPE
CALL @ty_base
ST r1,r0,#W_IELEM
CALL @ty_size
ST r1,r0,#W_IESZ
MOVI r1,0
ST r1,r0,#W_II
pib_a_l:
LD r1,r0,#W_II
LD r2,r0,#W_INNUM
CMP r1,r2
JMP[GE] @pib_close
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pib_close
LA r1,#I_DUP
CALL @ir_op
LA r1,#I_PUSH
LD r2,r0,#W_II
LD r3,r0,#W_IESZ
MUL r2,r2,r3
CALL @ir_emit
LA r1,#I_ADD
CALL @ir_op
; save loop state across a nested initializer
LD r1,r0,#W_ITYPE
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_INNUM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_IELEM
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_IESZ
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_II
ST r1,r14,0
ADD r14,r14,r13
LD r1,r0,#W_IELEM
CALL @p_init_value
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_II
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_IESZ
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_IELEM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_INNUM
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#W_ITYPE
LD r1,r0,#W_II
ADD r1,r1,r13
ST r1,r0,#W_II
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[EQ] @pib_close
JMP @pib_a_l
pib_close:
MOVI r1,#P_RBRACE
MOVI r2,35
CALL @p_expect_p
LA r1,#I_POP
CALL @ir_op
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
MOVI r2,#K_WSTRING
CMP r1,r2
JMP[EQ] @pisa_wide
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
pisa_wide:
LD r1,r0,#W_TY_TMP
CALL @ty_base
ST r1,r0,#W_TY_ID
CALL @ty_size
MOVI r2,4
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

; ty_is_funcptr: r1=type -> r1=1 for pointer-to-function
ty_is_funcptr:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_TMP
CALL @ty_kind
MOVI r2,#TY_PTR
CMP r1,r2
JMP[NE] @tif_n
LD r1,r0,#W_TY_TMP
CALL @ty_base
CALL @ty_kind
MOVI r2,#TY_FUNC
CMP r1,r2
JMP[NE] @tif_n
MOVI r1,1
JMP @tif_d
tif_n:
MOVI r1,0
tif_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ty_funcptr_ret: r1=pointer-to-function -> r1=return type
ty_funcptr_ret:
ST r15,r14,0
ADD r14,r14,r13
CALL @ty_base
CALL @ty_base
SUB r14,r14,r13
LD r15,r14,0
RET

; p_at_funcptr_decl: 1 if the declarator starts with '(' '*'
p_at_funcptr_decl:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#P_LPAREN
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pafpd_n
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pafpd_n
LD r1,r0,#W_TKB+1
MOVI r2,#P_STAR
CMP r1,r2
JMP[NE] @pafpd_n
MOVI r1,1
JMP @pafpd_d
pafpd_n:
MOVI r1,0
pafpd_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_funcptr_decl: r1=return type, r2=global flag (1=global)
; Parses ( * name ) ( params ) and allocates a 4-byte pointer variable.
p_funcptr_decl:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_OUTER
ST r0,r0,#W_FPDEF
ST r1,r0,#W_FPRET
ST r2,r0,#W_FPGLOBAL
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,#P_STAR
MOVI r2,36
CALL @p_expect_p
pfpd_stars:
MOVI r1,#P_STAR
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pfpd_name
CALL @p_adv
JMP @pfpd_stars
pfpd_name:
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pfpd_nm
MOVI r1,23
CALL @p_err
pfpd_nm:
LD r1,r0,#W_FPGLOBAL
MOVI r2,2
CMP r1,r2
JMP[EQ] @pfpd_typedef
CMP r1,r0
JMP[EQ] @pfpd_local
MOVI r1,#SK_GLOBAL
CALL @sym_get_cur
JMP @pfpd_sym
pfpd_local:
MOVI r1,#SK_LOCAL
CALL @sym_new_cur
JMP @pfpd_sym
pfpd_typedef:
MOVI r1,#SK_TYPE
CALL @sym_get_cur
pfpd_sym:
ST r1,r0,#W_FPSYM
CALL @p_adv
MOVI r1,#P_LPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pfpd_outer
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
pfpd_second:
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
ST r0,r0,#W_FPNP
LD r1,r0,#W_PARAMP
ST r1,r0,#W_FPSTART
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pfpd_params_done
MOVI r1,#KW_VOID
CALL @p_at_k
CMP r1,r0
JMP[EQ] @pfpd_param_l
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pfpd_param_l
LD r1,r0,#W_TKB+1
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[NE] @pfpd_param_l
CALL @p_adv
JMP @pfpd_params_done
pfpd_param_l:
CALL @p_typespec
CALL @p_ptr_suffix
ST r1,r0,#W_FPTMP
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pfpd_noid
CALL @p_adv
pfpd_noid:
LD r2,r0,#W_PARAMP
ADD r3,r2,r0
LD r1,r0,#W_FPTMP
ST r1,r3,0
ADD r2,r2,r13
ST r2,r0,#W_PARAMP
LD r1,r0,#W_FPNP
ADD r1,r1,r13
ST r1,r0,#W_FPNP
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pfpd_param_l
pfpd_params_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r1,r0,#W_FPRET
LD r2,r0,#W_FPNP
CALL @ty_func
ST r1,r0,#W_TY_TMP
LD r2,r0,#W_FPSTART
LD r3,r0,#W_FPNP
CALL @ty_func_set_params
LD r1,r0,#W_TY_TMP
CALL @ty_ptr
ST r1,r0,#W_FPTR_TYPE
LD r1,r0,#W_OUTER
CMP r1,r0
JMP[NE] @pfpd_outer_final
LD r1,r0,#W_FPSYM
CALL @sym_entry
LD r2,r0,#W_FPTR_TYPE
ST r2,r1,#SY_TYPE
MOVI r3,4
ST r3,r1,#SY_SIZE
ST r0,r1,#SY_CLS
LD r1,r0,#W_FPGLOBAL
MOVI r2,2
CMP r1,r2
JMP[EQ] @pfpd_setaux
CMP r1,r0
JMP[EQ] @pfpd_alloc_l
LD r1,r0,#W_GLOBP
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_TY_BASE
ADDI r2,r1,4
ST r2,r0,#W_GLOBP
JMP @pfpd_setaux
pfpd_alloc_l:
LD r1,r0,#W_LOCALB
MOVI r2,4
CALL @px_align_up
ST r1,r0,#W_TY_BASE
ADDI r2,r1,4
ST r2,r0,#W_LOCALB
pfpd_setaux:
LD r1,r0,#W_FPGLOBAL
MOVI r2,2
CMP r1,r2
JMP[EQ] @pfpd_ret
LD r1,r0,#W_FPSYM
CALL @sym_entry
LD r2,r0,#W_TY_BASE
ST r2,r1,#SY_AUX
pfpd_ret:
LD r1,r0,#W_FPTR_TYPE
SUB r14,r14,r13
LD r15,r14,0
RET

pfpd_outer:
MOVI r1,1
ST r1,r0,#W_OUTER
LD r1,r0,#W_FPSYM
ST r1,r0,#W_FUNCSYM
ST r0,r0,#W_SCOPEID
MOVI r1,1
ST r1,r0,#W_NEXTSCOPE
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,80
ST r1,r0,#W_LOCALB
LD r1,r0,#W_PARAMP
ST r1,r0,#W_FUNCARG
ST r0,r0,#W_FPNP
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @fpof_params_done
MOVI r1,#KW_VOID
CALL @p_at_k
CMP r1,r0
JMP[NE] @fpof_voidchk
JMP @fpof_param_l
fpof_voidchk:
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @fpof_param_l
LD r1,r0,#W_TKB+1
MOVI r2,#P_RPAREN
CMP r1,r2
JMP[NE] @fpof_param_l
CALL @p_adv
JMP @fpof_params_done
fpof_param_l:
CALL @p_typespec
ST r1,r0,#W_TY_ID
CALL @p_at_funcptr_decl
CMP r1,r0
JMP[EQ] @fpof_plain
LD r1,r0,#W_TY_ID
MOVI r2,0
CALL @p_funcptr_decl
LD r2,r0,#W_FUNCARG
LD r3,r0,#W_FPNP
ADD r3,r3,r3
ADD r2,r2,r3
LD r3,r0,#W_TY_BASE
ST r3,r2,0
LD r3,r0,#W_FPTR_TYPE
ST r3,r2,1
ADDI r2,r2,2
ST r2,r0,#W_PARAMP
LD r3,r0,#W_FPNP
ADD r3,r3,r13
ST r3,r0,#W_FPNP
JMP @fpof_param_next
fpof_plain:
LD r1,r0,#W_TY_ID
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
LD r2,r0,#W_TCONST
ST r2,r0,#W_DECL_CONST
CALL @px_decl_mark
MOVI r2,0
ST r2,r0,#W_TY_BASE
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @fpof_no_name
MOVI r1,#SK_LOCAL
CALL @sym_new_cur
CALL @px_const_sym
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @fpof_alloc
LD r1,r0,#W_TY_ID
CALL @ty_base
CALL @ty_ptr
ST r1,r0,#W_TY_ID
fpof_alloc:
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
fpof_no_name:
LD r2,r0,#W_FUNCARG
LD r3,r0,#W_FPNP
ADD r3,r3,r3
ADD r2,r2,r3
LD r3,r0,#W_TY_BASE
ST r3,r2,0
LD r3,r0,#W_TY_ID
ST r3,r2,1
ADDI r2,r2,2
ST r2,r0,#W_PARAMP
LD r3,r0,#W_FPNP
ADD r3,r3,r13
ST r3,r0,#W_FPNP
fpof_param_next:
ST r0,r0,#W_MARK_CONST
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @fpof_param_l
fpof_params_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
LD r1,r0,#W_FPNP
ST r1,r0,#W_FPNP1
JMP @pfpd_second

pfpd_outer_final:
LD r1,r0,#W_FPSYM
CALL @sym_entry
MOVI r3,#SK_FUNC
ST r3,r1,#SY_KIND
LD r3,r0,#W_FPTR_TYPE
ST r3,r1,#SY_TYPE
LD r3,r0,#W_FPNP1
ST r3,r1,#SY_NP
LD r3,r0,#W_FUNCARG
ST r3,r1,#SY_ARG
ST r0,r1,#SY_ENTRY
ST r0,r1,#SY_SIZE
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pfpd_outer_body
JMP @pfpd_ret
pfpd_outer_body:
MOVI r1,1
ST r1,r0,#W_FPDEF
LD r1,r0,#W_FPTR_TYPE
ST r1,r0,#W_FUNCRET
LD r1,r0,#W_FPNP1
ST r1,r0,#W_FUNCNP
LD r1,r0,#W_FPSYM
ST r1,r0,#W_FUNCSYM
ST r1,r14,0
ADD r14,r14,r13
JMP @pfu_body

; p_funcptr_init: optional '= expr' initializer for the function pointer
; declared by p_funcptr_decl (W_FPSYM/W_FPGLOBAL). Emits the store.
p_funcptr_init:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,#P_ASSIGN
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pfpi_d
CALL @p_adv
LD r1,r0,#W_FPGLOBAL
MOVI r2,2
CMP r1,r2
JMP[EQ] @pfpi_d
LD r1,r0,#W_FPSYM
CALL @sym_entry
LD r1,r1,#SY_AUX
LD r2,r0,#W_FPGLOBAL
CMP r2,r0
JMP[NE] @pfpi_g
CALL @px_addr_l
JMP @pfpi_val
pfpi_g:
CALL @px_addr_g
pfpi_val:
CALL @p_assign
CALL @p_emit_rv
LD r1,r0,#W_FPTR_TYPE
CALL @px_cast_stack
LD r1,r0,#W_FPTR_TYPE
MOVI r2,0
CALL @px_emit_store
pfpi_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; p_set_call_result: W_ETYPE holds the call's return type. Struct/union
; results leave a byte address on the eval stack and are lvalues.
p_set_call_result:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ETYPE
CALL @ty_kind
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pscr_agg
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pscr_agg
ST r0,r0,#W_LVAL
JMP @pscr_d
pscr_agg:
LD r1,r0,#W_ETYPE
ST r1,r0,#W_LTYPE
MOVI r1,1
ST r1,r0,#W_LVAL
pscr_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; tok_is_str: r1=current token text, r2=packed string -> 1/0
tok_is_str:
LA r1,#W_TKA+#TK_TEXT
SHL r1,r1,2
SHL r2,r2,2
tis_l:
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @tis_n
CMP r3,r0
JMP[EQ] @tis_y
ADD r1,r1,r13
ADD r2,r2,r13
JMP @tis_l
tis_y:
MOVI r1,1
RET
tis_n:
MOVI r1,0
RET

; local declarations
p_decl:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_ALIGNAS
CALL @p_typespec
ST r1,r0,#W_TY_RET
ST r0,r0,#W_MARK_CONST
LD r2,r0,#W_TCONST
ST r2,r0,#W_DECL_CONST
CALL @p_at_funcptr_decl
CMP r1,r0
JMP[EQ] @pd_one
LD r1,r0,#W_TY_RET
MOVI r2,0
LD r3,r0,#W_SCLASS
MOVI r4,3
CMP r3,r4
JMP[NE] @pd_fp_go
MOVI r2,2
pd_fp_go:
CALL @p_funcptr_decl
CALL @p_funcptr_init
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
SUB r14,r14,r13
LD r15,r14,0
RET
pd_one:
; "(*name)[" is a pointer-to-array declarator, not a function pointer
MOVI r1,#P_LPAREN
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pd_one_plain
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pd_one_plain
LD r1,r0,#W_TKB+1
MOVI r2,#P_STAR
CMP r1,r2
JMP[EQ] @pd_paren_ptr
pd_one_plain:
LD r1,r0,#W_TY_RET
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
CALL @px_decl_mark
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pd_ident
MOVI r1,23
CALL @p_err
pd_ident:
; block-scope function prototype: name followed by '('
CALL @p_peek
LD r1,r0,#W_TKB
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pd_not_proto
LD r1,r0,#W_TKB+1
MOVI r2,#P_LPAREN
CMP r1,r2
JMP[EQ] @pd_func_proto
pd_not_proto:
LD r1,r0,#W_SCLASS
MOVI r2,3
CMP r1,r2
JMP[EQ] @pd_typedef
MOVI r1,#SK_LOCAL
CALL @sym_new_cur
CALL @px_const_sym
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
pd_after_suffix:
CALL @p_infer_str_array
ST r1,r0,#W_TY_ID
CALL @p_arr_pre
ST r1,r0,#W_TY_BASE
CALL @ty_size
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_TY_ID
CALL @ty_align
ST r1,r0,#W_TY_COUNT
LD r2,r0,#W_ALIGNAS
CMP r2,r1
JMP[LE] @pd_al_ok
ST r2,r0,#W_TY_COUNT
pd_al_ok:
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
LD r1,r0,#W_TKA
MOVI r2,#K_WSTRING
CMP r1,r2
JMP[NE] @pd_not_wstr
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pd_not_wstr
LD r1,r0,#W_TY_ID
CALL @ty_base
CALL @ty_size
MOVI r2,4
CMP r1,r2
JMP[NE] @pd_not_wstr
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
MOVI r1,0
CALL @p_wstr_init
JMP @pd_afterinit
pd_not_wstr:
LD r1,r0,#W_TY_ID
CALL @ty_kind
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
; brace elision for arrays of flat aggregates
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_EL_ELEM
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_AUX
ST r1,r0,#W_EL_BASE
LD r1,r0,#W_EL_ELEM
CALL @ty_base
ST r1,r0,#W_EL_OFF
LD r1,r0,#W_EL_OFF
CALL @p_flat_agg
CMP r1,r0
JMP[EQ] @pd_ai_normal
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pd_ai_normal
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[NE] @pd_ai_normal
LD r1,r0,#W_EL_ELEM
CALL @ty_count
ADD r2,r1,r0
LD r1,r0,#W_EL_OFF
LD r3,r0,#W_EL_BASE
MOVI r4,0
CALL @p_elide_elems
MOVI r1,#P_RBRACE
MOVI r2,35
CALL @p_expect_p
JMP @pd_afterinit
pd_ai_normal:
MOVI r1,0
ST r1,r14,0
ADD r14,r14,r13
pd_ai_l:
ST r0,r0,#W_ARRMAX
ST r0,r0,#W_DESOFF
LA r1,0xFFFFFFFF
ST r1,r0,#W_DESTYPE
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[NE] @pd_ai_desig
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pd_ai_done
JMP @pd_ai_elem
pd_ai_desig:
CALL @p_adv
CALL @p_cexpr
ST r1,r0,#W_DESIDX
MOVI r1,#P_RBRACK
MOVI r2,33
CALL @p_expect_p
MOVI r1,#P_DOT
CALL @p_at_p
CMP r1,r0
JMP[NE] @pd_ai_member
JMP @pd_ai_setidx
pd_ai_member:
CALL @p_adv
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
CALL @p_member_lookup
ST r1,r0,#W_DESOFF
ST r2,r0,#W_DESTYPE
pd_ai_setidx:
MOVI r1,#P_ASSIGN
MOVI r2,21
CALL @p_expect_p
ADDI r3,r14,-1
LD r4,r0,#W_DESIDX
ST r4,r3,0
pd_ai_elem:
; element type and size from the array symbol
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_RET
LD r1,r0,#W_TY_RET
CALL @ty_size
ST r1,r0,#W_ELEMSZ
LD r1,r0,#W_DESTYPE
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @pd_ai_tyok
ST r1,r0,#W_TY_RET
pd_ai_tyok:
LD r1,r0,#W_ELEMSZ
ADDI r3,r14,-1
LD r4,r3,0
MUL r4,r4,r1
LD r1,r0,#W_DESOFF
ADD r4,r4,r1
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
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pd_ai_plain
LD r1,r0,#W_TY_RET
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @pd_ai_nested
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pd_ai_nested
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pd_ai_nested
JMP @pd_ai_plain
pd_ai_nested:
LD r1,r0,#W_TY_RET
CALL @p_init_braced
JMP @pd_ai_next
pd_ai_plain:
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_RET
LD r1,r0,#W_DESTYPE
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @pd_ai_pv
ST r1,r0,#W_TY_RET
pd_ai_pv:
LD r1,r0,#W_TY_RET
CALL @p_init_value
pd_ai_next:
ADDI r3,r14,-1
LD r4,r3,0
ADD r4,r4,r13
LD r5,r0,#W_ARRMAX
CMPS r4,r5
JMP[LE] @pd_ai_mx
ST r4,r0,#W_ARRMAX
pd_ai_mx:
ST r0,r0,#W_DESOFF
LA r1,0xFFFFFFFF
ST r1,r0,#W_DESTYPE
ADDI r3,r14,-1
LD r4,r3,0
ADD r4,r4,r13
ST r4,r3,0
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pd_ai_l
pd_ai_done:
ADDI r3,r14,-2
LD r1,r3,0
LD r2,r0,#W_ARRMAX
CALL @p_arr_fix
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
ST r3,r0,#W_DECLTYPE
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
LD r1,r0,#W_DECLTYPE
CALL @px_cast_stack
LD r1,r0,#W_DECLTYPE
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
pd_func_proto:
; Lightweight block-scope prototype: consume "name(params);" without
; creating a function body, locals, or a new scope.  The definition or a
; file-scope declaration supplies the callable symbol.
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pdp_done
MOVI r1,#KW_VOID
CALL @p_at_k
CMP r1,r0
JMP[EQ] @pdp_param
CALL @p_adv
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pdp_done
pdp_param:
CALL @p_typespec
ST r1,r0,#W_TY_ID
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pdp_noname
CALL @p_adv
pdp_noname:
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[NE] @pdp_param
pdp_done:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
SUB r14,r14,r13
LD r15,r14,0
RET

pd_paren_ptr:
; current '('; parse ( * name ) then [N] and build pointer-to-array
CALL @p_adv
MOVI r1,#P_STAR
MOVI r2,36
CALL @p_expect_p
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[EQ] @pp_name
MOVI r1,23
CALL @p_err
pp_name:
MOVI r1,#SK_LOCAL
CALL @sym_new_cur
CALL @px_const_sym
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pp_not_array
LD r1,r0,#W_TY_RET
CALL @p_array_suffix
CALL @ty_ptr
ST r1,r0,#W_TY_ID
JMP @pd_after_suffix
pp_not_array:
LD r1,r0,#W_TY_RET
CALL @ty_ptr
ST r1,r0,#W_TY_ID
JMP @pd_after_suffix

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
ST r1,r0,#W_SWSAVE
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
; W_TMP is the patching cursor now; restore from the untouched saved copy
LD r1,r0,#W_SWSAVE
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
JMP[EQ] @pf_init
; empty init clause: consume its semicolon
CALL @p_adv
JMP @pf_cond
pf_init:
CALL @p_is_type
CMP r1,r0
JMP[EQ] @pf_expinit
CALL @p_decl
JMP @pf_cond
pf_expinit:
CALL @p_expr
CALL @p_emit_rv
CALL @px_discard
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
; an empty post clause is legal: for(;;) and for(;cond;)
MOVI r1,#P_RPAREN
CALL @p_at_p
CMP r1,r0
JMP[NE] @pf_nopost
CALL @p_expr
CALL @p_emit_rv
LA r1,#I_POP
CALL @ir_op
pf_nopost:
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
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pret_struct
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pret_struct
LD r1,r0,#W_FUNCRET
CALL @ty_kind
CMP r1,r0
JMP[NE] @pret_cast
LA r1,#I_POP
CALL @ir_op
CALL @px_ret_zero
JMP @pret_go
pret_cast:
LD r1,r0,#W_FUNCRET
CALL @px_cast_stack
JMP @pret_go
pret_struct:
LD r1,r0,#W_FUNCRET
CALL @ty_size
ADD r2,r1,r0
LA r1,#I_RETSTRUCT
CALL @ir_emit
pret_go:
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
CALL @px_ret_emit
SUB r14,r14,r13
LD r15,r14,0
RET

; external declarations and function definitions
; px_ret_emit: I_RET with a 2-word operand for long long returns
px_ret_emit:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_FUNCRET
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[NE] @pxre_one
LA r1,#I_RET
MOVI r2,2
CALL @ir_emit
JMP @pxre_d
pxre_one:
LA r1,#I_RET
CALL @ir_op
pxre_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; px_ret_zero: push a zero return value (two words for long long)
px_ret_zero:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_FUNCRET
CALL @ty_kind
MOVI r2,#TY_LL
CMP r1,r2
JMP[NE] @pxrz_one
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
pxrz_one:
LA r1,#I_PUSH
MOVI r2,0
CALL @ir_emit
SUB r14,r14,r13
LD r15,r14,0
RET

; px_arg_cast: cast the current call argument to its declared parameter type
px_arg_cast:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_CALLSYM
CMP r1,r0
JMP[NE] @pxac_direct
LD r1,r0,#W_CALLFTYPE
CMP r1,r0
JMP[EQ] @pxac_d
SHL r2,r1,3
LA r3,#NCC_TYPEB
ADD r2,r2,r3
LD r3,r2,#TY_NMEM
LD r4,r0,#W_ARGIDX
CMP r4,r3
JMP[GE] @pxac_d
LD r2,r2,#TY_MEM
ADD r2,r2,r4
LD r1,r2,0
ST r1,r0,#W_TLL
CALL @px_cast_stack
LD r1,r0,#W_TLL
ST r1,r0,#W_ETYPE
JMP @pxac_d
pxac_direct:
LD r1,r0,#W_CALLSYM
CALL @sym_entry
LD r2,r1,#SY_ARG
CMP r2,r0
JMP[EQ] @pxac_d
LD r3,r1,#SY_NP
LD r4,r0,#W_ARGIDX
CMP r4,r3
JMP[GE] @pxac_d
SHL r4,r4,1
ADD r2,r2,r4
LD r1,r2,1
ST r1,r0,#W_TLL
CALL @px_cast_stack
LD r1,r0,#W_TLL
ST r1,r0,#W_ETYPE
pxac_d:
LD r1,r0,#W_ARGIDX
ADD r1,r1,r13
ST r1,r0,#W_ARGIDX
SUB r14,r14,r13
LD r15,r14,0
RET

; p_decl_external: r1=base type, current token begins a declarator or name
p_decl_external:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TY_RET
ST r1,r0,#W_DECLBASE
ST r0,r0,#W_MARK_CONST
LD r2,r0,#W_TCONST
ST r2,r0,#W_DECL_CONST
; consume pointer stars/qualifiers on the base type before looking for
; a function-pointer declarator, so "RET *(*name)(...)" is recognised.
; Keep the unsuffixed base in W_DECLBASE and remember that the first
; declarator's stars are already consumed.
LD r1,r0,#W_TY_RET
CALL @p_ptr_suffix
ST r1,r0,#W_TY_TMP
MOVI r1,1
ST r1,r0,#W_DECLFLAG
CALL @p_at_funcptr_decl
CMP r1,r0
JMP[EQ] @pde_not_fp
LD r1,r0,#W_TY_TMP
MOVI r2,1
LD r3,r0,#W_SCLASS
MOVI r4,3
CMP r3,r4
JMP[NE] @pde_fp_go
MOVI r2,2
pde_fp_go:
CALL @p_funcptr_decl
LD r2,r0,#W_FPDEF
CMP r2,r0
JMP[NE] @pde_d
CALL @p_funcptr_init
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
JMP @pde_d
pde_not_fp:
LD r1,r0,#W_TY_TMP
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
LD r1,r0,#W_DECLFLAG
CMP r1,r0
JMP[EQ] @pde_one_stars
ST r0,r0,#W_DECLFLAG
JMP @pde_one_have
pde_one_stars:
LD r1,r0,#W_DECLBASE
ST r1,r0,#W_TY_RET
LD r1,r0,#W_TY_RET
CALL @p_ptr_suffix
ST r1,r0,#W_TY_RET
pde_one_have:
LD r1,r0,#W_TY_RET
ST r1,r0,#W_TY_ID
CALL @px_decl_mark
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
CALL @px_const_sym
ST r1,r14,0
ADD r14,r14,r13
CALL @p_adv
LD r1,r0,#W_TY_ID
CALL @p_array_suffix
ST r1,r0,#W_TY_ID
CALL @p_infer_str_array
ST r1,r0,#W_TY_ID
CALL @p_arr_pre
CALL @ty_size
ST r1,r0,#W_TY_TMP
LD r1,r0,#W_TY_ID
CALL @ty_align
ST r1,r0,#W_TY_COUNT
LD r2,r0,#W_ALIGNAS
CMP r2,r1
JMP[LE] @pde_al_ok
ST r2,r0,#W_TY_COUNT
pde_al_ok:
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
LD r1,r0,#W_TKA
MOVI r2,#K_WSTRING
CMP r1,r2
JMP[NE] @pde_not_wstr
LD r1,r0,#W_TY_ID
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[NE] @pde_not_wstr
LD r1,r0,#W_TY_ID
CALL @ty_base
CALL @ty_size
MOVI r2,4
CMP r1,r2
JMP[NE] @pde_not_wstr
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
LD r3,r1,#SY_TYPE
MOVI r1,1
CALL @p_wstr_init
JMP @pde_after
pde_not_wstr:
LD r1,r0,#W_TY_ID
CALL @ty_kind
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
; brace elision for arrays of flat aggregates
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
ST r1,r0,#W_EL_ELEM
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_AUX
ST r1,r0,#W_EL_BASE
LD r1,r0,#W_EL_ELEM
CALL @ty_base
ST r1,r0,#W_EL_OFF
LD r1,r0,#W_EL_OFF
CALL @p_flat_agg
CMP r1,r0
JMP[EQ] @pde_ai_normal
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pde_ai_normal
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[NE] @pde_ai_normal
LD r1,r0,#W_EL_ELEM
CALL @ty_count
ADD r2,r1,r0
LD r1,r0,#W_EL_OFF
LD r3,r0,#W_EL_BASE
MOVI r4,1
CALL @p_elide_elems
MOVI r1,#P_RBRACE
MOVI r2,35
CALL @p_expect_p
JMP @pde_after
pde_ai_normal:
MOVI r1,0
ST r1,r14,0
ADD r14,r14,r13
pde_ai_l:
ST r0,r0,#W_ARRMAX
ST r0,r0,#W_DESOFF
LA r1,0xFFFFFFFF
ST r1,r0,#W_DESTYPE
MOVI r1,#P_LBRACK
CALL @p_at_p
CMP r1,r0
JMP[NE] @pde_ai_desig
MOVI r1,#P_RBRACE
CALL @p_at_p
CMP r1,r0
JMP[NE] @pde_ai_done
JMP @pde_ai_elem
pde_ai_desig:
CALL @p_adv
CALL @p_cexpr
ST r1,r0,#W_DESIDX
MOVI r1,#P_RBRACK
MOVI r2,33
CALL @p_expect_p
MOVI r1,#P_DOT
CALL @p_at_p
CMP r1,r0
JMP[NE] @pde_ai_member
JMP @pde_ai_setidx
pde_ai_member:
CALL @p_adv
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
CALL @p_member_lookup
ST r1,r0,#W_DESOFF
ST r2,r0,#W_DESTYPE
pde_ai_setidx:
MOVI r1,#P_ASSIGN
MOVI r2,21
CALL @p_expect_p
ADDI r3,r14,-1
LD r4,r0,#W_DESIDX
ST r4,r3,0
pde_ai_elem:
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_COUNT
LD r1,r0,#W_TY_COUNT
CALL @ty_size
ST r1,r0,#W_ELEMSZ
LD r1,r0,#W_DESTYPE
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @pde_ai_tyok
ST r1,r0,#W_TY_COUNT
pde_ai_tyok:
LD r1,r0,#W_ELEMSZ
ADDI r3,r14,-1
LD r4,r3,0
MUL r4,r4,r1
LD r1,r0,#W_DESOFF
ADD r4,r4,r1
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r2,r1,#SY_AUX
ADD r2,r2,r4
MOVI r1,1
CALL @p_decl_store_addr
MOVI r1,#P_LBRACE
CALL @p_at_p
CMP r1,r0
JMP[EQ] @pde_ai_plain
LD r1,r0,#W_TY_COUNT
CALL @ty_kind
MOVI r2,#TY_ARRAY
CMP r1,r2
JMP[EQ] @pde_ai_nested
MOVI r2,#TY_STRUCT
CMP r1,r2
JMP[EQ] @pde_ai_nested
MOVI r2,#TY_UNION
CMP r1,r2
JMP[EQ] @pde_ai_nested
JMP @pde_ai_plain
pde_ai_nested:
LD r1,r0,#W_TY_COUNT
CALL @p_init_braced
JMP @pde_ai_next
pde_ai_plain:
ADDI r3,r14,-2
LD r1,r3,0
CALL @sym_entry
LD r1,r1,#SY_TYPE
CALL @ty_base
ST r1,r0,#W_TY_COUNT
LD r1,r0,#W_DESTYPE
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @pde_ai_pv
ST r1,r0,#W_TY_COUNT
pde_ai_pv:
LD r1,r0,#W_TY_COUNT
CALL @p_init_value
pde_ai_next:
ADDI r3,r14,-1
LD r4,r3,0
ADD r4,r4,r13
LD r5,r0,#W_ARRMAX
CMPS r4,r5
JMP[LE] @pde_ai_mx
ST r4,r0,#W_ARRMAX
pde_ai_mx:
ST r0,r0,#W_DESOFF
LA r1,0xFFFFFFFF
ST r1,r0,#W_DESTYPE
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
ADDI r3,r14,-2
LD r1,r3,0
LD r2,r0,#W_ARRMAX
CALL @p_arr_fix
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
JMP[NE] @pde_one_more
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
JMP @pde_d
pde_one_more:
LD r1,r0,#W_DECLBASE
ST r1,r0,#W_TY_RET
ST r0,r0,#W_DECLFLAG
JMP @pde_one
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
JMP[NE] @pde_typedef_more
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
pde_d:
SUB r14,r14,r13
LD r15,r14,0
RET
pde_typedef_more:
LD r1,r0,#W_DECLBASE
ST r1,r0,#W_TY_RET
ST r0,r0,#W_DECLFLAG
JMP @pde_typedef
pde_type_only:
CALL @p_adv
JMP @pde_d

; function definition/prototype; current token is the name, r1=return type
p_func:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_MARK_CONST
ST r0,r0,#W_SCOPEID
MOVI r2,1
ST r2,r0,#W_NEXTSCOPE
ST r1,r0,#W_FUNCRET
; a prototype for a standard-library name (e.g. "int strlen(char*);")
; must not hide the builtin implementation
MOVI r1,#SK_BUILTIN
CALL @sym_find_cur
ST r1,r0,#W_BUILTIN_IDX
MOVI r1,#SK_FUNC
CALL @sym_find_cur
ST r1,r0,#W_EXISTFUNC
MOVI r1,#SK_FUNC
CALL @sym_get_cur
ST r1,r14,0
ADD r14,r14,r13
ST r1,r0,#W_FUNCSYM
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
MOVI r1,80
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
LD r1,r0,#W_TKA
MOVI r2,#K_PUNCT
CMP r1,r2
JMP[NE] @pfu_not_dots
LD r1,r0,#W_TKA+1
MOVI r2,#P_DOT
CMP r1,r2
JMP[NE] @pfu_not_dots
CALL @p_adv
LD r1,r0,#W_TKA+1
MOVI r2,#P_DOT
CMP r1,r2
JMP[NE] @pfu_bad_dots
CALL @p_adv
LD r1,r0,#W_TKA+1
MOVI r2,#P_DOT
CMP r1,r2
JMP[NE] @pfu_bad_dots
CALL @p_adv
ADDI r3,r14,-1
LD r1,r3,0
CALL @sym_entry
MOVI r2,1
ST r2,r1,#SY_OFF
JMP @pfu_done_params
pfu_bad_dots:
MOVI r1,23
CALL @p_err
pfu_not_dots:
CALL @p_typespec
ST r1,r0,#W_TY_ID
CALL @p_at_funcptr_decl
CMP r1,r0
JMP[EQ] @pfu_plain_type
LD r1,r0,#W_TY_ID
MOVI r2,0
CALL @p_funcptr_decl
LD r2,r0,#W_FUNCARG
LD r3,r0,#W_FUNCNP
ADD r3,r3,r3
ADD r2,r2,r3
LD r3,r0,#W_TY_BASE
ST r3,r2,0
LD r3,r0,#W_FPTR_TYPE
ST r3,r2,1
ADDI r2,r2,2
ST r2,r0,#W_PARAMP
LD r3,r0,#W_FUNCNP
ADD r3,r3,r13
ST r3,r0,#W_FUNCNP
JMP @pfu_param_next
pfu_plain_type:
LD r1,r0,#W_TY_ID
CALL @p_ptr_suffix
ST r1,r0,#W_TY_ID
LD r2,r0,#W_TCONST
ST r2,r0,#W_DECL_CONST
CALL @px_decl_mark
MOVI r2,0
ST r2,r0,#W_TY_BASE
LD r1,r0,#W_TKA
MOVI r2,#K_IDENT
CMP r1,r2
JMP[NE] @pfu_no_name
MOVI r1,#SK_LOCAL
CALL @sym_new_cur
CALL @px_const_sym
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
LD r1,r0,#W_LOCALB
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
pfu_param_next:
ST r0,r0,#W_MARK_CONST
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
; if this prototype names a builtin, make the symbol dispatch to it
LD r2,r0,#W_BUILTIN_IDX
MOVI r3,0xFFFF
SHL r3,r3,16
ADDI r3,r3,-1
CMP r2,r3
JMP[EQ] @pfu_proto_done
LD r1,r0,#W_BUILTIN_IDX
CALL @sym_entry
LD r3,r1,#SY_KIND
LD r1,r0,#W_BUILTIN_IDX
CALL @sym_entry
LD r4,r1,#SY_AUX
ADDI r5,r14,-1
LD r1,r5,0
CALL @sym_entry
ST r3,r1,#SY_KIND
ST r4,r1,#SY_AUX
pfu_try_existing:
; if an earlier definition of this name exists, reuse its entry
LD r2,r0,#W_EXISTFUNC
MOVI r3,0xFFFF
SHL r3,r3,16
ADDI r3,r3,-1
CMP r2,r3
JMP[EQ] @pfu_proto_done
LD r1,r0,#W_EXISTFUNC
CALL @sym_entry
LD r3,r1,#SY_ENTRY
CMP r3,r0
JMP[EQ] @pfu_proto_done
ADDI r5,r14,-1
LD r1,r5,0
CALL @sym_entry
ST r3,r1,#SY_ENTRY
pfu_proto_done:
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
CALL @px_ret_zero
CALL @px_ret_emit
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
; p_const_eval: parse a full constant expression and execute just its IR.
; Used by _Static_assert. The generated instructions are discarded afterwards.
p_const_eval:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#R_SP
ST r1,r0,#W_CNST_SAVE
LD r1,r0,#W_IRPC
ST r1,r0,#W_CNST_START
LD r1,r0,#R_FP
ST r1,r0,#W_CNST_FP
LD r1,r0,#W_IRYSTOP
ST r1,r0,#W_CNST_STOP
LD r1,r0,#W_ALARM
ST r1,r0,#W_CNST_ALARM
LA r1,#NCC_ESB
ST r1,r0,#R_SP
ST r0,r0,#R_FP
ST r0,r0,#W_IRYSTOP
ST r0,r0,#W_ALARM
CALL @p_expr
CALL @p_emit_rv
LA r1,#I_HALT
MOVI r2,0
CALL @ir_emit
LD r1,r0,#W_CNST_START
ST r1,r0,#R_IP
CALL @ncc_ir_loop
CALL @ni_pop
ST r1,r0,#W_ISO_TMP
LD r1,r0,#W_CNST_START
ST r1,r0,#W_IRPC
LD r1,r0,#W_CNST_SAVE
ST r1,r0,#R_SP
LD r1,r0,#W_CNST_FP
ST r1,r0,#R_FP
LD r1,r0,#W_CNST_STOP
ST r1,r0,#W_IRYSTOP
LD r1,r0,#W_CNST_ALARM
ST r1,r0,#W_ALARM
LD r1,r0,#W_ISO_TMP
SUB r14,r14,r13
LD r15,r14,0
RET

; p_static_assert: _Static_assert(expr[, "message"]);
p_static_assert:
ST r15,r14,0
ADD r14,r14,r13
CALL @p_adv
MOVI r1,#P_LPAREN
MOVI r2,9
CALL @p_expect_p
CALL @p_const_eval
ST r1,r0,#W_ISO_TMP
MOVI r1,#P_COMMA
CALL @p_take_p
CMP r1,r0
JMP[EQ] @psa_close
LD r1,r0,#W_TKA
MOVI r2,#K_STRING
CMP r1,r2
JMP[NE] @psa_msg
CALL @p_adv
psa_close:
MOVI r1,#P_RPAREN
MOVI r2,10
CALL @p_expect_p
MOVI r1,#P_SEMI
MOVI r2,24
CALL @p_expect_p
LD r1,r0,#W_ISO_TMP
CMP r1,r0
JMP[NE] @psa_ok
MOVI r1,80
CALL @p_err
psa_ok:
SUB r14,r14,r13
LD r15,r14,0
RET
psa_msg:
MOVI r1,83
CALL @p_err

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
JMP[NE] @ptu_sa
CALL @p_adv
JMP @ptu_l
ptu_sa:
MOVI r2,#K_KEYWORD
CMP r1,r2
JMP[NE] @ptu_type
LD r1,r0,#W_TKA+1
MOVI r2,#KW_STATIC_ASSERT
CMP r1,r2
JMP[NE] @ptu_type
CALL @p_static_assert
JMP @ptu_l
ptu_type:
CALL @p_is_type
CMP r1,r0
JMP[NE] @ptu_go
MOVI r1,30
CALL @p_err
ptu_go:
ST r0,r0,#W_ALIGNAS
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
LD r3,r0,#W_PF_OFF
ADD r1,r1,r3
LD r2,r0,#R_SP
LD r3,r0,#W_CALLWORDS
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

; ------------------------------------------------------------------ libm sin/cos
; Correctly-rounded binary32 sin/cos for a scoped range.
;
; Internal arithmetic is a software double-float (two binary32 values hi+lo,
; about 48 significant bits). Range reduction is Cody-Waite against a
; five-part binary32 expansion of pi/2; the polynomial kernels use fdlibm's
; minimax coefficients split into hi/lo binary32 pairs.
;
; Exactness scope: |x| <= 65536 (all finite binary32 inputs in that range).
; Above that the old float32 reduction is used as a coarse fallback; those
; results are not claimed correctly rounded (and may be NaN for enormous
; finite arguments). NaN -> qNaN,
; +-Inf -> qNaN, sin(+-0) = +-0, cos(+-0) = 1.

; nix_dadd: (r1,r2) + (r3,r4) -> (r1,r2), normalised double-float.
nix_dadd:
FADD r5,r1,r3
FSUB r6,r5,r1
FSUB r7,r5,r6
FSUB r7,r1,r7
FSUB r8,r3,r6
FADD r7,r7,r8
FADD r7,r7,r2
FADD r7,r7,r4
FADD r9,r5,r7
FSUB r10,r9,r5
FSUB r2,r7,r10
ADD r1,r9,r0
RET

; nix_dsub: (r1,r2) - (r3,r4) -> (r1,r2).
nix_dsub:
LA r5,0x80000000
BOOL.6 r3,r3,r5
BOOL.6 r4,r4,r5
JMP @nix_dadd

; nix_dmul: (r1,r2) * (r3,r4) -> (r1,r2), Dekker split + TwoProduct.
nix_dmul:
LA r5,0x45800800
FMUL r6,r1,r5
FSUB r7,r6,r1
FSUB r7,r6,r7
FSUB r8,r1,r7
FMUL r11,r3,r5
FSUB r9,r11,r3
FSUB r9,r11,r9
FSUB r10,r3,r9
FMUL r11,r1,r3
FMUL r12,r7,r9
FSUB r12,r12,r11
FMUL r6,r7,r10
FADD r12,r12,r6
FMUL r6,r8,r9
FADD r12,r12,r6
FMUL r6,r8,r10
FADD r12,r12,r6
FMUL r6,r1,r4
FADD r12,r12,r6
FMUL r6,r2,r3
FADD r12,r12,r6
FADD r5,r11,r12
FSUB r6,r5,r11
FSUB r2,r12,r6
ADD r1,r5,r0
RET

; nix_rsubc: r=(r1=const bits) -> W_LM_R - W_LM_ND*const, kept double-float.
nix_rsubc:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_LM_C
LD r1,r0,#W_LM_C
MOVI r2,0
LD r3,r0,#W_LM_ND
MOVI r4,0
CALL @nix_dmul
ST r1,r0,#W_LM_PH
ST r2,r0,#W_LM_PL
LD r1,r0,#W_LM_RH
LD r2,r0,#W_LM_RL
LD r3,r0,#W_LM_PH
LD r4,r0,#W_LM_PL
CALL @nix_dsub
ST r1,r0,#W_LM_RH
ST r2,r0,#W_LM_RL
SUB r14,r14,r13
LD r15,r14,0
RET

; nix_reduce: r1=x bits -> W_LM_RH/RL = x-n*pi/2, W_LM_Q = n&3.
; n = round(x*2/pi); Cody-Waite with five pi/2 parts.
nix_reduce:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_LM_X
LA r2,0x3F22F983
FMUL r3,r1,r2
LA r2,0x3F000000
LA r4,0x80000000
BOOL.8 r5,r3,r4
BOOL.14 r2,r2,r5
FADD r3,r3,r2
CVTFI r4,r3
ST r4,r0,#W_LM_N
MOVI r5,3
BOOL.8 r5,r4,r5
ST r5,r0,#W_LM_Q
CVTIF r5,r4
ST r5,r0,#W_LM_ND
ST r1,r0,#W_LM_RH
MOVI r6,0
ST r6,r0,#W_LM_RL
LA r1,0x3FC90FDB
CALL @nix_rsubc
LA r1,0xB33BBD2E
CALL @nix_rsubc
LA r1,0xA6F72CED
CALL @nix_rsubc
LA r1,0x194C5170
CALL @nix_rsubc
LA r1,0x0BDC1CD1
CALL @nix_rsubc
LD r1,r0,#W_LM_RH
LD r2,r0,#W_LM_RL
LD r3,r0,#W_LM_Q
SUB r14,r14,r13
LD r15,r14,0
RET

; nix_sin_kernel: r=W_LM_RH/RL, |r|<=pi/4 -> r1,r2 = sin(r) double-float.
nix_sin_kernel:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_LM_RH
LD r2,r0,#W_LM_RL
LD r3,r0,#W_LM_RH
LD r4,r0,#W_LM_RL
CALL @nix_dmul
ST r1,r0,#W_LM_ZH
ST r2,r0,#W_LM_ZL
LA r1,0x2F2EC9D3
LA r2,0xA2260550
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = S5 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0xB2D72F34
LA r2,0xA622B9CF
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = S4 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0x3638EF1B
LA r2,0xA984E018
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = S3 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0xB9500D01
LA r2,0x2C47D3C5
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = S2 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0x3C088889
LA r2,0xAFEEF076
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = S1 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0xBE2AAAAB
LA r2,0x31AAAAAB
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; return r + r*(z*acc)
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LD r1,r0,#W_LM_RH
LD r2,r0,#W_LM_RL
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LD r1,r0,#W_LM_RH
LD r2,r0,#W_LM_RL
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
SUB r14,r14,r13
LD r15,r14,0
RET

; nix_cos_kernel: r=W_LM_RH/RL, |r|<=pi/4 -> r1,r2 = cos(r) double-float.
nix_cos_kernel:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_LM_RH
LD r2,r0,#W_LM_RL
LD r3,r0,#W_LM_RH
LD r4,r0,#W_LM_RL
CALL @nix_dmul
ST r1,r0,#W_LM_ZH
ST r2,r0,#W_LM_ZL
LA r1,0xAD47D74E
LA r2,0x1F3BE396
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = C5 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0x310F74F6
LA r2,0xA392D38F
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = C4 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0xB493F27C
LA r2,0xA61C52AD
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = C3 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0x37D00D01
LA r2,0xAAC69D4E
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = C2 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0xBAB60B61
LA r2,0x2E13EAE9
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; acc = C1 + z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0x3D2AAAAB
LA r2,0xB0AAAAAB
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dadd
ST r1,r0,#W_LM_AH
ST r2,r0,#W_LM_AL
; q = z*z*acc
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_AH
LD r4,r0,#W_LM_AL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dmul
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
; h = z/2 (exact); return 1 - (h - q)
LD r1,r0,#W_LM_ZH
LD r2,r0,#W_LM_ZL
LA r3,0x3F000000
FMUL r1,r1,r3
FMUL r2,r2,r3
ST r1,r0,#W_LM_PH
ST r2,r0,#W_LM_PL
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dsub
ST r1,r0,#W_LM_TH
ST r2,r0,#W_LM_TL
LA r1,0x3F800000
MOVI r2,0
LD r3,r0,#W_LM_TH
LD r4,r0,#W_LM_TL
CALL @nix_dsub
SUB r14,r14,r13
LD r15,r14,0
RET

; nix_sin_coarse: old float32 path, finite fallback for |x| > 65536.
nix_sin_coarse:
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
JMP[GT] @nsc_hi
LA r2,0xC0490FDB
FCMP r1,r2
JMP[LT] @nsc_lo
JMP @nsc_taylor
nsc_hi:
LA r2,0x40C90FDB
FSUB r1,r1,r2
JMP @nsc_taylor
nsc_lo:
LA r2,0x40C90FDB
FADD r1,r1,r2
nsc_taylor:
; fold into [-pi/2,pi/2]
LA r2,0x3FC90FDB
FCMP r1,r2
JMP[LE] @nsc_chkneg
LA r2,0x40490FDB
FSUB r1,r2,r1
JMP @nsc_poly
nsc_chkneg:
LA r2,0xBFC90FDB
FCMP r1,r2
JMP[GE] @nsc_poly
LA r2,0xC0490FDB
FSUB r1,r2,r1
nsc_poly:
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
LA r4,0x39500D01
FMUL r3,r3,r4
FSUB r6,r6,r3
FMUL r3,r2,r2
FMUL r3,r3,r2
FMUL r3,r3,r2
FMUL r3,r3,r5
LA r4,0x3638EF1D
FMUL r3,r3,r4
FADD r6,r6,r3
FMUL r3,r2,r2
FMUL r3,r3,r2
FMUL r3,r3,r2
FMUL r3,r3,r2
FMUL r3,r3,r5
LA r4,0x32D7322B
FMUL r3,r3,r4
FSUB r6,r6,r3
ADD r1,r6,r0
RET

; ni_sin: r1=float bits -> r1=sin(r1)
ni_sin:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_LM_X
LA r2,0x7FFFFFFF
BOOL.8 r3,r1,r2
ST r3,r0,#W_LM_AX
LA r2,0x7F800000
CMP r3,r2
JMP[GT] @ns_nan
JMP[EQ] @ns_nan
CMP r3,r0
JMP[EQ] @ns_zero
LA r2,0x47800000
CMP r3,r2
JMP[GT] @ns_coarse
LD r1,r0,#W_LM_X
CALL @nix_reduce
MOVI r2,1
BOOL.8 r4,r3,r2
CMP r4,r0
JMP[NE] @ns_cos
CALL @nix_sin_kernel
JMP @ns_sign
ns_cos:
CALL @nix_cos_kernel
ns_sign:
LD r3,r0,#W_LM_Q
MOVI r4,2
BOOL.8 r3,r3,r4
CMP r3,r0
JMP[EQ] @ns_round
LA r3,0x80000000
BOOL.6 r1,r1,r3
BOOL.6 r2,r2,r3
ns_round:
FADD r1,r1,r2
JMP @ns_done
ns_nan:
LA r1,0x7FC00000
JMP @ns_done
ns_zero:
LD r1,r0,#W_LM_X
JMP @ns_done
ns_coarse:
LD r1,r0,#W_LM_X
CALL @nix_sin_coarse
ns_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_cos: r1=float bits -> r1=cos(r1)
ni_cos:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_LM_X
LA r2,0x7FFFFFFF
BOOL.8 r3,r1,r2
ST r3,r0,#W_LM_AX
LA r2,0x7F800000
CMP r3,r2
JMP[GT] @nc_nan
JMP[EQ] @nc_nan
CMP r3,r0
JMP[EQ] @nlc_zero
LA r2,0x47800000
CMP r3,r2
JMP[GT] @nc_coarse
LD r1,r0,#W_LM_X
CALL @nix_reduce
MOVI r2,1
BOOL.8 r4,r3,r2
CMP r4,r0
JMP[NE] @nc_sin
CALL @nix_cos_kernel
JMP @nc_sign
nc_sin:
CALL @nix_sin_kernel
nc_sign:
LD r3,r0,#W_LM_Q
ADDI r3,r3,1
MOVI r4,2
BOOL.8 r3,r3,r4
CMP r3,r0
JMP[EQ] @nc_round
LA r3,0x80000000
BOOL.6 r1,r1,r3
BOOL.6 r2,r2,r3
nc_round:
FADD r1,r1,r2
JMP @nc_done
nc_nan:
LA r1,0x7FC00000
JMP @nc_done
nlc_zero:
LA r1,0x3F800000
JMP @nc_done
nc_coarse:
LD r1,r0,#W_LM_X
LA r2,0x3FC90FDB
FADD r1,r1,r2
CALL @nix_sin_coarse
nc_done:
SUB r14,r14,r13
LD r15,r14,0
RET

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
ST r0,r0,#W_PF_LL
ST r0,r0,#W_PF_LSTR
LA r3,0xFFFFFFFF
ST r3,r0,#W_PF_PREC
npf_flag_l:
LD r1,r0,#W_PF_FMT
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @npf_done
MOVI r3,45
CMP r2,r3
JMP[NE] @npf_flag_h
LD r3,r0,#W_PF_FLAGS
MOVI r4,1
BOOL.14 r3,r3,r4
ST r3,r0,#W_PF_FLAGS
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_flag_l
npf_flag_h:
MOVI r3,35
CMP r2,r3
JMP[NE] @npf_flag_z
LD r3,r0,#W_PF_FLAGS
MOVI r4,3
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
MOVI r3,42
CMP r2,r3
JMP[NE] @npf_w_digits
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_W
CMPS r1,r0
JMP[GE] @npf_w_abs
SUB r1,r0,r1
ST r1,r0,#W_PF_W
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.14 r2,r2,r3
ST r2,r0,#W_PF_FLAGS
npf_w_abs:
LD r1,r0,#W_PF_FMT
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_w_d
npf_w_digits:
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
MOVI r3,46
CMP r2,r3
JMP[NE] @npf_prec_done
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
MOVI r3,0
ST r3,r0,#W_PF_PREC
npf_prec_l:
LD r1,r0,#W_PF_FMT
LDB r2,r1,0
MOVI r3,42
CMP r2,r3
JMP[NE] @npf_prec_digits
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
CMPS r1,r0
JMP[GE] @npf_prec_abs
MOVI r1,0
npf_prec_abs:
ST r1,r0,#W_PF_PREC
LD r1,r0,#W_PF_FMT
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_prec_done
npf_prec_digits:
MOVI r3,48
CMP r2,r3
JMP[LT] @npf_prec_done
MOVI r3,58
CMP r2,r3
JMP[GE] @npf_prec_done
LD r3,r0,#W_PF_PREC
MOVI r4,10
MUL r3,r3,r4
ADDI r2,r2,-48
ADD r3,r3,r2
ST r3,r0,#W_PF_PREC
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
JMP @npf_prec_l
npf_prec_done:
LD r1,r0,#W_PF_FMT
LDB r2,r1,0
MOVI r3,108
CMP r2,r3
JMP[NE] @npf_fmt
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
LDB r2,r1,0
MOVI r3,108
CMP r2,r3
JMP[NE] @npf_single_l
ADD r1,r1,r13
ST r1,r0,#W_PF_FMT
LDB r2,r1,0
MOVI r3,1
ST r3,r0,#W_PF_LL
ST r0,r0,#W_PF_LSTR
JMP @npf_fmt
npf_single_l:
MOVI r3,1
ST r3,r0,#W_PF_LSTR
npf_fmt:
ST r2,r0,#W_PF_CASE
MOVI r3,100
CMP r2,r3
JMP[EQ] @npf_int
MOVI r3,105
CMP r2,r3
JMP[EQ] @npf_int
MOVI r3,117
CMP r2,r3
JMP[EQ] @npf_uint
MOVI r3,111
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
MOVI r3,101
CMP r2,r3
JMP[EQ] @npf_exp
MOVI r3,69
CMP r2,r3
JMP[EQ] @npf_exp
MOVI r3,102
CMP r2,r3
JMP[EQ] @npf_float
MOVI r3,70
CMP r2,r3
JMP[EQ] @npf_float
MOVI r3,103
CMP r2,r3
JMP[EQ] @npf_g
MOVI r3,71
CMP r2,r3
JMP[EQ] @npf_g
MOVI r3,37
CMP r2,r3
JMP[EQ] @npf_pctc
ADD r1,r2,r0
CALL @ncc_putc
JMP @npf_adv
npf_int:
LD r1,r0,#W_PF_LL
CMP r1,r0
JMP[NE] @npf_ll_signed
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
LA r3,0xFFFFFFFF
LD r1,r0,#W_PF_PREC
CMP r1,r3
JMP[NE] @npf_i_prec
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
npf_i_prec:
; precision: sign, zero pad to prec digits, then digits
LD r4,r0,#W_PF_NEG
CMP r4,r0
JMP[EQ] @npf_ip_nosign
MOVI r1,45
CALL @ncc_putc
npf_ip_nosign:
LD r2,r0,#W_PF_LEN
LD r1,r0,#W_PF_PREC
LD r2,r0,#W_PF_TMP
ADD r1,r1,r0
CALL @ni_decdigits
LD r1,r0,#W_PF_PREC
SUB r1,r1,r2
CMP r1,r0
JMP[LE] @npf_ip_digits
MOVI r2,48
CALL @ni_pad
npf_ip_digits:
LD r5,r0,#W_PF_TMP
CALL @putudec
LD r2,r0,#W_PF_PREC
LD r1,r0,#W_PF_NEG
ADD r2,r2,r1
ST r2,r0,#W_PF_LEN
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv


; ---- long long printf ------------------------------------------------
npf_ll_get:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_LLD0
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_LLD1
SUB r14,r14,r13
LD r15,r14,0
RET

npf_ll_signed:
CALL @npf_ll_get
ST r0,r0,#W_PF_NEG
LD r2,r0,#W_LLD1
CMPS r2,r0
JMP[GE] @npf_ll_sp
MOVI r2,1
ST r2,r0,#W_PF_NEG
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CALL @ll_neg_pair
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
npf_ll_sp:
MOVI r1,10
CALL @ll_fmt_base
JMP @npf_ll_emit

npf_ll_unsigned:
CALL @npf_ll_get
ST r0,r0,#W_PF_NEG
LD r1,r0,#W_PF_CASE
MOVI r2,111
CMP r1,r2
JMP[EQ] @npf_ll_oct
MOVI r1,10
CALL @ll_fmt_base
JMP @npf_ll_emit
npf_ll_oct:
MOVI r1,8
CALL @ll_fmt_base
JMP @npf_ll_emit

npf_ll_hex:
CALL @npf_ll_get
ST r0,r0,#W_PF_NEG
CALL @ll_fmt16
LD r3,r0,#W_PF_CASE
CMP r3,r0
JMP[NE] @npf_ll_emit
; lowercase a-f in place
LA r4,#LLFMT
MOVI r5,0
nllx_lc:
CMP r5,r2
JMP[GE] @npf_ll_emit
ADD r6,r4,r5
LDB r7,r6,0
MOVI r8,65
CMP r7,r8
JMP[LT] @nllx_n
MOVI r8,70
CMP r7,r8
JMP[GT] @nllx_n
ADDI r7,r7,32
STB r7,r6,0
nllx_n:
ADD r5,r5,r13
JMP @nllx_lc

npf_ll_emit:
ST r2,r0,#W_PF_TMP
ST r0,r0,#W_PF_VAL
LD r3,r0,#W_PF_PREC
LA r4,0xFFFFFFFF
CMP r3,r4
JMP[EQ] @nll_zpd
CMP r3,r2
JMP[LE] @nll_zpd
SUB r3,r3,r2
ST r3,r0,#W_PF_VAL
nll_zpd:
LD r1,r0,#W_PF_TMP
LD r2,r0,#W_PF_VAL
ADD r1,r1,r2
LD r3,r0,#W_PF_NEG
ADD r1,r1,r3
ST r1,r0,#W_PF_LEN
; leading spaces unless zero flag or left flag
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @nll_nolead
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @nll_nolead
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CMP r2,r1
JMP[LE] @nll_nolead
SUB r1,r2,r1
MOVI r2,32
CALL @ni_pad
nll_nolead:
; sign
LD r2,r0,#W_PF_NEG
CMP r2,r0
JMP[EQ] @nll_nosign
MOVI r1,45
CALL @ncc_putc
nll_nosign:
; zero flag padding
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @nll_nozero
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CMP r2,r1
JMP[LE] @nll_nozero
SUB r1,r2,r1
MOVI r2,48
CALL @ni_pad
nll_nozero:
; precision zeros
LD r1,r0,#W_PF_VAL
CMP r1,r0
JMP[EQ] @nll_digits
MOVI r2,48
CALL @ni_pad
nll_digits:
LA r4,#LLFMT
LD r5,r0,#W_PF_TMP
nll_dl:
CMP r5,r0
JMP[EQ] @nll_tail
LDB r1,r4,0
ST r4,r0,#W_PF_TMP
ST r5,r0,#W_PF_VAL
CALL @ncc_putc
LD r4,r0,#W_PF_TMP
LD r5,r0,#W_PF_VAL
ADD r4,r4,r13
SUB r5,r5,r13
JMP @nll_dl
nll_tail:
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @npf_adv
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CMP r2,r1
JMP[LE] @npf_adv
SUB r1,r2,r1
MOVI r2,32
CALL @ni_pad
JMP @npf_adv

npf_exp:
MOVI r3,101
CMP r2,r3
JMP[EQ] @npf_exp_lc
MOVI r2,1
JMP @npf_exp_set
npf_exp_lc:
MOVI r2,0
npf_exp_set:
ST r2,r0,#W_PF_CASE
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
LD r2,r0,#W_PF_PREC
CALL @ni_ecalc
ST r3,r0,#W_PF_LEN
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_e_emit
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
MOVI r3,32
CALL @ni_field_pre
npf_e_emit:
CALL @ni_eemit
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv

; ni_ecalc: r1=float bits r2=precision -> r3=length; sets W_F2* and W_F2EXP
ni_ecalc:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_F2V
ST r2,r0,#W_F2P
LA r4,0xFFFFFFFF
CMP r2,r4
JMP[NE] @nec_have
MOVI r2,6
ST r2,r0,#W_F2P
nec_have:
LD r2,r0,#W_F2P
MOVI r4,9
CMP r2,r4
JMP[LE] @nec_ok
MOVI r2,9
ST r2,r0,#W_F2P
nec_ok:
LD r5,r0,#W_F2V
LA r4,0x80000000
BOOL.8 r6,r5,r4
ST r0,r0,#W_F2NEG
ST r0,r0,#W_F2SIGN2
CMP r6,r0
JMP[EQ] @nec_pos
MOVI r6,1
ST r6,r0,#W_F2NEG
ST r6,r0,#W_F2SIGN2
LA r4,0x7FFFFFFF
BOOL.8 r5,r5,r4
nec_pos:
ST r0,r0,#W_F2EXP
CMP r5,r0
JMP[EQ] @nec_zero
nec_hi:
LA r4,0x41200000
FCMP r5,r4
JMP[LT] @nec_lo
FDIV r5,r5,r4
LD r2,r0,#W_F2EXP
ADD r2,r2,r13
ST r2,r0,#W_F2EXP
JMP @nec_hi
nec_lo:
LA r4,0x3F800000
FCMP r5,r4
JMP[GE] @nec_done
LA r4,0x41200000
FMUL r5,r5,r4
LD r2,r0,#W_F2EXP
SUB r2,r2,r13
ST r2,r0,#W_F2EXP
JMP @nec_lo
nec_done:
LD r2,r0,#W_F2P
ADD r1,r5,r0
CALL @ni_fcalc
LD r2,r0,#W_F2SIGN2
ST r2,r0,#W_F2NEG
JMP @nec_len
nec_zero:
ST r0,r0,#W_F2EXP
MOVI r1,0
LD r2,r0,#W_F2P
CALL @ni_fcalc
nec_len:
; exponent digit count first (ni_decdigits clobbers r3)
LD r1,r0,#W_F2EXP
CMPS r1,r0
JMP[GE] @nec_abs
SUB r1,r0,r1
nec_abs:
CALL @ni_decdigits
ST r2,r0,#W_F2TMP
; length = sign + 1 digit + (p ? 1+p : 0) + 'e' + exp sign + max(2,digits)
LD r3,r0,#W_F2NEG
ADD r3,r3,r13
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nec_len2
ADD r3,r3,r1
ADD r3,r3,r13
nec_len2:
ADD r3,r3,r13
ADD r3,r3,r13
LD r1,r0,#W_F2TMP
MOVI r2,2
CMP r1,r2
JMP[GE] @nec_len3
MOVI r1,2
nec_len3:
ADD r3,r3,r1
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_eemit: sign mantissa e exp using W_F2* state
ni_eemit:
ST r15,r14,0
ADD r14,r14,r13
LD r4,r0,#W_F2NEG
CMP r4,r0
JMP[EQ] @nee_nosign
MOVI r1,45
CALL @ncc_putc
nee_nosign:
LD r5,r0,#W_F2I
CALL @putudec
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nee_exp
MOVI r1,46
CALL @ncc_putc
LD r1,r0,#W_F2F
CALL @ni_decdigits
LD r1,r0,#W_F2P
SUB r1,r1,r2
CMP r1,r0
JMP[LE] @nee_frac
MOVI r2,48
CALL @ni_pad
nee_frac:
LD r5,r0,#W_F2F
CALL @putudec
nee_exp:
LD r3,r0,#W_PF_CASE
MOVI r1,101
CMP r3,r0
JMP[EQ] @nee_emark
MOVI r1,69
nee_emark:
CALL @ncc_putc
LD r2,r0,#W_F2EXP
ST r2,r0,#W_F2TMP
CMPS r2,r0
JMP[GE] @nee_epos
MOVI r1,45
CALL @ncc_putc
LD r2,r0,#W_F2TMP
SUB r2,r0,r2
ST r2,r0,#W_F2TMP
JMP @nee_edigits
nee_epos:
MOVI r1,43
CALL @ncc_putc
nee_edigits:
LD r2,r0,#W_F2TMP
MOVI r1,10
CMP r2,r1
JMP[GE] @nee_e2
MOVI r1,48
CALL @ncc_putc
nee_e2:
LD r5,r0,#W_F2TMP
CALL @putudec
SUB r14,r14,r13
LD r15,r14,0
RET

; %g/%G: precision P (default 6, 0 -> 1), choose %e when X < -4 or X >= P,
; otherwise fixed with P-1-X fraction digits; trailing zeros removed unless '#'.
npf_g:
MOVI r3,103
CMP r2,r3
JMP[NE] @npf_g_up
MOVI r3,0
JMP @npf_g_case0
npf_g_up:
MOVI r3,1
npf_g_case0:
ST r3,r0,#W_PF_CASE
CALL @ni_gprec
ST r1,r0,#W_PF_PREC
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
LD r2,r0,#W_PF_PREC
SUB r2,r2,r13
CALL @ni_ecalc
LD r1,r0,#W_F2EXP
LD r2,r0,#W_PF_PREC
LA r3,0xFFFFFFFC
CMPS r1,r3
JMP[LT] @npf_g_exp
CMPS r1,r2
JMP[GE] @npf_g_exp
; fixed-point form
SUB r2,r2,r13
SUB r2,r2,r1
LD r1,r0,#W_PF_VAL
CALL @ni_fcalc
CALL @ni_gtrim
CALL @ni_glen_fix
ST r0,r0,#W_F2TMP
JMP @npf_g_emit
npf_g_exp:
CALL @ni_gtrim
CALL @ni_glen_exp
MOVI r1,1
ST r1,r0,#W_F2TMP
npf_g_emit:
; zero-padded form keeps the sign before the zeros
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @npf_g_space
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_g_space
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CMP r2,r1
JMP[LE] @npf_g_do
LD r4,r0,#W_F2NEG
CMP r4,r0
JMP[EQ] @npf_g_zero
MOVI r1,45
CALL @ncc_putc
ST r0,r0,#W_F2NEG
npf_g_zero:
LD r1,r0,#W_PF_W
LD r2,r0,#W_PF_LEN
SUB r1,r1,r2
MOVI r2,48
CALL @ni_pad
JMP @npf_g_do
npf_g_space:
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_g_do
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
MOVI r3,32
CALL @ni_field_pre
npf_g_do:
LD r1,r0,#W_F2TMP
CMP r1,r0
JMP[NE] @npf_g_e
CALL @ni_femit
JMP @npf_g_tail
npf_g_e:
CALL @ni_eemit
npf_g_tail:
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv

; ni_gprec: r1 = normalized %g precision
ni_gprec:
LD r1,r0,#W_PF_PREC
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @ngp_have
MOVI r1,6
ngp_have:
CMP r1,r0
JMP[NE] @ngp_d
MOVI r1,1
ngp_d:
RET

; ni_gtrim: drop trailing zero fraction digits unless '#' is set
ni_gtrim:
LD r1,r0,#W_PF_FLAGS
MOVI r2,3
BOOL.8 r1,r1,r2
CMP r1,r0
JMP[NE] @ngt_d
LD r2,r0,#W_F2P
ngt_l:
CMP r2,r0
JMP[EQ] @ngt_d
LD r1,r0,#W_F2F
MOVI r3,10
MODU r4,r1,r3
CMP r4,r0
JMP[NE] @ngt_d
DIVU r1,r1,r3
ST r1,r0,#W_F2F
SUB r2,r2,r13
ST r2,r0,#W_F2P
JMP @ngt_l
ngt_d:
RET

; ni_glen_fix: length of the fixed %g form
ni_glen_fix:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_F2NEG
ST r1,r0,#W_F2TMP
LD r1,r0,#W_F2I
CALL @ni_decdigits
LD r3,r0,#W_F2TMP
ADD r3,r3,r2
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nglf_d
ADD r3,r3,r1
ADD r3,r3,r13
nglf_d:
ST r3,r0,#W_PF_LEN
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_glen_exp: length of the scientific %g form
ni_glen_exp:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_F2NEG
ST r1,r0,#W_F2TMP
LD r1,r0,#W_F2I
CALL @ni_decdigits
LD r3,r0,#W_F2TMP
ADD r3,r3,r2
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @ngle_2
ADD r3,r3,r1
ADD r3,r3,r13
ngle_2:
ADD r3,r3,r13
ADD r3,r3,r13
LD r1,r0,#W_F2EXP
CMPS r1,r0
JMP[GE] @ngle_abs
SUB r1,r0,r1
ngle_abs:
CALL @ni_decdigits
MOVI r4,2
CMP r2,r4
JMP[GE] @ngle_3
MOVI r2,2
ngle_3:
ADD r3,r3,r2
ST r3,r0,#W_PF_LEN
SUB r14,r14,r13
LD r15,r14,0
RET

npf_float:
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
LD r2,r0,#W_PF_PREC
CALL @ni_fcalc
ST r3,r0,#W_PF_LEN
; zero padding takes precedence when the '-' flag is not set
LD r2,r0,#W_PF_FLAGS
MOVI r3,2
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[EQ] @npf_f_spacepad
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_f_spacepad
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CMP r2,r1
JMP[LE] @npf_f_emit
LD r4,r0,#W_F2NEG
CMP r4,r0
JMP[EQ] @npf_f_zero
MOVI r1,45
CALL @ncc_putc
ST r0,r0,#W_F2NEG
npf_f_zero:
LD r1,r0,#W_PF_W
LD r2,r0,#W_PF_LEN
SUB r1,r1,r2
MOVI r2,48
CALL @ni_pad
JMP @npf_f_emit
npf_f_spacepad:
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_f_emit
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
MOVI r3,32
CALL @ni_field_pre
npf_f_emit:
CALL @ni_femit
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv

; ni_fcalc: r1=float bits r2=precision -> r3=length; sets W_F2*
ni_fcalc:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_F2BIG
ST r1,r0,#W_F2V
ST r2,r0,#W_F2P
; large magnitudes use decimal scaling instead of int32 conversion
LD r5,r0,#W_F2V
LA r4,0x7FFFFFFF
BOOL.8 r5,r5,r4
LA r4,0x4F000000
FCMP r5,r4
JMP[LT] @nfc_norm
SUB r14,r14,r13
LD r15,r14,0
JMP @ni_fbig_calc
nfc_norm:
LA r4,0xFFFFFFFF
CMP r2,r4
JMP[NE] @nfc_have
MOVI r2,6
ST r2,r0,#W_F2P
nfc_have:
LD r2,r0,#W_F2P
MOVI r4,9
CMP r2,r4
JMP[LE] @nfc_ok
MOVI r2,9
ST r2,r0,#W_F2P
nfc_ok:
LD r5,r0,#W_F2V
LA r4,0x80000000
BOOL.8 r6,r5,r4
ST r0,r0,#W_F2NEG
CMP r6,r0
JMP[EQ] @nfc_pos
MOVI r6,1
ST r6,r0,#W_F2NEG
LA r4,0x7FFFFFFF
BOOL.8 r5,r5,r4
ST r5,r0,#W_F2V
nfc_pos:
MOVI r7,1
LD r3,r0,#W_F2P
nfc_sc:
CMP r3,r0
JMP[EQ] @nfc_scd
MOVI r4,10
MUL r7,r7,r4
SUB r3,r3,r13
JMP @nfc_sc
nfc_scd:
ST r7,r0,#W_F2S
CVTIF r8,r7
CVTFI r9,r5
ST r9,r0,#W_F2I
CVTIF r10,r9
FSUB r11,r5,r10
FMUL r11,r11,r8
LA r4,0x3F000000
FADD r11,r11,r4
CVTFI r11,r11
CMP r11,r7
JMP[LT] @nfc_nc
ADD r9,r9,r13
ST r9,r0,#W_F2I
SUB r11,r11,r7
nfc_nc:
ST r11,r0,#W_F2F
; length = sign + int digits + (p ? 1+p : 0)
LD r1,r0,#W_F2I
CALL @ni_decdigits
LD r3,r0,#W_F2NEG
ADD r3,r3,r2
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nfc_d
ADD r3,r3,r1
ADD r3,r3,r13
nfc_d:
ST r3,r0,#W_F2L
ADD r1,r3,r0
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_femit: print W_F2* fixed-point state
ni_femit:
ST r15,r14,0
ADD r14,r14,r13
LD r4,r0,#W_F2BIG
CMP r4,r0
JMP[EQ] @nfe_norm
SUB r14,r14,r13
LD r15,r14,0
JMP @ni_fbig_emit
nfe_norm:
LD r4,r0,#W_F2NEG
CMP r4,r0
JMP[EQ] @nfe_nosign
MOVI r1,45
CALL @ncc_putc
nfe_nosign:
LD r5,r0,#W_F2I
CALL @putudec
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nfe_d
MOVI r1,46
CALL @ncc_putc
LD r1,r0,#W_F2F
CALL @ni_decdigits
LD r1,r0,#W_F2P
SUB r1,r1,r2
CMP r1,r0
JMP[LE] @nfe_frac
MOVI r2,48
CALL @ni_pad
nfe_frac:
LD r5,r0,#W_F2F
CALL @putudec
nfe_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_big_pair: r1=abs float bits (<2^64) -> W_LLD pair, r2=digit length at LLFMT
ni_big_pair:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#R_SP
ST r1,r2,0
ADD r2,r2,r13
ST r2,r0,#R_SP
ST r0,r0,#W_LLS
CALL @ll_from_f
LD r2,r0,#R_SP
ADDI r2,r2,-2
LD r3,r2,0
LD r4,r2,1
ST r2,r0,#R_SP
ST r3,r0,#W_LLD0
ST r4,r0,#W_LLD1
MOVI r1,10
CALL @ll_fmt_base
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_fbig_calc: r1=float bits r2=precision -> r3=length (|v| >= 2^31)
ni_fbig_calc:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_F2V
ST r2,r0,#W_F2P
MOVI r1,1
ST r1,r0,#W_F2BIG
LA r4,0xFFFFFFFF
LD r2,r0,#W_F2P
CMP r2,r4
JMP[NE] @nfb_have
MOVI r2,6
ST r2,r0,#W_F2P
nfb_have:
LD r2,r0,#W_F2P
MOVI r4,9
CMP r2,r4
JMP[LE] @nfb_ok
MOVI r2,9
ST r2,r0,#W_F2P
nfb_ok:
LD r5,r0,#W_F2V
LA r4,0x80000000
BOOL.8 r6,r5,r4
ST r0,r0,#W_F2NEG
CMP r6,r0
JMP[EQ] @nfb_pos
MOVI r6,1
ST r6,r0,#W_F2NEG
LA r4,0x7FFFFFFF
BOOL.8 r5,r5,r4
ST r5,r0,#W_F2V
nfb_pos:
LD r5,r0,#W_F2V
LA r4,0x5F800000
FCMP r5,r4
JMP[GE] @nfb_scaled
ADD r1,r5,r0
CALL @ni_big_pair
ADD r1,r2,r0
JMP @nfb_have_d
nfb_scaled:
MOVI r1,1
LA r4,0x41200000
nfb_c:
FCMP r5,r4
JMP[LT] @nfb_cd
FDIV r5,r5,r4
ADD r1,r1,r13
JMP @nfb_c
nfb_cd:
nfb_have_d:
ST r1,r0,#W_F2I
ST r5,r0,#W_F2S
LD r3,r0,#W_F2NEG
ADD r3,r3,r1
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nfb_d
ADD r3,r3,r1
ADD r3,r3,r13
nfb_d:
ST r3,r0,#W_F2L
ADD r1,r3,r0
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_fbig_emit: print W_F2* fixed-point for large magnitudes
ni_fbig_emit:
ST r15,r14,0
ADD r14,r14,r13
LD r4,r0,#W_F2NEG
CMP r4,r0
JMP[EQ] @nfe_b_nosign
MOVI r1,45
CALL @ncc_putc
nfe_b_nosign:
LD r5,r0,#W_F2V
LA r4,0x5F800000
FCMP r5,r4
JMP[GE] @nfe_b_scaled
ADD r1,r5,r0
CALL @ni_big_pair
ST r2,r0,#W_F2L
LA r4,#LLFMT
MOVI r6,0
nfe_b_lll:
LD r1,r0,#W_F2L
CMP r6,r1
JMP[GE] @nfe_b_frac0
ADD r7,r4,r6
LDB r1,r7,0
CALL @ncc_putc
ADD r6,r6,r13
JMP @nfe_b_lll
nfe_b_scaled:
LD r6,r0,#W_F2I
LD r5,r0,#W_F2S
nfe_b_int:
CVTFI r7,r5
ADDI r1,r7,48
CALL @ncc_putc
ADDI r1,r7,48
CVTIF r8,r7
FSUB r5,r5,r8
LA r4,0x41200000
FMUL r5,r5,r4
SUB r6,r6,r13
CMP r6,r0
JMP[NE] @nfe_b_int
nfe_b_frac0:
LD r1,r0,#W_F2P
CMP r1,r0
JMP[EQ] @nfe_b_d
MOVI r1,46
CALL @ncc_putc
LD r6,r0,#W_F2P
nfe_b_frac:
MOVI r1,48
CALL @ncc_putc
SUB r6,r6,r13
CMP r6,r0
JMP[NE] @nfe_b_frac
nfe_b_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_putsn: r1=ptr r2=len
ni_putsn:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_F2V
ST r2,r0,#W_F2P
nps_l:
LD r2,r0,#W_F2P
CMP r2,r0
JMP[EQ] @nps_d
LD r1,r0,#W_F2V
LDB r1,r1,0
CALL @ncc_putc
LD r1,r0,#W_F2V
ADD r1,r1,r13
ST r1,r0,#W_F2V
LD r2,r0,#W_F2P
SUB r2,r2,r13
ST r2,r0,#W_F2P
JMP @nps_l
nps_d:
SUB r14,r14,r13
LD r15,r14,0
RET

npf_uint:
LD r1,r0,#W_PF_LL
CMP r1,r0
JMP[NE] @npf_ll_unsigned
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
LD r1,r0,#W_PF_LL
CMP r1,r0
JMP[NE] @npf_ll_hex
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
LD r1,r0,#W_PF_LSTR
CMP r1,r0
JMP[NE] @npf_lstr
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
CALL @ni_strlen
ST r1,r0,#W_PF_LEN
LA r2,0xFFFFFFFF
LD r1,r0,#W_PF_PREC
CMP r1,r2
JMP[EQ] @npf_s_noprec
LD r2,r0,#W_PF_LEN
CMP r1,r2
JMP[GE] @npf_s_noprec
ST r1,r0,#W_PF_LEN
npf_s_noprec:
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
LD r2,r0,#W_PF_LEN
CALL @ni_putsn
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
CALL @ni_field_tail
JMP @npf_adv
npf_lstr:
LD r1,r0,#W_PF_IDX
ADD r1,r1,r13
ST r1,r0,#W_PF_IDX
CALL @ni_arg
ST r1,r0,#W_PF_VAL
ST r0,r0,#W_PF_LEN
npf_ls_l:
LD r2,r0,#W_PF_PREC
LA r3,0xFFFFFFFF
CMP r2,r3
JMP[EQ] @npf_ls_load
LD r1,r0,#W_PF_LEN
CMP r1,r2
JMP[GE] @npf_ls_have
npf_ls_load:
LD r1,r0,#W_PF_VAL
LD r2,r0,#W_PF_LEN
SHL r2,r2,2
ADD r1,r1,r2
MOVI r2,#SZ_32
CALL @ni_loadv
CMP r1,r0
JMP[EQ] @npf_ls_have
LD r2,r0,#W_PF_LEN
ADD r2,r2,r13
ST r2,r0,#W_PF_LEN
JMP @npf_ls_l
npf_ls_have:
LD r2,r0,#W_PF_FLAGS
MOVI r3,1
BOOL.8 r2,r2,r3
CMP r2,r0
JMP[NE] @npf_ls_print
LD r1,r0,#W_PF_LEN
LD r2,r0,#W_PF_W
MOVI r3,32
CALL @ni_field_pre
npf_ls_print:
ST r0,r0,#W_PF_TMP
npf_ls_pl:
LD r1,r0,#W_PF_TMP
LD r2,r0,#W_PF_LEN
CMP r1,r2
JMP[GE] @npf_ls_tail
LD r3,r0,#W_PF_VAL
SHL r1,r1,2
ADD r1,r3,r1
MOVI r2,#SZ_32
CALL @ni_loadv
MOVI r2,255
BOOL.8 r1,r1,r2
CALL @ncc_putc
LD r1,r0,#W_PF_TMP
ADD r1,r1,r13
ST r1,r0,#W_PF_TMP
JMP @npf_ls_pl
npf_ls_tail:
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
LD r1,r0,#W_CALLWORDS
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

; ---- free-list C heap (4-byte aligned, coalescing) -----------------
; Header word: size_words | 0x80000000 when allocated.
; Block layout (word addresses): [header][payload...][footer].
; Free payload words 0/1 hold next/prev; minimum block = 4 words.
; The whole heap starts as one free block; ncc_run resets the allocator.

ni_heap_init:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_HEAP_INIT
CMP r1,r0
JMP[NE] @nhi_d
MOVI r1,1
ST r1,r0,#W_HEAP_INIT
LA r1,#C_HEAP
SHR r1,r1,2
LD r2,r0,#W_HEAP_LIMIT
CMP r2,r0
JMP[NE] @nhi_have
; start with 256 KiB and grow on demand up to C_HEAP_END
LA r2,0x7F98A0
ST r2,r0,#W_HEAP_LIMIT
nhi_have:
LD r3,r0,#W_HEAP_END
CMP r2,r3
JMP[LE] @nhi_clamp
ADD r2,r3,r0
ST r2,r0,#W_HEAP_LIMIT
nhi_clamp:
SHR r2,r2,2
SUB r2,r2,r1
CMP r2,r0
JMP[EQ] @nhi_empty
ST r2,r1,0
ADD r3,r1,r2
ADDI r3,r3,-1
ST r2,r3,0
ST r0,r1,1
ST r0,r1,2
ST r1,r0,#W_FREELIST
JMP @nhi_d
nhi_empty:
ST r0,r0,#W_FREELIST
nhi_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_heap_grow: extend the contiguous heap toward C_HEAP_END.
; r1 = requested words -> r1=1 if grown, 0 if full.
; The new tail is inserted as a free block; if the old tail is free,
; the two are merged. The C stack and N16T buffers are above C_HEAP_END.
ni_heap_grow:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ALLOC_NEED
LD r1,r0,#W_HEAP_LIMIT
CMP r1,r0
JMP[EQ] @nhg_no
LD r2,r0,#W_HEAP_END
CMP r1,r2
JMP[GE] @nhg_no
LA r3,0x40000
LD r4,r0,#W_ALLOC_NEED
SHL r4,r4,2
ADDI r4,r4,8
CMP r4,r3
JMP[LE] @nhg_use
ADD r3,r4,r0
nhg_use:
ADD r2,r1,r3
LD r5,r0,#W_HEAP_END
CMP r2,r5
JMP[LE] @nhg_fit
ADD r2,r5,r0
nhg_fit:
SUB r3,r2,r1
MOVI r4,16
CMP r3,r4
JMP[LT] @nhg_no
ST r2,r0,#W_HEAP_LIMIT
SHR r5,r1,2
SHR r6,r2,2
SUB r7,r6,r5
ST r5,r0,#W_ALLOC_OLD
ST r7,r0,#W_ALLOC_A
; If a free block ends exactly at the old limit, absorb it.
LD r1,r0,#W_FREELIST
nhg_scan:
CMP r1,r0
JMP[EQ] @nhg_new
LD r2,r1,0
ADD r3,r1,r2
LD r4,r0,#W_ALLOC_OLD
CMP r3,r4
JMP[EQ] @nhg_merge
LD r1,r1,1
JMP @nhg_scan
nhg_merge:
LD r4,r0,#W_ALLOC_A
ADD r7,r2,r4
ST r7,r0,#W_ALLOC_SIZE
ST r1,r0,#W_ALLOC_BLK
CALL @ni_fl_remove
LD r1,r0,#W_ALLOC_BLK
LD r7,r0,#W_ALLOC_SIZE
JMP @nhg_mark
nhg_new:
LD r1,r0,#W_ALLOC_OLD
LD r7,r0,#W_ALLOC_A
ST r7,r0,#W_ALLOC_SIZE
nhg_mark:
ST r7,r1,0
ADD r4,r1,r7
ADDI r4,r4,-1
ST r7,r4,0
ST r0,r1,1
ST r0,r1,2
CALL @ni_fl_insert
MOVI r1,1
JMP @nhg_d
nhg_no:
MOVI r1,0
nhg_d:
SUB r14,r14,r13
LD r15,r14,0
RET


ni_fl_insert:
LD r2,r0,#W_FREELIST
ST r2,r1,1
ST r0,r1,2
CMP r2,r0
JMP[EQ] @nfi_set
ST r1,r2,2
nfi_set:
ST r1,r0,#W_FREELIST
RET

; remove block r1 from the free list
ni_fl_remove:
LD r2,r1,1
LD r3,r1,2
CMP r3,r0
JMP[EQ] @nfr_head
ST r2,r3,1
JMP @nfr_next
nfr_head:
ST r2,r0,#W_FREELIST
nfr_next:
CMP r2,r0
JMP[EQ] @nfr_d
ST r3,r2,2
nfr_d:
RET

ni_malloc:
ST r15,r14,0
ADD r14,r14,r13
CMP r1,r0
JMP[EQ] @nm_zero
LA r2,0xFFFFFFF0
CMP r1,r2
JMP[GT] @nm_zero
ADDI r1,r1,3
SHR r1,r1,2
ADDI r1,r1,2
MOVI r2,4
CMP r1,r2
JMP[GE] @nm_min
ADD r1,r2,r0
nm_min:
ST r1,r0,#W_ALLOC_NEED
CALL @ni_heap_init
LD r2,r0,#W_FREELIST
nm_search:
CMP r2,r0
JMP[EQ] @nm_grow
LD r3,r2,0
LD r4,r0,#W_ALLOC_NEED
CMP r3,r4
JMP[GE] @nm_found
LD r2,r2,1
JMP @nm_search
nm_grow:
LD r1,r0,#W_ALLOC_NEED
CALL @ni_heap_grow
CMP r1,r0
JMP[EQ] @nm_zero
LD r2,r0,#W_FREELIST
JMP @nm_search
nm_found:
ST r2,r0,#W_ALLOC_BLK
ST r3,r0,#W_ALLOC_SIZE
ADD r1,r2,r0
CALL @ni_fl_remove
LD r1,r0,#W_ALLOC_SIZE
LD r2,r0,#W_ALLOC_NEED
SUB r5,r1,r2
MOVI r6,4
CMP r5,r6
JMP[LT] @nm_nosplit
; split: remainder at block+need
LD r2,r0,#W_ALLOC_BLK
LD r1,r0,#W_ALLOC_NEED
ADD r3,r2,r1
ST r5,r3,0
ADD r4,r3,r5
ADDI r4,r4,-1
ST r5,r4,0
ADD r1,r3,r0
CALL @ni_fl_insert
LD r2,r0,#W_ALLOC_BLK
LD r1,r0,#W_ALLOC_NEED
LA r4,0x80000000
BOOL.14 r5,r1,r4
ST r5,r2,0
ADD r4,r2,r1
ADDI r4,r4,-1
ST r1,r4,0
JMP @nm_ret
nm_nosplit:
LD r2,r0,#W_ALLOC_BLK
LD r1,r0,#W_ALLOC_SIZE
LA r4,0x80000000
BOOL.14 r5,r1,r4
ST r5,r2,0
ADD r4,r2,r1
ADDI r4,r4,-1
ST r1,r4,0
nm_ret:
LD r1,r0,#W_ALLOC_BLK
SHL r1,r1,2
ADDI r1,r1,4
JMP @nm_d
nm_zero:
MOVI r1,0
nm_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_malloc_aligned: r1=size bytes, r2=alignment bytes -> r1=aligned payload or 0
; Reserves size+align+8, then stores the raw pointer at p-4 and a magic at
; p-8 so ni_free can recover the real block. ncc's realloc always moves.
ni_malloc_aligned:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#W_ALIGN
MOVI r3,4
CMP r2,r3
JMP[GE] @nma_min
ADD r2,r3,r0
nma_min:
; power-of-two check: align & (align-1) == 0
SUB r3,r2,r13
BOOL.8 r3,r2,r3
CMP r3,r0
JMP[NE] @nma_bad
LA r3,0xFFFFFF00
CMP r1,r3
JMP[GT] @nma_bad
ADD r1,r1,r2
ADDI r1,r1,8
CALL @ni_malloc
CMP r1,r0
JMP[EQ] @nma_bad
LD r2,r0,#W_ALIGN
ADD r3,r1,r2
ADDI r3,r3,7
SUB r4,r0,r2
BOOL.8 r3,r3,r4
ADDI r4,r1,8
CMP r3,r4
JMP[GE] @nma_ok
ADD r3,r4,r0
nma_ok:
SHR r5,r3,2
ST r1,r5,-1
LA r6,0xA11C0DE5
ST r6,r5,-2
ADD r1,r3,r0
JMP @nma_d
nma_bad:
MOVI r1,0
nma_d:
SUB r14,r14,r13
LD r15,r14,0
RET

ni_free:
ST r15,r14,0
ADD r14,r14,r13
CMP r1,r0
JMP[EQ] @nf_d
SHR r4,r1,2
ADDI r5,r4,-2
LD r6,r5,0
LA r7,0xA11C0DE5
CMP r6,r7
JMP[NE] @nf_plain
ADDI r5,r4,-1
LD r1,r5,0
CMP r1,r0
JMP[EQ] @nf_d
nf_plain:
SHR r1,r1,2
ADDI r1,r1,-1
LD r2,r1,0
LA r3,0x80000000
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[EQ] @nf_d
LA r3,0x7FFFFFFF
BOOL.8 r2,r2,r3
ST r1,r0,#W_ALLOC_BLK
ST r2,r0,#W_ALLOC_SIZE
ST r2,r1,0
ADD r3,r1,r2
ADDI r3,r3,-1
ST r2,r3,0
; coalesce with the previous block (unless this is the heap start)
LA r4,#C_HEAP
SHR r4,r4,2
CMP r1,r4
JMP[LE] @nf_next
ADDI r4,r1,-1
LD r5,r4,0
CMP r5,r0
JMP[EQ] @nf_next
SUB r6,r1,r5
LD r7,r6,0
LA r8,0x80000000
BOOL.8 r9,r7,r8
CMP r9,r0
JMP[NE] @nf_next
ADD r1,r6,r0
CALL @ni_fl_remove
LD r2,r0,#W_ALLOC_SIZE
ADD r2,r2,r5
ST r2,r0,#W_ALLOC_SIZE
ST r6,r0,#W_ALLOC_BLK
nf_next:
LD r1,r0,#W_ALLOC_BLK
LD r2,r0,#W_ALLOC_SIZE
nf_mark:
ST r2,r1,0
ADD r3,r1,r2
ADDI r3,r3,-1
ST r2,r3,0
ADD r4,r1,r2
LD r5,r0,#W_HEAP_LIMIT
SHR r5,r5,2
CMP r4,r5
JMP[GE] @nf_insert
LD r5,r4,0
LA r6,0x80000000
BOOL.8 r7,r5,r6
CMP r7,r0
JMP[NE] @nf_insert
ST r5,r0,#W_ALLOC_A
ADD r1,r4,r0
CALL @ni_fl_remove
LD r1,r0,#W_ALLOC_BLK
LD r2,r0,#W_ALLOC_SIZE
LD r5,r0,#W_ALLOC_A
ADD r2,r2,r5
ST r2,r0,#W_ALLOC_SIZE
ST r2,r1,0
ADD r3,r1,r2
ADDI r3,r3,-1
ST r2,r3,0
nf_insert:
LD r1,r0,#W_ALLOC_BLK
CALL @ni_fl_insert
nf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

ni_calloc:
; r1=n r2=size
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ALLOC_A
ST r2,r0,#W_ALLOC_B
MUL r3,r1,r2
MULHU r4,r1,r2
CMP r4,r0
JMP[NE] @nc_zero
ADD r1,r3,r0
CALL @ni_malloc
CMP r1,r0
JMP[EQ] @nc_d
ST r1,r0,#W_ALLOC_NEW
LD r2,r0,#W_ALLOC_A
LD r3,r0,#W_ALLOC_B
MUL r3,r2,r3
MOVI r2,0
CALL @ni_memset_raw
LD r1,r0,#W_ALLOC_NEW
JMP @nc_d
nc_zero:
MOVI r1,0
nc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

ni_realloc:
; r1=oldptr r2=newsize. Always move: malloc, copy the old payload, free.
ST r15,r14,0
ADD r14,r14,r13
CMP r1,r0
JMP[NE] @nr_old
ADD r1,r2,r0
CALL @ni_malloc
JMP @nr_d
nr_old:
CMP r2,r0
JMP[NE] @nr_need
CALL @ni_free
MOVI r1,0
JMP @nr_d
nr_need:
ST r1,r0,#W_ALLOC_OLD
ST r2,r0,#W_ALLOC_B
SHR r3,r1,2
ADDI r3,r3,-1
LD r4,r3,0
LA r5,0x7FFFFFFF
BOOL.8 r4,r4,r5
ADDI r6,r4,-2
SHL r6,r6,2
ST r6,r0,#W_ALLOC_A
LD r1,r0,#W_ALLOC_B
CALL @ni_malloc
CMP r1,r0
JMP[EQ] @nr_zero
ST r1,r0,#W_ALLOC_NEW
LD r3,r0,#W_ALLOC_A
LD r4,r0,#W_ALLOC_B
CMP r3,r4
JMP[LE] @nr_cp
ADD r3,r4,r0
nr_cp:
LD r1,r0,#W_ALLOC_NEW
LD r2,r0,#W_ALLOC_OLD
CALL @ni_memcpy_raw
LD r1,r0,#W_ALLOC_OLD
CALL @ni_free
LD r1,r0,#W_ALLOC_NEW
JMP @nr_d
nr_zero:
MOVI r1,0
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
SUB[LT] r1,r0,r13
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
SUB[LT] r1,r0,r13
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
SUB[LT] r1,r0,r13
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
MOVI r2,#B_SQRT
CMP r1,r2
JMP[EQ] @nbi_sqrt
MOVI r2,#B_FABS
CMP r1,r2
JMP[EQ] @nbi_fabs
MOVI r2,#B_POW
CMP r1,r2
JMP[EQ] @nbi_pow
MOVI r2,#B_EXP
CMP r1,r2
JMP[EQ] @nbi_exp
MOVI r2,#B_LOG
CMP r1,r2
JMP[EQ] @nbi_log
MOVI r2,#B_LOG10
CMP r1,r2
JMP[EQ] @nbi_log10
MOVI r2,#B_TANH
CMP r1,r2
JMP[EQ] @nbi_tanh
MOVI r2,#B_FLOOR
CMP r1,r2
JMP[EQ] @nbi_floor
MOVI r2,#B_CEIL
CMP r1,r2
JMP[EQ] @nbi_ceil
MOVI r2,#B_FMOD
CMP r1,r2
JMP[EQ] @nbi_fmod
MOVI r2,#B_FMIN
CMP r1,r2
JMP[EQ] @nbi_fmin
MOVI r2,#B_FMAX
CMP r1,r2
JMP[EQ] @nbi_fmax
MOVI r2,#B_TAN
CMP r1,r2
JMP[EQ] @nbi_tan
MOVI r2,#B_STRCHR
CMP r1,r2
JMP[EQ] @nbi_strchr
MOVI r2,#B_STRSTR
CMP r1,r2
JMP[EQ] @nbi_strstr
MOVI r2,#B_STRDUP
CMP r1,r2
JMP[EQ] @nbi_strdup
MOVI r2,#B_ISDIGIT
CMP r1,r2
JMP[EQ] @nbi_isdigit
MOVI r2,#B_ISALPHA
CMP r1,r2
JMP[EQ] @nbi_isalpha
MOVI r2,#B_ISSPACE
CMP r1,r2
JMP[EQ] @nbi_isspace
MOVI r2,#B_ISUPPER
CMP r1,r2
JMP[EQ] @nbi_isupper
MOVI r2,#B_ISLOWER
CMP r1,r2
JMP[EQ] @nbi_islower
MOVI r2,#B_TOUPPER
CMP r1,r2
JMP[EQ] @nbi_toupper
MOVI r2,#B_TOLOWER
CMP r1,r2
JMP[EQ] @nbi_tolower
MOVI r2,#B_RAND
CMP r1,r2
JMP[EQ] @nbi_rand
MOVI r2,#B_SRAND
CMP r1,r2
JMP[EQ] @nbi_srand
MOVI r2,#B_LABS
CMP r1,r2
JMP[EQ] @nbi_labs
MOVI r2,#B_MEMMOVE
CMP r1,r2
JMP[EQ] @nbi_memmove
MOVI r2,#B_SPRINTF
CMP r1,r2
JMP[EQ] @nbi_sprintf
MOVI r2,#B_SNPRINTF
CMP r1,r2
JMP[EQ] @nbi_snprintf
MOVI r2,#B_TIME
CMP r1,r2
JMP[EQ] @nbi_time
MOVI r2,#B_CLOCK
CMP r1,r2
JMP[EQ] @nbi_clock
MOVI r2,#B_DIFFTIME
CMP r1,r2
JMP[EQ] @nbi_difftime
MOVI r2,#B_MKTIME
CMP r1,r2
JMP[EQ] @nbi_mktime
MOVI r2,#B_LOCALTIME
CMP r1,r2
JMP[EQ] @nbi_localtime
MOVI r2,#B_GMTIME
CMP r1,r2
JMP[EQ] @nbi_gmtime
MOVI r2,#B_ASCTIME
CMP r1,r2
JMP[EQ] @nbi_asctime
MOVI r2,#B_CTIME
CMP r1,r2
JMP[EQ] @nbi_ctime
MOVI r2,#B_SETLOCALE
CMP r1,r2
JMP[EQ] @nbi_setlocale
MOVI r2,#B_LOCALECONV
CMP r1,r2
JMP[EQ] @nbi_localeconv
MOVI r2,#B_SIGNAL
CMP r1,r2
JMP[EQ] @nbi_signal
MOVI r2,#B_RAISE
CMP r1,r2
JMP[EQ] @nbi_raise
MOVI r2,#B_ATOF
CMP r1,r2
JMP[EQ] @nbi_atof
MOVI r2,#B_STRTOD
CMP r1,r2
JMP[EQ] @nbi_strtod
MOVI r2,#B_FOPEN
CMP r1,r2
JMP[EQ] @nbi_fopen
MOVI r2,#B_FCLOSE
CMP r1,r2
JMP[EQ] @nbi_fclose
MOVI r2,#B_FGETC
CMP r1,r2
JMP[EQ] @nbi_fgetc
MOVI r2,#B_FPUTC
CMP r1,r2
JMP[EQ] @nbi_fputc
MOVI r2,#B_FGETS
CMP r1,r2
JMP[EQ] @nbi_fgets
MOVI r2,#B_GETCHAR
CMP r1,r2
JMP[EQ] @nbi_getchar
MOVI r2,#B_GETC
CMP r1,r2
JMP[EQ] @nbi_getc
MOVI r2,#B_UNGETC
CMP r1,r2
JMP[EQ] @nbi_ungetc
MOVI r2,#B_PUTC
CMP r1,r2
JMP[EQ] @nbi_putc2
MOVI r2,#B_CLEARERR
CMP r1,r2
JMP[EQ] @nbi_clearerr
MOVI r2,#B_SETVBUF
CMP r1,r2
JMP[EQ] @nbi_setvbuf
MOVI r2,#B_VPRINTF
CMP r1,r2
JMP[EQ] @nbi_vprintf
MOVI r2,#B_VFPRINTF
CMP r1,r2
JMP[EQ] @nbi_vfprintf
MOVI r2,#B_VSPRINTF
CMP r1,r2
JMP[EQ] @nbi_vsprintf
MOVI r2,#B_VSNPRINTF
CMP r1,r2
JMP[EQ] @nbi_vsnprintf
MOVI r2,#B_ISALNUM
CMP r1,r2
JMP[EQ] @nbi_isalnum
MOVI r2,#B_ISCNTRL
CMP r1,r2
JMP[EQ] @nbi_iscntrl
MOVI r2,#B_ISGRAPH
CMP r1,r2
JMP[EQ] @nbi_isgraph
MOVI r2,#B_ISPRINT
CMP r1,r2
JMP[EQ] @nbi_isprint
MOVI r2,#B_ISPUNCT
CMP r1,r2
JMP[EQ] @nbi_ispunct
MOVI r2,#B_ISXDIGIT
CMP r1,r2
JMP[EQ] @nbi_isxdigit
MOVI r2,#B_ATOL
CMP r1,r2
JMP[EQ] @nbi_atol
MOVI r2,#B_ATOLL
CMP r1,r2
JMP[EQ] @nbi_atoll
MOVI r2,#B_ABORT
CMP r1,r2
JMP[EQ] @nbi_abort
MOVI r2,#B_SETBUF
CMP r1,r2
JMP[EQ] @nbi_setvbuf
MOVI r2,#B_WCSCHR
CMP r1,r2
JMP[EQ] @nbi_wcschr
MOVI r2,#B_WCSRCHR
CMP r1,r2
JMP[EQ] @nbi_wcsrchr
MOVI r2,#B_WCSNCMP
CMP r1,r2
JMP[EQ] @nbi_wcsncmp
MOVI r2,#B_WCSNCPY
CMP r1,r2
JMP[EQ] @nbi_wcsncpy
MOVI r2,#B_WCSNCAT
CMP r1,r2
JMP[EQ] @nbi_wcsncat
MOVI r2,#B_WCSSPN
CMP r1,r2
JMP[EQ] @nbi_wcsspn
MOVI r2,#B_WCSCSPN
CMP r1,r2
JMP[EQ] @nbi_wcscspn
MOVI r2,#B_WCSPBRK
CMP r1,r2
JMP[EQ] @nbi_wcspbrk
MOVI r2,#B_WCSSTR
CMP r1,r2
JMP[EQ] @nbi_wcsstr
MOVI r2,#B_WCSTOK
CMP r1,r2
JMP[EQ] @nbi_wcstok
MOVI r2,#B_WMEMCHR
CMP r1,r2
JMP[EQ] @nbi_wmemchr
MOVI r2,#B_WMEMCMP
CMP r1,r2
JMP[EQ] @nbi_wmemcmp
MOVI r2,#B_WMEMCPY
CMP r1,r2
JMP[EQ] @nbi_wmemcpy
MOVI r2,#B_WMEMMOVE
CMP r1,r2
JMP[EQ] @nbi_wmemmove
MOVI r2,#B_WMEMSET
CMP r1,r2
JMP[EQ] @nbi_wmemset
MOVI r2,#B_BTOWC
CMP r1,r2
JMP[EQ] @nbi_btowc
MOVI r2,#B_WCTOB
CMP r1,r2
JMP[EQ] @nbi_wctob
MOVI r2,#B_MBLEN
CMP r1,r2
JMP[EQ] @nbi_mblen
MOVI r2,#B_MBTOWC
CMP r1,r2
JMP[EQ] @nbi_mbtowc
MOVI r2,#B_WCTOMB
CMP r1,r2
JMP[EQ] @nbi_wctomb
MOVI r2,#B_MBSTOWCS
CMP r1,r2
JMP[EQ] @nbi_mbstowcs
MOVI r2,#B_WCSTOMBS
CMP r1,r2
JMP[EQ] @nbi_wcstombs
MOVI r2,#B_EXP2
CMP r1,r2
JMP[EQ] @nbi_exp2
MOVI r2,#B_LOG2
CMP r1,r2
JMP[EQ] @nbi_log2
MOVI r2,#B_LOG1P
CMP r1,r2
JMP[EQ] @nbi_log1p
MOVI r2,#B_EXPM1
CMP r1,r2
JMP[EQ] @nbi_expm1
MOVI r2,#B_HYPOT
CMP r1,r2
JMP[EQ] @nbi_hypot
MOVI r2,#B_CBRT
CMP r1,r2
JMP[EQ] @nbi_cbrt
MOVI r2,#B_SINH
CMP r1,r2
JMP[EQ] @nbi_sinh
MOVI r2,#B_COSH
CMP r1,r2
JMP[EQ] @nbi_cosh
MOVI r2,#B_ASINH
CMP r1,r2
JMP[EQ] @nbi_asinh
MOVI r2,#B_ACOSH
CMP r1,r2
JMP[EQ] @nbi_acosh
MOVI r2,#B_ATANH
CMP r1,r2
JMP[EQ] @nbi_atanh
MOVI r2,#B_TRUNC
CMP r1,r2
JMP[EQ] @nbi_trunc
MOVI r2,#B_ROUND
CMP r1,r2
JMP[EQ] @nbi_round
MOVI r2,#B_RINT
CMP r1,r2
JMP[EQ] @nbi_rint
MOVI r2,#B_NEARBYINT
CMP r1,r2
JMP[EQ] @nbi_nearbyint
MOVI r2,#B_COPYSIGN
CMP r1,r2
JMP[EQ] @nbi_copysign
MOVI r2,#B_NAN
CMP r1,r2
JMP[EQ] @nbi_nan
MOVI r2,#B_FDIM
CMP r1,r2
JMP[EQ] @nbi_fdim
MOVI r2,#B_FMA
CMP r1,r2
JMP[EQ] @nbi_fma
MOVI r2,#B_DP4B
CMP r1,r2
JMP[EQ] @nbi_dp4b
MOVI r2,#B_ALIGNED_ALLOC
CMP r1,r2
JMP[EQ] @nbi_aligned_alloc
MOVI r2,#B_MODF
CMP r1,r2
JMP[EQ] @nbi_modf
MOVI r2,#B_LDEXP
CMP r1,r2
JMP[EQ] @nbi_ldexp
MOVI r2,#B_SCALBN
CMP r1,r2
JMP[EQ] @nbi_scalbn
MOVI r2,#B_REMAINDER
CMP r1,r2
JMP[EQ] @nbi_remainder
MOVI r2,#B_ATAN
CMP r1,r2
JMP[EQ] @nbi_atan
MOVI r2,#B_ATAN2
CMP r1,r2
JMP[EQ] @nbi_atan2
MOVI r2,#B_ASIN
CMP r1,r2
JMP[EQ] @nbi_asin
MOVI r2,#B_ACOS
CMP r1,r2
JMP[EQ] @nbi_acos
MOVI r2,#B_ATEXIT
CMP r1,r2
JMP[EQ] @nbi_atexit
MOVI r2,#B__EXIT
CMP r1,r2
JMP[EQ] @nbi__exit
MOVI r2,#B_VSCANF
CMP r1,r2
JMP[EQ] @nbi_vscanf
MOVI r2,#B_VFSCANF
CMP r1,r2
JMP[EQ] @nbi_vfscanf
MOVI r2,#B_VSSCANF
CMP r1,r2
JMP[EQ] @nbi_vsscanf
MOVI r2,#B_FGETPOS
CMP r1,r2
JMP[EQ] @nbi_fgetpos
MOVI r2,#B_FSETPOS
CMP r1,r2
JMP[EQ] @nbi_fsetpos
MOVI r2,#B_FREOPEN
CMP r1,r2
JMP[EQ] @nbi_freopen
MOVI r2,#B_FREXP
CMP r1,r2
JMP[EQ] @nbi_frexp
MOVI r2,#B_NEXTAFTER
CMP r1,r2
JMP[EQ] @nbi_nextafter
MOVI r2,#B_WCSTOL
CMP r1,r2
JMP[EQ] @nbi_wcstol
MOVI r2,#B_WCSTOUL
CMP r1,r2
JMP[EQ] @nbi_wcstoul
MOVI r2,#B_WCSTOLL
CMP r1,r2
JMP[EQ] @nbi_wcstoll
MOVI r2,#B_WCSTOULL
CMP r1,r2
JMP[EQ] @nbi_wcstoull
MOVI r2,#B_WCSTOD
CMP r1,r2
JMP[EQ] @nbi_wcstod
MOVI r2,#B_WCSTOF
CMP r1,r2
JMP[EQ] @nbi_wcstof
MOVI r2,#B_WCSTOLD
CMP r1,r2
JMP[EQ] @nbi_wcstold
MOVI r2,#B_WCSCOLL
CMP r1,r2
JMP[EQ] @nbi_wcscoll
MOVI r2,#B_WCSXFRM
CMP r1,r2
JMP[EQ] @nbi_wcsxfrm
MOVI r2,#B_ERF
CMP r1,r2
JMP[EQ] @nbi_erf
MOVI r2,#B_ERFC
CMP r1,r2
JMP[EQ] @nbi_erfc
MOVI r2,#B_TGAMMA
CMP r1,r2
JMP[EQ] @nbi_tgamma
MOVI r2,#B_LGAMMA
CMP r1,r2
JMP[EQ] @nbi_lgamma
MOVI r2,#B_IFVER
CMP r1,r2
JMP[EQ] @nbi_iface_version
MOVI r2,#B_DIV
CMP r1,r2
JMP[EQ] @nbi_div
MOVI r2,#B_LDIV
CMP r1,r2
JMP[EQ] @nbi_div
MOVI r2,#B_LLDIV
CMP r1,r2
JMP[EQ] @nbi_lldiv
MOVI r2,#B_SETITIMER
CMP r1,r2
JMP[EQ] @nbi_setitimer
MOVI r2,#B_GETITIMER
CMP r1,r2
JMP[EQ] @nbi_getitimer
MOVI r2,#B_STRTOF
CMP r1,r2
JMP[EQ] @nbi_strtod
MOVI r2,#B_STRTOLD
CMP r1,r2
JMP[EQ] @nbi_strtod
MOVI r2,#B_LLABS
CMP r1,r2
JMP[EQ] @nbi_llabs
MOVI r2,#B_STRNCAT
CMP r1,r2
JMP[EQ] @nbi_strncat
MOVI r2,#B_REMQUO
CMP r1,r2
JMP[EQ] @nbi_remquo
MOVI r2,#B_MBSINIT
CMP r1,r2
JMP[EQ] @nbi_mbsinit
MOVI r2,#B_MBRLEN
CMP r1,r2
JMP[EQ] @nbi_mbrlen
MOVI r2,#B_MBRTOWC
CMP r1,r2
JMP[EQ] @nbi_mbrtowc
MOVI r2,#B_WCRTOMB
CMP r1,r2
JMP[EQ] @nbi_wcrtomb
MOVI r2,#B_MBSRTOWCS
CMP r1,r2
JMP[EQ] @nbi_mbsrtowcs
MOVI r2,#B_WCSRTOMBS
CMP r1,r2
JMP[EQ] @nbi_wcsrtombs
MOVI r2,#B_WCTYPE
CMP r1,r2
JMP[EQ] @nbi_wctype
MOVI r2,#B_ISWCTYPE
CMP r1,r2
JMP[EQ] @nbi_iswctype
MOVI r2,#B_WCTRANS
CMP r1,r2
JMP[EQ] @nbi_wctrans
MOVI r2,#B_TOWCTRANS
CMP r1,r2
JMP[EQ] @nbi_towctrans
MOVI r2,#B_ASSERT
CMP r1,r2
JMP[EQ] @nbi_assert
MOVI r2,#B_FWIDE
CMP r1,r2
JMP[EQ] @nbi_fwide


MOVI r2,#B_FPUTS
CMP r1,r2
JMP[EQ] @nbi_fputs
MOVI r2,#B_FREAD
CMP r1,r2
JMP[EQ] @nbi_fread
MOVI r2,#B_FWRITE
CMP r1,r2
JMP[EQ] @nbi_fwrite
MOVI r2,#B_FPRINTF
CMP r1,r2
JMP[EQ] @nbi_fprintf
MOVI r2,#B_FSEEK
CMP r1,r2
JMP[EQ] @nbi_fseek
MOVI r2,#B_FTELL
CMP r1,r2
JMP[EQ] @nbi_ftell
MOVI r2,#B_REWIND
CMP r1,r2
JMP[EQ] @nbi_rewind
MOVI r2,#B_FEOF
CMP r1,r2
JMP[EQ] @nbi_feof
MOVI r2,#B_FERROR
CMP r1,r2
JMP[EQ] @nbi_ferror
MOVI r2,#B_FFLUSH
CMP r1,r2
JMP[EQ] @nbi_fflush
MOVI r2,#B_REMOVE
CMP r1,r2
JMP[EQ] @nbi_remove
MOVI r2,#B_RENAME
CMP r1,r2
JMP[EQ] @nbi_rename
MOVI r2,#B_SCANF
CMP r1,r2
JMP[EQ] @nbi_scanf
MOVI r2,#B_FSCANF
CMP r1,r2
JMP[EQ] @nbi_fscanf
MOVI r2,#B_SSCANF
CMP r1,r2
JMP[EQ] @nbi_sscanf
MOVI r2,#B_EXIT
CMP r1,r2
JMP[EQ] @nbi_exit
MOVI r2,#B_QSORT
CMP r1,r2
JMP[EQ] @nbi_qsort
MOVI r2,#B_BSEARCH
CMP r1,r2
JMP[EQ] @nbi_bsearch
MOVI r2,#B_SETJMP
CMP r1,r2
JMP[EQ] @nbi_setjmp
MOVI r2,#B_LONGJMP
CMP r1,r2
JMP[EQ] @nbi_longjmp
MOVI r2,#B_STRFTIME
CMP r1,r2
JMP[EQ] @nbi_strftime
MOVI r2,#B_TMPNAM
CMP r1,r2
JMP[EQ] @nbi_tmpnam
MOVI r2,#B_TMPFILE
CMP r1,r2
JMP[EQ] @nbi_tmpfile
MOVI r2,#B_WCSLEN
CMP r1,r2
JMP[EQ] @nbi_wcslen
MOVI r2,#B_WCSCMP
CMP r1,r2
JMP[EQ] @nbi_wcscmp
MOVI r2,#B_WCSCPY
CMP r1,r2
JMP[EQ] @nbi_wcscpy
MOVI r2,#B_WCSCAT
CMP r1,r2
JMP[EQ] @nbi_wcscat
MOVI r2,#B_ALARM
CMP r1,r2
JMP[EQ] @nbi_alarm
MOVI r2,#B_STRSPN
CMP r1,r2
JMP[EQ] @nbi_strspn
MOVI r2,#B_STRCSPN
CMP r1,r2
JMP[EQ] @nbi_strcspn
MOVI r2,#B_STRPBRK
CMP r1,r2
JMP[EQ] @nbi_strpbrk
MOVI r2,#B_STRTOK
CMP r1,r2
JMP[EQ] @nbi_strtok
MOVI r2,#B_GETENV
CMP r1,r2
JMP[EQ] @nbi_getenv
MOVI r2,#B_SYSTEM
CMP r1,r2
JMP[EQ] @nbi_system
MOVI r2,#B_MEMCHR
CMP r1,r2
JMP[EQ] @nbi_memchr
MOVI r2,#B_STRCOLL
CMP r1,r2
JMP[EQ] @nbi_strcoll
MOVI r2,#B_STRXFRM
CMP r1,r2
JMP[EQ] @nbi_strxfrm
MOVI r2,#B_STRERROR
CMP r1,r2
JMP[EQ] @nbi_strerror
MOVI r2,#B_PERROR
CMP r1,r2
JMP[EQ] @nbi_perror
MOVI r2,#B_WPRINTF
CMP r1,r2
JMP[EQ] @nbi_wprintf
MOVI r2,#B_WSCANF
CMP r1,r2
JMP[EQ] @nbi_wscanf
MOVI r2,#B_MBRTOC16
CMP r1,r2
JMP[EQ] @nbi_mbrtoc16
MOVI r2,#B_C16RTOMB
CMP r1,r2
JMP[EQ] @nbi_c16rtomb
MOVI r2,#B_MBRTOC32
CMP r1,r2
JMP[EQ] @nbi_mbrtoc32
MOVI r2,#B_C32RTOMB
CMP r1,r2
JMP[EQ] @nbi_c32rtomb
MOVI r2,#B_FWPRINTF
CMP r1,r2
JMP[EQ] @nbi_fwprintf
MOVI r2,#B_FWSCANF
CMP r1,r2
JMP[EQ] @nbi_fwscanf
MOVI r2,#B_SWPRINTF
CMP r1,r2
JMP[EQ] @nbi_swprintf
MOVI r2,#B_SWSCANF
CMP r1,r2
JMP[EQ] @nbi_swscanf
MOVI r2,#B_ATOMIC_INIT
CMP r1,r2
JMP[EQ] @nbi_atomic_init
MOVI r2,#B_ATOMIC_LOAD
CMP r1,r2
JMP[EQ] @nbi_atomic_load
MOVI r2,#B_ATOMIC_STORE
CMP r1,r2
JMP[EQ] @nbi_atomic_store
MOVI r2,#B_ATOMIC_EXCH
CMP r1,r2
JMP[EQ] @nbi_atomic_exch
MOVI r2,#B_ATOMIC_CAS
CMP r1,r2
JMP[EQ] @nbi_atomic_cas
MOVI r2,#B_ATOMIC_FADD
CMP r1,r2
JMP[EQ] @nbi_atomic_fadd
MOVI r2,#B_ATOMIC_FSUB
CMP r1,r2
JMP[EQ] @nbi_atomic_fsub
MOVI r2,#B_ATOMIC_FOR
CMP r1,r2
JMP[EQ] @nbi_atomic_for
MOVI r2,#B_ATOMIC_FXOR
CMP r1,r2
JMP[EQ] @nbi_atomic_fxor
MOVI r2,#B_ATOMIC_FAND
CMP r1,r2
JMP[EQ] @nbi_atomic_fand
MOVI r2,#B_ATOMIC_FLAG_TAS
CMP r1,r2
JMP[EQ] @nbi_atomic_flag_tas
MOVI r2,#B_ATOMIC_FLAG_CLR
CMP r1,r2
JMP[EQ] @nbi_atomic_flag_clr
MOVI r2,#B_ATOMIC_FENCE
CMP r1,r2
JMP[EQ] @nbi_atomic_fence
MOVI r2,#B_ATOMIC_ISLF
CMP r1,r2
JMP[EQ] @nbi_atomic_islf
MOVI r2,#B_ATOMIC_LOAD_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_load_ex
MOVI r2,#B_ATOMIC_STORE_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_store_ex
MOVI r2,#B_ATOMIC_EXCH_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_exch_ex
MOVI r2,#B_ATOMIC_CAS_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_cas_ex
MOVI r2,#B_ATOMIC_FADD_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_fadd_ex
MOVI r2,#B_ATOMIC_FSUB_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_fsub_ex
MOVI r2,#B_ATOMIC_FOR_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_for_ex
MOVI r2,#B_ATOMIC_FXOR_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_fxor_ex
MOVI r2,#B_ATOMIC_FAND_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_fand_ex
MOVI r2,#B_ATOMIC_FLAG_TAS_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_flag_tas_ex
MOVI r2,#B_ATOMIC_FLAG_CLR_EX
CMP r1,r2
JMP[EQ] @nbi_atomic_flag_clr_ex
MOVI r2,#B_FEGETROUND
CMP r1,r2
JMP[EQ] @nbi_fegetround
MOVI r2,#B_FESETROUND
CMP r1,r2
JMP[EQ] @nbi_fesetround
MOVI r2,#B_FECLEAREXCEPT
CMP r1,r2
JMP[EQ] @nbi_feclearexcept
MOVI r2,#B_FERAISEEXCEPT
CMP r1,r2
JMP[EQ] @nbi_feraiseexcept
MOVI r2,#B_FETESTEXCEPT
CMP r1,r2
JMP[EQ] @nbi_fetestexcept
MOVI r2,#B_FEGETENV
CMP r1,r2
JMP[EQ] @nbi_fegetenv
MOVI r2,#B_FESETENV
CMP r1,r2
JMP[EQ] @nbi_fesetenv
MOVI r2,#B_FEHOLDEXCEPT
CMP r1,r2
JMP[EQ] @nbi_feholdexcept
MOVI r2,#B_FEUPDATEENV
CMP r1,r2
JMP[EQ] @nbi_feupdateenv
MOVI r2,#B_FEGETEXCEPTFLAG
CMP r1,r2
JMP[EQ] @nbi_fegetexceptflag
MOVI r2,#B_FESETEXCEPTFLAG
CMP r1,r2
JMP[EQ] @nbi_fesetexceptflag
MOVI r2,#B_THRD_CREATE
CMP r1,r2
JMP[EQ] @nbi_thrd_create
MOVI r2,#B_THRD_JOIN
CMP r1,r2
JMP[EQ] @nbi_thrd_join
MOVI r2,#B_THRD_CURRENT
CMP r1,r2
JMP[EQ] @nbi_thrd_current
MOVI r2,#B_THRD_EQUAL
CMP r1,r2
JMP[EQ] @nbi_thrd_equal
MOVI r2,#B_THRD_SLEEP
CMP r1,r2
JMP[EQ] @nbi_thrd_sleep
MOVI r2,#B_THRD_YIELD
CMP r1,r2
JMP[EQ] @nbi_thrd_yield
MOVI r2,#B_THRD_EXIT
CMP r1,r2
JMP[EQ] @nbi_thrd_exit
MOVI r2,#B_THRD_DETACH
CMP r1,r2
JMP[EQ] @nbi_thrd_detach
MOVI r2,#B_MTX_INIT
CMP r1,r2
JMP[EQ] @nbi_mtx_init
MOVI r2,#B_MTX_LOCK
CMP r1,r2
JMP[EQ] @nbi_mtx_lock
MOVI r2,#B_MTX_TRYLOCK
CMP r1,r2
JMP[EQ] @nbi_mtx_trylock
MOVI r2,#B_MTX_TIMEDLOCK
CMP r1,r2
JMP[EQ] @nbi_mtx_timedlock
MOVI r2,#B_MTX_UNLOCK
CMP r1,r2
JMP[EQ] @nbi_mtx_unlock
MOVI r2,#B_MTX_DESTROY
CMP r1,r2
JMP[EQ] @nbi_mtx_destroy
MOVI r2,#B_CND_INIT
CMP r1,r2
JMP[EQ] @nbi_cnd_init
MOVI r2,#B_CND_SIGNAL
CMP r1,r2
JMP[EQ] @nbi_cnd_signal
MOVI r2,#B_CND_BROADCAST
CMP r1,r2
JMP[EQ] @nbi_cnd_broadcast
MOVI r2,#B_CND_WAIT
CMP r1,r2
JMP[EQ] @nbi_cnd_wait
MOVI r2,#B_CND_TIMEDWAIT
CMP r1,r2
JMP[EQ] @nbi_cnd_timedwait
MOVI r2,#B_CND_DESTROY
CMP r1,r2
JMP[EQ] @nbi_cnd_destroy
MOVI r2,#B_TSS_CREATE
CMP r1,r2
JMP[EQ] @nbi_tss_create
MOVI r2,#B_TSS_GET
CMP r1,r2
JMP[EQ] @nbi_tss_get
MOVI r2,#B_TSS_SET
CMP r1,r2
JMP[EQ] @nbi_tss_set
MOVI r2,#B_TSS_DELETE
CMP r1,r2
JMP[EQ] @nbi_tss_delete
MOVI r2,#B_CALL_ONCE
CMP r1,r2
JMP[EQ] @nbi_call_once
MOVI r2,#B_VFWPRINTF
CMP r1,r2
JMP[EQ] @nbi_vfwprintf
MOVI r2,#B_VSWPRINTF
CMP r1,r2
JMP[EQ] @nbi_vswprintf
MOVI r2,#B_VFWSCANF
CMP r1,r2
JMP[EQ] @nbi_vfwscanf
MOVI r2,#B_VSWSCANF
CMP r1,r2
JMP[EQ] @nbi_vswscanf
MOVI r2,#B_STRTOL
CMP r1,r2
JMP[EQ] @nbi_strtol
MOVI r2,#B_STRTOUL
CMP r1,r2
JMP[EQ] @nbi_strtoul
MOVI r2,#B_STRTOLL
CMP r1,r2
JMP[EQ] @nbi_strtoll
MOVI r2,#B_STRTOULL
CMP r1,r2
JMP[EQ] @nbi_strtoull
MOVI r2,#B_STRRCHR
CMP r1,r2
JMP[EQ] @nbi_strrchr
MOVI r2,#B_STRNDUP
CMP r1,r2
JMP[EQ] @nbi_strndup
MOVI r2,#B_STPCPY
CMP r1,r2
JMP[EQ] @nbi_stpcpy
MOVI r2,#B_MEMCCPY
CMP r1,r2
JMP[EQ] @nbi_memccpy
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
ST r0,r0,#W_PF_OFF
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
CALL @ni_free
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
nbi_atol:
CALL @ni_pop
ST r1,r0,#W_SX_S
ST r1,r0,#W_SX_ORIG
ST r0,r0,#W_SX_ENDP
MOVI r2,10
ST r2,r0,#W_SX_BASE
ST r0,r0,#W_SX_SIGN
CALL @sx_parse
LD r1,r0,#W_LLD0
CALL @ni_push
JMP @nbi_d
nbi_atoll:
CALL @ni_pop
ST r1,r0,#W_SX_S
ST r1,r0,#W_SX_ORIG
ST r0,r0,#W_SX_ENDP
MOVI r2,10
ST r2,r0,#W_SX_BASE
ST r0,r0,#W_SX_SIGN
CALL @sx_parse
LD r1,r0,#W_LLD0
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
JMP @nbi_d
nbi_abort:
ST r0,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
MOVI r1,134
ST r1,r0,#W_EXITCODE
LD r1,r0,#W_TAILHALT
ST r1,r0,#R_IP
JMP @nbi_d

; nbi_call0: r1=function symbol -> call it with no arguments
nbi_call0:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_ATEXIT_SYM
MOVI r7,0
BOOL.14 r1,r1,r7
ST r1,r0,#R_T0
CALL @sym_entry
LD r2,r1,#SY_KIND
MOVI r3,#SK_BUILTIN
CMP r2,r3
JMP[NE] @ac0_user
LD r1,r1,#SY_AUX
MOVI r2,0
CALL @ni_builtin
CALL @ni_pop
JMP @ac0_d
ac0_user:
LD r4,r0,#R_FP
ST r4,r0,#W_ATEXIT_OLD
CALL @ni_call
LD r4,r0,#W_ATEXIT_OLD
ST r4,r0,#W_IRYSTOP
CALL @ncc_ir_loop
ST r0,r0,#W_IRYSTOP
CALL @ni_pop
ac0_d:
SUB r14,r14,r13
LD r15,r14,0
RET

run_atexit:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_ATEXIT_N
MOVI r2,32
CMP r1,r2
JMP[LE] @rae_l
MOVI r1,32
rae_l:
CMP r1,r0
JMP[EQ] @rae_d
SUB r1,r1,r13
ST r1,r0,#W_ATEXIT_I
LA r2,@atexit_tab
SHL r3,r1,2
ADD r2,r2,r3
LD r1,r2,0
CALL @nbi_call0
LD r1,r0,#W_ATEXIT_I
JMP @rae_l
rae_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nbi_atexit:
CALL @ni_pop
ST r1,r0,#W_ATEXIT_SYM
LD r2,r0,#W_ATEXIT_N
MOVI r3,32
CMP r2,r3
JMP[GE] @ate_f
LA r3,@atexit_tab
SHL r4,r2,2
ADD r3,r3,r4
LD r4,r0,#W_ATEXIT_SYM
ST r4,r3,0
ADD r2,r2,r13
ST r2,r0,#W_ATEXIT_N
MOVI r1,0
CALL @ni_push
JMP @nbi_d
ate_f:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi__exit:
CALL @ni_pop
ST r1,r0,#W_EXITCODE
LD r1,r0,#W_TAILHALT
ST r1,r0,#R_IP
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

nbi_sqrt:
CALL @ni_pop
FSQRT r1,r1
CALL @ni_push
JMP @nbi_d
nbi_fabs:
CALL @ni_pop
LA r2,0x7FFFFFFF
BOOL.8 r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_exp:
CALL @ni_pop
FEXP r1,r1
CALL @ni_push
JMP @nbi_d
nbi_log:
CALL @ni_pop
FLOG r1,r1
CALL @ni_push
JMP @nbi_d
nbi_log10:
CALL @ni_pop
FLOG r1,r1
LA r2,0x40135D8E
FDIV r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_tanh:
CALL @ni_pop
FTANH r1,r1
CALL @ni_push
JMP @nbi_d
nbi_floor:
CALL @ni_pop
LA r2,0x7FFFFFFF
BOOL.8 r3,r1,r2
CMP r3,r0
JMP[EQ] @nbi_floor_x
LA r2,0x4B000000
CMP r3,r2
JMP[GE] @nbi_floor_x
CVTFI r2,r1
CVTIF r3,r2
FCMP r1,r3
JMP[GE] @nbi_floor_d
SUB r2,r2,r13
nbi_floor_d:
CVTIF r1,r2
nbi_floor_x:
CALL @ni_push
JMP @nbi_d
nbi_ceil:
CALL @ni_pop
LA r2,0x80000000
BOOL.8 r3,r1,r2
ST r3,r0,#W_LM_SG
LA r2,0x7FFFFFFF
BOOL.8 r3,r1,r2
CMP r3,r0
JMP[EQ] @nbi_ceil_x
LA r2,0x4B000000
CMP r3,r2
JMP[GE] @nbi_ceil_x
CVTFI r2,r1
CVTIF r3,r2
FCMP r1,r3
JMP[LE] @nbi_ceil_d
ADD r2,r2,r13
nbi_ceil_d:
CVTIF r1,r2
nbi_ceil_x:
CMP r1,r0
JMP[NE] @nbi_ceil_p
LD r3,r0,#W_LM_SG
BOOL.14 r1,r1,r3
nbi_ceil_p:
CALL @ni_push
JMP @nbi_d
nbi_fmod:
; fmod(x,y) = x - trunc(x/y)*y. The quotient/product/subtract are carried
; in double-float, then one exact float correction fixes the possible
; off-by-one in trunc(x/y). Exact for |x/y| < 2^23 with |x|,|y| < 2^116
; (the Dekker split's range; see libm.md scope).
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LM_AX
CALL @ni_pop
ST r1,r0,#W_LM_X
; y == 0 or y is NaN -> qNaN
LD r2,r0,#W_LM_AX
LA r3,0x7FFFFFFF
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[EQ] @nfm_nan
LA r3,0x7F800000
CMP r4,r3
JMP[GT] @nfm_nan
JMP[EQ] @nfm_yinf
; x == +-0 -> x
LD r2,r0,#W_LM_X
LA r3,0x7FFFFFFF
BOOL.8 r5,r2,r3
CMP r5,r0
JMP[EQ] @nfm_xret
LA r3,0x7F800000
CMP r5,r3
JMP[GE] @nfm_nan
; the Dekker split overflows above 2^116; use the coarse path there
LA r3,0x79800000
CMP r4,r3
JMP[GE] @nfm_coarse
CMP r5,r3
JMP[GE] @nfm_coarse
; n = trunc(x/y)
LD r7,r0,#W_LM_AX
FDIV r6,r2,r7
CVTFI r8,r6
CMP r8,r0
JMP[EQ] @nfm_xret
CVTIF r9,r8
ST r9,r0,#W_LM_ND
; p = n*y in double-float
ADD r1,r9,r0
MOVI r2,0
LD r3,r0,#W_LM_AX
MOVI r4,0
CALL @nix_dmul
ST r1,r0,#W_LM_PH
ST r2,r0,#W_LM_PL
; r = x - p
LD r1,r0,#W_LM_X
MOVI r2,0
LD r3,r0,#W_LM_PH
LD r4,r0,#W_LM_PL
CALL @nix_dsub
FADD r1,r1,r2
ST r1,r0,#W_LM_RH
CMP r1,r0
JMP[EQ] @nfm_zerores
; if sign(r) != sign(x), r += copysign(|y|,x)
LD r2,r0,#W_LM_X
LA r3,0x80000000
BOOL.8 r4,r1,r3
BOOL.8 r5,r2,r3
CMP r4,r5
JMP[EQ] @nfm_mag
LD r6,r0,#W_LM_AX
LA r3,0x7FFFFFFF
BOOL.8 r6,r6,r3
BOOL.14 r6,r6,r5
FADD r1,r1,r6
ST r1,r0,#W_LM_RH
nfm_mag:
; if |r| >= |y|, r -= copysign(|y|,x)
LD r6,r0,#W_LM_AX
LA r3,0x7FFFFFFF
BOOL.8 r6,r6,r3
LA r3,0x7FFFFFFF
BOOL.8 r7,r1,r3
FCMP r7,r6
JMP[LT] @nfm_done
LD r5,r0,#W_LM_X
LA r3,0x80000000
BOOL.8 r5,r5,r3
BOOL.14 r6,r6,r5
FSUB r1,r1,r6
ST r1,r0,#W_LM_RH
JMP @nfm_done
nfm_zerores:
LD r2,r0,#W_LM_X
LA r3,0x80000000
BOOL.8 r1,r2,r3
JMP @nfm_done
nfm_yinf:
LD r2,r0,#W_LM_X
LA r3,0x7FFFFFFF
BOOL.8 r5,r2,r3
LA r3,0x7F800000
CMP r5,r3
JMP[GE] @nfm_nan
LD r1,r0,#W_LM_X
JMP @nfm_done
nfm_xret:
LD r1,r0,#W_LM_X
JMP @nfm_done
nfm_coarse:
LD r2,r0,#W_LM_X
LD r7,r0,#W_LM_AX
FDIV r3,r2,r7
CVTFI r3,r3
CVTIF r3,r3
FMUL r3,r3,r7
FSUB r1,r2,r3
JMP @nfm_done
nfm_nan:
LA r1,0x7FC00000
nfm_done:
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
JMP @nbi_d
nbi_fmin:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LD r2,r0,#W_F2P
FCMP r1,r2
JMP[LT] @nbi_fmin_d
ADD r1,r2,r0
nbi_fmin_d:
CALL @ni_push
JMP @nbi_d
nbi_fmax:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LD r2,r0,#W_F2P
FCMP r1,r2
JMP[GT] @nbi_fmax_d
ADD r1,r2,r0
nbi_fmax_d:
CALL @ni_push
JMP @nbi_d
nbi_pow:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
FLOG r1,r1
LD r2,r0,#W_F2P
FMUL r1,r1,r2
FEXP r1,r1
CALL @ni_push
JMP @nbi_d

; ---- additional math wrappers -------------------------------------
ni_round_bits:
LA r5,0x80000000
BOOL.8 r5,r1,r5
ST r5,r0,#W_LM_SG
LA r5,0x7FFFFFFF
BOOL.8 r4,r1,r5
CMP r4,r0
JMP[EQ] @nrb_ret
LA r5,0x4B000000
CMP r4,r5
JMP[GE] @nrb_ret
CVTFI r2,r1
CVTIF r3,r2
FSUB r4,r1,r3
LA r5,0x3F000000
FCMP r4,r5
JMP[GE] @nrb_up
LA r5,0xBF000000
FCMP r4,r5
JMP[LE] @nrb_dn
ADD r1,r3,r0
JMP @nrb_ret
nrb_up:
ADD r2,r2,r13
CVTIF r1,r2
JMP @nrb_ret
nrb_dn:
SUB r2,r2,r13
CVTIF r1,r2
nrb_ret:
CMP r1,r0
JMP[NE] @nrb_realret
LD r5,r0,#W_LM_SG
BOOL.14 r1,r1,r5
nrb_realret:
RET

; ni_round_even_bits: round to nearest, ties to even (the default IEEE mode).
ni_round_even_bits:
LA r5,0x80000000
BOOL.8 r5,r1,r5
ST r5,r0,#W_LM_SG
LA r5,0x7FFFFFFF
BOOL.8 r4,r1,r5
CMP r4,r0
JMP[EQ] @nre_ret
LA r5,0x4B000000
CMP r4,r5
JMP[GE] @nre_ret
CVTFI r2,r1
CVTIF r3,r2
FSUB r4,r1,r3
LA r5,0x3F000000
FCMP r4,r5
JMP[GT] @nre_up
LA r5,0xBF000000
FCMP r4,r5
JMP[LT] @nre_dn
LA r7,0x7FFFFFFF
BOOL.8 r6,r4,r7
LA r5,0x3F000000
FCMP r6,r5
JMP[LT] @nre_trunc
MOVI r7,1
BOOL.8 r6,r2,r7
CMP r6,r0
JMP[EQ] @nre_trunc
LA r7,0x80000000
BOOL.8 r6,r4,r7
CMP r6,r0
JMP[EQ] @nre_up
JMP @nre_dn
nre_up:
ADD r2,r2,r13
JMP @nre_trunc
nre_dn:
SUB r2,r2,r13
nre_trunc:
CVTIF r1,r2
nre_ret:
CMP r1,r0
JMP[NE] @nre_realret
LD r5,r0,#W_LM_SG
BOOL.14 r1,r1,r5
nre_realret:
RET

nbi_exp2:
CALL @ni_pop
LA r2,0x3F317218
FMUL r1,r1,r2
FEXP r1,r1
CALL @ni_push
JMP @nbi_d
nbi_log2:
CALL @ni_pop
FLOG r1,r1
LA r2,0x3F317218
FDIV r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_log1p:
CALL @ni_pop
LA r2,0x3F800000
FADD r1,r1,r2
FLOG r1,r1
CALL @ni_push
JMP @nbi_d
nbi_expm1:
CALL @ni_pop
FEXP r1,r1
LA r2,0x3F800000
FSUB r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_hypot:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
ST r1,r0,#W_F2V
FMUL r1,r1,r1
LD r2,r0,#W_F2P
FMUL r2,r2,r2
FADD r1,r1,r2
FSQRT r1,r1
CALL @ni_push
JMP @nbi_d
nbi_cbrt:
CALL @ni_pop
ST r1,r0,#W_F2S
LA r2,0x7FFFFFFF
BOOL.8 r1,r1,r2
FLOG r1,r1
LA r2,0x40400000
FDIV r1,r1,r2
FEXP r1,r1
LD r3,r0,#W_F2S
LA r4,0x80000000
BOOL.8 r3,r3,r4
BOOL.14 r1,r1,r3
CALL @ni_push
JMP @nbi_d
nbi_sinh:
CALL @ni_pop
ST r1,r0,#W_F2V
FEXP r1,r1
ST r1,r0,#W_F2S
LD r1,r0,#W_F2V
LA r2,0x80000000
BOOL.6 r1,r1,r2
FEXP r1,r1
ST r1,r0,#W_F2P
LD r1,r0,#W_F2S
LD r2,r0,#W_F2P
FSUB r1,r1,r2
LA r2,0x40000000
FDIV r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_cosh:
CALL @ni_pop
ST r1,r0,#W_F2V
FEXP r1,r1
ST r1,r0,#W_F2S
LD r1,r0,#W_F2V
LA r2,0x80000000
BOOL.6 r1,r1,r2
FEXP r1,r1
LD r2,r0,#W_F2S
FADD r1,r1,r2
LA r2,0x40000000
FDIV r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_asinh:
CALL @ni_pop
ST r1,r0,#W_F2V
FMUL r1,r1,r1
LA r2,0x3F800000
FADD r1,r1,r2
FSQRT r1,r1
LD r2,r0,#W_F2V
FADD r1,r1,r2
FLOG r1,r1
CALL @ni_push
JMP @nbi_d
nbi_acosh:
CALL @ni_pop
ST r1,r0,#W_F2V
FMUL r1,r1,r1
LA r2,0x3F800000
FSUB r1,r1,r2
FSQRT r1,r1
LD r2,r0,#W_F2V
FADD r1,r1,r2
FLOG r1,r1
CALL @ni_push
JMP @nbi_d
nbi_atanh:
CALL @ni_pop
ST r1,r0,#W_F2V
LA r2,0x3F800000
LD r3,r0,#W_F2V
FADD r3,r3,r2
FSUB r2,r2,r1
FDIV r1,r3,r2
FLOG r1,r1
LA r2,0x3F000000
FMUL r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_trunc:
CALL @ni_pop
LA r2,0x80000000
BOOL.8 r3,r1,r2
ST r3,r0,#W_LM_SG
LA r2,0x7FFFFFFF
BOOL.8 r3,r1,r2
CMP r3,r0
JMP[EQ] @nbi_trunc_x
LA r2,0x4B000000
CMP r3,r2
JMP[GE] @nbi_trunc_x
CVTFI r2,r1
CVTIF r1,r2
nbi_trunc_x:
CMP r1,r0
JMP[NE] @nbi_trunc_p
LD r3,r0,#W_LM_SG
BOOL.14 r1,r1,r3
nbi_trunc_p:
CALL @ni_push
JMP @nbi_d
nbi_round:
CALL @ni_pop
CALL @ni_round_bits
CALL @ni_push
JMP @nbi_d
nbi_rint:
CALL @ni_pop
CALL @ni_round_even_bits
CALL @ni_push
JMP @nbi_d
nbi_nearbyint:
CALL @ni_pop
CALL @ni_round_even_bits
CALL @ni_push
JMP @nbi_d
nbi_copysign:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LA r2,0x7FFFFFFF
BOOL.8 r1,r1,r2
LD r2,r0,#W_F2P
LA r3,0x80000000
BOOL.8 r2,r2,r3
BOOL.14 r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_nan:
LA r1,0x7FC00000
CALL @ni_push
JMP @nbi_d
nbi_fdim:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LD r2,r0,#W_F2P
FCMP r1,r2
JMP[LE] @nbi_fdim_z
FSUB r1,r1,r2
JMP @nbi_fdim_p
nbi_fdim_z:
MOVI r1,0
nbi_fdim_p:
CALL @ni_push
JMP @nbi_d
nbi_aligned_alloc:
CALL @ni_pop
ST r1,r0,#W_ALLOC_A
CALL @ni_pop
ST r1,r0,#W_ALLOC_B
LD r1,r0,#W_ALLOC_A
LD r2,r0,#W_ALLOC_B
CALL @ni_malloc_aligned
CALL @ni_push
JMP @nbi_d
nbi_dp4b:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LD r2,r0,#W_F2P
DP4B r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_fma:
CALL @ni_pop
ST r1,r0,#W_F2S
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LD r2,r0,#W_F2P
FMUL r1,r1,r2
LD r2,r0,#W_F2S
FADD r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_modf:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
ST r1,r0,#W_F2V
CVTFI r2,r1
CVTIF r3,r2
FSUB r4,r1,r3
ST r4,r0,#W_F2S
LD r1,r0,#W_F2P
CVTIF r2,r2
MOVI r3,#SZ_32
CALL @ni_storev
LD r1,r0,#W_F2S
CALL @ni_push
JMP @nbi_d
nbi_ldexp:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
ST r1,r0,#W_F2V
LD r1,r0,#W_F2P
CVTIF r1,r1
LA r2,0x3F317218
FMUL r1,r1,r2
FEXP r1,r1
LD r2,r0,#W_F2V
FMUL r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_scalbn:
JMP @nbi_ldexp
nbi_remainder:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
ST r1,r0,#W_F2V
LD r2,r0,#W_F2P
FDIV r3,r1,r2
ADD r1,r3,r0
CALL @ni_round_even_bits
LD r2,r0,#W_F2P
FMUL r1,r1,r2
LD r2,r0,#W_F2V
FSUB r1,r2,r1
CALL @ni_push
JMP @nbi_d
nbi_tan:
CALL @ni_pop
ST r1,r0,#W_F2V
CALL @ni_sin
ST r1,r0,#W_F2S
LD r1,r0,#W_F2V
CALL @ni_cos
LD r2,r0,#W_F2S
FDIV r1,r2,r1
CALL @ni_push
JMP @nbi_d

nbi_strchr:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
LD r2,r0,#W_F2P
nbi_sc_l:
LDB r3,r1,0
CMP r3,r2
JMP[EQ] @nbi_sc_y
CMP r3,r0
JMP[EQ] @nbi_sc_n
ADD r1,r1,r13
JMP @nbi_sc_l
nbi_sc_y:
CALL @ni_push
JMP @nbi_d
nbi_sc_n:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_strstr:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
ST r1,r0,#W_F2V
LD r2,r0,#W_F2P
LDB r3,r2,0
CMP r3,r0
JMP[NE] @nbi_ss_go
LD r1,r0,#W_F2V
CALL @ni_push
JMP @nbi_d
nbi_ss_go:
LD r1,r0,#W_F2V
nbi_ss_o:
LDB r3,r1,0
CMP r3,r0
JMP[EQ] @nbi_ss_n
ADD r2,r1,r0
LD r5,r0,#W_F2P
nbi_ss_i:
LDB r3,r5,0
CMP r3,r0
JMP[EQ] @nbi_ss_y
LDB r4,r2,0
CMP r3,r4
JMP[NE] @nbi_ss_nx
ADD r2,r2,r13
ADD r5,r5,r13
JMP @nbi_ss_i
nbi_ss_nx:
ADD r1,r1,r13
JMP @nbi_ss_o
nbi_ss_y:
CALL @ni_push
JMP @nbi_d
nbi_ss_n:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_strdup:
CALL @ni_pop
ST r1,r0,#W_F2V
CALL @ni_strlen
ADD r1,r1,r13
ST r1,r0,#W_F2P
CALL @ni_malloc
ST r1,r0,#W_F2S
LD r2,r0,#W_F2V
LD r3,r0,#W_F2P
nbi_sd_l:
CMP r3,r0
JMP[EQ] @nbi_sd_d
LDB r4,r2,0
STB r4,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @nbi_sd_l
nbi_sd_d:
LD r1,r0,#W_F2S
CALL @ni_push
JMP @nbi_d

nbi_isdigit:
CALL @ni_pop
MOVI r2,60
SUB r2,r1,r2
JMP @nbi_isdigit_go
nbi_isdigit_go:
JMP @nbi_ctype_digit
nbi_isalpha:
CALL @ni_pop
JMP @nbi_ctype_alpha
nbi_isspace:
CALL @ni_pop
MOVI r2,32
CMP r1,r2
JMP[EQ] @nbi_ctype_y
MOVI r2,9
CMP r1,r2
JMP[LT] @nbi_ctype_n
MOVI r2,13
CMP r1,r2
JMP[LE] @nbi_ctype_y
JMP @nbi_ctype_n
nbi_isupper:
CALL @ni_pop
MOVI r2,65
CMP r1,r2
JMP[LT] @nbi_ctype_n
MOVI r2,90
CMP r1,r2
JMP[LE] @nbi_ctype_y
JMP @nbi_ctype_n
nbi_islower:
CALL @ni_pop
MOVI r2,97
CMP r1,r2
JMP[LT] @nbi_ctype_n
MOVI r2,122
CMP r1,r2
JMP[LE] @nbi_ctype_y
JMP @nbi_ctype_n
nbi_ctype_digit:
MOVI r2,48
CMP r1,r2
JMP[LT] @nbi_ctype_n
MOVI r2,57
CMP r1,r2
JMP[LE] @nbi_ctype_y
JMP @nbi_ctype_n
nbi_ctype_alpha:
MOVI r2,65
CMP r1,r2
JMP[LT] @nbi_ctype_lo
MOVI r2,90
CMP r1,r2
JMP[LE] @nbi_ctype_y
nbi_ctype_lo:
MOVI r2,97
CMP r1,r2
JMP[LT] @nbi_ctype_n
MOVI r2,122
CMP r1,r2
JMP[LE] @nbi_ctype_y
JMP @nbi_ctype_n
nbi_ctype_y:
MOVI r1,1
CALL @ni_push
JMP @nbi_d
nbi_ctype_n:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_isalnum:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @nbi_ct_alpha_ck
CMP r1,r0
JMP[NE] @nbi_ct_y2
LD r1,r0,#W_TA
CALL @nbi_ct_digit_ck
JMP @nbi_ct_res
nbi_iscntrl:
CALL @ni_pop
MOVI r2,32
CMP r1,r2
JMP[LT] @nbi_ct_y2
MOVI r2,127
CMP r1,r2
JMP[EQ] @nbi_ct_y2
MOVI r1,0
JMP @nbi_ct_res
nbi_isgraph:
CALL @ni_pop
MOVI r2,33
CMP r1,r2
JMP[LT] @nbi_ct_n2
MOVI r2,127
CMP r1,r2
JMP[GE] @nbi_ct_n2
MOVI r1,1
JMP @nbi_ct_res
nbi_isprint:
CALL @ni_pop
MOVI r2,32
CMP r1,r2
JMP[LT] @nbi_ct_n2
MOVI r2,127
CMP r1,r2
JMP[GE] @nbi_ct_n2
MOVI r1,1
JMP @nbi_ct_res
nbi_ispunct:
CALL @ni_pop
ST r1,r0,#W_TA
MOVI r2,33
CMP r1,r2
JMP[LT] @nbi_ct_n2
MOVI r2,127
CMP r1,r2
JMP[GE] @nbi_ct_n2
LD r1,r0,#W_TA
CALL @nbi_ct_alpha_ck
CMP r1,r0
JMP[NE] @nbi_ct_n2
LD r1,r0,#W_TA
CALL @nbi_ct_digit_ck
CMP r1,r0
JMP[NE] @nbi_ct_n2
MOVI r1,1
JMP @nbi_ct_res
nbi_isxdigit:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @nbi_ct_digit_ck
CMP r1,r0
JMP[NE] @nbi_ct_y2
LD r1,r0,#W_TA
MOVI r2,65
CMP r1,r2
JMP[LT] @nbi_ct_xlo
MOVI r2,70
CMP r1,r2
JMP[LE] @nbi_ct_y2
nbi_ct_xlo:
LD r1,r0,#W_TA
MOVI r2,97
CMP r1,r2
JMP[LT] @nbi_ct_n2
MOVI r2,102
CMP r1,r2
JMP[LE] @nbi_ct_y2
JMP @nbi_ct_n2
nbi_ct_alpha_ck:
MOVI r2,65
CMP r1,r2
JMP[LT] @nbi_ct_alo
MOVI r2,90
CMP r1,r2
JMP[LE] @nbi_ct_cy
nbi_ct_alo:
MOVI r2,97
CMP r1,r2
JMP[LT] @nbi_ct_cn
MOVI r2,122
CMP r1,r2
JMP[LE] @nbi_ct_cy
JMP @nbi_ct_cn
nbi_ct_digit_ck:
MOVI r2,48
CMP r1,r2
JMP[LT] @nbi_ct_cn
MOVI r2,57
CMP r1,r2
JMP[LE] @nbi_ct_cy
JMP @nbi_ct_cn
nbi_ct_cy:
MOVI r1,1
RET
nbi_ct_cn:
MOVI r1,0
RET
nbi_ct_y2:
MOVI r1,1
JMP @nbi_ct_res
nbi_ct_n2:
MOVI r1,0
nbi_ct_res:
CALL @ni_push
JMP @nbi_d

nbi_toupper:
CALL @ni_pop
MOVI r2,97
CMP r1,r2
JMP[LT] @nbi_ct_done
MOVI r2,122
CMP r1,r2
JMP[GT] @nbi_ct_done
MOVI r2,32
SUB r1,r1,r2
nbi_ct_done:
CALL @ni_push
JMP @nbi_d
nbi_tolower:
CALL @ni_pop
MOVI r2,65
CMP r1,r2
JMP[LT] @nbi_cl_done
MOVI r2,90
CMP r1,r2
JMP[GT] @nbi_cl_done
MOVI r2,32
ADD r1,r1,r2
nbi_cl_done:
CALL @ni_push
JMP @nbi_d

nbi_rand:
LD r2,r0,#W_RAND_INIT
CMP r2,r0
JMP[NE] @nbr_go
ST r15,r14,0
ADD r14,r14,r13
LA r4,@bare_table
LD r4,r4,15
CALLR r4
SUB r14,r14,r13
LD r15,r14,0
ST r1,r0,#W_RAND
MOVI r2,1
ST r2,r0,#W_RAND_INIT
nbr_go:
LD r1,r0,#W_RAND
LA r2,1103515245
MUL r1,r1,r2
ADDI r1,r1,12345
ST r1,r0,#W_RAND
SHR r1,r1,16
MOVI r2,0x7FFF
BOOL.8 r1,r1,r2
CALL @ni_push
JMP @nbi_d
nbi_srand:
CALL @ni_pop
ST r1,r0,#W_RAND
MOVI r2,1
ST r2,r0,#W_RAND_INIT
MOVI r1,0
CALL @ni_push
JMP @nbi_d
nbi_labs:
CALL @ni_pop
CMPS r1,r0
JMP[GE] @nbi_labs_p
SUB r1,r0,r1
nbi_labs_p:
CALL @ni_push
JMP @nbi_d

nbi_memmove:
CALL @ni_pop
ST r1,r0,#W_F2P
CALL @ni_pop
ST r1,r0,#W_F2V
CALL @ni_pop
ST r1,r0,#W_F2S
LD r3,r0,#W_F2P
CMP r3,r0
JMP[EQ] @nbi_mm_d
LD r2,r0,#W_F2V
LD r1,r0,#W_F2S
CMP r1,r2
JMP[LT] @nbi_mm_fwd
ADD r4,r2,r3
CMP r1,r4
JMP[GE] @nbi_mm_fwd
; backward copy
ADD r5,r1,r0
ADD r1,r1,r3
ADD r2,r2,r3
nbi_mm_b_l:
CMP r1,r5
JMP[EQ] @nbi_mm_d
SUB r1,r1,r13
SUB r2,r2,r13
LDB r4,r2,0
STB r4,r1,0
JMP @nbi_mm_b_l
nbi_mm_fwd:
ADD r4,r1,r3
nbi_mm_f_l:
CMP r1,r4
JMP[EQ] @nbi_mm_d
LDB r5,r2,0
STB r5,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
JMP @nbi_mm_f_l
nbi_mm_d:
LD r1,r0,#W_F2S
CALL @ni_push
JMP @nbi_d

; sprintf/snprintf: redirect ncc_putc into a caller buffer.
nbi_sprintf:
ST r0,r0,#W_PF_OFF
JMP @nbi_sn_common
nbi_snprintf:
MOVI r1,2
ST r1,r0,#W_PF_OFF
nbi_sn_common:
; save output state
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
; destination (arg 0), count (arg 1), format offset
LD r1,r0,#R_T1
ST r1,r0,#W_PF_ARGC
ST r0,r0,#W_PF_IDX
ST r0,r0,#W_PF_OFF
MOVI r1,0
CALL @ni_arg
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
LD r2,r0,#R_T0
MOVI r3,#B_SNPRINTF
CMP r2,r3
JMP[NE] @nbi_sn_plain
MOVI r1,1
CALL @ni_arg
ST r1,r0,#W_SNLIM
MOVI r1,2
ST r1,r0,#W_PF_OFF
JMP @nbi_sn_fmt
nbi_sn_plain:
LA r1,0xFFFFFFFF
ST r1,r0,#W_SNLIM
MOVI r1,1
ST r1,r0,#W_PF_OFF
nbi_sn_fmt:
MOVI r1,0
ST r1,r0,#W_PF_IDX
LD r1,r0,#R_T1
CALL @ni_printf
; drop ni_printf's 0 return
CALL @ni_pop
; terminate and return the character count
LD r1,r0,#W_SNOUT
LD r2,r0,#W_SNPOS
LD r3,r0,#W_SNLIM
CMP r3,r0
JMP[EQ] @nbi_sn_nul_done
SUB r3,r3,r13
CMP r2,r3
JMP[LE] @nbi_sn_nul_at
ADD r2,r3,r0
nbi_sn_nul_at:
ADD r1,r1,r2
STB r0,r1,0
nbi_sn_nul_done:
LD r1,r0,#W_SNPOS
CALL @ni_push
; restore output state
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
JMP @nbi_d
nbi_exit:
CALL @ni_pop
ST r1,r0,#W_EXITCODE
LD r1,r0,#W_ATEXIT_RUN
CMP r1,r0
JMP[NE] @nex_go
MOVI r1,1
ST r1,r0,#W_ATEXIT_RUN
CALL @run_atexit
nex_go:
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
ST r2,r0,#W_CALLWORDS
CALL @sym_entry
LD r3,r1,#SY_OFF
ST r3,r0,#W_VARFLAG
LD r3,r1,#SY_NP
ST r3,r0,#W_VARNP
LD r3,r1,#SY_KIND
MOVI r4,#SK_BUILTIN
CMP r3,r4
JMP[NE] @ncl_func
LD r5,r1,#SY_NP
MOVI r4,0xFFFF
CMP r5,r4
JMP[EQ] @ncl_bok
LD r6,r0,#R_T1
CMP r6,r5
JMP[GE] @ncl_bok
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
CMP r6,r5
JMP[GE] @ncl_argc_ok
MOVI r1,40
CALL @ncc_err
ncl_argc_ok:
LD r5,r1,#SY_NL
LD r6,r1,#SY_ARG
ST r4,r0,#W_CALLENTRY
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
LD r9,r0,#W_C_STACK_END
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
ST r0,r0,#W_SRCOFF
ncl_copy:
LD r1,r0,#W_TY_KIND
LD r2,r0,#W_VARNP
CMP r1,r2
JMP[GE] @ncl_varstore
LD r3,r0,#W_TY_BASE
SHL r4,r1,1
ADD r4,r3,r4
LD r5,r4,0
ADDI r4,r4,1
LD r6,r4,0
ST r5,r0,#W_TY_ALIGN
ST r6,r0,#W_TY_RET
ADD r1,r6,r0
CALL @ty_kind
MOVI r3,#TY_STRUCT
CMP r1,r3
JMP[EQ] @ncl_copy_agg
MOVI r3,#TY_UNION
CMP r1,r3
JMP[EQ] @ncl_copy_agg
LD r1,r0,#W_TY_RET
CALL @ty_kind
MOVI r3,#TY_LL
CMP r1,r3
JMP[EQ] @ncl_copy_ll
LD r1,r0,#W_TY_RET
CALL @ty_store_code
ST r1,r0,#W_TY_SIGN
LD r1,r0,#W_TY_ID
LD r2,r0,#W_TY_ALIGN
ADD r1,r1,r2
LD r2,r0,#R_SP
LD r3,r0,#R_T1
SUB r2,r2,r3
LD r3,r0,#W_SRCOFF
ADD r2,r2,r3
LD r2,r2,0
LD r3,r0,#W_TY_SIGN
CALL @ni_storev
LD r1,r0,#W_TY_KIND
ADD r1,r1,r13
ST r1,r0,#W_TY_KIND
LD r1,r0,#W_SRCOFF
ADD r1,r1,r13
ST r1,r0,#W_SRCOFF
JMP @ncl_copy
ncl_copy_ll:
LD r1,r0,#R_SP
LD r2,r0,#R_T1
SUB r1,r1,r2
LD r2,r0,#W_SRCOFF
ADD r1,r1,r2
LD r2,r1,0
LD r3,r1,1
LD r1,r0,#W_TY_ID
LD r4,r0,#W_TY_ALIGN
ADD r1,r1,r4
CALL @ni_store64
LD r1,r0,#W_TY_KIND
ADD r1,r1,r13
ST r1,r0,#W_TY_KIND
LD r1,r0,#W_SRCOFF
ADDI r1,r1,2
ST r1,r0,#W_SRCOFF
JMP @ncl_copy
ncl_copy_agg:
LD r1,r0,#W_TY_RET
CALL @ty_size
ST r1,r0,#W_TY_TMP
LD r2,r0,#R_SP
LD r3,r0,#R_T1
SUB r2,r2,r3
LD r3,r0,#W_SRCOFF
ADD r2,r2,r3
LD r2,r2,0
LD r1,r0,#W_TY_ID
LD r3,r0,#W_TY_ALIGN
ADD r1,r1,r3
LD r3,r0,#W_TY_TMP
CALL @ni_memcpy_raw
LD r1,r0,#W_TY_KIND
ADD r1,r1,r13
ST r1,r0,#W_TY_KIND
LD r1,r0,#W_SRCOFF
ADD r1,r1,r13
ST r1,r0,#W_SRCOFF
JMP @ncl_copy
ncl_varstore:
; copy variadic arguments into the callee's 64-byte varargs area at fp+16
LD r1,r0,#W_VARFLAG
CMP r1,r0
JMP[EQ] @ncl_copy_d
LD r2,r0,#R_T1
LD r3,r0,#W_VARNP
SUB r2,r2,r3
ST r2,r0,#W_VARCNT
MOVI r6,0
ncl_vcopy:
LD r2,r0,#W_VARCNT
CMP r6,r2
JMP[GE] @ncl_copy_d
MOVI r1,16
CMP r6,r1
JMP[GE] @ncl_copy_d
LD r1,r0,#R_SP
LD r2,r0,#R_T1
SUB r1,r1,r2
LD r2,r0,#W_VARNP
ADD r1,r1,r2
ADD r1,r1,r6
LD r1,r1,0
LD r2,r0,#W_TY_ID
ADDI r2,r2,16
SHL r3,r6,2
ADD r2,r2,r3
ADD r5,r1,r0
ADD r1,r2,r0
ADD r2,r5,r0
MOVI r3,#SZ_32
CALL @ni_storev
ADD r6,r6,r13
JMP @ncl_vcopy
ncl_copy_d:
SUB r14,r14,r13
LD r1,r14,0
ST r1,r0,#R_SP
LD r1,r0,#W_TY_ID
ST r1,r0,#R_FP
LD r1,r0,#W_CALLENTRY
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
LD r6,r0,#R_T0
MOVI r7,2
CMP r6,r7
JMP[EQ] @nrt_ll
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
JMP @nrt_restore
nrt_ll:
CMP r4,r3
JMP[LE] @nrt_ll_zero
ADDI r7,r4,-1
LD r6,r7,0
ADDI r7,r4,-2
LD r5,r7,0
ST r3,r0,#R_SP
ADD r1,r5,r0
ST r6,r0,#W_LLD1
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
JMP @nrt_restore
nrt_ll_zero:
ST r3,r0,#R_SP
MOVI r1,0
CALL @ni_push
MOVI r1,0
CALL @ni_push
nrt_restore:
ST r3,r14,0
ADD r14,r14,r13
ST r4,r14,0
ADD r14,r14,r13
LD r2,r0,#R_FP
SHR r2,r2,2
LD r3,r2,0
LD r4,r0,#W_C_STACK
CMP r3,r4
JMP[NE] @nrt_noexit
LD r1,r0,#W_ATEXIT_RUN
CMP r1,r0
JMP[NE] @nrt_noexit
LD r1,r0,#W_ATEXIT_N
CMP r1,r0
JMP[EQ] @nrt_noexit
MOVI r2,32
CMP r1,r2
JMP[GT] @nrt_noexit
MOVI r1,1
ST r1,r0,#W_ATEXIT_RUN
CALL @run_atexit
nrt_noexit:
SUB r14,r14,r13
LD r4,r14,0
SUB r14,r14,r13
LD r3,r14,0
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
LD r1,r0,#W_ALARM
CMP r1,r0
JMP[EQ] @nil_noalarm
SUB r1,r1,r13
ST r1,r0,#W_ALARM
CMP r1,r0
JMP[NE] @nil_noalarm
LD r1,r0,#W_IT_INTERVAL
ST r1,r0,#W_ALARM
MOVI r1,14
ST r1,r0,#W_LLQ0
SHL r2,r1,2
LA r3,11020300
ADD r3,r3,r2
LD r4,r3,0
CMP r4,r0
JMP[EQ] @nil_noalarm
CMP r4,r13
JMP[EQ] @nil_noalarm
ADD r1,r4,r0
LD r2,r0,#W_LLQ0
CALL @nbi_call1
nil_noalarm:
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
MOVI r2,#I_BITSTORE
CMP r1,r2
JMP[EQ] @nil_bitstore
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
MOVI r2,#I_CALLI
CMP r1,r2
JMP[EQ] @nil_calli
MOVI r2,#I_CALLB
CMP r1,r2
JMP[EQ] @nil_callb
MOVI r2,#I_RETSTRUCT
CMP r1,r2
JMP[EQ] @nil_retstruct
MOVI r2,#I_VAARG
CMP r1,r2
JMP[EQ] @nil_vaarg
MOVI r2,#I_LLEXT
CMP r1,r2
JMP[EQ] @nil_llext
MOVI r2,#I_LLTRUNC
CMP r1,r2
JMP[EQ] @nil_lltrunc
MOVI r2,#I_LLOP
CMP r1,r2
JMP[EQ] @nil_llop
MOVI r2,#I_LLOAD
CMP r1,r2
JMP[EQ] @nil_llload
MOVI r2,#I_LLSTORE
CMP r1,r2
JMP[EQ] @nil_llstore
MOVI r2,#I_WORDS
CMP r1,r2
JMP[EQ] @nil_words
MOVI r2,#I_LLF2I
CMP r1,r2
JMP[EQ] @nil_llf2i
MOVI r2,#I_LLI2F
CMP r1,r2
JMP[EQ] @nil_lli2f
MOVI r2,#I_LLBOOL
CMP r1,r2
JMP[EQ] @nil_llbool
MOVI r2,#I_LLNEG
CMP r1,r2
JMP[EQ] @nil_llneg
JMP @nil_bad

nil_words:
LD r1,r0,#R_T0
ST r1,r0,#W_CALLWORDS
JMP @nil_again
nil_llf2i:
LD r1,r0,#R_T0
ST r1,r0,#W_LLS
CALL @ll_from_f
JMP @nil_again
nil_lli2f:
CALL @ll_to_f
JMP @nil_again
nil_llbool:
CALL @ll_bool
JMP @nil_again
nil_llneg:
CALL @ll_neg
JMP @nil_again

nil_llext:
LD r1,r0,#R_T0
CALL @ll_ext
JMP @nil_again
nil_lltrunc:
LD r1,r0,#R_T0
CALL @ll_trunc
JMP @nil_again
nil_llop:
LD r1,r0,#R_T0
CALL @ll_op
JMP @nil_again
nil_llload:
CALL @ll_load
JMP @nil_again
nil_llstore:
LD r1,r0,#R_T0
CALL @ll_store
JMP @nil_again

nil_calli:
LD r1,r0,#R_T0
SHL r1,r1,16
ST r1,r0,#R_T2
CALL @ni_pop
LD r2,r0,#R_T2
BOOL.14 r1,r1,r2
ST r1,r0,#R_T0
CALL @ni_call
JMP @nil_again

; I_CALLB: fp value is below the arguments on the eval stack
nil_callb:
LD r1,r0,#R_T0
ST r1,r0,#R_T2
MOVI r5,0
nilcb_pop:
LD r1,r0,#R_T2
CMP r5,r1
JMP[GE] @nilcb_fp
CALL @ni_pop
LA r2,#CALB_SCRATCH
SHL r3,r5,2
ADD r2,r2,r3
ST r1,r2,0
ADD r5,r5,r13
JMP @nilcb_pop
nilcb_fp:
CALL @ni_pop
ST r1,r0,#R_T0
LD r5,r0,#R_T2
nilcb_push:
CMP r5,r0
JMP[EQ] @nilcb_call
SUB r5,r5,r13
LA r2,#CALB_SCRATCH
SHL r3,r5,2
ADD r2,r2,r3
LD r1,r2,0
CALL @ni_push
JMP @nilcb_push
nilcb_call:
LD r1,r0,#R_T2
SHL r1,r1,16
LD r2,r0,#R_T0
BOOL.14 r1,r1,r2
ST r1,r0,#R_T0
CALL @ni_call
JMP @nil_again
nil_vaarg:
LD r1,r0,#R_T0
ST r1,r0,#W_TY_TMP
CALL @ni_pop
ST r1,r0,#R_T2
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#R_T0
LD r2,r0,#W_TY_TMP
MOVI r3,8
CMP r2,r3
JMP[NE] @nva_one
LD r1,r0,#R_T0
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_LLD0
LD r1,r0,#R_T0
ADDI r1,r1,4
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_LLD1
LD r1,r0,#W_LLD0
CALL @ni_push
LD r1,r0,#W_LLD1
CALL @ni_push
LD r1,r0,#R_T0
ADDI r2,r1,8
JMP @nva_adv
nva_one:
LD r1,r0,#R_T0
MOVI r2,#SZ_32
CALL @ni_loadv
CALL @ni_push
LD r1,r0,#R_T0
ADDI r2,r1,4
nva_adv:
LD r1,r0,#R_T2
MOVI r3,#SZ_32
CALL @ni_storev
JMP @nil_again
nil_retstruct:
CALL @ni_pop
ST r1,r0,#R_T2
LD r1,r0,#R_T0
ST r1,r0,#R_T0
CALL @ni_malloc
ST r1,r0,#R_T1
LD r2,r0,#R_T2
LD r3,r0,#R_T0
CALL @ni_memcpy_raw
LD r1,r0,#R_T1
CALL @ni_push
CALL @ni_ret
JMP @nil_again
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
nil_bitstore:
CALL @ni_pop
ST r1,r0,#W_BF_VAL
CALL @ni_pop
ST r1,r0,#W_BF_ADDR
LD r2,r0,#R_T0
MOVI r3,255
BOOL.8 r2,r2,r3
ST r2,r0,#W_BF_OFF
LD r2,r0,#R_T0
SHR r2,r2,8
MOVI r3,255
BOOL.8 r2,r2,r3
ST r2,r0,#W_BF_BITS
MOVI r1,1
LD r2,r0,#W_BF_BITS
CALL @ni_shl
ADDI r1,r1,-1
ST r1,r0,#W_BF_MASK
LD r1,r0,#W_BF_VAL
LD r2,r0,#W_BF_MASK
BOOL.8 r1,r1,r2
LD r2,r0,#W_BF_OFF
CALL @ni_shl
ST r1,r0,#W_BF_FIELD
LD r1,r0,#W_BF_MASK
LD r2,r0,#W_BF_OFF
CALL @ni_shl
ST r1,r0,#W_BF_MASK
SUB r2,r0,r1
ADDI r2,r2,-1
LD r1,r0,#W_BF_ADDR
MOVI r3,#SZ_32
CALL @ni_loadv
BOOL.8 r1,r1,r2
LD r2,r0,#W_BF_FIELD
BOOL.14 r1,r1,r2
ST r1,r0,#W_BF_UNIT
LD r1,r0,#W_BF_ADDR
LD r2,r0,#W_BF_UNIT
MOVI r3,#SZ_32
CALL @ni_storev
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
LD r2,r0,#W_IRYSTOP
CMP r2,r0
JMP[EQ] @nil_again
LD r3,r0,#R_FP
CMP r3,r2
JMP[NE] @nil_again
ST r0,r0,#W_IRYSTOP
JMP @nil_halt
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
