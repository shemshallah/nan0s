; mpp.nas - C function-like macro preprocessor, raw NaN16.
;
; Runs as a text pass over the source before the lexer.  It removes
; function-like #define lines, then expands calls to those macros.  Object-like
; macros are left in the text for the existing q2 number-macro pass.
;
; Fast path: if the source has no function-like #define, the original word
; pointer is returned unchanged and nothing is copied.
;
; Address note: LA @label is a word address; LA #equ is the numeric (byte)
; address used by LDB/STB.  Source text is byte addressed, so a word pointer
; from the caller is shifted left before scanning and shifted right on return.

.equ MPTAB      12600000     ; 32 entries * 512 bytes
.equ MPSZ       512
.equ MPMax      32
.equ MPTMP      12617000     ; scratch identifier
.equ MPARG      12620000     ; 8 arguments * 1024 bytes
.equ MPARGSTEP  1024
.equ MPARGV     12630000     ; 8 * (ptr,len) word pairs
.equ MPSUB      12631000     ; substituted body, 8 KiB
.equ MPSUBMAX   8192
.equ MPOUT1     13000000
.equ MPOUT2     14000000
.equ MPEND      15000000
.equ MPBODY     232          ; entry byte offsets
.equ MPBODYMAX  279
.equ MPPARAMOFF 40
.equ MPPARAMSZ  24
.equ MPPARAMMAX 8

.equ W_MPSRC    61500
.equ W_MPDST    61501
.equ W_MPBOL    61502
.equ W_MPEXP    61503
.equ W_MPENT    61504
.equ W_MPCUR    61505
.equ W_MPARGN   61506
.equ W_MPARGL   61507
.equ W_MPCHAR   61508
.equ W_MPN      61509
.equ W_MPI       61510
.equ W_MPINW    61511
.equ W_MPDEPTH  61512
.equ W_MPQ      61513
.equ W_MPJ      61514
.equ W_MPK      61515
.equ W_MPSTART  61516
.equ W_MPEND    61517
.equ W_MPPASS   61518
.equ W_MPWHICH  61519
.equ W_MPBLEN   61520
.equ W_MPOUTL   61521
.equ W_MPENT2   61522
.equ W_MPVA     61523

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
ST r0,r0,#W_MPEXP
ST r0,r0,#W_MPWHICH
CALL @mp_pass
MOVI r1,8
ST r1,r0,#W_MPPASS
mpp_loop:
LD r1,r0,#W_MPEXP
CMP r1,r0
JMP[EQ] @mpp_ret
LD r1,r0,#W_MPPASS
SUB r1,r1,r13
ST r1,r0,#W_MPPASS
CMP r1,r0
JMP[EQ] @mpp_ret
LD r1,r0,#W_MPWHICH
CMP r1,r0
JMP[NE] @mpp_to1
LA r2,#MPOUT2
LA r3,#MPOUT1
MOVI r1,1
JMP @mpp_go
mpp_to1:
LA r2,#MPOUT1
LA r3,#MPOUT2
MOVI r1,0
mpp_go:
ST r1,r0,#W_MPWHICH
ST r3,r0,#W_MPSRC
ST r2,r0,#W_MPDST
ST r0,r0,#W_MPEXP
CALL @mp_pass
JMP @mpp_loop
mpp_ret:
LD r1,r0,#W_MPWHICH
CMP r1,r0
JMP[NE] @mpp_ret2
LA r1,#MPOUT1
JMP @mpp_done
mpp_ret2:
LA r1,#MPOUT2
mpp_done:
SHR r1,r1,2
mpp_retw:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ detection
; mp_has_func: r1=source byte ptr -> 1 if a function-like #define exists
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
CALL @mp_skipsp
LD r1,r0,#W_MPCUR
LDB r1,r1,0
CALL @mp_id0
CMP r1,r0
JMP[EQ] @mhf_skip_line
mhf_name:
LD r1,r0,#W_MPCUR
LDB r1,r1,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mhf_after
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mhf_name
mhf_after:
LD r1,r0,#W_MPCUR
LDB r2,r1,0
MOVI r3,40
CMP r2,r3
JMP[EQ] @mhf_y
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

