; nixfd.nas - NANIX phase 1.5 descriptor table (raw NaN16).
;
; Contract: spec/NIX_FD.md.  Sixteen descriptors:
;   0 terminal input (the current FNB line, then EOF)
;   1 terminal output (Terminal vc_putc)
;   2 terminal error  (Terminal vc_putc, separate slot)
;   3..15 NPAF files or nanpipe pipes.
;
; Entry (5 words): { used, kind, handle, flags, pipe_id }
;   kind 0 unused, 1 terminal, 2 NPAF file, 3 pipe
;   file: handle = bare_fs_open/STTAB handle
;   pipe: pipe_id = nanpipe id, flags bit0 = 1 for the write end
;
; The NPAF/stdio helpers are ordinary raw-NaN16 routines that use very small
; stack frames; any state a caller keeps in memory above its stack pointer can
; be overwritten by their link words.  Therefore every descriptor operation
; keeps cross-call state in the NFD_G word block, not on the software stack.
;
; ABI (r0=0, r13=1, r14=soft stack, r15=link):
;   nfd_init
;   nfd_open  r1=path byte r2=flags(0 read,1 write,2 append) -> fd/-1
;   nfd_read  r1=fd r2=dst byte r3=len -> bytes/-1
;   nfd_write r1=fd r2=src byte r3=len -> bytes/-1
;   nfd_close r1=fd -> 0/-1
;   nfd_dup2  r1=old r2=new -> 0/-1
;   nfd_pipe  r1=out_fd_ptr (word ptr) -> 0/-1
;   nfd_putc  r1=fd r2=char -> 1/-1
;   nfd_puts  r1=fd r2=packed word string -> count/-1
;   nfd_fd0_line
; Shell-private snapshot helpers (no fd slots are consumed):
;   nfd_save    r1=fd r2=dest(5 words) -> 0/-1
;   nfd_restore r1=fd r2=src(5 words)  -> 0/-1

.equ NFD_TAB    0x240000             ; 16 * 5 words
.equ NFD_FH     0x240050             ; open-file handle slots (16)
.equ NFD_FC     0x240060             ; open-file reference counts
.equ NFD_PC     0x240070             ; pipe reference counts (id 1..8)
.equ NFD_INPOS  0x240078             ; byte position in FNB
.equ NFD_CHAR   0x240079             ; 1-byte nfd_putc scratch (word addr)
.equ NFD_G      0x240080             ; cross-call state block

; cross-call state, one small set per operation
.equ NFD_O_PATH 0x240080
.equ NFD_O_FLAG 0x240081
.equ NFD_O_HAND 0x240082
.equ NFD_O_FD   0x240083
.equ NFD_O_OLD  0x240084
.equ NFD_O_ENT  0x240085
.equ NFD_TC_PATH 0x240086
.equ NFD_FA_HAND 0x240087
.equ NFD_R_FD   0x240088
.equ NFD_R_DST  0x240089
.equ NFD_R_LEN  0x24008A
.equ NFD_R_ENT  0x24008B
.equ NFD_R_KIND 0x24008C
.equ NFD_W_FD   0x240090
.equ NFD_W_SRC  0x240091
.equ NFD_W_LEN  0x240092
.equ NFD_W_ENT  0x240093
.equ NFD_W_KIND 0x240094
.equ NFD_W_CNT  0x240095
.equ NFD_W_CUR  0x240096
.equ NFD_C_FD   0x240098
.equ NFD_C_ENT  0x240099
.equ NFD_C_KIND 0x24009A
.equ NFD_D_OLD  0x2400A0
.equ NFD_D_NEW  0x2400A1
.equ NFD_D_OENT 0x2400A2
.equ NFD_D_NENT 0x2400A3
.equ NFD_P_OUT  0x2400A8
.equ NFD_P_ID   0x2400A9
.equ NFD_P_RFD  0x2400AA
.equ NFD_P_WFD  0x2400AB
.equ NFD_PC_FD  0x2400B0
.equ NFD_PC_CH  0x2400B1
.equ NFD_PC_ENT 0x2400B2
.equ NFD_PS_FD  0x2400B8
.equ NFD_PS_PTR 0x2400B9
.equ NFD_PS_CNT 0x2400BA
.equ NFD_S_FD   0x2400C0
.equ NFD_S_DST  0x2400C1
.equ NFD_S_ENT  0x2400C2
.equ NFD_S_KIND 0x2400C3
.equ NFD_RS_FD  0x2400C8
.equ NFD_RS_SRC 0x2400C9
.equ NFD_RS_ENT 0x2400CA
.equ NFD_ABUF   0x1800000             ; append staging bytes
.equ NFD_ABUF_MAX 0x400000

