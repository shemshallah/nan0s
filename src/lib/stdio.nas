; stdio.nas - FILE streams over the NPAF path filesystem (raw NaN16).
; Handles 1/2/3 are stdin/stdout/stderr; files use handles 4..19.
; Entry layout (10 words each):
;   0 used, 1 path, 2 buffer, 3 len, 4 cap, 5 pos, 6 mode, 7 dirty,
;   8 eof, 9 spare.
.equ STTAB    2750000      ; word address of byte 11000000
.equ STTABSZ  10
.equ STMAX    16
.equ FMTBUF   11010000
.equ FMTBUFSZ 8192

; nfs_ensure: format the RAM filesystem once if it has no magic
nfs_ensure:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#NFS_BASE
LD r2,r1,0
LA r3,0x4E504146
CMP r2,r3
JMP[EQ] @stnfe_d
CALL @nfs_format
stnfe_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; st_entry: r1=fd -> r1=entry or 0
st_entry:
MOVI r2,4
CMP r1,r2
JMP[LT] @ste_n
ADDI r1,r1,-4
MOVI r2,#STMAX
CMP r1,r2
JMP[GE] @ste_n
MOVI r2,#STTABSZ
MUL r1,r1,r2
LA r2,#STTAB
ADD r1,r1,r2
RET
ste_n:
MOVI r1,0
RET

; st_alloc -> r1=zeroed entry or 0
st_alloc:
MOVI r2,0
sta_l:
MOVI r3,#STMAX
CMP r2,r3
JMP[GE] @sta_n
MOVI r3,#STTABSZ
MUL r3,r2,r3
LA r4,#STTAB
ADD r3,r3,r4
LD r4,r3,0
CMP r4,r0
JMP[EQ] @sta_use
ADD r2,r2,r13
JMP @sta_l
sta_use:
MOVI r4,1
ST r4,r3,0
ST r0,r3,1
ST r0,r3,2
ST r0,r3,3
ST r0,r3,4
ST r0,r3,5
ST r0,r3,6
ST r0,r3,7
ST r0,r3,8
ST r0,r3,9
ADD r1,r3,r0
RET
sta_n:
MOVI r1,0
RET

; st_strdup: r1=C string -> r1=heap copy
st_strdup:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TA
CALL @ni_strlen
ST r1,r0,#W_TB
ADD r1,r1,r13
CALL @ni_malloc
ST r1,r0,#W_TC
LD r1,r0,#W_TC
LD r2,r0,#W_TA
LD r3,r0,#W_TB
ADD r3,r3,r13
CALL @ni_memcpy_raw
LD r1,r0,#W_TC
SUB r14,r14,r13
LD r15,r14,0
RET

; st_grow: r1=entry r2=needed
st_grow:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TM0
LD r3,r1,4
CMP r3,r2
JMP[GE] @stg_d
ADD r3,r3,r3
MOVI r4,256
CMP r3,r4
JMP[GE] @stg_1
MOVI r3,256
stg_1:
CMP r3,r2
JMP[GE] @stg_2
ADD r3,r2,r0
stg_2:
ST r3,r0,#W_TC
LD r1,r0,#W_TM0
LD r1,r1,2
LD r2,r0,#W_TC
CALL @ni_realloc
LD r2,r0,#W_TM0
ST r1,r2,2
LD r3,r0,#W_TC
ST r3,r2,4
stg_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; st_putc: r1=entry r2=char -> r2=char or -1
st_putc:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TM0
ST r2,r0,#W_TB
LD r3,r1,6
MOVI r4,1
CMP r3,r4
JMP[EQ] @stp_fail
LD r3,r1,5
ADD r3,r3,r13
LD r1,r0,#W_TM0
ADD r2,r3,r0
CALL @st_grow
LD r1,r0,#W_TM0
LD r2,r1,2
LD r3,r1,5
ADD r2,r2,r3
LD r4,r0,#W_TB
STB r4,r2,0
LD r2,r1,5
ADD r2,r2,r13
ST r2,r1,5
LD r3,r1,3
CMP r2,r3
JMP[LE] @stp_nolen
ST r2,r1,3
stp_nolen:
MOVI r2,1
ST r2,r1,7
LD r2,r0,#W_TB
JMP @stp_d
stp_fail:
LA r2,0xFFFFFFFF
stp_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; st_getc: r1=entry -> r1=char or -1
st_getc:
LD r2,r1,5
LD r3,r1,3
CMP r2,r3
JMP[LT] @stg_ok
MOVI r2,1
ST r2,r1,8
LA r1,0xFFFFFFFF
RET
stg_ok:
LD r3,r1,2
ADD r3,r3,r2
LDB r3,r3,0
ADD r2,r2,r13
ST r2,r1,5
ADD r1,r3,r0
RET

