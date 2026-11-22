; mpp.nas - C macro preprocessor, raw NaN16.
;
; Runs as a text pass over the source before the lexer.  It handles both
; kinds of #define:
;   - function-like macros: parameters, # stringification, ## pasting,
;     __VA_ARGS__, multi-line bodies (these used to be the only kind);
;   - object-like macros: arbitrary replacement text, including types,
;     storage classes, expressions, declarations, and empty bodies.
;
; Expansion is recursive and applies the C "blue paint" rule: a macro is
; disabled while its own replacement text is rescanned, so self-reference
; and mutual recursion terminate.  Replacement text is never expanded
; inside string literals, character constants, or comments.
;
; #define/#undef lines are consumed by this pass.  #ifdef/#ifndef are
; rewritten to #if 0/#if 1, and defined(NAME) inside #if/#elif is replaced
; with 0/1, so the lexer-side conditional machinery keeps working without
; a duplicate numeric macro table.  A small conditional stack suppresses
; definitions in obvious inactive regions (#if 0 / #ifdef of an undefined
; name); more elaborate #if expressions default to "active" here while the
; lexer still selects the correct branch.
;
; Fast path: if the source has no #define at all, the original word pointer
; is returned unchanged and nothing is copied.
;
; Address note: LA @label is a word address; LA #equ is the numeric (byte)
; address used by LDB/STB.  Source text is byte addressed, so a word pointer
; from the caller is shifted left before scanning and shifted right on return.

.equ MPTAB      1500000      ; 128 entries * 1024 bytes
.equ MPSZ       1024
.equ MPMax      128
.equ MPTMP      1633000      ; scratch identifier
.equ MPARG      1635000      ; 8 arguments * 2048 bytes
.equ MPARGSTEP  2048
.equ MPARGV     1653000      ; 8 * (ptr,len) word pairs
.equ MPSUB      1655000      ; substituted bodies, one 8 KiB slot per depth
.equ MPSUBSZ    8192
.equ MPDEPTHMAX 16
.equ MPDIS      1789000      ; disabled counts, one byte per table entry
.equ MPIFBUF    1789100      ; expanded #if / #elif expression
.equ MPIFBUFSZ  3072
.equ MPOUT1     1800000
.equ MPOUT2     2800000
.equ MPEND      3800000
.equ MPBODY     232          ; function body byte offset
.equ MPBODYMAX  792
.equ MPOBBODY   40           ; object replacement byte offset
.equ MPOBMAX    984
.equ MPPARAMOFF 40
.equ MPPARAMSZ  24
.equ MPPARAMMAX 8
.equ MPIFSTK    980000       ; word-addressed conditional stack, 3 words/level
.equ MPIFMAX    16

.equ W_MPSRC    61500
.equ W_MPDST    61501
.equ W_MPBOL    61502
.equ W_MPENT    61504
.equ W_MPCUR    61505
.equ W_MPARGN   61506
.equ W_MPARGL   61507
.equ W_MPCHAR   61508
.equ W_MPN      61509
.equ W_MPI      61510
.equ W_MPINW    61511
.equ W_MPDEPTH  61512
.equ W_MPQ      61513
.equ W_MPJ      61514
.equ W_MPK      61515
.equ W_MPSTART  61516
.equ W_MPEND    61517
.equ W_MPBLEN   61520
.equ W_MPOUTL   61521
.equ W_MPENT2   61522
.equ W_MPVA     61523
; recursive expansion state
.equ W_MXSRC    61547
.equ W_MXLEN    61548
.equ W_MXDST    61549
.equ W_MXEND    61550
.equ W_MXPOS    61551
.equ W_MPMPSUB  61552
.equ W_MPBODYLEN 61554
.equ W_MPIFMODE 61555
.equ W_MPIFDEP  61556
.equ W_MPIFSKIP 61557
.equ W_MPTMP2   61558
.equ W_MPTMP3   61559
.equ W_MPTMP4   61836
.equ W_MPIFBUFLEN 61837
.equ W_MPIDLEN  61838
.equ W_MPBODYPTR 61839

; ------------------------------------------------------------------ entry
; mp_preprocess: r1=source word ptr -> r1=source word ptr to compile
mp_preprocess:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_MPINW
SHL r1,r1,2
ST r1,r0,#W_MPSRC
CALL @mp_has_func
CMP r1,r0
JMP[NE] @mpp_run
LD r1,r0,#W_MPINW
JMP @mpp_retw
mpp_run:
LA r1,#MPOUT1
ST r1,r0,#W_MPDST
CALL @mp_pass
LA r1,#MPOUT1
SHR r1,r1,2
mpp_retw:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ detection
; mp_has_func: r1=source byte ptr -> 1 if any #define exists.
; The historical name is kept for the small standalone mpp unit tests.
mp_has_func:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_MPCUR
MOVI r1,1
ST r1,r0,#W_MPBOL
mhf_l:
LD r1,r0,#W_MPCUR
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mhf_n
LD r3,r0,#W_MPBOL
CMP r3,r0
JMP[EQ] @mhf_nb
MOVI r3,32
CMP r2,r3
JMP[EQ] @mhf_adv
MOVI r3,9
CMP r2,r3
JMP[EQ] @mhf_adv
MOVI r3,35
CMP r2,r3
JMP[NE] @mhf_nb
; '#' at the beginning of a line
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
CALL @mp_skipsp
LA r2,@mp_s_define
CALL @mp_match_word
CMP r1,r0
JMP[EQ] @mhf_skip_line
JMP @mhf_y
mhf_skip_line:
LD r1,r0,#W_MPCUR
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mhf_n
MOVI r3,10
CMP r2,r3
JMP[EQ] @mhf_nl2
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mhf_skip_line
mhf_nl2:
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
MOVI r2,1
ST r2,r0,#W_MPBOL
JMP @mhf_l
mhf_nb:
ST r0,r0,#W_MPBOL
mhf_adv:
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mhf_l
mhf_n:
MOVI r1,0
JMP @mhf_d
mhf_y:
MOVI r1,1
mhf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_skipsp: skip spaces/tabs from W_MPCUR
mp_skipsp:
ST r15,r14,0
ADD r14,r14,r13
mss_l:
LD r1,r0,#W_MPCUR
LDB r2,r1,0
MOVI r3,32
CMP r2,r3
JMP[EQ] @mss_a
MOVI r3,9
CMP r2,r3
JMP[NE] @mss_d
mss_a:
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mss_l
mss_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_match_word: r2=packed word-address string -> r1=1, W_MPCUR advanced.
; Rejects a prefix match when the next character is an identifier char.
mp_match_word:
ST r15,r14,0
ADD r14,r14,r13
SHL r2,r2,2
LD r3,r0,#W_MPCUR
mmw_l:
LDB r4,r2,0
CMP r4,r0
JMP[EQ] @mmw_y
LDB r5,r3,0
CMP r4,r5
JMP[NE] @mmw_n
ADD r2,r2,r13
ADD r3,r3,r13
JMP @mmw_l
mmw_y:
LDB r1,r3,0
ST r3,r0,#W_MPCUR
ST r1,r0,#W_MPCHAR
LD r1,r0,#W_MPCHAR
CALL @mp_idc
CMP r1,r0
JMP[NE] @mmw_n
MOVI r1,1
JMP @mmw_d
mmw_n:
MOVI r1,0
mmw_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_id0: r1=char -> r1=1 for identifier start
mp_id0:
ST r1,r0,#W_MPCHAR
LD r2,r0,#W_MPCHAR
MOVI r1,0
MOVI r3,65
CMP r2,r3
JMP[LT] @mid0_low
MOVI r3,90
CMP r2,r3
JMP[LE] @mid0_y
mid0_low:
MOVI r3,97
CMP r2,r3
JMP[LT] @mid0_us
MOVI r3,122
CMP r2,r3
JMP[LE] @mid0_y
mid0_us:
MOVI r3,95
CMP r2,r3
JMP[NE] @mid0_d
mid0_y:
MOVI r1,1
mid0_d:
RET

; mp_idc: r1=char -> r1=1 for identifier continuation
mp_idc:
ST r15,r14,0
ADD r14,r14,r13
CALL @mp_id0
CMP r1,r0
JMP[NE] @midc_y
LD r2,r0,#W_MPCHAR
MOVI r3,48
CMP r2,r3
JMP[LT] @midc_n
MOVI r3,57
CMP r2,r3
JMP[GT] @midc_n
midc_y:
MOVI r1,1
JMP @midc_d
midc_n:
MOVI r1,0
midc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ output
; mp_putc: r1=char -> append to W_MPDST
mp_putc:
LD r2,r0,#W_MPDST
LA r3,#MPEND
CMP r2,r3
JMP[GE] @mpc_d
STB r1,r2,0
ADD r2,r2,r13
ST r2,r0,#W_MPDST
mpc_d:
RET