; ---------------------------------------------------------------------------
nfd_init:
  ST r15,r14,0
  ADDI r14,r14,9
  ; bare_fs_open lazily allocates its stream through the ncc heap.  In the
  ; shell that heap ceiling is still zero, and ni_heap_init would wrap its
  ; footer far past RAM.  Keep the shell heap below CEB (8.8 MB) and the
  ; PID 2 stack (byte 0x940000) until a real ncc_mem_setup run sizes it.
  LA r1,#W_HEAP_END
  LD r2,r1,0
  CMP r2,r0
  JMP[NE] @nfd_i_heap_end
  LA r2,0x218000
  ST r2,r1,0
nfd_i_heap_end:
  LA r1,#W_HEAP_LIMIT
  ST r0,r1,0
  LA r1,#W_HEAP_INIT
  ST r0,r1,0
  ; clear the 80-word descriptor table
  LA r2,#NFD_TAB
  MOVI r3,80
nfd_i_tab:
  ST r0,r2,0
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nfd_i_tab
  ; clear handle/ref tables (16+16+8 words)
  LA r2,#NFD_FH
  MOVI r3,40
nfd_i_ref:
  ST r0,r2,0
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nfd_i_ref
  LA r2,#NFD_INPOS
  ST r0,r2,0
  ; clear the cross-call state block (128 words)
  LA r2,#NFD_G
  MOVI r3,128
nfd_i_g:
  ST r0,r2,0
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nfd_i_g
  ; fd 0/1/2: used, kind=terminal, handle=fd, flags, pipe
  LA r2,#NFD_TAB
  MOVI r1,1
  ST r1,r2,0
  ST r1,r2,1
  ST r0,r2,2
  ST r0,r2,3
  ST r0,r2,4
  ADDI r2,r2,5
  ST r1,r2,0
  ST r1,r2,1
  ST r1,r2,2
  ST r0,r2,3
  ST r0,r2,4
  ADDI r2,r2,5
  ST r1,r2,0
  ST r1,r2,1
  MOVI r1,2
  ST r1,r2,2
  ST r0,r2,3
  ST r0,r2,4
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nfd_entry: r1=fd -> r1=entry or 0
nfd_entry:
  MOVI r2,16
  CMP r1,r2
  JMP[GE] @nfd_e_no
  MOVI r2,5
  MUL r1,r1,r2
  LA r2,#NFD_TAB
  ADD r1,r1,r2
  RET
nfd_e_no:
  MOVI r1,0
  RET

; nfd_alloc -> r1=zeroed descriptor 3..15 or -1
nfd_alloc:
  MOVI r1,3
nfd_a_l:
  MOVI r2,16
  CMP r1,r2
  JMP[GE] @nfd_a_no
  MOVI r2,5
  MUL r3,r1,r2
  LA r2,#NFD_TAB
  ADD r3,r3,r2
  LD r4,r3,0
  CMP r4,r0
  JMP[EQ] @nfd_a_use
  ADD r1,r1,r13
  JMP @nfd_a_l