; st_write_buf: r1=entry r2=ptr r3=len -> r1=bytes written
st_write_buf:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TM0
ST r2,r0,#W_TM1
ST r3,r0,#W_TM2
LD r4,r1,6
MOVI r5,1
CMP r4,r5
JMP[EQ] @swb_zero
LD r4,r1,5
LD r5,r0,#W_TM2
ADD r4,r4,r5
LD r1,r0,#W_TM0
ADD r2,r4,r0
CALL @st_grow
LD r1,r0,#W_TM0
LD r4,r1,2
LD r5,r1,5
ADD r4,r4,r5
LD r6,r0,#W_TM1
LD r7,r0,#W_TM2
swb_l:
CMP r7,r0
JMP[EQ] @swb_done
LDB r3,r6,0
STB r3,r4,0
ADD r4,r4,r13
ADD r6,r6,r13
SUB r7,r7,r13
JMP @swb_l
swb_done:
LD r1,r0,#W_TM0
LD r2,r1,5
LD r3,r0,#W_TM2
ADD r2,r2,r3
ST r2,r1,5
LD r3,r1,3
CMP r2,r3
JMP[LE] @swb_nolen
ST r2,r1,3
swb_nolen:
MOVI r2,1
ST r2,r1,7
LD r1,r0,#W_TM2
JMP @swb_d
swb_zero:
MOVI r1,0
swb_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; st_read_buf: r1=entry r2=dst r3=len -> r1=bytes read
st_read_buf:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TM0
ST r2,r0,#W_TM1
ST r3,r0,#W_TM2
LD r4,r1,5
LD r5,r1,3
CMP r4,r5
JMP[LT] @srb_go
MOVI r2,1
ST r2,r1,8
MOVI r1,0
JMP @srb_d
srb_go:
SUB r5,r5,r4
LD r6,r0,#W_TM2
CMP r6,r5
JMP[GE] @srb_n
ADD r5,r6,r0
srb_n:
ST r5,r0,#W_TM2
LD r6,r1,2
ADD r6,r6,r4
LD r7,r0,#W_TM1
srb_l:
CMP r5,r0
JMP[EQ] @srb_done
LDB r3,r6,0
STB r3,r7,0
ADD r6,r6,r13
ADD r7,r7,r13
SUB r5,r5,r13
JMP @srb_l
srb_done:
LD r1,r0,#W_TM0
LD r2,r1,5
LD r3,r0,#W_TM2
ADD r2,r2,r3
ST r2,r1,5
CMP r2,r1
JMP[LT] @srb_noeof
srb_noeof:
LD r1,r0,#W_TM2
srb_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; st_flush: r1=entry -> 0
st_flush:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_TM0
LD r2,r1,7
CMP r2,r0
JMP[EQ] @sf_d
LD r1,r1,1
LD r2,r0,#W_TM0
LD r2,r2,2
SHR r2,r2,2
LD r3,r0,#W_TM0
LD r3,r3,3
CALL @nfs_write
LD r2,r0,#W_TM0
ST r0,r2,7
sf_d:
MOVI r1,0
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- fopen/fclose -------------------------------------------------
nbi_fopen:
CALL @nfs_ensure
CALL @ni_pop
ST r1,r0,#W_TM8
CALL @ni_pop
ST r1,r0,#W_TM7
CALL @st_alloc
ST r1,r0,#W_TM0
CMP r1,r0
JMP[EQ] @fop_fail
LD r1,r0,#W_TM7
CALL @st_strdup
LD r2,r0,#W_TM0
ST r1,r2,1
; mode
LD r1,r0,#W_TM8
LDB r2,r1,0
MOVI r3,1
MOVI r4,119
CMP r2,r4
JMP[NE] @fop_a
MOVI r3,2
JMP @fop_mode
fop_a:
MOVI r4,97
CMP r2,r4
JMP[NE] @fop_mode
MOVI r3,3
fop_mode:
LD r1,r0,#W_TM8
fop_pl:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @fop_pd
MOVI r4,43
CMP r2,r4
JMP[NE] @fop_pn
ADDI r3,r3,3
fop_pn:
ADD r1,r1,r13
JMP @fop_pl
fop_pd:
ST r3,r0,#W_TM1
LD r2,r0,#W_TM0
ST r3,r2,6
; read existing?
MOVI r4,1
CMP r3,r4
JMP[EQ] @fop_read
MOVI r4,3
CMP r3,r4
JMP[EQ] @fop_read
MOVI r4,4
CMP r3,r4
JMP[EQ] @fop_read
MOVI r4,6
CMP r3,r4
JMP[EQ] @fop_read
JMP @fop_empty
fop_read:
LD r1,r0,#W_TM7
CALL @nfs_find
CMP r1,r0
JMP[EQ] @fop_missing
LD r1,r0,#W_TM7
CALL @nfs_data
ST r1,r0,#W_TM4
ST r2,r0,#W_TM2
LD r1,r0,#W_TM2
ADD r1,r1,r13
CALL @ni_malloc
ST r1,r0,#W_TM3
LD r1,r0,#W_TM3
LD r2,r0,#W_TM4
SHL r2,r2,2
LD r3,r0,#W_TM2
CALL @ni_memcpy_raw
LD r2,r0,#W_TM0
LD r3,r0,#W_TM3
ST r3,r2,2
LD r3,r0,#W_TM2
ST r3,r2,3
ADD r3,r3,r13
ST r3,r2,4
ST r0,r2,5
ST r0,r2,8
; append modes start at end
LD r3,r0,#W_TM1
MOVI r4,3
CMP r3,r4
JMP[EQ] @fop_end
MOVI r4,6
CMP r3,r4
JMP[NE] @fop_dirty
fop_end:
LD r3,r2,3
ST r3,r2,5
fop_dirty:
MOVI r3,0
LD r4,r0,#W_TM1
MOVI r5,3
CMP r4,r5
JMP[EQ] @fop_dirty1
MOVI r5,6
CMP r4,r5
JMP[NE] @fop_setd
fop_dirty1:
MOVI r3,1
fop_setd:
ST r3,r2,7
JMP @fop_ok
fop_missing:
LD r3,r0,#W_TM1
MOVI r4,3
CMP r3,r4
JMP[EQ] @fop_empty
MOVI r4,6
CMP r3,r4
JMP[EQ] @fop_empty
JMP @fop_clean
fop_empty:
MOVI r1,256
CALL @ni_malloc
LD r2,r0,#W_TM0
ST r1,r2,2
ST r0,r2,3
MOVI r3,256
ST r3,r2,4
ST r0,r2,5
ST r0,r2,8
MOVI r3,1
ST r3,r2,7
fop_ok:
LD r1,r0,#W_TM0
LA r2,#STTAB
SUB r1,r1,r2
MOVI r2,#STTABSZ
DIVU r1,r1,r2
ADDI r1,r1,4
CALL @ni_push
JMP @nbi_d
fop_clean:
LD r2,r0,#W_TM0
ST r0,r2,0
fop_fail:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_fclose:
CALL @ni_pop
CALL @st_entry
CMP r1,r0
JMP[EQ] @fcl_e
ST r1,r0,#W_TM0
CALL @st_flush
LD r2,r0,#W_TM0
ST r0,r2,0
MOVI r1,0
CALL @ni_push
JMP @nbi_d
fcl_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