; mp_copy1: copy the byte at W_MPSRC, advance, track beginning-of-line
mp_copy1:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_MPSRC
LDB r1,r2,0
ST r1,r0,#W_MPCHAR
CALL @mp_putc
LD r1,r0,#W_MPCHAR
MOVI r2,10
CMP r1,r2
JMP[EQ] @mpc1_nl
ST r0,r0,#W_MPBOL
JMP @mpc1_d
mpc1_nl:
MOVI r1,1
ST r1,r0,#W_MPBOL
mpc1_d:
LD r2,r0,#W_MPSRC
ADD r2,r2,r13
ST r2,r0,#W_MPSRC
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_copy_line: copy from W_MPSRC through newline; sets W_MPBOL
mp_copy_line:
ST r15,r14,0
ADD r14,r14,r13
mcl_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mcl_d
ST r1,r0,#W_MPCHAR
CALL @mp_putc
LD r1,r0,#W_MPCHAR
LD r2,r0,#W_MPSRC
ADD r2,r2,r13
ST r2,r0,#W_MPSRC
MOVI r2,10
CMP r1,r2
JMP[NE] @mcl_l
MOVI r1,1
ST r1,r0,#W_MPBOL
JMP @mcl_d2
mcl_d:
ST r0,r0,#W_MPBOL
mcl_d2:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_copy_lit: W_MPSRC at opening quote, W_MPQ holds it; copies through
; the closing quote, honouring backslash escapes.
mp_copy_lit:
ST r15,r14,0
ADD r14,r14,r13
CALL @mp_copy1
mclt_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mclt_d
ST r1,r0,#W_MPCHAR
CALL @mp_copy1
LD r1,r0,#W_MPCHAR
MOVI r2,92
CMP r1,r2
JMP[EQ] @mclt_esc
LD r2,r0,#W_MPQ
CMP r1,r2
JMP[NE] @mclt_l
JMP @mclt_d
mclt_esc:
CALL @mp_copy1
JMP @mclt_l
mclt_d:
ST r0,r0,#W_MPBOL
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ table
; Entry: 0 used, 1 nparams, 2 namelen, 3/4 bodylen (16-bit),
;        8.. name, 40.. params (24 bytes each), 232.. function body.
; Object-like entries (nparams=0) store their replacement at 40.
; mp_find_name: r1=name ptr r2=len -> r1=entry or 0
mp_find_name:
ST r1,r0,#W_MPK
ST r2,r0,#W_MPN
MOVI r3,0
mfn_l:
MOVI r4,#MPMax
CMP r3,r4
JMP[GE] @mfn_n
MOVI r4,#MPSZ
MUL r4,r3,r4
LA r5,#MPTAB
ADD r4,r4,r5
LDB r5,r4,0
CMP r5,r0
JMP[EQ] @mfn_nx
LDB r5,r4,2
LD r6,r0,#W_MPN
CMP r5,r6
JMP[NE] @mfn_nx
LD r5,r0,#W_MPK
MOVI r6,0
mfn_c:
LD r7,r0,#W_MPN
CMP r6,r7
JMP[GE] @mfn_y
ADD r7,r4,r6
ADDI r7,r7,8
LDB r7,r7,0
ADD r8,r5,r6
LDB r8,r8,0
CMP r7,r8
JMP[NE] @mfn_nx
ADD r6,r6,r13
JMP @mfn_c
mfn_y:
ADD r1,r4,r0
RET
mfn_nx:
ADD r3,r3,r13
JMP @mfn_l
mfn_n:
MOVI r1,0
RET

; mp_ent_index: r1=entry -> r1=entry index (entry size is 1024)
mp_ent_index:
LA r2,#MPTAB
SUB r1,r1,r2
SHR r1,r1,10
RET

; mp_ent_disabled: r1=index -> r1=1 if currently being expanded
mp_ent_disabled:
LA r2,#MPDIS
ADD r2,r2,r1
LDB r2,r2,0
CMP r2,r0
MOVI r1,0
MOVI[NE] r1,1
RET

; mp_get_bodylen: r1=entry -> r1=16-bit body length
mp_get_bodylen:
LDB r2,r1,3
LDB r3,r1,4
SHL r3,r3,8
BOOL.14 r1,r2,r3
RET