nfd_a_use:
  MOVI r4,1
  ST r4,r3,0
  ST r0,r3,1
  ST r0,r3,2
  ST r0,r3,3
  ST r0,r3,4
  RET
nfd_a_no:
  LA r1,0xFFFFFFFF
  RET

; ---- open-file handle reference counts -----------------------------------
; nfd_fref_find: r1=handle -> r1=index or -1
nfd_fref_find:
  MOVI r2,0
  LA r3,#NFD_FH
nfd_ff_l:
  MOVI r4,16
  CMP r2,r4
  JMP[GE] @nfd_ff_no
  LD r5,r3,0
  CMP r5,r1
  JMP[EQ] @nfd_ff_y
  ADD r3,r3,r13
  ADD r2,r2,r13
  JMP @nfd_ff_l
nfd_ff_y:
  ADD r1,r2,r0
  RET
nfd_ff_no:
  LA r1,0xFFFFFFFF
  RET

; nfd_fref_add: r1=handle -> r1=index or -1
nfd_fref_add:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NFD_FA_HAND
  CALL @nfd_fref_find
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @nfd_fa_inc
  MOVI r2,0
  LA r3,#NFD_FC
nfd_fa_l:
  MOVI r4,16
  CMP r2,r4
  JMP[GE] @nfd_fa_no
  LD r5,r3,0
  CMP r5,r0
  JMP[EQ] @nfd_fa_use
  ADD r3,r3,r13
  ADD r2,r2,r13
  JMP @nfd_fa_l
nfd_fa_use:
  LD r5,r0,#NFD_FA_HAND
  LA r4,#NFD_FH
  ADD r4,r4,r2
  ST r5,r4,0
  MOVI r5,1
  ST r5,r3,0
  ADD r1,r2,r0
  JMP @nfd_fa_d
nfd_fa_inc:
  LA r3,#NFD_FC
  ADD r3,r3,r1
  LD r4,r3,0
  ADD r4,r4,r13
  ST r4,r3,0
  JMP @nfd_fa_d
nfd_fa_no:
  LA r1,0xFFFFFFFF
nfd_fa_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nfd_fref_inc: r1=handle -> 0/-1
nfd_fref_inc:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @nfd_fref_find
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nfd_fi_no
  LA r2,#NFD_FC
  ADD r2,r2,r1
  LD r3,r2,0
  ADD r3,r3,r13
  ST r3,r2,0
  MOVI r1,0
  JMP @nfd_fi_d
nfd_fi_no:
  LA r1,0xFFFFFFFF
nfd_fi_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nfd_fref_dec: r1=handle -> remaining count (0 means close it now), -1 bad
nfd_fref_dec:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @nfd_fref_find
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nfd_fd_no
  LA r2,#NFD_FC
  ADD r2,r2,r1
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @nfd_fd_no
  SUB r3,r3,r13
  ST r3,r2,0
  CMP r3,r0
  JMP[NE] @nfd_fd_ret
  LA r4,#NFD_FH
  ADD r4,r4,r1
  ST r0,r4,0
nfd_fd_ret:
  ADD r1,r3,r0
  JMP @nfd_fd_d
nfd_fd_no:
  LA r1,0xFFFFFFFF
nfd_fd_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---- pipe reference counts ------------------------------------------------
nfd_pref_inc:
  MOVI r2,1
  CMP r1,r2
  JMP[LT] @nfd_pi_no
  MOVI r2,#NPIPE_MAX
  CMP r1,r2
  JMP[GT] @nfd_pi_no
  SUB r1,r1,r13
  LA r2,#NFD_PC
  ADD r1,r1,r2
  LD r2,r1,0
  ADD r2,r2,r13
  ST r2,r1,0
  MOVI r1,0
  RET
nfd_pi_no:
  LA r1,0xFFFFFFFF
  RET