; ------------------------------------------------------------------ table
; Entry: 0 used, 1 nparams, 2 namelen, 3 bodylen, 8.. name,
;        40.. params (24 bytes each: len, name), 232.. body.
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
ADD r2,r2,r13
LDB r2,r2,0
MOVI r3,10
CMP r2,r3
JMP[EQ] @mdf_bcont
MOVI r3,13
CMP r2,r3
JMP[NE] @mdf_bstore
mdf_bcont:
LD r1,r0,#W_MPCUR
ADDI r1,r1,2
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
MOVI r1,1
JMP @mdf_d
mdf_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ pass
; mp_pass: copy/expand W_MPSRC into W_MPDST
mp_pass:
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,1
ST r1,r0,#W_MPBOL
mp_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mp_fin
LD r2,r0,#W_MPBOL
CMP r2,r0
JMP[EQ] @mp_scan
MOVI r2,32
CMP r1,r2
JMP[EQ] @mp_copy
MOVI r2,9
CMP r1,r2
JMP[EQ] @mp_copy
MOVI r2,35
CMP r1,r2
JMP[EQ] @mp_directive
ST r0,r0,#W_MPBOL
JMP @mp_scan
mp_copy:
CALL @mp_putc
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
JMP @mp_l
mp_scan:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CALL @mp_id0
CMP r1,r0
JMP[EQ] @mp_punct
; collect the identifier (r4/r5 survive mp_idc)
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
LA r1,#MPTMP
LD r2,r0,#W_MPN
CALL @mp_find_name
CMP r1,r0
JMP[EQ] @mp_id_out
ST r1,r0,#W_MPENT
; look ahead past spaces for '('
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
JMP[NE] @mp_id_out
LD r1,r0,#W_MPCUR
ST r1,r0,#W_MPSRC
LD r1,r0,#W_MPENT
CALL @mp_expand
CMP r1,r0
JMP[EQ] @mp_id_fail
MOVI r1,1
ST r1,r0,#W_MPEXP
ST r0,r0,#W_MPBOL
JMP @mp_l
mp_id_fail:
LD r1,r0,#W_MPSTART
ST r1,r0,#W_MPSRC
mp_id_out:
LA r4,#MPTMP
LD r5,r0,#W_MPN
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
JMP @mp_l
mp_punct:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
ST r1,r0,#W_MPCHAR
CALL @mp_putc
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
LD r1,r0,#W_MPCHAR
MOVI r2,10
CMP r1,r2
JMP[NE] @mp_p_nb
MOVI r1,1
ST r1,r0,#W_MPBOL
JMP @mp_l
mp_p_nb:
ST r0,r0,#W_MPBOL
JMP @mp_l
mp_fin:
MOVI r1,0
CALL @mp_putc
SUB r14,r14,r13
LD r15,r14,0
RET