; mp_define_func: name in MPTMP/W_MPN, W_MPCUR at '('.
; Stores params and body; leaves W_MPCUR at newline (or NUL).
mp_define_func:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#MPTMP
LD r2,r0,#W_MPN
CALL @mp_find_name
CMP r1,r0
JMP[NE] @mdf_have
MOVI r3,0
mdf_alloc:
MOVI r4,#MPMax
CMP r3,r4
JMP[GE] @mdf_full
MOVI r4,#MPSZ
MUL r4,r3,r4
LA r5,#MPTAB
ADD r4,r4,r5
LDB r5,r4,0
CMP r5,r0
JMP[EQ] @mdf_use
ADD r3,r3,r13
JMP @mdf_alloc
mdf_full:
MOVI r1,0
JMP @mdf_d
mdf_use:
ADD r1,r4,r0
mdf_have:
ST r1,r0,#W_MPENT
ST r0,r0,#W_MPENT2
MOVI r4,1
STB r4,r1,0
MOVI r4,1
STB r4,r1,1
LD r4,r0,#W_MPN
STB r4,r1,2
STB r0,r1,3
STB r0,r1,4
MOVI r4,1
STB r4,r1,5
; copy the name
MOVI r4,0
mdf_name:
LD r5,r0,#W_MPN
CMP r4,r5
JMP[GE] @mdf_params
LA r6,#MPTMP
ADD r6,r6,r4
LDB r6,r6,0
LD r7,r0,#W_MPENT
ADD r7,r7,r4
ADDI r7,r7,8
STB r6,r7,0
ADD r4,r4,r13
JMP @mdf_name
mdf_params:
; consume '('
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
CALL @mp_skipsp
ST r0,r0,#W_MPARGN
mdf_pl:
LD r1,r0,#W_MPCUR
LDB r2,r1,0
MOVI r3,41
CMP r2,r3
JMP[EQ] @mdf_pdone
MOVI r3,46
CMP r2,r3
JMP[EQ] @mdf_variadic
; read one parameter name into slot W_MPARGN
LD r2,r0,#W_MPARGN
MOVI r3,#MPPARAMMAX
CMP r2,r3
JMP[GE] @mdf_pskip
MOVI r3,#MPPARAMSZ
MUL r3,r2,r3
LD r4,r0,#W_MPENT
ADD r3,r4,r3
ADDI r3,r3,#MPPARAMOFF
STB r0,r3,0
LD r4,r0,#W_MPCUR
LDB r1,r4,0
CALL @mp_id0
CMP r1,r0
JMP[EQ] @mdf_pskip
mdf_pc:
LD r4,r0,#W_MPCUR
LDB r1,r4,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mdf_pend
LD r4,r0,#W_MPCUR
LDB r1,r4,0
ST r1,r0,#W_MPCHAR
; slot address again
LD r2,r0,#W_MPARGN
MOVI r3,#MPPARAMSZ
MUL r3,r2,r3
LD r4,r0,#W_MPENT
ADD r3,r4,r3
ADDI r3,r3,#MPPARAMOFF
LDB r5,r3,0
MOVI r6,22
CMP r5,r6
JMP[GE] @mdf_padv
ADD r5,r5,r13
STB r5,r3,0
ADD r3,r3,r5
LD r1,r0,#W_MPCHAR
STB r1,r3,0
mdf_padv:
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mdf_pc
mdf_variadic:
LD r1,r0,#W_MPCUR
ADDI r1,r1,3
ST r1,r0,#W_MPCUR
MOVI r1,1
ST r1,r0,#W_MPENT2
CALL @mp_skipsp
JMP @mdf_pl
mdf_pend:
LD r1,r0,#W_MPARGN
ADD r1,r1,r13
ST r1,r0,#W_MPARGN
mdf_pskip:
CALL @mp_skipsp
LD r1,r0,#W_MPCUR
LDB r2,r1,0
MOVI r3,44
CMP r2,r3
JMP[NE] @mdf_pl
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
CALL @mp_skipsp
JMP @mdf_pl
mdf_pdone:
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
LD r2,r0,#W_MPENT
LD r1,r0,#W_MPARGN
LD r3,r0,#W_MPENT2
CMP r3,r0
JMP[EQ] @mdf_pd_st
SHL r3,r3,7
ADD r1,r1,r3
mdf_pd_st:
STB r1,r2,1
; body starts after spaces (newlines are not part of the body)
CALL @mp_skipsp
MOVI r4,0
mdf_body:
LD r1,r0,#W_MPCUR
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mdf_bdone
MOVI r2,10
CMP r1,r2
JMP[EQ] @mdf_bdone
MOVI r2,13
CMP r1,r2
JMP[EQ] @mdf_bdone
; backslash-newline continuation
MOVI r2,92
CMP r1,r2
JMP[NE] @mdf_bstore
LD r2,r0,#W_MPCUR
LDB r2,r2,1
MOVI r3,10
CMP r2,r3
JMP[EQ] @mdf_bcont
MOVI r3,13
CMP r2,r3
JMP[NE] @mdf_bstore
LD r2,r0,#W_MPCUR
LDB r2,r2,2
MOVI r3,10
CMP r2,r3
JMP[EQ] @mdf_bcont3
mdf_bcont:
LD r1,r0,#W_MPCUR
ADDI r1,r1,2
ST r1,r0,#W_MPCUR
JMP @mdf_body
mdf_bcont3:
LD r1,r0,#W_MPCUR
ADDI r1,r1,3
ST r1,r0,#W_MPCUR
JMP @mdf_body
mdf_bstore:
MOVI r2,#MPBODYMAX
CMP r4,r2
JMP[GE] @mdf_badv
LD r2,r0,#W_MPENT
ADD r2,r2,r4
ADDI r2,r2,#MPBODY
STB r1,r2,0
ADD r4,r4,r13
mdf_badv:
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mdf_body
mdf_bdone:
LD r2,r0,#W_MPENT
STB r4,r2,3
SHR r4,r4,8
STB r4,r2,4
MOVI r1,1
JMP @mdf_d
mdf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_define_obj: name in MPTMP/W_MPN, W_MPCUR after the name.
; Stores arbitrary replacement text at offset 40; leaves W_MPCUR at newline.
mp_define_obj:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#MPTMP
LD r2,r0,#W_MPN
CALL @mp_find_name
CMP r1,r0
JMP[NE] @mdo_have
MOVI r3,0
mdo_alloc:
MOVI r4,#MPMax
CMP r3,r4
JMP[GE] @mdo_full
MOVI r4,#MPSZ
MUL r4,r3,r4
LA r5,#MPTAB
ADD r4,r4,r5
LDB r5,r4,0
CMP r5,r0
JMP[EQ] @mdo_use
ADD r3,r3,r13
JMP @mdo_alloc
mdo_full:
MOVI r1,0
JMP @mdo_d
mdo_use:
ADD r1,r4,r0
mdo_have:
ST r1,r0,#W_MPENT
MOVI r4,1
STB r4,r1,0
STB r0,r1,1
LD r4,r0,#W_MPN
STB r4,r1,2
STB r0,r1,3
STB r0,r1,4
STB r0,r1,5
; copy the name
MOVI r4,0
mdo_name:
LD r5,r0,#W_MPN
CMP r4,r5
JMP[GE] @mdo_body
LA r6,#MPTMP
ADD r6,r6,r4
LDB r6,r6,0
LD r7,r0,#W_MPENT
ADD r7,r7,r4
ADDI r7,r7,8
STB r6,r7,0
ADD r4,r4,r13
JMP @mdo_name
mdo_body:
CALL @mp_skipsp
MOVI r4,0
mdo_bl:
LD r1,r0,#W_MPCUR
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mdo_done
MOVI r2,10
CMP r1,r2
JMP[EQ] @mdo_done
MOVI r2,13
CMP r1,r2
JMP[EQ] @mdo_done
; backslash-newline continuation (also \r\n)
MOVI r2,92
CMP r1,r2
JMP[NE] @mdo_store
LD r2,r0,#W_MPCUR
LDB r2,r2,1
MOVI r3,10
CMP r2,r3
JMP[EQ] @mdo_cont
MOVI r3,13
CMP r2,r3
JMP[NE] @mdo_store
LD r2,r0,#W_MPCUR
LDB r2,r2,2
MOVI r3,10
CMP r2,r3
JMP[EQ] @mdo_cont3
LD r1,r0,#W_MPCUR
ADDI r1,r1,2
ST r1,r0,#W_MPCUR
JMP @mdo_bl
mdo_cont3:
LD r1,r0,#W_MPCUR
ADDI r1,r1,3
ST r1,r0,#W_MPCUR
JMP @mdo_bl
mdo_cont:
LD r1,r0,#W_MPCUR
ADDI r1,r1,2
ST r1,r0,#W_MPCUR
JMP @mdo_bl
mdo_store:
MOVI r2,#MPOBMAX
CMP r4,r2
JMP[GE] @mdo_adv
LD r2,r0,#W_MPENT
ADD r2,r2,r4
ADDI r2,r2,#MPOBBODY
STB r1,r2,0
ADD r4,r4,r13
mdo_adv:
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mdo_bl
mdo_done:
LD r2,r0,#W_MPENT
STB r4,r2,3
SHR r4,r4,8
STB r4,r2,4
MOVI r1,1
JMP @mdo_d
mdo_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ pass
; mp_pass: copy/expand W_MPSRC into W_MPDST, one recursive pass.
mp_pass:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,1
ST r1,r0,#W_MPBOL
ST r0,r0,#W_MPDEPTH
ST r0,r0,#W_MPIFSKIP
ST r0,r0,#W_MPIFDEP
mp_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mp_fin
LD r2,r0,#W_MPBOL
CMP r2,r0
JMP[EQ] @mp_nb
MOVI r2,32
CMP r1,r2
JMP[EQ] @mp_bolws
MOVI r2,9
CMP r1,r2
JMP[EQ] @mp_bolws
MOVI r2,35
CMP r1,r2
JMP[EQ] @mp_bolhash
JMP @mp_nb
mp_bolws:
CALL @mp_putc
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
JMP @mp_l
mp_bolhash:
CALL @mp_directive
JMP @mp_l
mp_nb:
ST r0,r0,#W_MPBOL
LD r1,r0,#W_MPIFSKIP
CMP r1,r0
JMP[NE] @mp_skip_line
CALL @mp_scan
JMP @mp_l
mp_skip_line:
CALL @mp_copy_line
JMP @mp_l
mp_fin:
MOVI r1,0
CALL @mp_putc
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_scan: one normal-text token/character at W_MPSRC
mp_scan:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPSRC
LDB r1,r1,0
ST r1,r0,#W_MPCHAR
MOVI r2,34
CMP r1,r2
JMP[EQ] @mp_str
MOVI r2,39
CMP r1,r2
JMP[EQ] @mp_chr
MOVI r2,47
CMP r1,r2
JMP[EQ] @mp_slash
LD r1,r0,#W_MPCHAR
CALL @mp_id0
CMP r1,r0
JMP[NE] @mp_ident
CALL @mp_copy1
JMP @mp_s_d
mp_str:
MOVI r1,34
ST r1,r0,#W_MPQ
CALL @mp_copy_lit
JMP @mp_s_d
mp_chr:
MOVI r1,39
ST r1,r0,#W_MPQ
CALL @mp_copy_lit
JMP @mp_s_d
mp_slash:
LD r1,r0,#W_MPSRC
LDB r2,r1,1
MOVI r3,47
CMP r2,r3
JMP[EQ] @mp_lcom
MOVI r3,42
CMP r2,r3
JMP[EQ] @mp_bcom
CALL @mp_copy1
JMP @mp_s_d
mp_lcom:
CALL @mp_copy1
CALL @mp_copy1
mp_lcom_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mp_s_d
CALL @mp_copy1
LD r1,r0,#W_MPCHAR
MOVI r2,10
CMP r1,r2
JMP[NE] @mp_lcom_l
JMP @mp_s_d
mp_bcom:
CALL @mp_copy1
CALL @mp_copy1
mp_bcom_l:
LD r1,r0,#W_MPSRC
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mp_s_d
MOVI r3,42
CMP r2,r3
JMP[NE] @mp_bcom_a
LDB r3,r1,1
MOVI r4,47
CMP r3,r4
JMP[NE] @mp_bcom_a
CALL @mp_copy1
CALL @mp_copy1
JMP @mp_s_d
mp_bcom_a:
CALL @mp_copy1
JMP @mp_bcom_l
mp_s_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_ident: identifier at W_MPSRC, expand or copy
mp_ident:
ST r15,r14,0
ADD r14,r14,r13
LA r4,#MPTMP
MOVI r5,0
mp_id_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mp_id_end
LD r1,r0,#W_MPSRC
LDB r1,r1,0
STB r1,r4,0
ADD r4,r4,r13
ADD r5,r5,r13
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
JMP @mp_id_l
mp_id_end:
ST r5,r0,#W_MPN
ST r5,r0,#W_MPIDLEN
LA r1,#MPTMP
LD r2,r0,#W_MPN
CALL @mp_find_name
CMP r1,r0
JMP[EQ] @mp_copy_id
ST r1,r0,#W_MPENT
CALL @mp_ent_index
ST r1,r0,#W_MPTMP2
CALL @mp_ent_disabled
CMP r1,r0
JMP[NE] @mp_copy_id
LD r1,r0,#W_MPENT
LDB r2,r1,5
CMP r2,r0
JMP[EQ] @mp_obj
; function-like: only expand when '(' follows (after whitespace)
LD r1,r0,#W_MPSRC
ST r1,r0,#W_MPSTART
ST r1,r0,#W_MPCUR
mp_call_sp:
LD r1,r0,#W_MPCUR
LDB r2,r1,0
MOVI r3,32
CMP r2,r3
JMP[EQ] @mp_call_sp_a
MOVI r3,9
CMP r2,r3
JMP[EQ] @mp_call_sp_a
MOVI r3,10
CMP r2,r3
JMP[EQ] @mp_call_sp_a
MOVI r3,13
CMP r2,r3
JMP[NE] @mp_call_chk
mp_call_sp_a:
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mp_call_sp
mp_call_chk:
MOVI r3,40
CMP r2,r3
JMP[NE] @mp_copy_id
LD r1,r0,#W_MPCUR
ST r1,r0,#W_MPSRC
CALL @mp_expand_call
CMP r1,r0
JMP[EQ] @mp_call_fail
ST r1,r0,#W_MPBODYLEN
ST r2,r0,#W_MPBODYPTR
LD r1,r0,#W_MPSRC
ST r1,r0,#W_MPTMP4
LD r1,r0,#W_MPBODYPTR
LD r2,r0,#W_MPBODYLEN
LD r3,r0,#W_MPTMP2
LD r4,r0,#W_MPDST
LA r5,#MPEND
CALL @mp_expand_macro
ST r1,r0,#W_MPDST
LD r1,r0,#W_MPTMP4
ST r1,r0,#W_MPSRC
CALL @mp_leave_call
ST r0,r0,#W_MPBOL
JMP @mp_i_d
mp_call_fail:
LD r1,r0,#W_MPSTART
ST r1,r0,#W_MPSRC
JMP @mp_copy_id
mp_obj:
LD r1,r0,#W_MPENT
CALL @mp_get_bodylen
ST r1,r0,#W_MPBODYLEN
LD r1,r0,#W_MPENT
ADDI r1,r1,#MPOBBODY
LD r2,r0,#W_MPBODYLEN
LD r3,r0,#W_MPTMP2
LD r4,r0,#W_MPDST
LA r5,#MPEND
LD r6,r0,#W_MPSRC
ST r6,r0,#W_MPTMP4
CALL @mp_expand_macro
ST r1,r0,#W_MPDST
LD r1,r0,#W_MPTMP4
ST r1,r0,#W_MPSRC
ST r0,r0,#W_MPBOL
JMP @mp_i_d
mp_copy_id:
LA r4,#MPTMP
LD r5,r0,#W_MPIDLEN
mp_id_ol:
CMP r5,r0
JMP[EQ] @mp_id_od
LDB r1,r4,0
CALL @mp_putc
ADD r4,r4,r13
SUB r5,r5,r13
JMP @mp_id_ol
mp_id_od:
ST r0,r0,#W_MPBOL
mp_i_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ xscan
; mp_xscan: recursively expand a byte span.
;   r1=src r2=len r3=dst r4=end -> r1=new dst
mp_xscan:
ST r15,r14,0
ADD r14,r14,r13
LD r5,r0,#W_MXSRC
ST r5,r14,0
LD r5,r0,#W_MXLEN
ST r5,r14,1
LD r5,r0,#W_MXDST
ST r5,r14,2
LD r5,r0,#W_MXEND
ST r5,r14,3
LD r5,r0,#W_MXPOS
ST r5,r14,4
ADDI r14,r14,5
ST r1,r0,#W_MXSRC
ST r2,r0,#W_MXLEN
ST r3,r0,#W_MXDST
ST r4,r0,#W_MXEND
ST r0,r0,#W_MXPOS
xs_l:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_done
LD r1,r0,#W_MXSRC
LD r2,r0,#W_MXPOS
ADD r1,r1,r2
LDB r1,r1,0
ST r1,r0,#W_MPCHAR
MOVI r2,34
CMP r1,r2
JMP[EQ] @xs_lit
MOVI r2,39
CMP r1,r2
JMP[EQ] @xs_lit
MOVI r2,47
CMP r1,r2
JMP[EQ] @xs_slash
LD r1,r0,#W_MPCHAR
CALL @mp_id0
CMP r1,r0
JMP[NE] @xs_ident
CALL @mp_xcopy1
JMP @xs_l
xs_lit:
LD r1,r0,#W_MPCHAR
ST r1,r0,#W_MPQ
CALL @mp_xcopy1
xs_lit_l:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_done
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
ST r2,r0,#W_MPCHAR
CALL @mp_xcopy1
LD r1,r0,#W_MPCHAR
MOVI r2,92
CMP r1,r2
JMP[EQ] @xs_lit_esc
LD r2,r0,#W_MPQ
CMP r1,r2
JMP[NE] @xs_lit_l
JMP @xs_l
xs_lit_esc:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_done
CALL @mp_xcopy1
JMP @xs_lit_l
xs_slash:
LD r1,r0,#W_MXPOS
ADD r2,r1,r13
LD r3,r0,#W_MXLEN
CMP r2,r3
JMP[GE] @xs_char
LD r1,r0,#W_MXSRC
ADD r1,r1,r2
LDB r1,r1,0
MOVI r2,47
CMP r1,r2
JMP[EQ] @xs_lcom
MOVI r2,42
CMP r1,r2
JMP[EQ] @xs_bcom
xs_char:
CALL @mp_xcopy1
JMP @xs_l
xs_lcom:
CALL @mp_xcopy1
CALL @mp_xcopy1
xs_lcom_l:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_done
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
ST r2,r0,#W_MPCHAR
CALL @mp_xcopy1
LD r1,r0,#W_MPCHAR
MOVI r2,10
CMP r1,r2
JMP[NE] @xs_lcom_l
JMP @xs_l
xs_bcom:
CALL @mp_xcopy1
CALL @mp_xcopy1
xs_bcom_l:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_done
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
MOVI r3,42
CMP r2,r3
JMP[NE] @xs_bcom_a
; '*' at end of span: no room for '/'
ADD r3,r1,r13
LD r4,r0,#W_MXLEN
CMP r3,r4
JMP[GE] @xs_bcom_a
LD r4,r0,#W_MXSRC
ADD r4,r4,r1
LDB r4,r4,1
MOVI r5,47
CMP r4,r5
JMP[NE] @xs_bcom_a
CALL @mp_xcopy1
CALL @mp_xcopy1
JMP @xs_l
xs_bcom_a:
CALL @mp_xcopy1
JMP @xs_bcom_l
xs_ident:
LA r4,#MPTMP
MOVI r5,0
xs_id_l:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_id_end
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
ST r2,r0,#W_MPCHAR
ADD r1,r2,r0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @xs_id_end
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
STB r2,r4,0
ADD r4,r4,r13
ADD r5,r5,r13
ADD r1,r1,r13
ST r1,r0,#W_MXPOS
JMP @xs_id_l
xs_id_end:
ST r5,r0,#W_MPN
ST r5,r0,#W_MPIDLEN
LD r1,r0,#W_MPIFMODE
CMP r1,r0
JMP[EQ] @xs_id_norm
LA r1,#MPTMP
MOVI r2,7
CALL @mp_is_defined
CMP r1,r0
JMP[NE] @xs_defined
xs_id_norm:
LA r1,#MPTMP
LD r2,r0,#W_MPN
CALL @mp_find_name
CMP r1,r0
JMP[EQ] @xs_copy_id
ST r1,r0,#W_MPENT
CALL @mp_ent_index
ST r1,r0,#W_MPTMP2
CALL @mp_ent_disabled
CMP r1,r0
JMP[NE] @xs_copy_id
LD r1,r0,#W_MPENT
LDB r2,r1,5
CMP r2,r0
JMP[EQ] @xs_obj
CALL @xs_skip_ws
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_copy_id
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
MOVI r3,40
CMP r2,r3
JMP[NE] @xs_copy_id
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
ST r2,r0,#W_MPCUR
ST r2,r0,#W_MPSRC
CALL @mp_expand_call
CMP r1,r0
JMP[EQ] @xs_copy_id
ST r1,r0,#W_MPBODYLEN
ST r2,r0,#W_MPBODYPTR
LD r1,r0,#W_MPSRC
LD r2,r0,#W_MXSRC
SUB r1,r1,r2
ST r1,r0,#W_MXPOS
LD r1,r0,#W_MPBODYPTR
LD r2,r0,#W_MPBODYLEN
LD r3,r0,#W_MPTMP2
LD r4,r0,#W_MXDST
LD r5,r0,#W_MXEND
CALL @mp_expand_macro
ST r1,r0,#W_MXDST
CALL @mp_leave_call
JMP @xs_l
xs_obj:
LD r1,r0,#W_MPENT
CALL @mp_get_bodylen
ST r1,r0,#W_MPBODYLEN
LD r1,r0,#W_MPENT
ADDI r1,r1,#MPOBBODY
LD r2,r0,#W_MPBODYLEN
LD r3,r0,#W_MPTMP2
LD r4,r0,#W_MXDST
LD r5,r0,#W_MXEND
CALL @mp_expand_macro
ST r1,r0,#W_MXDST
JMP @xs_l
xs_copy_id:
LA r4,#MPTMP
LD r5,r0,#W_MPIDLEN
xs_cp_l:
CMP r5,r0
JMP[EQ] @xs_l
LDB r1,r4,0
CALL @mp_xputc
ADD r4,r4,r13
SUB r5,r5,r13
JMP @xs_cp_l
xs_done:
LD r1,r0,#W_MXDST
ADDI r14,r14,-5
LD r5,r14,0
ST r5,r0,#W_MXSRC
LD r5,r14,1
ST r5,r0,#W_MXLEN
LD r5,r14,2
ST r5,r0,#W_MXDST
LD r5,r14,3
ST r5,r0,#W_MXEND
LD r5,r14,4
ST r5,r0,#W_MXPOS
SUB r14,r14,r13
LD r15,r14,0
RET

