; nccinc.nas - #include expansion for ncc, raw NaN16.
;
; #include is handled while the lexer runs, so the conditional/define state
; built by q2_directive applies to included files exactly as it does to the
; main source.  A small stack of (file path, L_WP, L_BI, L_LINE) frames makes
; the included text flow into the token stream transparently; when a file's
; NUL terminator is reached, lx_peek pops back to the including file.
;
; Resolution:
;   #include "name"  current file's directory + name, then /name
;   #include <name>  built-in standard-header table, then NPAF /name, then
;                   current file's directory + name
; Standard headers are intentionally empty: the declarations and macros are
; installed by headers.nas / ncc_builtins.
;
; ncc_compile callers may set @ncc_src_path to a .str word pointer before
; compiling so a main source loaded from NPAF resolves quoted includes
; relative to its own directory.  Zero means "/".

; ---- state ---------------------------------------------------------------
.equ W_INC_DEPTH   0xF079E
.equ W_INC_LASTSL  0xF079F
.equ W_INC_NAMEP   0xF07A0
.equ W_INC_QUOTED  0xF07A1
.equ W_INC_DIRP    0xF07A2
.equ W_INC_FILEP   0xF07A3
.equ W_INC_TMP     0xF07A4
.equ W_INC_TMP2    0xF07A5
.equ W_INC_TMP3    0xF07A6
.equ W_INC_TMP4    0xF07A7
.equ W_INC_PATH    0xF07A8
.equ W_INC_RET    0xF07A9
.equ W_INC_SYNTH  0xF07AA

.equ INC_MAXDEPTH  16
.equ INC_FRAME     12          ; words: 8 path words + L_WP/L_BI/L_LINE
.equ INC_STKW      0xF0834       ; word address of the frame stack
.equ INC_NAMEB     248000      ; byte buffers (word 62000)
.equ INC_PATHB     248032
.equ INC_TMPB      248064
.equ INC_STKB      248400      ; byte address of INC_STKW

; error codes used by this file
.equ INC_E_MISSING 0x90
.equ INC_E_DEPTH   0x91
.equ INC_E_RECUR   0x92
.equ INC_E_SYNTAX  0x93

; ------------------------------------------------------------------ init
; inc_init: reset depth and install the main file's path in frame 0.
inc_init:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_INC_DEPTH
ST r0,r0,#W_INC_SYNTH
LA r1,#INC_STKB
LD r2,r0,@ncc_src_path
CMP r2,r0
JMP[EQ] @ini_root
SHL r2,r2,2
MOVI r3,31
CALL @nf2_strcpy
JMP @ini_d
ini_root:
MOVI r2,47
STB r2,r1,0
ADDI r1,r1,1
STB r0,r1,0
ini_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ pop
; inc_pop: leave the current include frame.  Called by lx_peek at NUL.
inc_pop:
ST r15,r14,0
ADD r14,r14,r13
; source files that do not end in a newline get a virtual one
ST r0,r0,#W_INC_SYNTH
LD r6,r0,#L_WP
SHL r6,r6,2
LD r7,r0,#L_BI
ADD r6,r6,r7
CMP r6,r0
JMP[EQ] @ip_nonl
ADDI r6,r6,-1
LDB r6,r6,0
MOVI r7,10
CMP r6,r7
JMP[EQ] @ip_nonl
MOVI r6,1
ST r6,r0,#W_INC_SYNTH
ip_nonl:
LD r2,r0,#W_INC_DEPTH
CMP r2,r0
JMP[EQ] @ip_d
MOVI r3,#INC_FRAME
MUL r3,r2,r3
LA r4,#INC_STKW
ADD r4,r4,r3
LD r5,r4,8
ST r5,r0,#L_WP
LD r5,r4,9
ST r5,r0,#L_BI
LD r5,r4,10
ST r5,r0,#L_LINE
SUB r2,r2,r13
ST r2,r0,#W_INC_DEPTH
ip_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ paths
; inc_strlen: r1=C string -> r1=length
inc_strlen:
MOVI r2,0
il_l:
LDB r3,r1,0
CMP r3,r0
JMP[EQ] @il_d
ADD r1,r1,r13
ADD r2,r2,r13
JMP @il_l
il_d:
ADD r1,r2,r0
RET