; ------------------------------------------------------------------ directives
mp_directive:
LD r1,r0,#W_MPSRC
ST r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
CALL @mp_skipsp
LA r2,@mp_s_define
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_def
; try #undef so a function-like macro can be retired
LD r1,r0,#W_MPI
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
CALL @mp_skipsp
LA r2,@mp_s_undef
CALL @mp_match_word
CMP r1,r0
JMP[NE] @mp_undef
; not a define/undef: copy the whole line verbatim
LD r1,r0,#W_MPI
ST r1,r0,#W_MPSRC
CALL @mp_copy_line
JMP @mp_l
mp_undef:
CALL @mp_skipsp
LA r4,#MPTMP
MOVI r5,0
mp_und_n:
LD r1,r0,#W_MPCUR
LDB r1,r1,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mp_und_d
LD r1,r0,#W_MPCUR
LDB r1,r1,0
STB r1,r4,0
ADD r4,r4,r13
ADD r5,r5,r13
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mp_und_n
mp_und_d:
CMP r5,r0
JMP[EQ] @mp_und_done
LA r1,#MPTMP
ADD r2,r5,r0
CALL @mp_find_name
CMP r1,r0
JMP[EQ] @mp_und_done
STB r0,r1,0
mp_und_done:
LD r1,r0,#W_MPI
ST r1,r0,#W_MPSRC
CALL @mp_copy_line
JMP @mp_l
mp_def:
CALL @mp_skipsp
LA r4,#MPTMP
MOVI r5,0
mp_defn:
LD r1,r0,#W_MPCUR
LDB r1,r1,0
CALL @mp_idc
CMP r1,r0
JMP[EQ] @mp_defn_d
LD r1,r0,#W_MPCUR
LDB r1,r1,0
STB r1,r4,0
ADD r4,r4,r13
ADD r5,r5,r13
LD r1,r0,#W_MPCUR
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
JMP @mp_defn
mp_defn_d:
ST r5,r0,#W_MPN
CMP r5,r0
JMP[EQ] @mp_defobj
LD r1,r0,#W_MPCUR
LDB r1,r1,0
MOVI r2,40
CMP r1,r2
JMP[NE] @mp_defobj
CALL @mp_define_func
CMP r1,r0
JMP[EQ] @mp_defobj
; remove the definition line, keep the newline
LD r1,r0,#W_MPCUR
ST r1,r0,#W_MPSRC
CALL @mp_copy_line
JMP @mp_l
mp_defobj:
LD r1,r0,#W_MPI
ST r1,r0,#W_MPSRC
CALL @mp_copy_line
JMP @mp_l