; ---- character / string I/O ---------------------------------------
nbi_fputc:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
LD r1,r0,#W_TA
MOVI r2,4
CMP r1,r2
JMP[LT] @fpc_std
CALL @st_entry
CMP r1,r0
JMP[EQ] @fpc_e
LD r2,r0,#W_TB
CALL @st_putc
CALL @ni_push
JMP @nbi_d
fpc_std:
LD r1,r0,#W_TB
CALL @ncc_putc
LD r1,r0,#W_TB
CALL @ni_push
JMP @nbi_d
fpc_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_fgetc:
CALL @ni_pop
MOVI r2,4
CMP r1,r2
JMP[LT] @fgc_e
CALL @st_entry
CMP r1,r0
JMP[EQ] @fgc_e
CALL @st_getc
CALL @ni_push
JMP @nbi_d
fgc_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_fputs:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
LD r1,r0,#W_TA
MOVI r2,4
CMP r1,r2
JMP[LT] @fps_std
CALL @st_entry
CMP r1,r0
JMP[EQ] @fps_e
ST r1,r0,#W_TM0
LD r1,r0,#W_TB
fps_l:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @fps_ok
ST r1,r0,#W_TD
LD r1,r0,#W_TM0
CALL @st_putc
LD r1,r0,#W_TD
ADD r1,r1,r13
JMP @fps_l
fps_ok:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
fps_std:
LD r1,r0,#W_TB
CALL @ni_puts
MOVI r1,10
CALL @ncc_putc
MOVI r1,0
CALL @ni_push
JMP @nbi_d
fps_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_fgets:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
CALL @ni_pop
ST r1,r0,#W_TC
LD r1,r0,#W_TA
MOVI r2,4
CMP r1,r2
JMP[LT] @fgs_e
CALL @st_entry
CMP r1,r0
JMP[EQ] @fgs_e
ST r1,r0,#W_TM0
LD r4,r0,#W_TC
MOVI r5,0
fgs_l:
LD r2,r0,#W_TB
SUB r2,r2,r13
CMP r5,r2
JMP[GE] @fgs_done
LD r1,r0,#W_TM0
CALL @st_getc
CMPS r1,r0
JMP[LT] @fgs_done
LD r2,r0,#W_TC
ADD r2,r2,r5
STB r1,r2,0
ST r1,r0,#W_TD
ADD r5,r5,r13
LD r1,r0,#W_TD
MOVI r2,10
CMP r1,r2
JMP[NE] @fgs_l
fgs_done:
LD r2,r0,#W_TC
ADD r2,r2,r5
STB r0,r2,0
CMP r5,r0
JMP[EQ] @fgs_null
LD r1,r0,#W_TC
CALL @ni_push
JMP @nbi_d
fgs_null:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
fgs_e:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