; inc_dirname: -> r1=byte ptr to directory of frame[depth], ending in '/'
inc_dirname:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_INC_DEPTH
MOVI r2,#INC_FRAME
MUL r1,r1,r2
LA r2,#INC_STKW
ADD r3,r2,r1
SHL r3,r3,2
LA r4,#INC_TMPB
ST r0,r0,#W_INC_LASTSL
idn_l:
LDB r1,r3,0
CMP r1,r0
JMP[EQ] @idn_done
STB r1,r4,0
MOVI r2,47
CMP r1,r2
JMP[NE] @idn_next
ST r4,r0,#W_INC_LASTSL
idn_next:
ADD r3,r3,r13
ADD r4,r4,r13
JMP @idn_l
idn_done:
STB r0,r4,0
LD r5,r0,#W_INC_LASTSL
CMP r5,r0
JMP[NE] @idn_have
LA r5,#INC_TMPB
MOVI r2,47
STB r2,r5,0
ADDI r5,r5,1
STB r0,r5,0
JMP @idn_ret
idn_have:
ADDI r5,r5,1
STB r0,r5,0
idn_ret:
LA r1,#INC_TMPB
SUB r14,r14,r13
LD r15,r14,0
RET

; inc_build: r1=dir ptr r2=name ptr -> r1=1, INC_PATHB = dir+name; 0 too long
inc_build:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_INC_TMP
ST r2,r0,#W_INC_TMP2
CALL @inc_strlen
ST r1,r0,#W_INC_TMP3
LD r1,r0,#W_INC_TMP2
CALL @inc_strlen
ST r1,r0,#W_INC_TMP4
LD r2,r0,#W_INC_TMP3
ADD r2,r2,r1
MOVI r3,31
CMP r2,r3
JMP[GT] @ib_no
LA r4,#INC_PATHB
LD r5,r0,#W_INC_TMP
LD r7,r0,#W_INC_TMP3
ib_dl:
CMP r7,r0
JMP[EQ] @ib_nl
LDB r6,r5,0
STB r6,r4,0
ADD r5,r5,r13
ADD r4,r4,r13
SUB r7,r7,r13
JMP @ib_dl
ib_nl:
LD r5,r0,#W_INC_TMP2
LD r7,r0,#W_INC_TMP4
ib_nll:
CMP r7,r0
JMP[EQ] @ib_done
LDB r6,r5,0
STB r6,r4,0
ADD r5,r5,r13
ADD r4,r4,r13
SUB r7,r7,r13
JMP @ib_nll
ib_done:
STB r0,r4,0
MOVI r1,1
JMP @ib_d
ib_no:
MOVI r1,0
ib_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; inc_try: r1=path -> r1=1 if it exists in NPAF
inc_try:
ST r15,r14,0
ADD r14,r14,r13
CALL @nfs_find
CMP r1,r0
MOVI r1,0
MOVI[NE] r1,1
SUB r14,r14,r13
LD r15,r14,0
RET