nfd_pref_dec:
  MOVI r2,1
  CMP r1,r2
  JMP[LT] @nfd_pd_no
  MOVI r2,#NPIPE_MAX
  CMP r1,r2
  JMP[GT] @nfd_pd_no
  SUB r1,r1,r13
  LA r2,#NFD_PC
  ADD r2,r2,r1
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @nfd_pd_no
  SUB r3,r3,r13
  ST r3,r2,0
  ADD r1,r3,r0
  RET
nfd_pd_no:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nfd_touch_create: r1=path -> 0.  nfs_create is balanced now, so this is a
; normal pre-create before bare_fs_open's write/append paths.
nfd_touch_create:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  LD r1,r14,1
  MOVI r2,0
  CALL @nfs_create
  MOVI r1,0
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_open: r1=path byte r2=flags 0 read / 1 write / 2 append -> fd or -1
nfd_open:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r0,#NFD_O_PATH
  ST r2,r0,#NFD_O_FLAG
  ST r0,r0,#NFD_O_OLD
  MOVI r3,2
  CMP r2,r3
  JMP[EQ] @nfd_o_app
  CMP r2,r0
  JMP[EQ] @nfd_o_read
  ; write: pre-create through the safe wrapper so bare_fs_open takes the
  ; existing-file branch inside nfs_create.
  LD r1,r0,#NFD_O_PATH
  CALL @nfd_touch_create
  LD r1,r0,#NFD_O_PATH
  MOVI r2,1
  CALL @bare_fs_open
  JMP @nfd_o_got
nfd_o_read:
  LD r1,r0,#NFD_O_PATH
  MOVI r2,0
  CALL @bare_fs_open
  JMP @nfd_o_got
nfd_o_app:
  LD r1,r0,#NFD_O_PATH
  CALL @nfd_touch_create
  LD r1,r0,#NFD_O_PATH
  LA r2,#NFD_ABUF
  LA r3,#NFD_ABUF_MAX
  CALL @bare_fs_load
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nfd_o_app_empty
  ST r1,r0,#NFD_O_OLD
nfd_o_app_empty:
  LD r1,r0,#NFD_O_PATH
  MOVI r2,1
  CALL @bare_fs_open
nfd_o_got:
  CMP r1,r0
  JMP[EQ] @nfd_o_fail
  ST r1,r0,#NFD_O_HAND
  CALL @nfd_alloc
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nfd_o_close_fail
  ST r1,r0,#NFD_O_FD
  ; fill descriptor: used=1, kind=2 file, handle, flags, pipe=0
  MOVI r2,5
  MUL r3,r1,r2
  LA r2,#NFD_TAB
  ADD r3,r3,r2
  ST r3,r0,#NFD_O_ENT
  MOVI r2,1
  ST r2,r3,0
  MOVI r2,2
  ST r2,r3,1
  LD r2,r0,#NFD_O_HAND
  ST r2,r3,2
  LD r2,r0,#NFD_O_FLAG
  ST r2,r3,3
  ST r0,r3,4
  LD r1,r0,#NFD_O_HAND
  CALL @nfd_fref_add
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nfd_o_unalloc
  ; append: recreate the file with its old bytes
  LD r2,r0,#NFD_O_FLAG
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nfd_o_ok
  LD r3,r0,#NFD_O_OLD
  CMP r3,r0
  JMP[EQ] @nfd_o_ok
  LD r1,r0,#NFD_O_HAND
  LA r2,#NFD_ABUF
  CALL @bare_fs_write
  LD r3,r0,#NFD_O_OLD
  CMP r1,r3
  JMP[NE] @nfd_o_unalloc
nfd_o_ok:
  LD r1,r0,#NFD_O_FD
  JMP @nfd_o_d
nfd_o_unalloc:
  LD r1,r0,#NFD_O_HAND
  CALL @nfd_fref_dec
  LD r1,r0,#NFD_O_HAND
  CALL @bare_fs_close
  LD r2,r0,#NFD_O_ENT
  ST r0,r2,0
  JMP @nfd_o_fail