; ---- block I/O -----------------------------------------------------
nbi_fread:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
CALL @ni_pop
ST r1,r0,#W_TC
CALL @ni_pop
ST r1,r0,#W_TD
LD r1,r0,#W_TC
CMP r1,r0
JMP[EQ] @frd_zero
LD r1,r0,#W_TA
MOVI r2,4
CMP r1,r2
JMP[LT] @frd_e
CALL @st_entry
CMP r1,r0
JMP[EQ] @frd_e
ST r1,r0,#W_TM0
LD r1,r0,#W_TC
LD r2,r0,#W_TB
MUL r1,r1,r2
ST r1,r0,#W_TM1
LD r1,r0,#W_TM0
LD r2,r0,#W_TD
LD r3,r0,#W_TM1
CALL @st_read_buf
LD r2,r0,#W_TC
DIVU r1,r1,r2
CALL @ni_push
JMP @nbi_d
frd_zero:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
frd_e:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_fwrite:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
CALL @ni_pop
ST r1,r0,#W_TC
CALL @ni_pop
ST r1,r0,#W_TD
LD r1,r0,#W_TC
CMP r1,r0
JMP[EQ] @fwr_zero
LD r1,r0,#W_TA
MOVI r2,4
CMP r1,r2
JMP[LT] @fwr_std
CALL @st_entry
CMP r1,r0
JMP[EQ] @fwr_e
ST r1,r0,#W_TM0
LD r1,r0,#W_TC
LD r2,r0,#W_TB
MUL r1,r1,r2
ST r1,r0,#W_TM1
LD r1,r0,#W_TM0
LD r2,r0,#W_TD
LD r3,r0,#W_TM1
CALL @st_write_buf
LD r2,r0,#W_TC
DIVU r1,r1,r2
CALL @ni_push
JMP @nbi_d
fwr_std:
LD r1,r0,#W_TC
LD r2,r0,#W_TB
MUL r1,r1,r2
ST r1,r0,#W_TM1
LD r4,r0,#W_TD
LD r5,r0,#W_TM1
fwr_l:
CMP r5,r0
JMP[EQ] @fwr_ok
LDB r1,r4,0
ST r4,r0,#W_TD
ST r5,r0,#W_TM1
CALL @ncc_putc
LD r4,r0,#W_TD
LD r5,r0,#W_TM1
ADD r4,r4,r13
SUB r5,r5,r13
JMP @fwr_l
fwr_ok:
LD r1,r0,#W_TC
CALL @ni_push
JMP @nbi_d
fwr_zero:
MOVI r1,0
CALL @ni_push
JMP @nbi_d
fwr_e:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