; inc_try_root: try "/" + name -> r1=1/0
inc_try_root:
ST r15,r14,0
ADD r14,r14,r13
LA r1,@inc_root
SHL r1,r1,2
LD r2,r0,#W_INC_NAMEP
CALL @inc_build
CMP r1,r0
JMP[EQ] @itr_no
LA r1,#INC_PATHB
CALL @inc_try
JMP @itr_d
itr_no:
MOVI r1,0
itr_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; inc_resolve: r1=name ptr r2=0 quoted / 1 angle -> r1=1 and INC_PATHB set
inc_resolve:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_INC_NAMEP
ST r2,r0,#W_INC_QUOTED
LDB r3,r1,0
MOVI r4,47
CMP r3,r4
JMP[NE] @ir_rel
; absolute name: use it verbatim
LA r1,#INC_PATHB
LD r2,r0,#W_INC_NAMEP
MOVI r3,31
CALL @nf2_strcpy
LA r1,#INC_PATHB
CALL @inc_try
JMP @ir_d
ir_rel:
CALL @inc_dirname
ST r1,r0,#W_INC_DIRP
LD r2,r0,#W_INC_QUOTED
CMP r2,r0
JMP[NE] @ir_angle
; quoted: directory first, then root
LD r1,r0,#W_INC_DIRP
LD r2,r0,#W_INC_NAMEP
CALL @inc_build
CMP r1,r0
JMP[EQ] @ir_qroot
LA r1,#INC_PATHB
CALL @inc_try
CMP r1,r0
JMP[NE] @ir_yes
ir_qroot:
CALL @inc_try_root
JMP @ir_d
ir_angle:
; angle: root first, then the including directory
CALL @inc_try_root
CMP r1,r0
JMP[NE] @ir_d
LD r1,r0,#W_INC_DIRP
LD r2,r0,#W_INC_NAMEP
CALL @inc_build
CMP r1,r0
JMP[EQ] @ir_no
LA r1,#INC_PATHB
CALL @inc_try
JMP @ir_d
ir_yes:
MOVI r1,1
JMP @ir_d
ir_no:
MOVI r1,0
ir_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; inc_std_header: r1=name -> r1=1 for a built-in standard header
inc_std_header:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_INC_TMP2
LA r2,@inc_std_tab
ST r2,r0,#W_INC_TMP
ish_l:
LD r3,r0,#W_INC_TMP
LD r3,r3,0
CMP r3,r0
JMP[EQ] @ish_no
SHL r3,r3,2
LD r1,r0,#W_INC_TMP2
ADD r2,r3,r0
CALL @nf2_streq
CMP r1,r0
JMP[NE] @ish_yes
LD r3,r0,#W_INC_TMP
ADD r3,r3,r13
ST r3,r0,#W_INC_TMP
JMP @ish_l
ish_yes:
MOVI r1,1
JMP @ish_d
ish_no:
MOVI r1,0
ish_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ open
; inc_open: r1=resolved path -> push the file into the lexer input stack.
inc_open:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_INC_PATH
LD r2,r0,#W_INC_DEPTH
MOVI r3,#INC_MAXDEPTH
CMP r2,r3
JMP[GE] @io_depth
; recursion: the new path must not already be active
MOVI r4,1
io_rec_l:
LD r2,r0,#W_INC_DEPTH
CMP r4,r2
JMP[GT] @io_rec_done
MOVI r3,#INC_FRAME
MUL r3,r4,r3
LA r5,#INC_STKW
ADD r5,r5,r3
SHL r5,r5,2
LD r1,r0,#W_INC_PATH
ADD r2,r5,r0
CALL @nf2_streq
CMP r1,r0
JMP[NE] @io_rec
ADD r4,r4,r13
JMP @io_rec_l
io_rec_done:
LD r1,r0,#W_INC_PATH
CALL @nfs_data
CMP r3,r0
JMP[EQ] @io_missing
ST r1,r0,#W_INC_FILEP
LD r2,r0,#W_INC_DEPTH
ADD r2,r2,r13
ST r2,r0,#W_INC_DEPTH
MOVI r3,#INC_FRAME
MUL r3,r2,r3
LA r4,#INC_STKW
ADD r4,r4,r3
SHL r5,r4,2
MOVI r3,31
ADD r1,r5,r0
LD r2,r0,#W_INC_PATH
CALL @nf2_strcpy
; save parent cursor in the frame
LD r5,r0,#W_INC_DEPTH
MOVI r3,#INC_FRAME
MUL r3,r5,r3
LA r4,#INC_STKW
ADD r4,r4,r3
LD r6,r0,#L_WP
ST r6,r4,8
LD r6,r0,#L_BI
ST r6,r4,9
LD r6,r0,#L_LINE
ST r6,r4,10
; enter the file
LD r6,r0,#W_INC_FILEP
ST r6,r0,#L_WP
ST r0,r0,#L_BI
ST r0,r0,#W_INC_SYNTH
MOVI r6,1
ST r6,r0,#L_LINE
JMP @io_d
io_depth:
MOVI r1,#INC_E_DEPTH
CALL @ncc_err
io_rec:
MOVI r1,#INC_E_RECUR
CALL @ncc_err
io_missing:
MOVI r1,#INC_E_MISSING
CALL @ncc_err
io_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ directive
; q2dir_include: called with the lexer just past "#", at "include".
q2dir_include:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_Q2SKIP
CMP r1,r0
JMP[NE] @q2inc_skip
CALL @q2_skipsp
CALL @lx_peek
MOVI r2,34
CMP r1,r2
JMP[EQ] @q2inc_quote
MOVI r2,60
CMP r1,r2
JMP[EQ] @q2inc_angle
JMP @q2inc_syntax
q2inc_quote:
ST r0,r0,#W_INC_QUOTED
JMP @q2inc_read
q2inc_angle:
MOVI r2,1
ST r2,r0,#W_INC_QUOTED
q2inc_read:
CALL @lx_get
LA r7,#INC_NAMEB
MOVI r8,0
q2inc_rl:
CALL @lx_peek
CMP r1,r0
JMP[EQ] @q2inc_syntax
MOVI r2,10
CMP r1,r2
JMP[EQ] @q2inc_syntax
MOVI r2,34
CMP r1,r2
JMP[EQ] @q2inc_close_q
MOVI r2,62
CMP r1,r2
JMP[EQ] @q2inc_close_a
MOVI r2,31
CMP r8,r2
JMP[GE] @q2inc_syntax
STB r1,r7,0
ADD r7,r7,r13
ADD r8,r8,r13
CALL @lx_get
JMP @q2inc_rl
q2inc_close_q:
LD r2,r0,#W_INC_QUOTED
CMP r2,r0
JMP[NE] @q2inc_syntax
JMP @q2inc_close
q2inc_close_a:
LD r2,r0,#W_INC_QUOTED
CMP r2,r0
JMP[EQ] @q2inc_syntax
q2inc_close:
STB r0,r7,0
CALL @lx_get                    ; consume the closing delimiter
; resolve before eating the line so a diagnostic keeps this line number
LD r2,r0,#W_INC_QUOTED
CMP r2,r0
JMP[NE] @q2inc_go_angle
LA r1,#INC_NAMEB
MOVI r2,0
CALL @inc_resolve
JMP @q2inc_have
q2inc_go_angle:
LA r1,#INC_NAMEB
CALL @inc_std_header
CMP r1,r0
JMP[NE] @q2inc_std
LA r1,#INC_NAMEB
MOVI r2,1
CALL @inc_resolve
q2inc_have:
CMP r1,r0
JMP[EQ] @q2inc_missing
CALL @q2_eat                    ; parent cursor now after the directive line
LA r1,#INC_PATHB
CALL @inc_open
JMP @q2inc_done
q2inc_std:
CALL @q2_eat                    ; built-in header: empty replacement text
JMP @q2inc_done
q2inc_missing:
MOVI r1,#INC_E_MISSING
CALL @ncc_err
q2inc_syntax:
MOVI r1,#INC_E_SYNTAX
CALL @ncc_err
q2inc_skip:
CALL @q2_eat
q2inc_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ data
inc_root:
.str "/"