nfd_o_close_fail:
  LD r1,r0,#NFD_O_HAND
  CALL @bare_fs_close
nfd_o_fail:
  LA r1,0xFFFFFFFF
nfd_o_d:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_read: r1=fd r2=dst byte r3=len -> bytes / -1
nfd_read:
  ST r15,r14,0
  ADDI r14,r14,30
  ST r1,r0,#NFD_R_FD
  ST r2,r0,#NFD_R_DST
  ST r3,r0,#NFD_R_LEN
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_r_no
  ST r1,r0,#NFD_R_ENT
  LD r2,r1,1
  ST r2,r0,#NFD_R_KIND
  MOVI r3,2
  CMP r2,r3
  JMP[EQ] @nfd_r_file
  MOVI r3,3
  CMP r2,r3
  JMP[EQ] @nfd_r_pipe
  MOVI r3,1
  CMP r2,r3
  JMP[EQ] @nfd_r_term
  JMP @nfd_r_no
nfd_r_file:
  LD r2,r0,#NFD_R_ENT
  LD r1,r2,2
  LD r2,r0,#NFD_R_DST
  LD r3,r0,#NFD_R_LEN
  CALL @bare_fs_read
  JMP @nfd_r_d
nfd_r_pipe:
  LD r2,r0,#NFD_R_ENT
  LD r1,r2,4
  LD r2,r0,#NFD_R_DST
  LD r3,r0,#NFD_R_LEN
  CALL @np_read
  JMP @nfd_r_d
nfd_r_term:
  ; terminal input is only fd 0
  LD r2,r0,#NFD_R_ENT
  LD r1,r2,2
  CMP r1,r0
  JMP[NE] @nfd_r_no
  LA r1,#NFD_INPOS
  LD r2,r1,0
  LA r3,#FNB
  ADD r3,r3,r2
  LD r4,r0,#NFD_R_DST
  LD r5,r0,#NFD_R_LEN
  MOVI r6,0
nfd_r_t_l:
  CMP r5,r0
  JMP[EQ] @nfd_r_t_done
  LDB r7,r3,0
  CMP r7,r0
  JMP[EQ] @nfd_r_t_done
  STB r7,r4,0
  ADD r3,r3,r13
  ADD r4,r4,r13
  ADD r6,r6,r13
  SUB r5,r5,r13
  JMP @nfd_r_t_l
nfd_r_t_done:
  LA r1,#NFD_INPOS
  LD r2,r1,0
  ADD r2,r2,r6
  ST r2,r1,0
  ADD r1,r6,r0
  JMP @nfd_r_d
nfd_r_no:
  LA r1,0xFFFFFFFF
nfd_r_d:
  ADDI r14,r14,-30
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_write: r1=fd r2=src byte r3=len -> bytes / -1
nfd_write:
  ST r15,r14,0
  ADDI r14,r14,30
  ST r1,r0,#NFD_W_FD
  ST r2,r0,#NFD_W_SRC
  ST r3,r0,#NFD_W_LEN
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_w_no
  ST r1,r0,#NFD_W_ENT
  LD r2,r1,1
  ST r2,r0,#NFD_W_KIND
  MOVI r3,2
  CMP r2,r3
  JMP[EQ] @nfd_w_file
  MOVI r3,3
  CMP r2,r3
  JMP[EQ] @nfd_w_pipe
  MOVI r3,1
  CMP r2,r3
  JMP[EQ] @nfd_w_term
  JMP @nfd_w_no
nfd_w_file:
  LD r2,r0,#NFD_W_ENT
  LD r1,r2,2
  LD r2,r0,#NFD_W_SRC
  LD r3,r0,#NFD_W_LEN
  CALL @bare_fs_write
  JMP @nfd_w_d