; ------------------------------------------------------------------ expansion
; mp_expand: W_MPENT entry, W_MPSRC at '(' -> 1 if expanded.
mp_expand:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#W_MPARGN
ST r0,r0,#W_MPARGL
ST r0,r0,#W_MPDEPTH
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
; zero-parameter macro: accept "()" with optional spaces
LD r2,r0,#W_MPENT
LDB r2,r2,1
SHL r2,r2,25
SHR r2,r2,25
CMP r2,r0
JMP[NE] @mpe_arg_l
mpe_zsp:
LD r1,r0,#W_MPSRC
LDB r2,r1,0
MOVI r3,32
CMP r2,r3
JMP[EQ] @mpe_zsp_a
MOVI r3,9
CMP r2,r3
JMP[NE] @mpe_zchk
mpe_zsp_a:
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
JMP @mpe_zsp
mpe_zchk:
MOVI r3,41
CMP r2,r3
JMP[NE] @mpe_arg_l
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
ST r0,r0,#W_MPARGN
JMP @mpe_sub
mpe_arg_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mpe_fail
MOVI r2,34
CMP r1,r2
JMP[EQ] @mpe_str
MOVI r2,39
CMP r1,r2
JMP[EQ] @mpe_chr
MOVI r2,40
CMP r1,r2
JMP[EQ] @mpe_open
MOVI r2,41
CMP r1,r2
JMP[EQ] @mpe_close
MOVI r2,44
CMP r1,r2
JMP[EQ] @mpe_comma
MOVI r2,47
CMP r1,r2
JMP[EQ] @mpe_slash
CALL @mpe_put_arg
JMP @mpe_arg_l
mpe_slash:
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
LDB r2,r1,0
MOVI r3,42
CMP r2,r3
JMP[EQ] @mpe_bcom
MOVI r3,47
CMP r2,r3
JMP[EQ] @mpe_lcom
CALL @mpe_put_arg
JMP @mpe_arg_l
mpe_lcom:
CALL @mpe_put_arg
CALL @mpe_put_arg
mpe_lcom_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mpe_fail
ST r1,r0,#W_MPCHAR
CALL @mpe_put_arg
LD r1,r0,#W_MPCHAR
MOVI r2,10
CMP r1,r2
JMP[NE] @mpe_lcom_l
JMP @mpe_arg_l
mpe_bcom:
CALL @mpe_put_arg
CALL @mpe_put_arg
mpe_bcom_l:
LD r1,r0,#W_MPSRC
LDB r1,r1,0
CMP r1,r0
JMP[EQ] @mpe_fail
ST r1,r0,#W_MPCHAR
CALL @mpe_put_arg
LD r1,r0,#W_MPCHAR
MOVI r2,42
CMP r1,r2
JMP[NE] @mpe_bcom_l
LD r1,r0,#W_MPSRC
LDB r2,r1,0
MOVI r3,47
CMP r2,r3
JMP[NE] @mpe_bcom_l
CALL @mpe_put_arg
JMP @mpe_arg_l
mpe_open:
LD r2,r0,#W_MPDEPTH
ADD r2,r2,r13
ST r2,r0,#W_MPDEPTH
CALL @mpe_put_arg
JMP @mpe_arg_l
mpe_close:
LD r2,r0,#W_MPDEPTH
CMP r2,r0
JMP[NE] @mpe_close_in
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
CALL @mpe_finish
LD r1,r0,#W_MPARGN
ADD r1,r1,r13
ST r1,r0,#W_MPARGN
JMP @mpe_sub
mpe_close_in:
SUB r2,r2,r13
ST r2,r0,#W_MPDEPTH
CALL @mpe_put_arg
JMP @mpe_arg_l
mpe_comma:
LD r2,r0,#W_MPDEPTH
CMP r2,r0
JMP[NE] @mpe_cp_comma
LD r1,r0,#W_MPSRC
ADD r1,r1,r13
ST r1,r0,#W_MPSRC
CALL @mpe_finish
LD r2,r0,#W_MPARGN
ADD r2,r2,r13
MOVI r3,#MPPARAMMAX
CMP r2,r3
JMP[GE] @mpe_fail
ST r2,r0,#W_MPARGN
ST r0,r0,#W_MPARGL
JMP @mpe_arg_l
mpe_cp_comma:
CALL @mpe_put_arg
JMP @mpe_arg_l
mpe_str:
MOVI r2,34
CALL @mpe_lit
JMP @mpe_arg_l
mpe_chr:
MOVI r2,39
CALL @mpe_lit
JMP @mpe_arg_l

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

; mp_sub_putc: r1=char -> append to MPSUB
mp_sub_putc:
LD r2,r0,#W_MPOUTL
MOVI r3,#MPSUBMAX
CMP r2,r3
JMP[GE] @msp_d
LA r3,#MPSUB
ADD r3,r3,r2
STB r1,r3,0
ADD r2,r2,r13
ST r2,r0,#W_MPOUTL
msp_d:
RET

; mp_sub_trim: drop trailing spaces/tabs from MPSUB
mp_sub_trim:
LD r2,r0,#W_MPOUTL
mst_l:
CMP r2,r0
JMP[EQ] @mst_d
ADDI r3,r2,-1
LA r4,#MPSUB
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

; mp_emit_arg: r1=index -> append argument text to MPSUB
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

; mpe_sub: substitute the body into MPSUB
mpe_sub:
LD r1,r0,#W_MPENT
LDB r2,r1,3
ST r2,r0,#W_MPBLEN
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
LA r4,#MPSUB
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
; append MPSUB to the output
LA r4,#MPSUB
LD r5,r0,#W_MPOUTL
mpe_bd_l:
CMP r5,r0
JMP[EQ] @mpe_ok
LDB r1,r4,0
ST r4,r0,#W_MPK
ST r5,r0,#W_MPN
CALL @mp_putc
LD r4,r0,#W_MPK
LD r5,r0,#W_MPN
ADD r4,r4,r13
SUB r5,r5,r13
JMP @mpe_bd_l
mpe_ok:
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
mp_s_va:
.str "__VA_ARGS__"