; ---- fprintf -------------------------------------------------------
nbi_fprintf:
LD r1,r0,#W_SNOUT
ST r1,r0,#W_SNTMP1
LD r1,r0,#W_SNLIM
ST r1,r0,#W_SNTMP2
LD r1,r0,#W_SNPOS
ST r1,r0,#W_SNTMP3
LA r1,#FMTBUF
ST r1,r0,#W_SNOUT
ST r0,r0,#W_SNPOS
LA r1,#FMTBUFSZ
SUB r1,r1,r13
ST r1,r0,#W_SNLIM
LD r1,r0,#R_T1
ST r1,r0,#W_PF_ARGC
ST r0,r0,#W_PF_OFF
ST r0,r0,#W_PF_IDX
MOVI r1,0
CALL @ni_arg
ST r1,r0,#W_TE
MOVI r1,1
ST r1,r0,#W_PF_OFF
LD r1,r0,#R_T1
CALL @ni_printf
CALL @ni_pop
stfp_done:
; restore output redirection before emitting to a terminal handle
LD r1,r0,#W_SNPOS
ST r1,r0,#W_TC
LD r1,r0,#W_SNTMP1
ST r1,r0,#W_SNOUT
LD r1,r0,#W_SNTMP2
ST r1,r0,#W_SNLIM
LD r1,r0,#W_SNTMP3
ST r1,r0,#W_SNPOS
LD r1,r0,#W_TE
MOVI r2,4
CMP r1,r2
JMP[LT] @ststfp_std2
CALL @st_entry
CMP r1,r0
JMP[EQ] @stfp_ret
LA r2,#FMTBUF
LD r3,r0,#W_TC
CALL @st_write_buf
JMP @stfp_ret
ststfp_std2:
LA r4,#FMTBUF
LD r5,r0,#W_TC
ststfp_l2:
CMP r5,r0
JMP[EQ] @stfp_ret
LDB r1,r4,0
ST r4,r0,#W_TM2
ST r5,r0,#W_TM3
CALL @ncc_putc
LD r4,r0,#W_TM2
LD r5,r0,#W_TM3
ADD r4,r4,r13
SUB r5,r5,r13
JMP @ststfp_l2
stfp_ret:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

; ---- positioning ---------------------------------------------------
nbi_fseek:
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
CALL @ni_pop
ST r1,r0,#W_TC
LD r1,r0,#W_TC
MOVI r2,4
CMP r1,r2
JMP[LT] @fsk_e
CALL @st_entry
CMP r1,r0
JMP[EQ] @fsk_e
ST r1,r0,#W_TM0
LD r3,r0,#W_TA
CMP r3,r0
JMP[EQ] @fsk_set
MOVI r4,1
CMP r3,r4
JMP[EQ] @fsk_cur
LD r2,r1,3
JMP @fsk_add
fsk_set:
MOVI r2,0
JMP @fsk_add
fsk_cur:
LD r2,r1,5
fsk_add:
LD r3,r0,#W_TB
ADD r2,r2,r3
CMPS r2,r0
JMP[GE] @fsk_pos
MOVI r2,0
fsk_pos:
LD r3,r1,3
CMP r2,r3
JMP[LE] @fsk_store
ADD r2,r3,r0
fsk_store:
ST r2,r1,5
ST r0,r1,8
MOVI r1,0
CALL @ni_push
JMP @nbi_d
fsk_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_ftell:
CALL @ni_pop
MOVI r2,4
CMP r1,r2
JMP[LT] @ftl_e
CALL @st_entry
CMP r1,r0
JMP[EQ] @ftl_e
LD r1,r1,5
CALL @ni_push
JMP @nbi_d
ftl_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d

nbi_rewind:
CALL @ni_pop
MOVI r2,4
CMP r1,r2
JMP[LT] @rwd_d
CALL @st_entry
CMP r1,r0
JMP[EQ] @rwd_d
ST r0,r1,5
ST r0,r1,8
rwd_d:
JMP @nbi_zero

nbi_feof:
CALL @ni_pop
MOVI r2,4
CMP r1,r2
JMP[LT] @feo_z
CALL @st_entry
CMP r1,r0
JMP[EQ] @feo_z
LD r1,r1,8
CALL @ni_push
JMP @nbi_d
feo_z:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_ferror:
CALL @ni_pop
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_fflush:
CALL @ni_pop
MOVI r2,4
CMP r1,r2
JMP[LT] @ffl_z
CALL @st_entry
CMP r1,r0
JMP[EQ] @ffl_z
CALL @st_flush
MOVI r1,0
CALL @ni_push
JMP @nbi_d
ffl_z:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_remove:
CALL @nfs_ensure
CALL @ni_pop
CALL @nfs_delete
CALL @ni_push
JMP @nbi_d

nbi_rename:
CALL @nfs_ensure
CALL @ni_pop
ST r1,r0,#W_TA
CALL @ni_pop
ST r1,r0,#W_TB
LD r1,r0,#W_TB
CALL @nfs_find
CMP r1,r0
JMP[EQ] @ren_e
LD r1,r0,#W_TB
CALL @nfs_data
ST r1,r0,#W_TM0
ST r2,r0,#W_TM1
LD r1,r0,#W_TA
LD r2,r0,#W_TM0
LD r3,r0,#W_TM1
CALL @nfs_write
CMP r1,r0
JMP[EQ] @ren_e
LD r1,r0,#W_TB
CALL @nfs_delete
MOVI r1,0
CALL @ni_push
JMP @nbi_d
ren_e:
LA r1,0xFFFFFFFF
CALL @ni_push
JMP @nbi_d