nfd_w_pipe:
  LD r2,r0,#NFD_W_ENT
  LD r1,r2,4
  LD r2,r0,#NFD_W_SRC
  LD r3,r0,#NFD_W_LEN
  CALL @np_write
  JMP @nfd_w_d
nfd_w_term:
  LD r3,r0,#NFD_W_LEN
  CMP r3,r0
  JMP[EQ] @nfd_w_zero
  LD r4,r0,#NFD_W_SRC
  ST r4,r0,#NFD_W_CUR
  ST r0,r0,#NFD_W_CNT
nfd_w_t_l:
  LD r3,r0,#NFD_W_LEN
  LD r5,r0,#NFD_W_CNT
  CMP r5,r3
  JMP[GE] @nfd_w_t_done
  LD r4,r0,#NFD_W_CUR
  LDB r2,r4,0
  LD r1,r0,@tk_id
  CALL @vc_putc
  LD r4,r0,#NFD_W_CUR
  ADD r4,r4,r13
  ST r4,r0,#NFD_W_CUR
  LD r5,r0,#NFD_W_CNT
  ADD r5,r5,r13
  ST r5,r0,#NFD_W_CNT
  JMP @nfd_w_t_l
nfd_w_t_done:
  LD r1,r0,#NFD_W_CNT
  JMP @nfd_w_d
nfd_w_zero:
  MOVI r1,0
  JMP @nfd_w_d
nfd_w_no:
  LA r1,0xFFFFFFFF
nfd_w_d:
  ADDI r14,r14,-30
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_close: r1=fd -> 0/-1
nfd_close:
  ST r15,r14,0
  ADDI r14,r14,18
  ST r1,r0,#NFD_C_FD
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_c_no
  ST r1,r0,#NFD_C_ENT
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nfd_c_no
  LD r2,r1,1
  ST r2,r0,#NFD_C_KIND
  MOVI r3,2
  CMP r2,r3
  JMP[EQ] @nfd_c_file
  MOVI r3,3
  CMP r2,r3
  JMP[EQ] @nfd_c_pipe
  JMP @nfd_c_clear
nfd_c_file:
  LD r2,r0,#NFD_C_ENT
  LD r1,r2,2
  CALL @nfd_fref_dec
  CMP r1,r0
  JMP[NE] @nfd_c_clear
  LD r2,r0,#NFD_C_ENT
  LD r1,r2,2
  CALL @bare_fs_close
  JMP @nfd_c_clear
nfd_c_pipe:
  LD r2,r0,#NFD_C_ENT
  LD r1,r2,4
  CALL @nfd_pref_dec
  CMP r1,r0
  JMP[NE] @nfd_c_clear
  LD r2,r0,#NFD_C_ENT
  LD r1,r2,4
  CALL @np_close
nfd_c_clear:
  LD r1,r0,#NFD_C_ENT
  ST r0,r1,0
  MOVI r1,0
  JMP @nfd_c_d
nfd_c_no:
  LA r1,0xFFFFFFFF
nfd_c_d:
  ADDI r14,r14,-18
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_dup2: r1=old r2=new -> 0/-1
nfd_dup2:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r0,#NFD_D_OLD
  ST r2,r0,#NFD_D_NEW
  CMP r1,r2
  JMP[EQ] @nfd_d_ok
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_d_no
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nfd_d_no
  ST r1,r0,#NFD_D_OENT
  LD r1,r0,#NFD_D_NEW
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_d_no
  ST r1,r0,#NFD_D_NENT
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nfd_d_copy
  LD r1,r0,#NFD_D_NEW
  CALL @nfd_close
nfd_d_copy:
  LD r1,r0,#NFD_D_OENT
  LD r2,r0,#NFD_D_NENT
  MOVI r3,5
nfd_d_cp_l:
  LD r4,r1,0
  ST r4,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nfd_d_cp_l
  LD r1,r0,#NFD_D_NENT
  LD r2,r1,1
  MOVI r3,2
  CMP r2,r3
  JMP[EQ] @nfd_d_fref
  MOVI r3,3
  CMP r2,r3
  JMP[EQ] @nfd_d_pref
  JMP @nfd_d_ok