; xs_skip_ws: advance W_MXPOS over spaces/tabs/CR/LF
xs_skip_ws:
ST r15,r14,0
ADD r14,r14,r13
xsw_l:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xsw_d
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
MOVI r3,32
CMP r2,r3
JMP[EQ] @xsw_a
MOVI r3,9
CMP r2,r3
JMP[EQ] @xsw_a
MOVI r3,10
CMP r2,r3
JMP[EQ] @xsw_a
MOVI r3,13
CMP r2,r3
JMP[NE] @xsw_d
xsw_a:
ADD r1,r1,r13
ST r1,r0,#W_MXPOS
JMP @xsw_l
xsw_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; xs_defined: W_MXPOS after "defined"; emit 1/0 and consume the operand
xs_defined:
CALL @xs_skip_ws
ST r0,r0,#W_MPTMP3
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_def_zero
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
MOVI r3,40
CMP r2,r3
JMP[NE] @xs_def_name
MOVI r3,1
ST r3,r0,#W_MPTMP3
ADD r1,r1,r13
ST r1,r0,#W_MXPOS
CALL @xs_skip_ws
xs_def_name:
LA r4,#MPTMP
MOVI r5,0
xs_def_l:
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_def_end
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
ST r2,r0,#W_MPCHAR
ADD r1,r2,r0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @xs_def_end
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
STB r2,r4,0
ADD r4,r4,r13
ADD r5,r5,r13
ADD r1,r1,r13
ST r1,r0,#W_MXPOS
JMP @xs_def_l
xs_def_end:
ST r5,r0,#W_MPN
CALL @xs_skip_ws
LD r1,r0,#W_MPTMP3
CMP r1,r0
JMP[EQ] @xs_def_lookup
LD r1,r0,#W_MXPOS
LD r2,r0,#W_MXLEN
CMP r1,r2
JMP[GE] @xs_def_lookup
LD r2,r0,#W_MXSRC
ADD r2,r2,r1
LDB r2,r2,0
MOVI r3,41
CMP r2,r3
JMP[NE] @xs_def_lookup
ADD r1,r1,r13
ST r1,r0,#W_MXPOS
xs_def_lookup:
LA r1,#MPTMP
LD r2,r0,#W_MPN
CALL @mp_find_name
CMP r1,r0
JMP[EQ] @xs_def_zero
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @xs_def_zero
MOVI r1,49
JMP @xs_def_emit
xs_def_zero:
MOVI r1,48
xs_def_emit:
CALL @mp_xputc
JMP @xs_l

; mp_is_defined: r1=name ptr r2=len -> 1 if the name is "defined"
mp_is_defined:
MOVI r3,7
CMP r2,r3
JMP[NE] @midf_n
LA r3,@mp_s_defined
SHL r3,r3,2
MOVI r4,0
midf_l:
CMP r4,r2
JMP[GE] @midf_y
ADD r5,r1,r4
LDB r5,r5,0
ADD r6,r3,r4
LDB r6,r6,0
CMP r5,r6
JMP[NE] @midf_n
ADD r4,r4,r13
JMP @midf_l
midf_y:
MOVI r1,1
RET
midf_n:
MOVI r1,0
RET

; mp_xcopy1: copy the byte at W_MXSRC+W_MXPOS, advance W_MXPOS
mp_xcopy1:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MXSRC
LD r2,r0,#W_MXPOS
ADD r1,r1,r2
LDB r1,r1,0
CALL @mp_xputc
LD r1,r0,#W_MXPOS
ADD r1,r1,r13
ST r1,r0,#W_MXPOS
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_xputc: r1=char -> append to W_MXDST while < W_MXEND
mp_xputc:
LD r2,r0,#W_MXDST
LD r3,r0,#W_MXEND
CMP r2,r3
JMP[GE] @xpc_d
STB r1,r2,0
ADD r2,r2,r13
ST r2,r0,#W_MXDST
xpc_d:
RET