; Built-in standard headers.  Contents are empty because the libc surface and
; the standard macros/types are installed by headers.nas and ncc_builtins.
inc_std_tab:
.word @inc_sh_assert, @inc_sh_complex, @inc_sh_ctype, @inc_sh_errno
.word @inc_sh_fenv, @inc_sh_float, @inc_sh_inttypes, @inc_sh_iso646
.word @inc_sh_limits, @inc_sh_locale, @inc_sh_math, @inc_sh_setjmp
.word @inc_sh_signal, @inc_sh_stdarg, @inc_sh_stdbool, @inc_sh_stddef
.word @inc_sh_stdint, @inc_sh_stdio, @inc_sh_stdlib, @inc_sh_string
.word @inc_sh_tgmath, @inc_sh_time, @inc_sh_wchar, @inc_sh_wctype
.word @inc_sh_stdatomic, @inc_sh_threads, @inc_sh_uchar
.word @inc_sh_stdalign, @inc_sh_stdnoreturn
.word 0
inc_sh_assert:
.str "assert.h"
inc_sh_complex:
.str "complex.h"
inc_sh_ctype:
.str "ctype.h"
inc_sh_errno:
.str "errno.h"
inc_sh_fenv:
.str "fenv.h"
inc_sh_float:
.str "float.h"
inc_sh_inttypes:
.str "inttypes.h"
inc_sh_iso646:
.str "iso646.h"
inc_sh_limits:
.str "limits.h"
inc_sh_locale:
.str "locale.h"
inc_sh_math:
.str "math.h"
inc_sh_setjmp:
.str "setjmp.h"
inc_sh_signal:
.str "signal.h"
inc_sh_stdarg:
.str "stdarg.h"
inc_sh_stdbool:
.str "stdbool.h"
inc_sh_stddef:
.str "stddef.h"
inc_sh_stdint:
.str "stdint.h"
inc_sh_stdio:
.str "stdio.h"
inc_sh_stdlib:
.str "stdlib.h"
inc_sh_string:
.str "string.h"
inc_sh_tgmath:
.str "tgmath.h"
inc_sh_time:
.str "time.h"
inc_sh_wchar:
.str "wchar.h"
inc_sh_wctype:
.str "wctype.h"
inc_sh_stdatomic:
.str "stdatomic.h"
inc_sh_threads:
.str "threads.h"
inc_sh_uchar:
.str "uchar.h"
inc_sh_stdalign:
.str "stdalign.h"
inc_sh_stdnoreturn:
.str "stdnoreturn.h"

; Optional path of the main source (a .str word pointer), set by callers that
; load the main file from NPAF.  Zero means "/".
ncc_src_path:
.word 0