nfd_d_fref:
  LD r1,r1,2
  CALL @nfd_fref_inc
  JMP @nfd_d_ok
nfd_d_pref:
  LD r1,r1,4
  CALL @nfd_pref_inc
nfd_d_ok:
  MOVI r1,0
  JMP @nfd_d_d
nfd_d_no:
  LA r1,0xFFFFFFFF
nfd_d_d:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_pipe: r1=out_fd_ptr (word ptr) -> 0/-1; writes read fd then write fd
nfd_pipe:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r0,#NFD_P_OUT
  CALL @np_open
  CMP r1,r0
  JMP[EQ] @nfd_p_no
  ST r1,r0,#NFD_P_ID
  CALL @nfd_alloc
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nfd_p_fail
  ST r1,r0,#NFD_P_RFD
  CALL @nfd_alloc
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nfd_p_unread
  ST r1,r0,#NFD_P_WFD
  ; read descriptor
  MOVI r2,5
  LD r1,r0,#NFD_P_RFD
  MUL r3,r1,r2
  LA r2,#NFD_TAB
  ADD r3,r3,r2
  MOVI r2,1
  ST r2,r3,0
  MOVI r2,3
  ST r2,r3,1
  ST r0,r3,2
  ST r0,r3,3
  LD r2,r0,#NFD_P_ID
  ST r2,r3,4
  ; write descriptor (flags bit0 = write end)
  MOVI r2,5
  LD r1,r0,#NFD_P_WFD
  MUL r3,r1,r2
  LA r2,#NFD_TAB
  ADD r3,r3,r2
  MOVI r2,1
  ST r2,r3,0
  MOVI r2,3
  ST r2,r3,1
  ST r0,r3,2
  MOVI r2,1
  ST r2,r3,3
  LD r2,r0,#NFD_P_ID
  ST r2,r3,4
  LD r1,r0,#NFD_P_ID
  SUB r1,r1,r13
  LA r2,#NFD_PC
  ADD r2,r2,r1
  MOVI r3,2
  ST r3,r2,0
  LD r3,r0,#NFD_P_OUT
  LD r2,r0,#NFD_P_RFD
  ST r2,r3,0
  LD r2,r0,#NFD_P_WFD
  ST r2,r3,1
  MOVI r1,0
  JMP @nfd_p_d
nfd_p_unread:
  LD r1,r0,#NFD_P_RFD
  MOVI r2,5
  MUL r3,r1,r2
  LA r2,#NFD_TAB
  ADD r3,r3,r2
  ST r0,r3,0
nfd_p_fail:
  LD r1,r0,#NFD_P_ID
  CALL @np_close
nfd_p_no:
  LA r1,0xFFFFFFFF
nfd_p_d:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_putc: r1=fd r2=char -> 1/-1
nfd_putc:
  ST r15,r14,0
  ADDI r14,r14,18
  ST r1,r0,#NFD_PC_FD
  ST r2,r0,#NFD_PC_CH
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_pc_no
  ST r1,r0,#NFD_PC_ENT
  LD r2,r1,1
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nfd_pc_other
  LD r2,r0,#NFD_PC_CH
  LD r1,r0,@tk_id
  CALL @vc_putc
  MOVI r1,1
  JMP @nfd_pc_d
nfd_pc_other:
  LD r2,r0,#NFD_PC_CH
  LA r3,#NFD_CHAR
  SHL r3,r3,2
  STB r2,r3,0
  LD r1,r0,#NFD_PC_FD
  ADD r2,r3,r0
  MOVI r3,1
  CALL @nfd_write
  JMP @nfd_pc_d
nfd_pc_no:
  LA r1,0xFFFFFFFF