; ------------------------------------------------------------------ directives
mp_directive:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPSRC
ST r1,r0,#W_MPI
CALL @mp_dir_reset
LA r2,@mp_s_define
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_define
CALL @mp_dir_reset
LA r2,@mp_s_undef
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_undef
CALL @mp_dir_reset
LA r2,@mp_s_ifdef
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_ifdef
CALL @mp_dir_reset
LA r2,@mp_s_ifndef
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_ifndef
CALL @mp_dir_reset
LA r2,@mp_s_if
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_if
CALL @mp_dir_reset
LA r2,@mp_s_elif
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_elif
CALL @mp_dir_reset
LA r2,@mp_s_else
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_else
CALL @mp_dir_reset
LA r2,@mp_s_endif
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_dir_endif
JMP @mp_dir_copy
mp_dir_reset:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
CALL @mp_skipsp
SUB r14,r14,r13
LD r15,r14,0
RET
mp_dir_define:
LD r1,r0,#W_MPIFSKIP
CMP r1,r0
JMP[NE] @mp_dir_eat
CALL @mp_skipsp
CALL @mp_read_word
LD r1,r0,#W_MPN
CMP r1,r0
JMP[EQ] @mp_dir_eat
; entry name area is 32 bytes (offsets 8..39); ignore over-long names
MOVI r2,32
CMP r1,r2
JMP[GT] @mp_dir_eat
LD r1,r0,#W_MPCUR
LDB r1,r1,0
MOVI r2,40
CMP r1,r2
JMP[NE] @mp_dir_defobj
CALL @mp_define_func
JMP @mp_dir_eat
mp_dir_defobj:
CALL @mp_define_obj
JMP @mp_dir_eat
mp_dir_undef:
LD r1,r0,#W_MPIFSKIP
CMP r1,r0
JMP[NE] @mp_dir_eat
CALL @mp_skipsp
CALL @mp_read_word
LD r2,r0,#W_MPN
CMP r2,r0
JMP[EQ] @mp_dir_eat
LA r1,#MPTMP
CALL @mp_find_name
CMP r1,r0
JMP[EQ] @mp_dir_eat
STB r0,r1,0
JMP @mp_dir_eat
mp_dir_ifdef:
CALL @mp_skipsp
CALL @mp_read_word
CALL @mp_defined_value
ST r1,r0,#W_MPTMP3
CALL @mp_if_push
CALL @mp_emit_if_prefix
LD r1,r0,#W_MPTMP3
CALL @mp_emit_cond_digit
CALL @mp_dir_eat
JMP @mp_dir_ret
mp_dir_ifndef:
CALL @mp_skipsp
CALL @mp_read_word
CALL @mp_defined_value
MOVI r2,1
SUB r1,r2,r1
ST r1,r0,#W_MPTMP3
CALL @mp_if_push
CALL @mp_emit_if_prefix
LD r1,r0,#W_MPTMP3
CALL @mp_emit_cond_digit
CALL @mp_dir_eat
JMP @mp_dir_ret
mp_dir_if:
CALL @mp_expand_condline
CALL @mp_cond_from_buf
CALL @mp_if_push
CALL @mp_emit_if_prefix
CALL @mp_emit_condbuf
CALL @mp_dir_eat
JMP @mp_dir_ret
mp_dir_elif:
CALL @mp_expand_condline
CALL @mp_cond_from_buf
ST r1,r0,#W_MPTMP3
CALL @mp_if_elif
CALL @mp_emit_elif_prefix
CALL @mp_emit_condbuf
CALL @mp_dir_eat
JMP @mp_dir_ret
mp_dir_else:
CALL @mp_if_else
CALL @mp_dir_copy
JMP @mp_dir_ret
mp_dir_endif:
CALL @mp_if_pop
CALL @mp_dir_copy
JMP @mp_dir_ret
mp_dir_eat:
CALL @mp_eatline
JMP @mp_dir_ret
mp_dir_copy:
LD r1,r0,#W_MPI
ST r1,r0,#W_MPSRC
CALL @mp_copy_line
mp_dir_ret:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_read_word: read identifier at W_MPCUR into MPTMP, W_MPN=len
mp_read_word:
ST r15,r14,0
ADD r14,r14,r13
LA r4,#MPTMP
MOVI r5,0
mp_rw_l:
LD r1,r0,#W_MPCUR
LDB r1,r1,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mrw_d
LD r1,r0,#W_MPCUR
LDB r1,r1,0
STB r1,r4,0
ADD r4,r4,r13
ADD r5,r5,r13
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mp_rw_l
mrw_d:
ST r5,r0,#W_MPN
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_defined_value: MPTMP/W_MPN -> r1=1 if defined and active
mp_defined_value:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#MPTMP
LD r2,r0,#W_MPN
CALL @mp_find_name
CMP r1,r0
JMP[EQ] @mdv_n
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mdv_n
MOVI r1,1
JMP @mdv_d
mdv_n:
MOVI r1,0
mdv_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_eatline: consume the physical line from W_MPSRC (including backslash
; continuations) and emit one newline.
mp_eatline:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPSRC
mel_l:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @mel_eof
MOVI r3,10
CMP r2,r3
JMP[EQ] @mel_nl
MOVI r3,92
CMP r2,r3
JMP[NE] @mel_adv
LDB r3,r1,1
MOVI r4,10
CMP r3,r4
JMP[EQ] @mel_skip2
MOVI r4,13
CMP r3,r4
JMP[NE] @mel_adv
; backslash CRLF?
LDB r4,r1,2
MOVI r5,10
CMP r4,r5
JMP[EQ] @mel_skip3
mel_skip2:
ADD r1,r1,r13
ADD r1,r1,r13
JMP @mel_l
mel_skip3:
ADD r1,r1,r13
ADD r1,r1,r13
ADD r1,r1,r13
JMP @mel_l
mel_adv:
ADD r1,r1,r13
JMP @mel_l
mel_nl:
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
JMP @mel_put
mel_eof:
ST r1,r0,#W_MPSRC
mel_put:
MOVI r1,10
CALL @mp_putc
MOVI r1,1
ST r1,r0,#W_MPBOL
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_expand_condline: expand the rest of the directive line into MPIFBUF
; using if-mode (defined() substituted); returns r1=buffer length.
mp_expand_condline:
ST r15,r14,0
ADD r14,r14,r13
; length until newline or NUL
LD r1,r0,#W_MPCUR
MOVI r2,0
mec_len_l:
ADD r3,r1,r2
LDB r3,r3,0
CMP r3,r0
JMP[EQ] @mec_len_d
MOVI r4,10
CMP r3,r4
JMP[EQ] @mec_len_d
ADD r2,r2,r13
JMP @mec_len_l
mec_len_d:
ST r2,r0,#W_MPTMP2
LD r1,r0,#W_MPSRC
ST r1,r0,#W_MPTMP4
MOVI r1,1
ST r1,r0,#W_MPIFMODE
LD r1,r0,#W_MPCUR
LD r2,r0,#W_MPTMP2
LA r3,#MPIFBUF
LA r4,#MPIFBUF
ADDI r4,r4,#MPIFBUFSZ
CALL @mp_xscan
ST r0,r0,#W_MPIFMODE
LD r2,r0,#W_MPTMP4
ST r2,r0,#W_MPSRC
LA r2,#MPIFBUF
SUB r1,r1,r2
ST r1,r0,#W_MPIFBUFLEN
; NUL terminate
ADD r2,r2,r1
STB r0,r2,0
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_cond_from_buf: r1=len -> r1=0/1 (small evaluator for skip tracking)
mp_cond_from_buf:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_MPIFBUFLEN
LA r10,#MPIFBUF
MOVI r4,0
mcf_l:
CMP r4,r1
JMP[GE] @mcf_zero
ADD r5,r10,r4
LDB r5,r5,0
MOVI r6,32
CMP r5,r6
JMP[EQ] @mcf_l_a
MOVI r6,9
CMP r5,r6
JMP[EQ] @mcf_l_a
MOVI r6,13
CMP r5,r6
JMP[EQ] @mcf_l_a
JMP @mcf_body
mcf_l_a:
ADD r4,r4,r13
JMP @mcf_l
mcf_body:
ST r4,r0,#W_MPTMP2
; trim end
mcf_r:
CMP r1,r4
JMP[LE] @mcf_zero
ADDI r5,r1,-1
ADD r6,r10,r5
LDB r6,r6,0
MOVI r7,32
CMP r6,r7
JMP[EQ] @mcf_r_a
MOVI r7,9
CMP r6,r7
JMP[EQ] @mcf_r_a
MOVI r7,13
CMP r6,r7
JMP[NE] @mcf_shape
mcf_r_a:
SUB r1,r1,r13
JMP @mcf_r
mcf_shape:
ST r0,r0,#W_MPTMP3
ADD r5,r10,r4
LDB r5,r5,0
MOVI r6,33
CMP r5,r6
JMP[NE] @mcf_value
MOVI r6,1
ST r6,r0,#W_MPTMP3
ADD r4,r4,r13
CMP r4,r1
JMP[GE] @mcf_zero
mcf_value:
; classify a single token: 0/false, a numeric token, or an undefined
; identifier (which evaluates to 0 in #if)
ADD r7,r1,r0
SUB r7,r7,r4
CMP r7,r0
JMP[EQ] @mcf_zero
ADD r5,r10,r4
LDB r5,r5,0
MOVI r6,48
CMP r5,r6
JMP[LT] @mcf_ident_chk
MOVI r6,58
CMP r5,r6
JMP[GE] @mcf_ident_chk
; numeric token: exactly "0" is false, everything else is true
MOVI r6,48
CMP r5,r6
JMP[NE] @mcf_one
MOVI r6,1
CMP r7,r6
JMP[NE] @mcf_one
JMP @mcf_zero
mcf_ident_chk:
MOVI r6,95
CMP r5,r6
JMP[EQ] @mcf_ident
MOVI r6,65
CMP r5,r6
JMP[LT] @mcf_lower
MOVI r6,91
CMP r5,r6
JMP[LT] @mcf_ident
mcf_lower:
MOVI r6,97
CMP r5,r6
JMP[LT] @mcf_one
MOVI r6,123
CMP r5,r6
JMP[LT] @mcf_ident
JMP @mcf_one
mcf_ident:
MOVI r8,0
mcf_il:
CMP r8,r7
JMP[GE] @mcf_zero
ADD r9,r10,r4
ADD r9,r9,r8
LDB r1,r9,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mcf_one
ADD r8,r8,r13
JMP @mcf_il
mcf_one:
MOVI r1,1
JMP @mcf_inv
mcf_zero:
MOVI r1,0
mcf_inv:
LD r2,r0,#W_MPTMP3
CMP r2,r0
JMP[EQ] @mcf_d
MOVI r2,1
SUB r1,r2,r1
mcf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_emit_if_prefix / mp_emit_elif_prefix
mp_emit_if_prefix:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,35
CALL @mp_putc
MOVI r1,105
CALL @mp_putc
MOVI r1,102
CALL @mp_putc
MOVI r1,32
CALL @mp_putc
SUB r14,r14,r13
LD r15,r14,0
RET
mp_emit_elif_prefix:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,35
CALL @mp_putc
MOVI r1,101
CALL @mp_putc
MOVI r1,108
CALL @mp_putc
MOVI r1,105
CALL @mp_putc
MOVI r1,102
CALL @mp_putc
MOVI r1,32
CALL @mp_putc
SUB r14,r14,r13
LD r15,r14,0
RET
mp_emit_cond_digit:
; r1 = condition
ST r15,r14,0
ADD r14,r14,r13
ADDI r1,r1,48
CALL @mp_putc
SUB r14,r14,r13
LD r15,r14,0
RET
mp_emit_condbuf:
ST r15,r14,0
ADD r14,r14,r13
LA r4,#MPIFBUF
LD r5,r0,#W_MPIFBUFLEN
mecb_l:
CMP r5,r0
JMP[EQ] @mecb_d
LDB r1,r4,0
CALL @mp_putc
ADD r4,r4,r13
SUB r5,r5,r13
JMP @mecb_l
mecb_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ cond stack
; mp_if_push: r1=condition
mp_if_push:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_MPTMP2
LD r2,r0,#W_MPIFDEP
MOVI r3,#MPIFMAX
CMP r2,r3
JMP[GE] @mip_over
MOVI r3,3
MUL r4,r2,r3
LA r5,#MPIFSTK
ADD r5,r5,r4
LD r6,r0,#W_MPIFSKIP
ST r6,r5,0
LD r7,r0,#W_MPTMP2
ST r7,r5,1
MOVI r8,1
SUB r8,r8,r7
BOOL.14 r8,r6,r8
ST r8,r5,2
ST r8,r0,#W_MPIFSKIP
ADD r2,r2,r13
ST r2,r0,#W_MPIFDEP
JMP @mip_d
mip_over:
MOVI r1,1
ST r1,r0,#W_MPIFSKIP
mip_d:
SUB r14,r14,r13
LD r15,r14,0
RET

mp_if_else:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_MPIFDEP
CMP r2,r0
JMP[EQ] @mie_d
ADDI r2,r2,-1
MOVI r3,3
MUL r4,r2,r3
LA r5,#MPIFSTK
ADD r5,r5,r4
LD r6,r5,0
LD r7,r5,1
CMP r6,r0
JMP[NE] @mie_skip
CMP r7,r0
JMP[NE] @mie_skip
MOVI r8,0
JMP @mie_set
mie_skip:
MOVI r8,1
mie_set:
ST r8,r5,2
ST r8,r0,#W_MPIFSKIP
MOVI r8,1
ST r8,r5,1
mie_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_if_elif: condition in W_MPTMP3
mp_if_elif:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_MPIFDEP
CMP r2,r0
JMP[EQ] @miel_d
ADDI r2,r2,-1
MOVI r3,3
MUL r4,r2,r3
LA r5,#MPIFSTK
ADD r5,r5,r4
LD r6,r5,0
LD r7,r5,1
CMP r6,r0
JMP[NE] @miel_skip
CMP r7,r0
JMP[NE] @miel_skip
LD r1,r0,#W_MPTMP3
MOVI r8,1
SUB r8,r8,r1
BOOL.14 r8,r6,r8
JMP @miel_set
miel_skip:
MOVI r8,1
miel_set:
ST r8,r5,2
ST r8,r0,#W_MPIFSKIP
LD r1,r0,#W_MPTMP3
BOOL.14 r7,r7,r1
ST r7,r5,1
miel_d:
SUB r14,r14,r13
LD r15,r14,0
RET

mp_if_pop:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#W_MPIFDEP
CMP r2,r0
JMP[EQ] @mipop_d
ADDI r2,r2,-1
ST r2,r0,#W_MPIFDEP
CMP r2,r0
JMP[EQ] @mipop_zero
MOVI r3,3
MUL r4,r2,r3
LA r5,#MPIFSTK
ADD r5,r5,r4
LD r6,r5,0
ST r6,r0,#W_MPIFSKIP
JMP @mipop_d
mipop_zero:
ST r0,r0,#W_MPIFSKIP
mipop_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ expansion
; mp_expand_macro: r1=src r2=len r3=entry index r4=dst r5=end -> r1=new dst
; Locks the entry while the replacement is rescanned (blue paint).
mp_expand_macro:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r14,0
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
ST r5,r14,4
ADDI r14,r14,6
LA r6,#MPDIS
ADD r6,r6,r3
LDB r7,r6,0
ADD r7,r7,r13
STB r7,r6,0
ADDI r8,r14,-6
LD r1,r8,0
LD r2,r8,1
LD r3,r8,3
LD r4,r8,4
CALL @mp_xscan
ADDI r8,r14,-6
ST r1,r8,5
LD r3,r8,2
LA r6,#MPDIS
ADD r6,r6,r3
LDB r7,r6,0
SUB r7,r7,r13
STB r7,r6,0
LD r1,r8,5
ADDI r14,r14,-6
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_leave_call: drop one function-substitution depth
mp_leave_call:
LD r1,r0,#W_MPDEPTH
SUB r1,r1,r13
ST r1,r0,#W_MPDEPTH
RET

; mp_expand_call: W_MPENT entry, W_MPMPSUB buffer, W_MPSRC at '('.
; On success returns r1=substituted length, r2=buffer base, W_MPSRC after
; the closing ')' and W_MPDEPTH left incremented until mp_leave_call.
; On failure returns r1=0 with the depth restored.
mp_expand_call:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPDEPTH
MOVI r2,#MPDEPTHMAX
CMP r1,r2
JMP[GE] @mec_fail
ADD r1,r1,r13
ST r1,r0,#W_MPDEPTH
ADDI r2,r1,-1
MOVI r3,#MPSUBSZ
MUL r2,r2,r3
LA r3,#MPSUB
ADD r2,r3,r2
ST r2,r0,#W_MPMPSUB
ST r0,r0,#W_MPARGN
ST r0,r0,#W_MPARGL
ST r0,r0,#W_MPTMP3
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
; zero-parameter macro: accept "()" with optional spaces
LD r2,r0,#W_MPENT
LDB r2,r2,1
SHL r2,r2,25
SHR r2,r2,25
CMP r2,r0
JMP[NE] @mec_arg_l
mec_zsp:
LD r1,r0,#W_MPSRC
LDB r2,r1,0
MOVI r3,32
CMP r2,r3
JMP[EQ] @mec_zsp_a
MOVI r3,9
CMP r2,r3
JMP[NE] @mec_zchk
mec_zsp_a:
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
JMP @mec_zsp
mec_zchk:
MOVI r3,41
CMP r2,r3
JMP[NE] @mec_arg_l
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
ST r0,r0,#W_MPARGN
JMP @mec_sub
mec_arg_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mec_fail
MOVI r2,34
CMP r1,r2
JMP[EQ] @mec_str
MOVI r2,39
CMP r1,r2
JMP[EQ] @mec_chr
MOVI r2,40
CMP r1,r2
JMP[EQ] @mec_open
MOVI r2,41
CMP r1,r2
JMP[EQ] @mec_close
MOVI r2,44
CMP r1,r2
JMP[EQ] @mec_comma
MOVI r2,47
CMP r1,r2
JMP[EQ] @mec_slash
CALL @mpe_put_arg
JMP @mec_arg_l
mec_slash:
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
LDB r2,r1,0
MOVI r3,42
CMP r2,r3
JMP[EQ] @mec_bcom
MOVI r3,47
CMP r2,r3
JMP[EQ] @mec_lcom
CALL @mpe_put_arg
JMP @mec_arg_l
mec_lcom:
CALL @mpe_put_arg
CALL @mpe_put_arg
mec_lcom_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mec_fail
ST r1,r0,#W_MPCHAR
CALL @mpe_put_arg
LD r1,r0,#W_MPCHAR
MOVI r2,10
CMP r1,r2
JMP[NE] @mec_lcom_l
JMP @mec_arg_l
mec_bcom:
CALL @mpe_put_arg
CALL @mpe_put_arg
mec_bcom_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mec_fail
ST r1,r0,#W_MPCHAR
CALL @mpe_put_arg
LD r1,r0,#W_MPCHAR
MOVI r2,42
CMP r1,r2
JMP[NE] @mec_bcom_l
LD r1,r0,#W_MPSRC
LDB r2,r1,0
MOVI r3,47
CMP r2,r3
JMP[NE] @mec_bcom_l
CALL @mpe_put_arg
JMP @mec_arg_l
mec_open:
LD r2,r0,#W_MPTMP3
ADD r2,r2,r13
ST r2,r0,#W_MPTMP3
CALL @mpe_put_arg
JMP @mec_arg_l
mec_close:
LD r2,r0,#W_MPTMP3
CMP r2,r0
JMP[NE] @mec_close_in
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
CALL @mpe_finish
LD r1,r0,#W_MPARGN
ADD r1,r1,r13
ST r1,r0,#W_MPARGN
JMP @mec_sub
mec_close_in:
SUB r2,r2,r13
ST r2,r0,#W_MPTMP3
CALL @mpe_put_arg
JMP @mec_arg_l
mec_comma:
LD r2,r0,#W_MPTMP3
CMP r2,r0
JMP[NE] @mec_cp_comma
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
CALL @mpe_finish
LD r2,r0,#W_MPARGN
ADD r2,r2,r13
MOVI r3,#MPPARAMMAX
CMP r2,r3
JMP[GE] @mec_fail
ST r2,r0,#W_MPARGN
ST r0,r0,#W_MPARGL
JMP @mec_arg_l
mec_cp_comma:
CALL @mpe_put_arg
JMP @mec_arg_l
mec_str:
MOVI r2,34
CALL @mpe_lit
JMP @mec_arg_l
mec_chr:
MOVI r2,39
CALL @mpe_lit
JMP @mec_arg_l
mec_sub:
CALL @mpe_sub
CMP r1,r0
JMP[EQ] @mec_fail2
LD r1,r0,#W_MPOUTL
LD r2,r0,#W_MPMPSUB
JMP @mec_d
mec_fail2:
CALL @mp_leave_call
MOVI r1,0
JMP @mec_d
mec_fail:
CALL @mp_leave_call
MOVI r1,0
mec_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mpe_put_arg: append the char at W_MPSRC to the current argument
mpe_put_arg:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
LD r2,r0,#W_MPARGL
MOVI r3,#MPARGSTEP
CMP r2,r3
JMP[GE] @mpa_adv
LD r3,r0,#W_MPARGN
MOVI r4,#MPARGSTEP
MUL r3,r3,r4
LA r4,#MPARG
ADD r3,r4,r3
ADD r3,r3,r2
STB r1,r3,0
ADD r2,r2,r13
ST r2,r0,#W_MPARGL
mpa_adv:
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
RET

; mpe_lit: copy a string/char literal (r2=quote) into the current argument
mpe_lit:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#W_MPQ
CALL @mpe_put_arg
mpe_lit_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mpe_lit_d
ST r1,r0,#W_MPCHAR
CALL @mpe_put_arg
LD r1,r0,#W_MPCHAR
MOVI r2,92
CMP r1,r2
JMP[NE] @mpe_lit_q
CALL @mpe_put_arg
JMP @mpe_lit_l
mpe_lit_q:
LD r2,r0,#W_MPQ
CMP r1,r2
JMP[NE] @mpe_lit_l
mpe_lit_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mpe_finish: trim the current argument and record ptr/len
mpe_finish:
LD r2,r0,#W_MPARGN
MOVI r3,#MPARGSTEP
MUL r3,r2,r3
LA r4,#MPARG
ADD r4,r4,r3
LD r5,r0,#W_MPARGL
mpe_fin_r:
CMP r5,r0
JMP[EQ] @mpe_fin_l
ADDI r6,r5,-1
ADD r6,r4,r6
LDB r6,r6,0
MOVI r7,32
CMP r6,r7
JMP[EQ] @mpe_fin_rd
MOVI r7,9
CMP r6,r7
JMP[EQ] @mpe_fin_rd
MOVI r7,10
CMP r6,r7
JMP[EQ] @mpe_fin_rd
MOVI r7,13
CMP r6,r7
JMP[NE] @mpe_fin_l
mpe_fin_rd:
SUB r5,r5,r13
JMP @mpe_fin_r
mpe_fin_l:
CMP r5,r0
JMP[EQ] @mpe_fin_store
LDB r6,r4,0
MOVI r7,32
CMP r6,r7
JMP[EQ] @mpe_fin_ld
MOVI r7,9
CMP r6,r7
JMP[EQ] @mpe_fin_ld
MOVI r7,10
CMP r6,r7
JMP[EQ] @mpe_fin_ld
MOVI r7,13
CMP r6,r7
JMP[NE] @mpe_fin_store
mpe_fin_ld:
ADD r4,r4,r13
SUB r5,r5,r13
JMP @mpe_fin_l
mpe_fin_store:
SHL r2,r2,3
LA r3,#MPARGV
ADD r3,r3,r2
ST r4,r3,0
ST r5,r3,1
RET

; mp_arg_get: r1=index -> r1=ptr r2=len
mp_arg_get:
SHL r2,r1,3
LA r3,#MPARGV
ADD r2,r3,r2
LD r1,r2,0
LD r2,r2,1
RET

; mp_sub_putc: r1=char -> append to the current substitution buffer
mp_sub_putc:
LD r2,r0,#W_MPOUTL
MOVI r3,#MPSUBSZ
CMP r2,r3
JMP[GE] @msp_d
LD r3,r0,#W_MPMPSUB
ADD r3,r3,r2
STB r1,r3,0
ADD r2,r2,r13
ST r2,r0,#W_MPOUTL
msp_d:
RET

; mp_sub_trim: drop trailing spaces/tabs from the substitution buffer
mp_sub_trim:
LD r2,r0,#W_MPOUTL
mst_l:
CMP r2,r0
JMP[EQ] @mst_d
ADDI r3,r2,-1
LD r4,r0,#W_MPMPSUB
ADD r4,r4,r3
LDB r4,r4,0
MOVI r5,32
CMP r4,r5
JMP[EQ] @mst_dec
MOVI r5,9
CMP r4,r5
JMP[NE] @mst_d
mst_dec:
SUB r2,r2,r13
JMP @mst_l
mst_d:
ST r2,r0,#W_MPOUTL
RET

; mp_param_find: r1=name ptr r2=len -> r1=index or -1
mp_param_find:
ST r1,r0,#W_MPK
ST r2,r0,#W_MPN
MOVI r3,0
ppf_l:
LD r4,r0,#W_MPENT
LDB r4,r4,1
CMP r3,r4
JMP[GE] @ppf_n
MOVI r5,#MPPARAMSZ
MUL r5,r3,r5
LD r4,r0,#W_MPENT
ADD r5,r4,r5
ADDI r5,r5,#MPPARAMOFF
LDB r6,r5,0
LD r7,r0,#W_MPN
CMP r6,r7
JMP[NE] @ppf_next
LD r7,r0,#W_MPK
MOVI r8,0
ppf_c:
CMP r8,r6
JMP[GE] @ppf_y
ADD r9,r5,r8
ADDI r9,r9,1
LDB r9,r9,0
ADD r10,r7,r8
LDB r10,r10,0
CMP r9,r10
JMP[NE] @ppf_next
ADD r8,r8,r13
JMP @ppf_c
ppf_next:
ADD r3,r3,r13
JMP @ppf_l
ppf_y:
ADD r1,r3,r0
JMP @ppf_d
ppf_n:
LA r1,0xFFFFFFFF
ppf_d:
RET

; mp_emit_arg: r1=index -> append argument text to the substitution buffer
mp_emit_arg:
ST r15,r14,0
ADD r14,r14,r13
CALL @mp_arg_get
ST r1,r0,#W_MPK
ST r2,r0,#W_MPN
mp_ea_l:
LD r2,r0,#W_MPN
CMP r2,r0
JMP[EQ] @mp_ea_d
LD r1,r0,#W_MPK
LDB r1,r1,0
CALL @mp_sub_putc
LD r1,r0,#W_MPK
ADD r1,r1,r13
ST r1,r0,#W_MPK
LD r2,r0,#W_MPN
SUB r2,r2,r13
ST r2,r0,#W_MPN
JMP @mp_ea_l
mp_ea_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_is_va: r1=ptr r2=len -> 1 if the name is __VA_ARGS__
mp_is_va:
ST r15,r14,0
ADD r14,r14,r13
MOVI r3,11
CMP r2,r3
JMP[NE] @miv_n
ST r1,r0,#W_MPENT2
LA r3,@mp_s_va
SHL r3,r3,2
MOVI r4,0
miv_l:
CMP r4,r2
JMP[GE] @miv_y
LD r5,r0,#W_MPENT2
ADD r5,r5,r4
LDB r5,r5,0
ADD r6,r3,r4
LDB r6,r6,0
CMP r5,r6
JMP[NE] @miv_n
ADD r4,r4,r13
JMP @miv_l
miv_y:
MOVI r1,1
JMP @miv_d
miv_n:
MOVI r1,0
miv_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_emit_va: append the variadic arguments joined by ", "
mp_emit_va:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPENT
LDB r1,r1,1
SHL r1,r1,25
SHR r1,r1,25
ST r1,r0,#W_MPVA
LD r2,r0,#W_MPARGN
CMP r1,r2
JMP[GE] @mev_d
mev_l:
LD r1,r0,#W_MPVA
LD r2,r0,#W_MPARGN
CMP r1,r2
JMP[GE] @mev_d
CALL @mp_emit_arg
LD r1,r0,#W_MPVA
ADD r1,r1,r13
ST r1,r0,#W_MPVA
LD r2,r0,#W_MPARGN
CMP r1,r2
JMP[GE] @mev_d
MOVI r1,44
CALL @mp_sub_putc
MOVI r1,32
CALL @mp_sub_putc
JMP @mev_l
mev_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mp_emit_va_str: append the variadic arguments, escaped, joined by ", "
mp_emit_va_str:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPENT
LDB r1,r1,1
SHL r1,r1,25
SHR r1,r1,25
ST r1,r0,#W_MPVA
mevs_l:
LD r1,r0,#W_MPVA
LD r2,r0,#W_MPARGN
CMP r1,r2
JMP[GE] @mevs_d
CALL @mp_arg_get
ST r1,r0,#W_MPK
ST r2,r0,#W_MPN
mevs_c:
LD r2,r0,#W_MPN
CMP r2,r0
JMP[EQ] @mevs_next
LD r1,r0,#W_MPK
LDB r1,r1,0
ST r1,r0,#W_MPCHAR
MOVI r3,34
CMP r1,r3
JMP[EQ] @mevs_esc
MOVI r3,92
CMP r1,r3
JMP[NE] @mevs_put
mevs_esc:
MOVI r1,92
CALL @mp_sub_putc
mevs_put:
LD r1,r0,#W_MPCHAR
CALL @mp_sub_putc
LD r1,r0,#W_MPK
ADD r1,r1,r13
ST r1,r0,#W_MPK
LD r2,r0,#W_MPN
SUB r2,r2,r13
ST r2,r0,#W_MPN
JMP @mevs_c
mevs_next:
LD r1,r0,#W_MPVA
ADD r1,r1,r13
ST r1,r0,#W_MPVA
LD r2,r0,#W_MPARGN
CMP r1,r2
JMP[GE] @mevs_d
MOVI r1,44
CALL @mp_sub_putc
MOVI r1,32
CALL @mp_sub_putc
JMP @mevs_l
mevs_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; mpe_sub: substitute the function body into the current substitution buffer
mpe_sub:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#W_MPENT
CALL @mp_get_bodylen
ST r1,r0,#W_MPBLEN
ST r0,r0,#W_MPI
ST r0,r0,#W_MPOUTL
mpe_b_l:
LD r1,r0,#W_MPI
LD r2,r0,#W_MPBLEN
CMP r1,r2
JMP[GE] @mpe_b_done
LD r3,r0,#W_MPENT
ADD r3,r3,r1
ADDI r3,r3,#MPBODY
LDB r3,r3,0
ST r3,r0,#W_MPCHAR
MOVI r4,34
CMP r3,r4
JMP[EQ] @mpe_b_lit
MOVI r4,39
CMP r3,r4
JMP[EQ] @mpe_b_lit
MOVI r4,35
CMP r3,r4
JMP[EQ] @mpe_b_hash
ADD r1,r3,r0
CALL @mp_id0
CMP r1,r0
JMP[EQ] @mpe_b_char
JMP @mpe_b_ident
mpe_b_char:
LD r1,r0,#W_MPCHAR
CALL @mp_sub_putc
LD r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPI
JMP @mpe_b_l
mpe_b_lit:
LD r1,r0,#W_MPCHAR
ST r1,r0,#W_MPQ
CALL @mp_sub_putc
LD r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPI
mpe_bll:
LD r1,r0,#W_MPI
LD r2,r0,#W_MPBLEN
CMP r1,r2
JMP[GE] @mpe_b_done
LD r3,r0,#W_MPENT
ADD r3,r3,r1
ADDI r3,r3,#MPBODY
LDB r3,r3,0
ST r3,r0,#W_MPCHAR
LD r1,r0,#W_MPCHAR
CALL @mp_sub_putc
LD r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPI
LD r1,r0,#W_MPCHAR
MOVI r2,92
CMP r1,r2
JMP[NE] @mpe_blq
; escaped char
LD r1,r0,#W_MPI
LD r2,r0,#W_MPBLEN
CMP r1,r2
JMP[GE] @mpe_b_done
LD r3,r0,#W_MPENT
ADD r3,r3,r1
ADDI r3,r3,#MPBODY
LDB r1,r3,0
CALL @mp_sub_putc
LD r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPI
JMP @mpe_bll
mpe_blq:
LD r2,r0,#W_MPQ
CMP r1,r2
JMP[NE] @mpe_bll
JMP @mpe_b_l
mpe_b_hash:
; '##' paste
LD r1,r0,#W_MPI
ADD r2,r1,r13
LD r3,r0,#W_MPBLEN
CMP r2,r3
JMP[GE] @mpe_hash_one
LD r4,r0,#W_MPENT
ADD r4,r4,r2
ADDI r4,r4,#MPBODY
LDB r4,r4,0
MOVI r5,35
CMP r4,r5
JMP[NE] @mpe_hash_one
CALL @mp_sub_trim
LD r1,r0,#W_MPI
ADDI r1,r1,2
ST r1,r0,#W_MPI
mpe_paste_l:
LD r1,r0,#W_MPI
LD r2,r0,#W_MPBLEN
CMP r1,r2
JMP[GE] @mpe_b_l
LD r3,r0,#W_MPENT
ADD r3,r3,r1
ADDI r3,r3,#MPBODY
LDB r3,r3,0
MOVI r4,32
CMP r3,r4
JMP[EQ] @mpe_paste_a
MOVI r4,9
CMP r3,r4
JMP[NE] @mpe_paste_chk
mpe_paste_a:
ADD r1,r1,r13
ST r1,r0,#W_MPI
JMP @mpe_paste_l
mpe_paste_chk:
; GNU ", ##__VA_ARGS__": drop the comma when the variadic list is empty
LD r1,r0,#W_MPENT
LDB r1,r1,1
SHR r1,r1,7
CMP r1,r0
JMP[EQ] @mpe_b_l
LD r1,r0,#W_MPENT
LD r2,r0,#W_MPI
ADD r1,r1,r2
ADDI r1,r1,#MPBODY
MOVI r2,11
CALL @mp_is_va
CMP r1,r0
JMP[EQ] @mpe_b_l
LD r1,r0,#W_MPENT
LDB r1,r1,1
SHL r1,r1,25
SHR r1,r1,25
LD r2,r0,#W_MPARGN
CMP r2,r1
JMP[GT] @mpe_b_l
CALL @mp_sub_trim
LD r2,r0,#W_MPOUTL
CMP r2,r0
JMP[EQ] @mpe_paste_sv
ADDI r3,r2,-1
LD r4,r0,#W_MPMPSUB
ADD r4,r4,r3
LDB r4,r4,0
MOVI r5,44
CMP r4,r5
JMP[NE] @mpe_paste_sv
SUB r2,r2,r13
ST r2,r0,#W_MPOUTL
CALL @mp_sub_trim
mpe_paste_sv:
LD r1,r0,#W_MPI
ADDI r1,r1,11
ST r1,r0,#W_MPI
JMP @mpe_b_l
mpe_hash_one:
; possible stringification
LD r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPSTART
ST r1,r0,#W_MPI
mpe_hs_sp:
LD r1,r0,#W_MPI
LD r2,r0,#W_MPBLEN
CMP r1,r2
JMP[GE] @mpe_hash_copy
LD r3,r0,#W_MPENT
ADD r3,r3,r1
ADDI r3,r3,#MPBODY
LDB r3,r3,0
MOVI r4,32
CMP r3,r4
JMP[EQ] @mpe_hs_a
MOVI r4,9
CMP r3,r4
JMP[NE] @mpe_hs_name
mpe_hs_a:
ADD r1,r1,r13
ST r1,r0,#W_MPI
JMP @mpe_hs_sp
mpe_hs_name:
LD r2,r0,#W_MPI
ST r2,r0,#W_MPJ
mpe_hs_nl:
LD r2,r0,#W_MPJ
LD r3,r0,#W_MPBLEN
CMP r2,r3
JMP[GE] @mpe_hs_end
LD r4,r0,#W_MPENT
ADD r4,r4,r2
ADDI r4,r4,#MPBODY
LDB r1,r4,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mpe_hs_end
LD r2,r0,#W_MPJ
ADD r2,r2,r13
ST r2,r0,#W_MPJ
JMP @mpe_hs_nl
mpe_hs_end:
LD r1,r0,#W_MPENT
LD r2,r0,#W_MPI
ADD r1,r1,r2
ADDI r1,r1,#MPBODY
LD r2,r0,#W_MPJ
LD r3,r0,#W_MPI
SUB r2,r2,r3
CALL @mp_param_find
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @mpe_hs_param
LD r1,r0,#W_MPENT
LD r2,r0,#W_MPI
ADD r1,r1,r2
ADDI r1,r1,#MPBODY
LD r2,r0,#W_MPJ
LD r3,r0,#W_MPI
SUB r2,r2,r3
CALL @mp_is_va
CMP r1,r0
JMP[EQ] @mpe_hash_copy
MOVI r1,34
CALL @mp_sub_putc
CALL @mp_emit_va_str
MOVI r1,34
CALL @mp_sub_putc
LD r1,r0,#W_MPJ
ST r1,r0,#W_MPI
JMP @mpe_b_l
mpe_hs_param:
ST r1,r0,#W_MPK
MOVI r1,34
CALL @mp_sub_putc
LD r1,r0,#W_MPK
CALL @mp_arg_get
ST r1,r0,#W_MPK
ST r2,r0,#W_MPN
mpe_hs_c:
LD r2,r0,#W_MPN
CMP r2,r0
JMP[EQ] @mpe_hs_q
LD r1,r0,#W_MPK
LDB r1,r1,0
ST r1,r0,#W_MPCHAR
MOVI r3,34
CMP r1,r3
JMP[EQ] @mpe_hs_esc
MOVI r3,92
CMP r1,r3
JMP[NE] @mpe_hs_put
mpe_hs_esc:
MOVI r1,92
CALL @mp_sub_putc
mpe_hs_put:
LD r1,r0,#W_MPCHAR
CALL @mp_sub_putc
LD r1,r0,#W_MPK
ADD r1,r1,r13
ST r1,r0,#W_MPK
LD r2,r0,#W_MPN
SUB r2,r2,r13
ST r2,r0,#W_MPN
JMP @mpe_hs_c
mpe_hs_q:
MOVI r1,34
CALL @mp_sub_putc
LD r1,r0,#W_MPJ
ST r1,r0,#W_MPI
JMP @mpe_b_l
mpe_hash_copy:
LD r1,r0,#W_MPSTART
ST r1,r0,#W_MPI
MOVI r1,35
CALL @mp_sub_putc
JMP @mpe_b_l
mpe_b_ident:
LD r2,r0,#W_MPI
ST r2,r0,#W_MPJ
mpe_bi_l:
LD r2,r0,#W_MPJ
LD r3,r0,#W_MPBLEN
CMP r2,r3
JMP[GE] @mpe_bi_end
LD r4,r0,#W_MPENT
ADD r4,r4,r2
ADDI r4,r4,#MPBODY
LDB r1,r4,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mpe_bi_end
LD r2,r0,#W_MPJ
ADD r2,r2,r13
ST r2,r0,#W_MPJ
JMP @mpe_bi_l
mpe_bi_end:
LD r1,r0,#W_MPENT
LD r2,r0,#W_MPI
ADD r1,r1,r2
ADDI r1,r1,#MPBODY
LD r2,r0,#W_MPJ
LD r3,r0,#W_MPI
SUB r2,r2,r3
ST r1,r0,#W_MPK
ST r2,r0,#W_MPN
CALL @mp_is_va
CMP r1,r0
JMP[NE] @mpe_bi_va
LD r1,r0,#W_MPK
LD r2,r0,#W_MPN
CALL @mp_param_find
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @mpe_bi_arg
; copy the identifier unchanged
LD r4,r0,#W_MPI
LD r5,r0,#W_MPJ
mpe_bi_cp:
CMP r4,r5
JMP[GE] @mpe_bi_done
LD r1,r0,#W_MPENT
ADD r1,r1,r4
ADDI r1,r1,#MPBODY
LDB r1,r1,0
ST r4,r0,#W_MPI
ST r5,r0,#W_MPJ
CALL @mp_sub_putc
LD r4,r0,#W_MPI
LD r5,r0,#W_MPJ
ADD r4,r4,r13
JMP @mpe_bi_cp
mpe_bi_done:
LD r1,r0,#W_MPJ
ST r1,r0,#W_MPI
JMP @mpe_b_l
mpe_bi_arg:
CALL @mp_emit_arg
LD r1,r0,#W_MPJ
ST r1,r0,#W_MPI
JMP @mpe_b_l
mpe_bi_va:
CALL @mp_emit_va
LD r1,r0,#W_MPJ
ST r1,r0,#W_MPI
JMP @mpe_b_l
mpe_b_done:
MOVI r1,1
JMP @mpe_d
mpe_fail:
MOVI r1,0
mpe_d:
SUB r14,r14,r13
LD r15,r14,0
RET

mp_s_define:
.str "define"
mp_s_undef:
.str "undef"
mp_s_ifdef:
.str "ifdef"
mp_s_ifndef:
.str "ifndef"
mp_s_if:
.str "if"
mp_s_elif:
.str "elif"
mp_s_else:
.str "else"
mp_s_endif:
.str "endif"
mp_s_va:
.str "__VA_ARGS__"
mp_s_defined:
.str "defined"