nfd_pc_d:
  ADDI r14,r14,-18
  LD r15,r14,0
  RET

; nfd_puts: r1=fd r2=packed word string -> count/-1
nfd_puts:
  ST r15,r14,0
  ADDI r14,r14,18
  ST r1,r0,#NFD_PS_FD
  SHL r2,r2,2
  ST r2,r0,#NFD_PS_PTR
  ST r0,r0,#NFD_PS_CNT
nfd_ps_l:
  LD r2,r0,#NFD_PS_PTR
  LDB r3,r2,0
  CMP r3,r0
  JMP[EQ] @nfd_ps_done
  ADD r2,r2,r13
  ST r2,r0,#NFD_PS_PTR
  LD r1,r0,#NFD_PS_FD
  ADD r2,r3,r0
  CALL @nfd_putc
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nfd_ps_no
  LD r3,r0,#NFD_PS_CNT
  ADD r3,r3,r13
  ST r3,r0,#NFD_PS_CNT
  JMP @nfd_ps_l
nfd_ps_done:
  LD r1,r0,#NFD_PS_CNT
  JMP @nfd_ps_d
nfd_ps_no:
  LA r1,0xFFFFFFFF
nfd_ps_d:
  ADDI r14,r14,-18
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfd_save / nfd_restore: shell snapshot of one descriptor, no fd slot used.
nfd_save:
  ST r15,r14,0
  ADDI r14,r14,18
  ST r2,r0,#NFD_S_DST
  ST r1,r0,#NFD_S_FD
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_s_no
  ST r1,r0,#NFD_S_ENT
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nfd_s_no
  LD r2,r1,1
  ST r2,r0,#NFD_S_KIND
  MOVI r3,2
  CMP r2,r3
  JMP[EQ] @nfd_s_fref
  MOVI r3,3
  CMP r2,r3
  JMP[EQ] @nfd_s_pref
  JMP @nfd_s_copy
nfd_s_fref:
  LD r1,r0,#NFD_S_ENT
  LD r1,r1,2
  CALL @nfd_fref_inc
  JMP @nfd_s_copy
nfd_s_pref:
  LD r1,r0,#NFD_S_ENT
  LD r1,r1,4
  CALL @nfd_pref_inc
nfd_s_copy:
  LD r1,r0,#NFD_S_ENT
  LD r2,r0,#NFD_S_DST
  MOVI r3,5
nfd_s_cp_l:
  LD r4,r1,0
  ST r4,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nfd_s_cp_l
  MOVI r1,0
  JMP @nfd_s_d
nfd_s_no:
  LA r1,0xFFFFFFFF
nfd_s_d:
  ADDI r14,r14,-18
  LD r15,r14,0
  RET

nfd_restore:
  ST r15,r14,0
  ADDI r14,r14,18
  ST r1,r0,#NFD_RS_FD
  ST r2,r0,#NFD_RS_SRC
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_rs_no
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nfd_rs_copy
  LD r1,r0,#NFD_RS_FD
  CALL @nfd_close
nfd_rs_copy:
  LD r1,r0,#NFD_RS_FD
  CALL @nfd_entry
  CMP r1,r0
  JMP[EQ] @nfd_rs_no
  ST r1,r0,#NFD_RS_ENT
  LD r2,r0,#NFD_RS_SRC
  MOVI r3,5
nfd_rs_cp_l:
  LD r4,r2,0
  ST r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nfd_rs_cp_l
  LD r2,r0,#NFD_RS_SRC
  ST r0,r2,0
  MOVI r1,0
  JMP @nfd_rs_d
nfd_rs_no:
  LA r1,0xFFFFFFFF
nfd_rs_d:
  ADDI r14,r14,-18
  LD r15,r14,0
  RET

; nfd_fd0_line: phase 1.5 stdin is the current completed FNB line.
nfd_fd0_line:
  LA r1,#NFD_INPOS
  ST r0,r1,0
  RET
