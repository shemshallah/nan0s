; nixsh.nas - NANIX POSIX shell, phase 1 (raw NaN16).
;
; Loaded at guest word 0x80000 as PID 2 by gui_sched_boot.  It owns the shell
; command line; the GUI Terminal remains the terminal emulator (PID 1).  The
; desktop writes a completed line to FNB, sets g_shell_req and yields; this
; process parses/executes it, writes through the Terminal's vc_putc, sets
; g_shell_done and yields back.
;
; Why a separate image: command growth must not consume the 64K GUI cart.
; This file may use the full word address space and CALL low-level GUI/FS
; helpers (vc_*, bare_fs_*) because all processes share the flat image.
;
; Phase 1.5: cwd, argv tokenisation, builtins, core file commands plus the
; NANIX fd table, redirection and sequential pipelines.
;
; ABI: r0=0, r13=1, r14=stack (grows up), r15=link.

.include "../lib/nanpipe.nas"
.include "../lib/nixfd.nas"
.include "../lib/nixcmds.nas"
.include "../lib/nixjobs.nas"
.include "../lib/nixjobs_sh.nas"

.equ NX_STACK   0x250000             ; words, below the heap
.equ NX_SCAN    0x200                ; low globals, direct LD/ST
.equ NX_IDX     0x201
.equ NX_LEN     0x202
.equ NX_TMP     0x203
.equ NX_STATUS  0x204
.equ NX_PTR     0x205
.equ NX_SRC     0x206
.equ NX_DST     0x207
.equ NX_A       0x208
.equ NX_B       0x209
.equ NX_STAT    0x210                ; 20-word stat block

; Byte-addressed scratch above the GUI compiler/terminal buffers.
.equ NX_BUF     0x1800000            ; 0x8000 bytes
.equ NX_P1      0x1010000
.equ NX_P2      0x1010100
.equ NX_CWD     0x1010200
.equ NX_CMD     0x1010300
.equ NX_A1      0x1010400
.equ NX_A2      0x1010500
.equ NX_A3      0x1010600
.equ NX_NAME    0x1010700
.equ NX_FMT     0x1010800
.equ NX_DECBUF  0x1010900
.equ NX_LINE    0x1011000             ; command with redirections removed
.equ NX_SEG0    0x1011100             ; pipeline left
.equ NX_SEG1    0x1011200             ; pipeline right
.equ NX_RIN     0x1011300
.equ NX_ROUT    0x1011400
.equ NX_RERR    0x1011500
.equ NX_RPATH   0x1011600

; Shell parse/execution words (above the phase-1 direct globals).
.equ NX_RFLAGS  0x230                 ; bit0 >, 1 >>, 2 2>&1, 3 2>, 4 2>>, 5 <
.equ NX_PIPE0   0x231                 ; read fd
.equ NX_PIPE1   0x232                 ; write fd
.equ NX_FD      0x233
.equ NX_OWN     0x234
.equ NX_WL      0x235
.equ NX_WW      0x236
.equ NX_WB      0x237
.equ NX_WIN     0x238
.equ NX_WIDX    0x239
.equ NX_WLEN    0x23A
; Cross-call shell state.  The NPAF/stdio helpers use very small frames, so
; values kept above the stack pointer can be overwritten by their link words.
; Descriptor setup, pipeline setup and output loops keep state here instead.
.equ NX_G_LINE   0x260
.equ NX_G_IN     0x261
.equ NX_G_OUT    0x262
.equ NX_G_STAT   0x263
.equ NX_G_FD     0x264
.equ NX_G_SAVE0  0x265
.equ NX_G_SAVE1  0x26A
.equ NX_G_SAVE2  0x26F
.equ NX_G_EL_LINE 0x274
.equ NX_G_EL_IN  0x275
.equ NX_G_EL_PIPE 0x276
.equ NX_G_EL_RFD 0x277
.equ NX_G_EL_WFD 0x278
.equ NX_G_EL_ST 0x279
.equ NX_G_PTR    0x27A
.equ NX_G_DEC_VAL 0x27B
.equ NX_G_DEC_PTR 0x27C
.equ NX_G_DEC_CNT 0x27D
.equ NX_G_PR_SRC 0x27E
.equ NX_G_PR_DST 0x27F
.equ NX_G_TGT_DST 0x280
.equ NX_G_PUTC_CH 0x281
.equ NX_G_PUTS_STR 0x282
.equ NX_G_EPUTC_CH 0x283
; In-shell NaN assembler/runner state.
.equ NX_A_STEPS  0x284
.equ NX_A_SP     0x285
.equ NX_A_R13    0x286
.equ NX_A_R15    0x287
.equ NX_A_CH     0x288
; Line-filter integration (nixcmds.nas).
.equ NX_F_CMD   0x2C0
.equ NX_F_PATH  0x2C1
.equ NX_F_COUNT 0x2C2
.equ NX_F_FLAGS 0x2C3
.equ NX_F_FD    0x2C4
.equ NX_F_PAT   0x2C5
.equ NX_F_FILE  0x2C6
.equ NX_F_TMP   0x2C7
.equ NX_JOB_READY 0x2C8
.equ NX_BG_ID    0x2C9
.equ NX_BG_TICKS 0x2CA
.equ NX_BG_JOB   0x2CB
.equ NX_JOBTAB   0x110000
.equ NX_JOBCTX1  0x110100
.equ NX_JOBFD1   0x110300
.equ NX_JOBSCR   0x110800
.equ NX_JOBSTK1  0x108000
.equ NX_JOBARENA 0x110000
.equ NX_JOBCAP   8

; POSIX variable lane: 16 entries of 16-byte name + 64-byte value.  The
; table and its string scratches are byte addressed and live above the GUI
; compiler/terminal buffers, below the SVC 2 heap.
.equ NX_VTAB     0x1900000            ; 16 * 80 bytes
.equ NX_VNAME    0x1201000            ; 16-byte name scratch
.equ NX_VVAL     0x1201100            ; 64-byte value scratch / read line
; Cross-call state for the variable lane.  NX_VG is a word address (the block
; is at byte 0x1202000); fields are word offsets.  Helpers only ever keep
; cross-call values here, never in a frame above SP, because shell callees
; reuse those words for their own link records.
.equ NX_VG       0x480800
.equ NX_VG_CNT   0
.equ NX_VG_NAMEP 1
.equ NX_VG_VALP  2
.equ NX_VG_ENT   3
.equ NX_VG_IDX   4
.equ NX_VG_LEN   5
.equ NX_VG_RD_NAME 6
.equ NX_VG_ENV_IDX 7
.equ NX_VG_NT_SCAN 8
.equ NX_VG_NT_DST  9
.equ NX_VG_NT_LONG 10

; ---------------------------------------------------------------------------
nx_main:
  MOVI r13,1
  LA r14,#NX_STACK
  CALL @nfd_init
  LA r1,@nx_root_path
  SHL r1,r1,2
  LA r2,#NX_CWD
  CALL @nx_copy
  CALL @nx_var_init
nx_loop:
  LA r2,@g_shell_req
  LD r1,r2,0
  CMP r1,r0
  JMP[EQ] @nx_idle
  ST r0,r2,0
  CALL @nx_run
  LA r2,@g_shell_done
  MOVI r1,1
  ST r1,r2,0
nx_idle:
  SVC 0
  JMP @nx_loop

; ---------------------------------------------------------------------------
; nx_run - parse FNB and execute one line (redirections and sequential pipes).
nx_run:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @nfd_fd0_line
  LA r1,#FNB
  CALL @nx_bg_tail
  CMP r1,r0
  JMP[NE] @nx_bg_run
  LA r1,#FNB
  LA r2,0xFFFFFFFF
  CALL @nx_exec_line
  JMP @nx_run_done
nx_bg_run:
  CALL @nx_exec_bg
nx_run_done:
  MOVI r1,0
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_exec_line: r1=line byte, r2=default input fd (-1 none) -> status
; Splits at the first unquoted '|', runs the left side with fd 1 on the pipe
; write end, then runs the right side with fd 0 on the read end (phase 1.5
; sequential pipeline).  A right side may contain another pipe.
nx_exec_line:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_EL_LINE
  ST r2,r0,#NX_G_EL_IN
  CALL @nx_find_pipe
  CMP r1,r0
  JMP[EQ] @nx_el_plain
  ST r1,r0,#NX_G_EL_PIPE
  ; left -> NX_SEG0, right -> NX_SEG1
  LD r1,r0,#NX_G_EL_LINE
  LA r2,#NX_SEG0
  LD r3,r0,#NX_G_EL_PIPE
  CALL @nx_copy_n
  LD r1,r0,#NX_G_EL_PIPE
  ADD r1,r1,r13
  LA r2,#NX_SEG1
  CALL @nx_copy
  LA r1,#NX_G_EL_RFD            ; nfd_pipe writes read then write fd
  CALL @nfd_pipe
  CMP r1,r0
  JMP[NE] @nx_el_pipefail
  ; left command: stdout defaults to the pipe write end
  LA r1,#NX_SEG0
  LD r2,r0,#NX_G_EL_IN
  LD r3,r0,#NX_G_EL_WFD
  CALL @nx_exec_cmd
  ST r1,r0,#NX_G_EL_ST
  LD r1,r0,#NX_G_EL_WFD
  CALL @nfd_close
  ; right command: stdin defaults to the pipe read end
  LA r1,#NX_SEG1
  LD r2,r0,#NX_G_EL_RFD
  CALL @nx_exec_line
  ST r1,r0,#NX_G_EL_ST
  LD r1,r0,#NX_G_EL_RFD
  CALL @nfd_close
  LD r1,r0,#NX_G_EL_ST
  JMP @nx_el_d
nx_el_plain:
  LD r1,r0,#NX_G_EL_LINE
  LD r2,r0,#NX_G_EL_IN
  LA r3,0xFFFFFFFF
  CALL @nx_exec_cmd
  JMP @nx_el_d
nx_el_pipefail:
  LA r1,@nx_s_pipebad
  CALL @nx_eputs
  MOVI r1,1
nx_el_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_exec_cmd: r1=line byte r2=default in fd r3=default out fd -> status
nx_exec_cmd:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_LINE
  ST r2,r0,#NX_G_IN
  ST r3,r0,#NX_G_OUT
  ST r0,r0,#NX_G_STAT
  LD r1,r0,#NX_G_LINE
  CALL @nx_parse_redirs
  CMP r1,r0
  JMP[NE] @nx_ec_bad
  ; first token -> NX_CMD, NX_SCAN after it
  LA r1,#NX_LINE
  LA r2,#NX_CMD
  CALL @nx_next_token
  ST r1,r0,#NX_SCAN
  LA r1,#NX_CMD
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_ec_done
  ; NAME=value is an assignment, not a command dispatch.
  LA r1,#NX_CMD
  CALL @nx_try_assign
  CMP r1,r0
  JMP[NE] @nx_ec_done
  ; snapshot the three standard descriptors
  MOVI r1,0
  LA r2,#NX_G_SAVE0
  CALL @nfd_save
  MOVI r1,1
  LA r2,#NX_G_SAVE1
  CALL @nfd_save
  MOVI r1,2
  LA r2,#NX_G_SAVE2
  CALL @nfd_save

  ; stdin: explicit '<' wins, else an inherited pipeline read end
  LD r1,r0,#NX_RFLAGS
  MOVI r2,32
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[EQ] @nx_ec_in_def
  LA r1,#NX_RIN
  LA r2,#NX_RPATH
  CALL @nx_abspath
  LA r1,#NX_RPATH
  MOVI r2,0
  CALL @nfd_open
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_ec_openbad
  ST r1,r0,#NX_G_FD
  MOVI r2,0
  CALL @nfd_dup2
  LD r1,r0,#NX_G_FD
  CALL @nfd_close
  JMP @nx_ec_out
nx_ec_in_def:
  LD r2,r0,#NX_G_IN
  LA r4,0xFFFFFFFF
  CMP r2,r4
  JMP[EQ] @nx_ec_out
  ADD r1,r2,r0
  MOVI r2,0
  CALL @nfd_dup2

nx_ec_out:
  ; stdout: explicit '>'/'>>' wins, else an inherited pipeline write end
  LD r1,r0,#NX_RFLAGS
  MOVI r2,1
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[EQ] @nx_ec_out_def
  LA r1,#NX_ROUT
  LA r2,#NX_RPATH
  CALL @nx_abspath
  LA r1,#NX_RPATH
  MOVI r2,1
  LD r3,r0,#NX_RFLAGS
  MOVI r4,2
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[EQ] @nx_ec_out_open
  MOVI r2,2
nx_ec_out_open:
  CALL @nfd_open
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_ec_openbad
  ST r1,r0,#NX_G_FD
  MOVI r2,1
  CALL @nfd_dup2
  LD r1,r0,#NX_G_FD
  CALL @nfd_close
  JMP @nx_ec_err
nx_ec_out_def:
  LD r2,r0,#NX_G_OUT
  LA r4,0xFFFFFFFF
  CMP r2,r4
  JMP[EQ] @nx_ec_err
  ADD r1,r2,r0
  MOVI r2,1
  CALL @nfd_dup2

nx_ec_err:
  ; stderr: 2>&1 duplicates the (already redirected) stdout, else 2> FILE
  LD r1,r0,#NX_RFLAGS
  MOVI r2,4
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[EQ] @nx_ec_err_file
  MOVI r1,1
  MOVI r2,2
  CALL @nfd_dup2
  JMP @nx_ec_exec
nx_ec_err_file:
  LD r1,r0,#NX_RFLAGS
  MOVI r2,8
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[EQ] @nx_ec_exec
  LA r1,#NX_RERR
  LA r2,#NX_RPATH
  CALL @nx_abspath
  LA r1,#NX_RPATH
  MOVI r2,1
  LD r3,r0,#NX_RFLAGS
  MOVI r4,16
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[EQ] @nx_ec_err_open
  MOVI r2,2
nx_ec_err_open:
  CALL @nfd_open
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_ec_openbad
  ST r1,r0,#NX_G_FD
  MOVI r2,2
  CALL @nfd_dup2
  LD r1,r0,#NX_G_FD
  CALL @nfd_close

nx_ec_exec:
  CALL @nx_dispatch
  ST r1,r0,#NX_G_STAT
  JMP @nx_ec_restore
nx_ec_openbad:
  LA r1,@nx_s_redirbad
  CALL @nx_eputs
  MOVI r1,1
  ST r1,r0,#NX_G_STAT
nx_ec_restore:
  MOVI r1,2
  LA r2,#NX_G_SAVE2
  CALL @nfd_restore
  MOVI r1,1
  LA r2,#NX_G_SAVE1
  CALL @nfd_restore
  MOVI r1,0
  LA r2,#NX_G_SAVE0
  CALL @nfd_restore
  LD r1,r0,#NX_G_STAT
  JMP @nx_ec_d
nx_ec_bad:
  LA r1,@nx_s_redirbad
  CALL @nx_eputs
  MOVI r1,1
  JMP @nx_ec_d
nx_ec_done:
  MOVI r1,0
nx_ec_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_dispatch: NX_CMD/NX_SCAN are set by nx_exec_cmd.
nx_dispatch:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#NX_CMD
  LA r2,@nx_c_cd
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_cd
  LA r1,#NX_CMD
  LA r2,@nx_c_pwd
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_pwd
  LA r1,#NX_CMD
  LA r2,@nx_c_echo
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_echo
  LA r1,#NX_CMD
  LA r2,@nx_c_printf
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_printf
  LA r1,#NX_CMD
  LA r2,@nx_c_true
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_true
  LA r1,#NX_CMD
  LA r2,@nx_c_false
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_false
  LA r1,#NX_CMD
  LA r2,@nx_c_test
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test
  LA r1,#NX_CMD
  LA r2,@nx_c_cp
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_cp
  LA r1,#NX_CMD
  LA r2,@nx_c_mv
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_mv
  LA r1,#NX_CMD
  LA r2,@nx_c_touch
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_touch
  LA r1,#NX_CMD
  LA r2,@nx_c_rm
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_rm
  LA r1,#NX_CMD
  LA r2,@nx_c_mkdir
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_mkdir
  LA r1,#NX_CMD
  LA r2,@nx_c_rmdir
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_rmdir
  LA r1,#NX_CMD
  LA r2,@nx_c_ls
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_ls
  LA r1,#NX_CMD
  LA r2,@nx_c_cat
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_cat
  LA r1,#NX_CMD
  LA r2,@nx_c_wc
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_wc
  LA r1,#NX_CMD
  LA r2,@nx_c_stat
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_stat
  LA r1,#NX_CMD
  LA r2,@nx_c_trunc
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_trunc
  LA r1,#NX_CMD
  LA r2,@nx_c_sleep
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_sleep
  LA r1,#NX_CMD
  LA r2,@nx_c_kill
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_kill
  LA r1,#NX_CMD
  LA r2,@nx_c_head
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_head
  LA r1,#NX_CMD
  LA r2,@nx_c_tail
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_tail
  LA r1,#NX_CMD
  LA r2,@nx_c_grep
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_grep
  LA r1,#NX_CMD
  LA r2,@nx_c_sort
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_sort
  LA r1,#NX_CMD
  LA r2,@nx_c_uniq
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_uniq
  LA r1,#NX_CMD
  LA r2,@nx_c_jobs
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_jobs
  LA r1,#NX_CMD
  LA r2,@nx_c_wait
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_wait
  LA r1,#NX_CMD
  LA r2,@nx_c_read
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_read
  LA r1,#NX_CMD
  LA r2,@nx_c_env
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_env
  LA r1,#NX_CMD
  LA r2,@nx_c_sync
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_sync
  LA r1,#NX_CMD
  LA r2,@nx_c_help
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_help
  LA r1,#NX_CMD
  LA r2,@nx_c_exit
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_exit
  LA r1,#NX_CMD
  LA r2,@nx_c_asm
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_asm

  ; Everything not ported yet keeps the existing GUI/NANIX command handler.
  ; Hand it the clean line so redirect operators are not part of its args.
  LA r1,#NX_LINE
  LA r2,#FNB
  CALL @nx_copy
  CALL @fs_dispatch
nx_done:
  MOVI r1,0
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Byte/string helpers.  Standard output goes through fd 1, diagnostics fd 2.
nx_putc:                                  ; r1=char
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_PUTC_CH
  MOVI r1,1
  LD r2,r0,#NX_G_PUTC_CH
  CALL @nfd_putc
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_eputc:                                 ; r1=char
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_EPUTC_CH
  MOVI r1,2
  LD r2,r0,#NX_G_EPUTC_CH
  CALL @nfd_putc
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_puts:                                  ; r1=word string
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_PUTS_STR
  MOVI r1,1
  LD r2,r0,#NX_G_PUTS_STR
  CALL @nfd_puts
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_eputs:                                 ; r1=word string
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_PUTS_STR
  MOVI r1,2
  LD r2,r0,#NX_G_PUTS_STR
  CALL @nfd_puts
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_putb:                                  ; r1=byte string
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_PTR
nx_pb_l:
  LD r1,r0,#NX_G_PTR
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_pb_d
  ADD r1,r1,r13
  ST r1,r0,#NX_G_PTR
  ADD r1,r2,r0
  CALL @nx_putc
  JMP @nx_pb_l
nx_pb_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_nl:
  ST r15,r14,0
  ADDI r14,r14,9
  MOVI r1,10
  CALL @nx_putc
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_dec:                                   ; r1=value -> fd 1
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_G_DEC_VAL
  LA r2,#NX_DECBUF
  ST r2,r0,#NX_G_DEC_PTR
  ST r0,r0,#NX_G_DEC_CNT
  CMP r1,r0
  JMP[NE] @nx_dec_nz
  MOVI r1,48
  CALL @nx_putc
  JMP @nx_dec_d
nx_dec_nz:
  LD r1,r0,#NX_G_DEC_VAL
  MOVI r4,10
  DIVU r5,r1,r4
  MUL r6,r5,r4
  SUB r6,r1,r6
  MOVI r7,48
  ADD r6,r6,r7
  LD r2,r0,#NX_G_DEC_PTR
  STB r6,r2,0
  ADD r2,r2,r13
  ST r2,r0,#NX_G_DEC_PTR
  LD r3,r0,#NX_G_DEC_CNT
  ADD r3,r3,r13
  ST r3,r0,#NX_G_DEC_CNT
  ST r5,r0,#NX_G_DEC_VAL
  CMP r5,r0
  JMP[NE] @nx_dec_nz
nx_dec_pr:
  LD r3,r0,#NX_G_DEC_CNT
  CMP r3,r0
  JMP[EQ] @nx_dec_d
  SUB r3,r3,r13
  ST r3,r0,#NX_G_DEC_CNT
  LA r2,#NX_DECBUF
  ADD r2,r2,r3
  LDB r1,r2,0
  CALL @nx_putc
  JMP @nx_dec_pr
nx_dec_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_copy:                                  ; r1=src byte, r2=dst byte
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_SRC
  ST r2,r0,#NX_DST
nx_cp_l:
  LD r1,r0,#NX_SRC
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_cp_d
  LD r2,r0,#NX_DST
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r0,#NX_SRC
  ADD r2,r2,r13
  ST r2,r0,#NX_DST
  JMP @nx_cp_l
nx_cp_d:
  LD r1,r0,#NX_DST
  STB r0,r1,0
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_streq:                                 ; r1=byte ptr, r2=word .str -> r1=1/0
  ST r15,r14,0
  ADDI r14,r14,9
  SHL r2,r2,2
nx_se_l:
  LDB r3,r1,0
  LDB r4,r2,0
  CMP r3,r4
  JMP[NE] @nx_se_n
  CMP r4,r0
  JMP[EQ] @nx_se_y
  ADD r1,r1,r13
  ADD r2,r2,r13
  JMP @nx_se_l
nx_se_y:
  MOVI r1,1
  JMP @nx_se_d
nx_se_n:
  MOVI r1,0
nx_se_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_streqb: r1=byte string a, r2=byte string b -> r1=1/0.  Leaf.
nx_streqb:
  LDB r3,r1,0
  LDB r4,r2,0
  CMP r3,r4
  JMP[NE] @nx_seb_n
  CMP r3,r0
  JMP[EQ] @nx_seb_y
  ADD r1,r1,r13
  ADD r2,r2,r13
  JMP @nx_streqb
nx_seb_y:
  MOVI r1,1
  RET
nx_seb_n:
  MOVI r1,0
  RET

; nx_copy_max: r1=src byte, r2=dst byte, r3=max bytes -> NUL-terminated copy.
; Copies at most max bytes; leaf, registers only.
nx_copy_max:
  MOVI r4,0
nx_cm_l:
  CMP r4,r3
  JMP[GE] @nx_cm_d
  LDB r5,r1,0
  CMP r5,r0
  JMP[EQ] @nx_cm_d
  STB r5,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  ADD r4,r4,r13
  JMP @nx_cm_l
nx_cm_d:
  STB r0,r2,0
  RET

; ---------------------------------------------------------------------------
; Variable table helpers.  Entries are 80 bytes: name[16], value[64].
; nx_var_find r1=name byte -> r1=entry byte ptr or 0; NX_VG_ENT holds it too.
nx_var_find:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r12,#NX_VG
  ST r0,r12,3
  ST r0,r12,4
nx_vf_l:
  LA r12,#NX_VG
  LD r2,r12,4
  LD r3,r12,0
  CMP r2,r3
  JMP[GE] @nx_vf_no
  MOVI r3,80
  MUL r4,r2,r3
  LA r5,#NX_VTAB
  ADD r5,r5,r4
  ST r5,r12,3
  LD r1,r12,1
  ADD r2,r5,r0
  CALL @nx_streqb
  CMP r1,r0
  JMP[NE] @nx_vf_yes
  LA r12,#NX_VG
  LD r3,r12,4
  ADD r3,r3,r13
  ST r3,r12,4
  JMP @nx_vf_l
nx_vf_yes:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_ENT
  JMP @nx_vf_d
nx_vf_no:
  MOVI r1,0
nx_vf_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_var_set r1=name byte, r2=value byte -> r1=0 / -1 (table full).
; Arguments and loop state live in NX_VG; frame is exactly the link word.
nx_var_set:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r12,#NX_VG
  ST r1,r12,#NX_VG_NAMEP
  ST r2,r12,#NX_VG_VALP
  CALL @nx_var_find
  CMP r1,r0
  JMP[EQ] @nx_vs_new
  ; Existing variable: replace the value in place.
  LA r12,#NX_VG
  LD r2,r12,#NX_VG_ENT
  ADDI r2,r2,16
  LD r1,r12,#NX_VG_VALP
  MOVI r3,63
  CALL @nx_copy_max
  MOVI r1,0
  JMP @nx_vs_d
nx_vs_new:
  LA r12,#NX_VG
  LD r3,r12,#NX_VG_CNT
  MOVI r4,16
  CMP r3,r4
  JMP[GE] @nx_vs_full
  MOVI r4,80
  MUL r5,r3,r4
  LA r6,#NX_VTAB
  ADD r6,r6,r5
  ST r6,r12,#NX_VG_ENT
  LD r1,r12,#NX_VG_NAMEP
  ADD r2,r6,r0
  MOVI r3,15
  CALL @nx_copy_max
  LA r12,#NX_VG
  LD r2,r12,#NX_VG_ENT
  ADDI r2,r2,16
  LD r1,r12,#NX_VG_VALP
  MOVI r3,63
  CALL @nx_copy_max
  LA r12,#NX_VG
  LD r3,r12,#NX_VG_CNT
  ADD r3,r3,r13
  ST r3,r12,#NX_VG_CNT
  MOVI r1,0
  JMP @nx_vs_d
nx_vs_full:
  LA r1,0xFFFFFFFF
nx_vs_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_var_init - seed PWD/HOME/PATH/SHELL in insertion order.
nx_var_init:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r2,#NX_VG
  ST r0,r2,0
  LA r1,@nx_s_pwd_n
  SHL r1,r1,2
  LA r2,#NX_CWD
  CALL @nx_var_set
  LA r1,@nx_s_home_n
  SHL r1,r1,2
  LA r2,@nx_root_path
  SHL r2,r2,2
  CALL @nx_var_set
  LA r1,@nx_s_path_n
  SHL r1,r1,2
  LA r2,@nx_root_path
  SHL r2,r2,2
  CALL @nx_var_set
  LA r1,@nx_s_shell_n
  SHL r1,r1,2
  LA r2,@nx_s_nixsh
  SHL r2,r2,2
  CALL @nx_var_set
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_try_assign - NX_CMD as NAME=value -> store it, return 1; else 0.
nx_try_assign:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#NX_CMD
  LDB r2,r1,0
  ; first name character: A-Z, a-z or '_'
  MOVI r3,65
  CMP r2,r3
  JMP[LT] @nx_as_lower
  MOVI r3,90
  CMP r2,r3
  JMP[LE] @nx_as_first
nx_as_lower:
  MOVI r3,97
  CMP r2,r3
  JMP[LT] @nx_as_us
  MOVI r3,122
  CMP r2,r3
  JMP[LE] @nx_as_first
nx_as_us:
  MOVI r3,95
  CMP r2,r3
  JMP[NE] @nx_as_no
nx_as_first:
  LA r4,#NX_VNAME
  MOVI r5,0
nx_as_l:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_as_no
  MOVI r3,61
  CMP r2,r3
  JMP[EQ] @nx_as_eq
  ; subsequent name characters: A-Z, a-z, 0-9 or '_'
  MOVI r3,65
  CMP r2,r3
  JMP[LT] @nx_as_c_lower
  MOVI r3,90
  CMP r2,r3
  JMP[LE] @nx_as_store
nx_as_c_lower:
  MOVI r3,97
  CMP r2,r3
  JMP[LT] @nx_as_c_digit
  MOVI r3,122
  CMP r2,r3
  JMP[LE] @nx_as_store
nx_as_c_digit:
  MOVI r3,48
  CMP r2,r3
  JMP[LT] @nx_as_c_us
  MOVI r3,57
  CMP r2,r3
  JMP[LE] @nx_as_store
nx_as_c_us:
  MOVI r3,95
  CMP r2,r3
  JMP[NE] @nx_as_no
nx_as_store:
  MOVI r3,15
  CMP r5,r3
  JMP[GE] @nx_as_no
  STB r2,r4,0
  ADD r4,r4,r13
  ADD r5,r5,r13
  ADD r1,r1,r13
  JMP @nx_as_l
nx_as_eq:
  CMP r5,r0
  JMP[EQ] @nx_as_no
  STB r0,r4,0
  ADD r1,r1,r13
  LA r2,#NX_VVAL
  MOVI r3,63
  CALL @nx_copy_max
  LA r1,#NX_VNAME
  LA r2,#NX_VVAL
  CALL @nx_var_set
  CMP r1,r0
  JMP[NE] @nx_as_full
  ST r0,r0,#NX_STATUS
  MOVI r1,1
  JMP @nx_as_d
nx_as_full:
  MOVI r1,1
  ST r1,r0,#NX_STATUS
  MOVI r1,1
  JMP @nx_as_d
nx_as_no:
  MOVI r1,0
nx_as_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_next_token r1=scan byte, r2=dest byte -> r1=scan after token.
; Splits on spaces outside single/double quotes; quotes are removed.
; $NAME expands outside single quotes (and inside double quotes); single-
; quoted text stays literal.  All cross-call state lives in NX_VG.
nx_next_token:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r12,#NX_VG
  ST r1,r12,#NX_VG_NT_SCAN
  ST r2,r12,#NX_VG_NT_DST
nx_nt_skip:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  LDB r3,r1,0
  MOVI r4,32
  CMP r3,r4
  JMP[NE] @nx_nt_start
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  JMP @nx_nt_skip
nx_nt_start:
  CMP r3,r0
  JMP[NE] @nx_nt_copy
  LA r12,#NX_VG
  LD r2,r12,#NX_VG_NT_DST
  STB r0,r2,0
  JMP @nx_nt_d
nx_nt_copy:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_nt_end
  MOVI r4,34
  CMP r3,r4
  JMP[EQ] @nx_nt_dquote
  MOVI r4,39
  CMP r3,r4
  JMP[EQ] @nx_nt_squote
  MOVI r4,32
  CMP r3,r4
  JMP[EQ] @nx_nt_end
  MOVI r4,36
  CMP r3,r4
  JMP[EQ] @nx_nt_dollar
  LA r12,#NX_VG
  LD r2,r12,#NX_VG_NT_DST
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  ADD r2,r2,r13
  ST r2,r12,#NX_VG_NT_DST
  JMP @nx_nt_copy
nx_nt_dquote:
  LA r12,#NX_VG
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
nx_nt_dq_l:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_nt_end
  MOVI r4,34
  CMP r3,r4
  JMP[EQ] @nx_nt_dq_done
  MOVI r4,36
  CMP r3,r4
  JMP[EQ] @nx_nt_dq_dollar
  LD r2,r12,#NX_VG_NT_DST
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  ADD r2,r2,r13
  ST r2,r12,#NX_VG_NT_DST
  JMP @nx_nt_dq_l
nx_nt_dq_done:
  LA r12,#NX_VG
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  JMP @nx_nt_copy
nx_nt_squote:
  LA r12,#NX_VG
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
nx_nt_sq_l:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_nt_end
  MOVI r4,39
  CMP r3,r4
  JMP[EQ] @nx_nt_sq_done
  LD r2,r12,#NX_VG_NT_DST
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  ADD r2,r2,r13
  ST r2,r12,#NX_VG_NT_DST
  JMP @nx_nt_sq_l
nx_nt_sq_done:
  LA r12,#NX_VG
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  JMP @nx_nt_copy
nx_nt_dollar:
  CALL @nx_nt_expand
  CMP r1,r0
  JMP[NE] @nx_nt_copy
  ; '$' not followed by a name: keep it literally.
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  LD r2,r12,#NX_VG_NT_DST
  MOVI r3,36
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  ADD r2,r2,r13
  ST r2,r12,#NX_VG_NT_DST
  JMP @nx_nt_copy
nx_nt_dq_dollar:
  CALL @nx_nt_expand
  CMP r1,r0
  JMP[NE] @nx_nt_dq_l
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  LD r2,r12,#NX_VG_NT_DST
  MOVI r3,36
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_NT_SCAN
  ADD r2,r2,r13
  ST r2,r12,#NX_VG_NT_DST
  JMP @nx_nt_dq_l
nx_nt_end:
  LA r12,#NX_VG
  LD r2,r12,#NX_VG_NT_DST
  STB r0,r2,0
nx_nt_d:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_nt_expand - scan points at '$'; append the named variable's value to the
; current token destination.  Returns 1 when a valid NAME followed the '$'
; (even if unset -> empty expansion), 0 when '$' is literal.  Parsing state is
; in NX_VG; only leaf nx_streqb is called below nx_var_find.
nx_nt_expand:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_NT_SCAN
  ADD r1,r1,r13
  LDB r2,r1,0
  ; first name character: A-Z, a-z or '_'
  MOVI r3,65
  CMP r2,r3
  JMP[LT] @nx_nx_lower
  MOVI r3,90
  CMP r2,r3
  JMP[LE] @nx_nx_first
nx_nx_lower:
  MOVI r3,97
  CMP r2,r3
  JMP[LT] @nx_nx_us
  MOVI r3,122
  CMP r2,r3
  JMP[LE] @nx_nx_first
nx_nx_us:
  MOVI r3,95
  CMP r2,r3
  JMP[NE] @nx_nx_none
nx_nx_first:
  LA r4,#NX_VNAME
  MOVI r5,0
  LA r12,#NX_VG
  ST r0,r12,10               ; truncation flag
nx_nx_copy:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_nx_name
  ; subsequent name characters: A-Z, a-z, 0-9 or '_'
  MOVI r3,65
  CMP r2,r3
  JMP[LT] @nx_nx_c_lower
  MOVI r3,90
  CMP r2,r3
  JMP[LE] @nx_nx_store
nx_nx_c_lower:
  MOVI r3,97
  CMP r2,r3
  JMP[LT] @nx_nx_c_digit
  MOVI r3,122
  CMP r2,r3
  JMP[LE] @nx_nx_store
nx_nx_c_digit:
  MOVI r3,48
  CMP r2,r3
  JMP[LT] @nx_nx_c_us
  MOVI r3,57
  CMP r2,r3
  JMP[LE] @nx_nx_store
nx_nx_c_us:
  MOVI r3,95
  CMP r2,r3
  JMP[NE] @nx_nx_name
nx_nx_store:
  MOVI r3,15
  CMP r5,r3
  JMP[GE] @nx_nx_long
  STB r2,r4,0
  ADD r4,r4,r13
  ADD r5,r5,r13
  ADD r1,r1,r13
  JMP @nx_nx_copy
nx_nx_long:
  ; Too long for the 16-byte field: consume the rest and expand to empty.
  LA r12,#NX_VG
  MOVI r3,1
  ST r3,r12,10
  ADD r1,r1,r13
  JMP @nx_nx_copy
nx_nx_name:
  LA r12,#NX_VG
  LD r6,r12,#NX_VG_NT_LONG
  CMP r6,r0
  JMP[EQ] @nx_nx_term
  LA r4,#NX_VNAME
nx_nx_term:
  STB r0,r4,0
  LA r12,#NX_VG
  ST r1,r12,#NX_VG_NT_SCAN
  LA r1,#NX_VNAME
  ST r1,r12,#NX_VG_NAMEP
  CALL @nx_var_find
  CMP r1,r0
  JMP[EQ] @nx_nx_done
  LA r12,#NX_VG
  LD r2,r12,#NX_VG_ENT
  ADDI r2,r2,16
  LD r4,r12,#NX_VG_NT_DST
nx_nx_app:
  LDB r3,r2,0
  CMP r3,r0
  JMP[EQ] @nx_nx_app_done
  STB r3,r4,0
  ADD r2,r2,r13
  ADD r4,r4,r13
  JMP @nx_nx_app
nx_nx_app_done:
  LA r12,#NX_VG
  ST r4,r12,#NX_VG_NT_DST
nx_nx_done:
  MOVI r1,1
  JMP @nx_nx_d
nx_nx_none:
  MOVI r1,0
nx_nx_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_next_arg r1=dest byte -> fills dest, advances NX_SCAN.
nx_next_arg:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  LD r1,r0,#NX_SCAN
  LD r2,r14,1
  CALL @nx_next_token
  ST r1,r0,#NX_SCAN
  LD r1,r14,1
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_copy_n r1=src byte r2=dst byte r3=end -> copies [src,end), NUL terminates.
nx_copy_n:
  CMP r1,r3
  JMP[GE] @nx_cn_d
nx_cn_l:
  LDB r4,r1,0
  STB r4,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  CMP r1,r3
  JMP[LT] @nx_cn_l
nx_cn_d:
  STB r0,r2,0
  RET

; nx_find_pipe r1=line byte -> r1=first unquoted '|' or 0
nx_find_pipe:
  MOVI r5,0                     ; quote state
nx_fp_l:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_fp_n
  CMP r5,r0
  JMP[NE] @nx_fp_q
  MOVI r3,34
  CMP r2,r3
  JMP[EQ] @nx_fp_open
  MOVI r3,39
  CMP r2,r3
  JMP[EQ] @nx_fp_open
  MOVI r3,124
  CMP r2,r3
  JMP[EQ] @nx_fp_y
  ADD r1,r1,r13
  JMP @nx_fp_l
nx_fp_open:
  ADD r5,r2,r0
  ADD r1,r1,r13
  JMP @nx_fp_l
nx_fp_q:
  CMP r2,r5
  JMP[NE] @nx_fp_qn
  MOVI r5,0
nx_fp_qn:
  ADD r1,r1,r13
  JMP @nx_fp_l
nx_fp_y:
  RET
nx_fp_n:
  MOVI r1,0
  RET

; nx_parse_target r1=ptr r2=dest byte -> r1=ptr after target or 0
nx_parse_target:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r2,r14,1
nx_pt_skip:
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_pt_no
  MOVI r4,32
  CMP r3,r4
  JMP[NE] @nx_pt_start
  ADD r1,r1,r13
  JMP @nx_pt_skip
nx_pt_start:
  LD r2,r14,1
  MOVI r4,34
  CMP r3,r4
  JMP[EQ] @nx_pt_quoted
  MOVI r4,39
  CMP r3,r4
  JMP[EQ] @nx_pt_quoted
nx_pt_copy:
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_pt_done
  MOVI r4,32
  CMP r3,r4
  JMP[EQ] @nx_pt_done
  STB r3,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  JMP @nx_pt_copy
nx_pt_quoted:
  ADD r5,r3,r0
  ADD r1,r1,r13
nx_pt_ql:
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_pt_done
  CMP r3,r5
  JMP[EQ] @nx_pt_qdone
  STB r3,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  JMP @nx_pt_ql
nx_pt_qdone:
  ADD r1,r1,r13
  JMP @nx_pt_copy
nx_pt_done:
  STB r0,r2,0
  JMP @nx_pt_d
nx_pt_no:
  MOVI r1,0
nx_pt_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_parse_redirs r1=src byte -> clean line in NX_LINE, paths/flags in NX_*;
; returns 0 or -1 when an operator has no target.
nx_parse_redirs:
  ST r15,r14,0
  ADDI r14,r14,18
  ST r1,r0,#NX_G_PR_SRC
  LA r2,#NX_LINE
  ST r2,r0,#NX_G_PR_DST
  ST r0,r0,#NX_RFLAGS
  LA r2,#NX_RIN
  STB r0,r2,0
  LA r2,#NX_ROUT
  STB r0,r2,0
  LA r2,#NX_RERR
  STB r0,r2,0
nx_pr_l:
  LD r1,r0,#NX_G_PR_SRC
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_pr_done
  ; quoted text is copied verbatim; operators inside are literal
  MOVI r4,34
  CMP r3,r4
  JMP[EQ] @nx_pr_quote
  MOVI r4,39
  CMP r3,r4
  JMP[EQ] @nx_pr_quote
  ; 2>&1
  MOVI r4,50
  CMP r3,r4
  JMP[NE] @nx_pr_chk2
  ADDI r4,r1,1
  LDB r5,r4,0
  MOVI r6,62
  CMP r5,r6
  JMP[NE] @nx_pr_chk2
  ADDI r4,r1,2
  LDB r5,r4,0
  MOVI r6,38
  CMP r5,r6
  JMP[NE] @nx_pr_chk2
  ADDI r4,r1,3
  LDB r5,r4,0
  MOVI r6,49
  CMP r5,r6
  JMP[NE] @nx_pr_chk2
  LD r5,r0,#NX_RFLAGS
  MOVI r6,4
  ADD r5,r5,r6
  ST r5,r0,#NX_RFLAGS
  ADDI r1,r1,4
  ST r1,r0,#NX_G_PR_SRC
  JMP @nx_pr_l
nx_pr_chk2:
  MOVI r4,50
  CMP r3,r4
  JMP[NE] @nx_pr_chklt
  ADDI r4,r1,1
  LDB r5,r4,0
  MOVI r6,62
  CMP r5,r6
  JMP[NE] @nx_pr_copy
  ; 2> or 2>>
  LD r5,r0,#NX_RFLAGS
  MOVI r6,8
  ADD r5,r5,r6
  ST r5,r0,#NX_RFLAGS
  ADDI r1,r1,2
  LDB r5,r1,0
  MOVI r6,62
  CMP r5,r6
  JMP[NE] @nx_pr_err_t
  LD r5,r0,#NX_RFLAGS
  MOVI r6,16
  ADD r5,r5,r6
  ST r5,r0,#NX_RFLAGS
  ADD r1,r1,r13
nx_pr_err_t:
  ST r1,r0,#NX_G_PR_SRC
  LA r2,#NX_RERR
  CALL @nx_parse_target
  CMP r1,r0
  JMP[EQ] @nx_pr_bad
  ST r1,r0,#NX_G_PR_SRC
  JMP @nx_pr_l
nx_pr_chklt:
  MOVI r4,60
  CMP r3,r4
  JMP[NE] @nx_pr_chkgt
  LD r5,r0,#NX_RFLAGS
  MOVI r6,32
  ADD r5,r5,r6
  ST r5,r0,#NX_RFLAGS
  ADD r1,r1,r13
  ST r1,r0,#NX_G_PR_SRC
  LA r2,#NX_RIN
  CALL @nx_parse_target
  CMP r1,r0
  JMP[EQ] @nx_pr_bad
  ST r1,r0,#NX_G_PR_SRC
  JMP @nx_pr_l
nx_pr_chkgt:
  MOVI r4,62
  CMP r3,r4
  JMP[NE] @nx_pr_copy
  LD r5,r0,#NX_RFLAGS
  MOVI r6,1
  ADD r5,r5,r6
  ST r5,r0,#NX_RFLAGS
  ADD r1,r1,r13
  LDB r5,r1,0
  MOVI r6,62
  CMP r5,r6
  JMP[NE] @nx_pr_out_t
  LD r5,r0,#NX_RFLAGS
  MOVI r6,2
  ADD r5,r5,r6
  ST r5,r0,#NX_RFLAGS
  ADD r1,r1,r13
nx_pr_out_t:
  ST r1,r0,#NX_G_PR_SRC
  LA r2,#NX_ROUT
  CALL @nx_parse_target
  CMP r1,r0
  JMP[EQ] @nx_pr_bad
  ST r1,r0,#NX_G_PR_SRC
  JMP @nx_pr_l
nx_pr_quote:
  LD r2,r0,#NX_G_PR_DST
  ADD r5,r3,r0
nx_pr_q_l:
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_pr_q_end
  MOVI r4,32
  CMP r3,r4
  JMP[NE] @nx_pr_q_copy
  ; spaces stay inside the quoted token
nx_pr_q_copy:
  STB r3,r2,0
  ADD r2,r2,r13
  ADD r1,r1,r13
  CMP r3,r5
  JMP[EQ] @nx_pr_q_done
  JMP @nx_pr_q_l
nx_pr_q_end:
  ST r1,r0,#NX_G_PR_SRC
  ST r2,r0,#NX_G_PR_DST
  JMP @nx_pr_done
nx_pr_q_done:
  ST r1,r0,#NX_G_PR_SRC
  ST r2,r0,#NX_G_PR_DST
  JMP @nx_pr_l
nx_pr_copy:
  LD r2,r0,#NX_G_PR_DST
  STB r3,r2,0
  ADD r2,r2,r13
  ST r2,r0,#NX_G_PR_DST
  ADD r1,r1,r13
  ST r1,r0,#NX_G_PR_SRC
  JMP @nx_pr_l
nx_pr_done:
  LD r2,r0,#NX_G_PR_DST
  STB r0,r2,0
  MOVI r1,0
  JMP @nx_pr_d
nx_pr_bad:
  LA r1,0xFFFFFFFF
nx_pr_d:
  ADDI r14,r14,-18
  LD r15,r14,0
  RET


nx_abspath:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
  LDB r3,r1,0
  MOVI r4,47
  CMP r3,r4
  JMP[EQ] @nx_ab_abs
  ; dest = cwd
  LD r5,r14,2
  LA r6,#NX_CWD
nx_ab_cwd:
  LDB r7,r6,0
  CMP r7,r0
  JMP[EQ] @nx_ab_cwd_d
  STB r7,r5,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  JMP @nx_ab_cwd
nx_ab_cwd_d:
  SUB r7,r5,r13
  LDB r8,r7,0
  MOVI r4,47
  CMP r8,r4
  JMP[EQ] @nx_ab_arg
  MOVI r8,47
  STB r8,r5,0
  ADD r5,r5,r13
nx_ab_arg:
  LD r6,r14,1
nx_ab_copy:
  LDB r7,r6,0
  CMP r7,r0
  JMP[EQ] @nx_ab_done
  STB r7,r5,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  JMP @nx_ab_copy
nx_ab_abs:
  LD r5,r14,2
  LD r6,r14,1
  JMP @nx_ab_copy
nx_ab_done:
  STB r0,r5,0
  LD r1,r14,2
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_atoi:                                  ; r1=byte ptr -> r1=value
  MOVI r2,0
nx_at_l:
  LDB r3,r1,0
  MOVI r4,48
  CMP r3,r4
  JMP[LT] @nx_at_d
  MOVI r4,57
  CMP r3,r4
  JMP[GT] @nx_at_d
  MOVI r4,10
  MUL r2,r2,r4
  MOVI r4,48
  SUB r3,r3,r4
  ADD r2,r2,r3
  ADD r1,r1,r13
  JMP @nx_at_l
nx_at_d:
  ADD r1,r2,r0
  RET

; ---------------------------------------------------------------------------
nx_cd:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[NE] @nx_cd_arg
  LA r1,@nx_root_path
  SHL r1,r1,2
  LA r2,#NX_CWD
  CALL @nx_copy
  JMP @nx_cd_ok
nx_cd_arg:
  LA r1,#NX_A1
  LDB r2,r1,0
  MOVI r4,47
  CMP r2,r4
  JMP[NE] @nx_cd_norm
  LDB r2,r1,1
  CMP r2,r0
  JMP[NE] @nx_cd_norm
  LA r1,@nx_root_path
  SHL r1,r1,2
  LA r2,#NX_CWD
  CALL @nx_copy
  JMP @nx_cd_ok
nx_cd_norm:
  LA r1,#NX_A1
  LA r2,#NX_CWD
  CALL @nx_abspath
  LA r1,#NX_CWD
  LA r2,#NX_STAT
  CALL @bare_fs_stat
  CMP r1,r0
  JMP[NE] @nx_cd_bad
  LA r1,#NX_STAT
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_cd_bad
nx_cd_ok:
  LA r1,@nx_s_pwd_n
  SHL r1,r1,2
  LA r2,#NX_CWD
  CALL @nx_var_set
  JMP @nx_done
nx_cd_bad:
  LA r1,@nx_s_cdbad
  CALL @nx_eputs
  JMP @nx_done

nx_pwd:
  LA r1,#NX_CWD
  CALL @nx_putb
  CALL @nx_nl
  JMP @nx_done

nx_echo:
  ST r0,r0,#NX_TMP
nx_echo_l:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_echo_d
  LD r1,r0,#NX_TMP
  CMP r1,r0
  JMP[EQ] @nx_echo_ns
  MOVI r1,32
  CALL @nx_putc
nx_echo_ns:
  LA r1,#NX_A1
  CALL @nx_putb
  MOVI r1,1
  ST r1,r0,#NX_TMP
  JMP @nx_echo_l
nx_echo_d:
  CALL @nx_nl
  JMP @nx_done

nx_printf:
  ; format is the first argument after the command
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LA r2,#NX_FMT
  CALL @nx_copy
  LA r1,#NX_FMT
  ST r1,r0,#NX_PTR
nx_pf_l:
  LD r1,r0,#NX_PTR
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_pf_done
  ADD r1,r1,r13
  ST r1,r0,#NX_PTR
  MOVI r3,37
  CMP r2,r3
  JMP[EQ] @nx_pf_conv
  ADD r1,r2,r0
  CALL @nx_putc
  JMP @nx_pf_l
nx_pf_conv:
  LD r1,r0,#NX_PTR
  LDB r3,r1,0
  ADD r1,r1,r13
  ST r1,r0,#NX_PTR
  MOVI r4,115
  CMP r3,r4
  JMP[EQ] @nx_pf_s
  MOVI r4,100
  CMP r3,r4
  JMP[EQ] @nx_pf_d
  MOVI r4,99
  CMP r3,r4
  JMP[EQ] @nx_pf_c
  MOVI r4,37
  CMP r3,r4
  JMP[EQ] @nx_pf_pct
  MOVI r1,37
  CALL @nx_putc
  ADD r1,r3,r0
  CALL @nx_putc
  JMP @nx_pf_l
nx_pf_pct:
  MOVI r1,37
  CALL @nx_putc
  JMP @nx_pf_l
nx_pf_s:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  CALL @nx_putb
  JMP @nx_pf_l
nx_pf_c:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  ADD r1,r2,r0
  CALL @nx_putc
  JMP @nx_pf_l
nx_pf_d:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  CALL @nx_atoi
  CALL @nx_dec
  JMP @nx_pf_l
nx_pf_done:
  JMP @nx_done

; ---------------------------------------------------------------------------
nx_true:
  MOVI r1,0
  ST r1,r0,#NX_STATUS
  JMP @nx_done
nx_false:
  MOVI r1,1
  ST r1,r0,#NX_STATUS
  JMP @nx_done

nx_test:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A2
  CALL @nx_next_arg
  LA r1,#NX_A3
  CALL @nx_next_arg
  ; -e / -f / -d PATH
  LA r1,#NX_A1
  LA r2,@nx_s_e
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_e
  LA r1,#NX_A1
  LA r2,@nx_s_f
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_f
  LA r1,#NX_A1
  LA r2,@nx_s_d
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_d
  LA r1,#NX_A1
  LA r2,@nx_s_z
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_z
  LA r1,#NX_A1
  LA r2,@nx_s_n
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_n
  ; A1 = A2 / A1 != A2
  LA r1,#NX_A2
  LA r2,@nx_s_eq
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_eq
  LA r1,#NX_A2
  LA r2,@nx_s_ne
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_ne
  JMP @nx_test_bad
nx_test_e:
  LA r1,#NX_A2
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  CALL @bare_fs_access
  CMP r1,r0
  JMP[NE] @nx_test_ok
  JMP @nx_test_bad
nx_test_f:
  LA r1,#NX_A2
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  LA r2,#NX_STAT
  CALL @bare_fs_stat
  CMP r1,r0
  JMP[NE] @nx_test_bad
  LA r1,#NX_STAT
  LD r1,r1,0
  CMP r1,r0
  JMP[EQ] @nx_test_ok
  JMP @nx_test_bad
nx_test_d:
  LA r1,#NX_A2
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  LA r2,#NX_STAT
  CALL @bare_fs_stat
  CMP r1,r0
  JMP[NE] @nx_test_bad
  LA r1,#NX_STAT
  LD r1,r1,0
  CMP r1,r0
  JMP[NE] @nx_test_ok
  JMP @nx_test_bad
nx_test_z:
  LA r1,#NX_A2
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_test_ok
  JMP @nx_test_bad
nx_test_n:
  LA r1,#NX_A2
  LDB r2,r1,0
  CMP r2,r0
  JMP[NE] @nx_test_ok
  JMP @nx_test_bad
nx_test_eq:
  LA r1,#NX_A1
  LA r2,#NX_A3
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_test_ok
  JMP @nx_test_bad
nx_test_ne:
  LA r1,#NX_A1
  LA r2,#NX_A3
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_test_ok
  JMP @nx_test_bad
nx_test_ok:
  MOVI r1,0
  ST r1,r0,#NX_STATUS
  JMP @nx_done
nx_test_bad:
  MOVI r1,1
  ST r1,r0,#NX_STATUS
  JMP @nx_done

; ---------------------------------------------------------------------------
nx_cp:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A2
  CALL @nx_next_arg
  LA r1,#NX_A2
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_cp_use
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_A2
  LA r2,#NX_P2
  CALL @nx_abspath
  LA r1,#NX_P1
  LA r2,#NX_BUF
  MOVI r3,0x8000
  CALL @bare_fs_load
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_cp_bad
  ST r1,r0,#NX_LEN
  LA r1,#NX_P2
  LA r2,#NX_BUF
  LD r3,r0,#NX_LEN
  CALL @bare_fs_save
  CMP r1,r0
  JMP[EQ] @nx_cp_bad
  LA r1,@nx_s_ok
  CALL @nx_puts
  JMP @nx_done
nx_cp_use:
  LA r1,@nx_s_cpuse
  CALL @nx_eputs
  JMP @nx_done
nx_cp_bad:
  LA r1,@nx_s_err
  CALL @nx_eputs
  JMP @nx_done

nx_mv:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A2
  CALL @nx_next_arg
  LA r1,#NX_A2
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_cp_use
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_A2
  LA r2,#NX_P2
  CALL @nx_abspath
  LA r1,#NX_P1
  LA r2,#NX_BUF
  MOVI r3,0x8000
  CALL @bare_fs_load
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_cp_bad
  ST r1,r0,#NX_LEN
  LA r1,#NX_P2
  LA r2,#NX_BUF
  LD r3,r0,#NX_LEN
  CALL @bare_fs_save
  CMP r1,r0
  JMP[EQ] @nx_cp_bad
  LA r1,#NX_P1
  CALL @bare_fs_remove
  LA r1,@nx_s_ok
  CALL @nx_puts
  JMP @nx_done

nx_touch:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_cp_use
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  CALL @bare_fs_access
  CMP r1,r0
  JMP[NE] @nx_touch_ok
  LA r1,#NX_P1
  LA r2,#NX_BUF
  MOVI r3,0
  CALL @bare_fs_save
  CMP r1,r0
  JMP[EQ] @nx_cp_bad
nx_touch_ok:
  LA r1,@nx_s_ok
  CALL @nx_puts
  JMP @nx_done

nx_rm:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  CALL @bare_fs_remove
  CMP r1,r0
  JMP[NE] @nx_cp_bad
  LA r1,@nx_s_removed
  CALL @nx_puts
  JMP @nx_done

nx_mkdir:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  CALL @bare_fs_mkdir
  CMP r1,r0
  JMP[NE] @nx_cp_bad
  LA r1,@nx_s_ok
  CALL @nx_puts
  JMP @nx_done

nx_rmdir:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  CALL @bare_fs_rmdir
  CMP r1,r0
  JMP[NE] @nx_cp_bad
  LA r1,@nx_s_removed
  CALL @nx_puts
  JMP @nx_done

nx_ls:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[NE] @nx_ls_arg
  LA r1,#NX_CWD
  LA r2,#NX_P1
  CALL @nx_copy
  JMP @nx_ls_go
nx_ls_arg:
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
nx_ls_go:
  MOVI r1,0
  ST r1,r0,#NX_IDX
nx_ls_l:
  LA r1,#NX_P1
  LA r2,#NX_IDX
  LA r3,#NX_NAME
  MOVI r4,64
  LA r5,#NX_TMP
  CALL @bare_fs_readdir
  CMP r1,r0
  JMP[EQ] @nx_done
  LA r1,#NX_NAME
  CALL @nx_putb
  CALL @nx_nl
  JMP @nx_ls_l

nx_cat:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_cat_stdin
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  MOVI r2,0
  CALL @nfd_open
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_cat_bad
  ST r1,r0,#NX_FD
  MOVI r1,1
  ST r1,r0,#NX_OWN
  JMP @nx_cat_loop
nx_cat_stdin:
  MOVI r1,0
  ST r1,r0,#NX_FD
  ST r0,r0,#NX_OWN
nx_cat_loop:
  LD r1,r0,#NX_FD
  LA r2,#NX_BUF
  MOVI r3,0x1000
  CALL @nfd_read
  CMP r1,r0
  JMP[EQ] @nx_cat_close
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_cat_close
  ST r1,r0,#NX_LEN
  MOVI r1,1
  LA r2,#NX_BUF
  LD r3,r0,#NX_LEN
  CALL @nfd_write
  JMP @nx_cat_loop
nx_cat_close:
  LD r1,r0,#NX_OWN
  CMP r1,r0
  JMP[EQ] @nx_cat_ok
  LD r1,r0,#NX_FD
  CALL @nfd_close
nx_cat_ok:
  JMP @nx_done
nx_cat_bad:
  LA r1,@nx_s_catbad
  CALL @nx_eputs
  MOVI r1,1
  ST r1,r0,#NX_STATUS
  JMP @nx_done

; wc: lines words bytes from a file or fd 0 (pipe/terminal line).
nx_wc:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_wc_stdin
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  MOVI r2,0
  CALL @nfd_open
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_wc_bad
  ST r1,r0,#NX_FD
  MOVI r1,1
  ST r1,r0,#NX_OWN
  JMP @nx_wc_zero
nx_wc_stdin:
  MOVI r1,0
  ST r1,r0,#NX_FD
  ST r0,r0,#NX_OWN
nx_wc_zero:
  ST r0,r0,#NX_WL
  ST r0,r0,#NX_WW
  ST r0,r0,#NX_WB
  ST r0,r0,#NX_WIN
nx_wc_loop:
  LD r1,r0,#NX_FD
  LA r2,#NX_BUF
  MOVI r3,0x1000
  CALL @nfd_read
  CMP r1,r0
  JMP[EQ] @nx_wc_done
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_wc_done
  ST r1,r0,#NX_WLEN
  ST r0,r0,#NX_WIDX
nx_wc_byte:
  LD r1,r0,#NX_WIDX
  LD r2,r0,#NX_WLEN
  CMP r1,r2
  JMP[GE] @nx_wc_loop
  LA r3,#NX_BUF
  ADD r3,r3,r1
  LDB r4,r3,0
  LD r5,r0,#NX_WB
  ADD r5,r5,r13
  ST r5,r0,#NX_WB
  MOVI r6,10
  CMP r4,r6
  JMP[NE] @nx_wc_notnl
  LD r5,r0,#NX_WL
  ADD r5,r5,r13
  ST r5,r0,#NX_WL
nx_wc_notnl:
  ; whitespace: space, tab, CR, LF
  MOVI r6,32
  CMP r4,r6
  JMP[EQ] @nx_wc_space
  MOVI r6,9
  CMP r4,r6
  JMP[EQ] @nx_wc_space
  MOVI r6,13
  CMP r4,r6
  JMP[EQ] @nx_wc_space
  MOVI r6,10
  CMP r4,r6
  JMP[EQ] @nx_wc_space
  LD r5,r0,#NX_WIN
  CMP r5,r0
  JMP[NE] @nx_wc_next
  LD r5,r0,#NX_WW
  ADD r5,r5,r13
  ST r5,r0,#NX_WW
  MOVI r5,1
  ST r5,r0,#NX_WIN
  JMP @nx_wc_next
nx_wc_space:
  ST r0,r0,#NX_WIN
nx_wc_next:
  LD r1,r0,#NX_WIDX
  ADD r1,r1,r13
  ST r1,r0,#NX_WIDX
  JMP @nx_wc_byte
nx_wc_done:
  LD r1,r0,#NX_OWN
  CMP r1,r0
  JMP[EQ] @nx_wc_print
  LD r1,r0,#NX_FD
  CALL @nfd_close
nx_wc_print:
  LD r1,r0,#NX_WL
  CALL @nx_dec
  MOVI r1,32
  CALL @nx_putc
  LD r1,r0,#NX_WW
  CALL @nx_dec
  MOVI r1,32
  CALL @nx_putc
  LD r1,r0,#NX_WB
  CALL @nx_dec
  CALL @nx_nl
  JMP @nx_done
nx_wc_bad:
  LA r1,@nx_s_catbad
  CALL @nx_eputs
  MOVI r1,1
  ST r1,r0,#NX_STATUS
  JMP @nx_done

; nx_bg_tail: strip one trailing unquoted '&' from FNB.  r1=1 if found.
nx_bg_tail:
  LA r1,#FNB
  MOVI r2,0
nx_bt_l:
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_bt_end
  MOVI r4,32
  CMP r3,r4
  JMP[EQ] @nx_bt_next
  ADD r2,r1,r0
nx_bt_next:
  ADD r1,r1,r13
  JMP @nx_bt_l
nx_bt_end:
  CMP r2,r0
  JMP[EQ] @nx_bt_no
  LDB r3,r2,0
  MOVI r4,38
  CMP r3,r4
  JMP[NE] @nx_bt_no
  STB r0,r2,0
  MOVI r1,1
  RET
nx_bt_no:
  MOVI r1,0
  RET

; nx_job_ensure: initialize the shell job table once.
nx_job_ensure:
  ST r15,r14,0
  ADDI r14,r14,9
  LD r1,r0,#NX_JOB_READY
  CMP r1,r0
  JMP[NE] @nx_je_d
  LA r1,#NX_JOBTAB
  MOVI r2,#NX_JOBCAP
  CALL @nj_job_init
  CMP r1,r0
  JMP[NE] @nx_je_d
  MOVI r1,1
  ST r1,r0,#NX_JOB_READY
nx_je_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_exec_bg: currently supports `sleep N &` on a real SVC 9 worker.
nx_exec_bg:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#FNB
  LA r2,#NX_CMD
  CALL @nx_next_token
  LA r1,#NX_CMD
  LA r2,@nx_c_sleep
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_bg_unsup
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  CALL @nx_atoi
  ST r1,r0,#NX_BG_TICKS
  CALL @nx_job_ensure
  LA r1,#NX_JOBCTX1
  LA r2,@njs_sleep
  LA r3,#NX_JOBSTK1
  MOVI r4,0x800
  MOVI r5,0
  LA r6,#NX_JOBARENA
  MOVI r7,0x1000
  LA r8,0x80000
  LA r9,0x83000
  LA r10,#NX_JOBFD1
  LA r11,#NX_JOBSCR
  LA r12,0x400
  CALL @nj_ctx_init
  CMP r1,r0
  JMP[EQ] @nx_bg_fail
  LA r1,#NX_JOBCTX1
  LD r2,r0,#NX_BG_TICKS
  ST r2,r1,#NJ_C_TICKS
  LA r1,#NX_JOBTAB
  LA r2,#NX_JOBCTX1
  CALL @nj_job_start
  CMP r1,r0
  JMP[EQ] @nx_bg_fail
  ST r1,r0,#NX_BG_JOB
  LA r1,@nx_s_job
  CALL @nx_puts
  LD r1,r0,#NX_BG_JOB
  CALL @nx_dec
  CALL @nx_nl
  JMP @nx_bg_d
nx_bg_unsup:
  LA r1,@nx_s_bgunsup
  CALL @nx_eputs
  JMP @nx_bg_d
nx_bg_fail:
  LA r1,@nx_s_bgfail
  CALL @nx_eputs
nx_bg_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_jobs: list live job slots as `job ID STATE`.
nx_jobs:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @nx_job_ensure
  MOVI r2,1
  ST r2,r0,#NX_BG_ID
nx_jobs_l:
  LD r2,r0,#NX_BG_ID
  MOVI r3,#NX_JOBCAP
  CMP r2,r3
  JMP[GT] @nx_jobs_d
  LA r1,#NX_JOBTAB
  CALL @nj_job_state
  CMP r1,r0
  JMP[LE] @nx_jobs_n
  ST r1,r0,#NX_BG_TICKS
  LA r1,@nx_s_job
  CALL @nx_puts
  LD r1,r0,#NX_BG_ID
  CALL @nx_dec
  MOVI r1,32
  CALL @nx_putc
  LD r1,r0,#NX_BG_TICKS
  CALL @nx_dec
  CALL @nx_nl
nx_jobs_n:
  LD r2,r0,#NX_BG_ID
  ADD r2,r2,r13
  ST r2,r0,#NX_BG_ID
  JMP @nx_jobs_l
nx_jobs_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_wait: wait and reap every live job as `done ID STATUS`.
nx_wait:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @nx_job_ensure
  MOVI r2,1
  ST r2,r0,#NX_BG_ID
nx_wait_l:
  LD r2,r0,#NX_BG_ID
  MOVI r3,#NX_JOBCAP
  CMP r2,r3
  JMP[GT] @nx_wait_d
  LA r1,#NX_JOBTAB
  CALL @nj_job_state
  CMP r1,r0
  JMP[LE] @nx_wait_n
  ST r1,r0,#NX_BG_TICKS
  MOVI r3,1
  CMP r1,r3
  JMP[NE] @nx_wait_reap
  ; Let a just-spawned worker reach its stage before blocking in SVC 10.
  MOVI r6,64
nx_wait_yield:
  LA r1,#NX_JOBCTX1
  LD r2,r1,#NJ_C_TMP1
  CMP r2,r0
  JMP[NE] @nx_wait_go
  SVC 0
  SUB r6,r6,r13
  CMP r6,r0
  JMP[NE] @nx_wait_yield
nx_wait_go:
  LA r1,#NX_JOBTAB
  LD r2,r0,#NX_BG_ID
  CALL @nj_job_wait
  CMP r1,r0
  JMP[LT] @nx_wait_n
nx_wait_reap:
  LA r1,#NX_JOBTAB
  LD r2,r0,#NX_BG_ID
  CALL @nj_job_reap
  CMP r1,r0
  JMP[LT] @nx_wait_n
  ST r1,r0,#NX_BG_JOB
  LA r1,@nx_s_done
  CALL @nx_puts
  LD r1,r0,#NX_BG_ID
  CALL @nx_dec
  MOVI r1,32
  CALL @nx_putc
  LD r1,r0,#NX_BG_JOB
  CALL @nx_dec
  CALL @nx_nl
nx_wait_n:
  LD r2,r0,#NX_BG_ID
  ADD r2,r2,r13
  ST r2,r0,#NX_BG_ID
  JMP @nx_wait_l
nx_wait_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_head:
  MOVI r1,0
  JMP @nx_filter
nx_tail:
  MOVI r1,1
  JMP @nx_filter
nx_grep:
  MOVI r1,2
  JMP @nx_filter
nx_sort:
  MOVI r1,3
  JMP @nx_filter
nx_uniq:
  MOVI r1,4
  JMP @nx_filter

; nx_filter_path: r1=arg byte -> r1=0 for stdin, else absolute NX_P1.
nx_filter_path:
  ST r15,r14,0
  ADDI r14,r14,9
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_fp_zero
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  JMP @nx_fp_d
nx_fp_zero:
  MOVI r1,0
nx_fp_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nx_filter: head/tail/grep/sort/uniq -> nxc_run.
nx_filter:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_F_CMD
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A2
  CALL @nx_next_arg
  LA r1,#NX_A3
  CALL @nx_next_arg
  LD r5,r0,#NX_F_CMD
  MOVI r6,2
  CMP r5,r6
  JMP[EQ] @nx_f_grep
  MOVI r6,3
  CMP r5,r6
  JMP[GE] @nx_f_list

  ; head/tail
  ST r0,r0,#NX_F_COUNT
  LA r1,#NX_A1
  LA r2,@nx_s_opt_n
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_f_ht_plain
  LA r2,#NX_A2
  ST r2,r0,#NX_F_COUNT
  LA r1,#NX_A3
  JMP @nx_f_path
nx_f_ht_plain:
  LA r3,#NX_A1
  LDB r4,r3,0
  MOVI r5,45
  CMP r4,r5
  JMP[NE] @nx_f_ht_plain2
  LDB r4,r3,1
  MOVI r5,110
  CMP r4,r5
  JMP[NE] @nx_f_ht_plain2
  LDB r4,r3,2
  CMP r4,r0
  JMP[EQ] @nx_f_ht_plain2
  ADDI r2,r3,2
  ST r2,r0,#NX_F_COUNT
  LA r1,#NX_A2
  JMP @nx_f_path
nx_f_ht_plain2:
  LA r1,#NX_A1
nx_f_path:
  CALL @nx_filter_path
  ST r1,r0,#NX_F_PATH
  LD r1,r0,#NX_F_CMD
  LD r2,r0,#NX_F_PATH
  LD r3,r0,#NX_F_COUNT
  MOVI r4,0
  CALL @nxc_run
  JMP @nx_f_done

; nx_f_parse_opt: r1=byte option token; sets NX_F_FLAGS for -v/-n/-vn/-nv.
nx_f_parse_opt:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_F_TMP
  LD r1,r0,#NX_F_TMP
  LA r2,@nx_s_opt_v
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_fpo_n
  MOVI r4,1
  ST r4,r0,#NX_F_FLAGS
  JMP @nx_fpo_d
nx_fpo_n:
  LD r1,r0,#NX_F_TMP
  LA r2,@nx_s_opt_n
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_fpo_vn
  MOVI r4,2
  ST r4,r0,#NX_F_FLAGS
  JMP @nx_fpo_d
nx_fpo_vn:
  LD r1,r0,#NX_F_TMP
  LA r2,@nx_s_opt_vn
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_fpo_nv
  MOVI r4,3
  ST r4,r0,#NX_F_FLAGS
  JMP @nx_fpo_d
nx_fpo_nv:
  LD r1,r0,#NX_F_TMP
  LA r2,@nx_s_opt_nv
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_fpo_d
  MOVI r4,3
  ST r4,r0,#NX_F_FLAGS
nx_fpo_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_f_grep:
  ; default: pattern = A1, no file, no flags
  LA r3,#NX_A1
  ST r3,r0,#NX_F_PAT
  ST r0,r0,#NX_F_FILE
  ST r0,r0,#NX_F_FLAGS
  LDB r4,r3,0
  CMP r4,r0
  JMP[EQ] @nx_f_grep_run
  MOVI r5,45
  CMP r4,r5
  JMP[EQ] @nx_f_g_opt_first
  ; pattern A1, optional option/file in A2
  LA r1,#NX_A2
  LDB r4,r1,0
  CMP r4,r0
  JMP[EQ] @nx_f_grep_run
  MOVI r5,45
  CMP r4,r5
  JMP[EQ] @nx_f_g_opt_second
  JMP @nx_f_g_file
nx_f_g_opt_first:
  LA r1,#NX_A1
  CALL @nx_f_parse_opt
  LA r1,#NX_A2
  ST r1,r0,#NX_F_PAT
  LA r1,#NX_A3
  JMP @nx_f_g_file
nx_f_g_opt_second:
  LA r1,#NX_A2
  CALL @nx_f_parse_opt
  LA r1,#NX_A3
nx_f_g_file:
  CALL @nx_filter_path
  ST r1,r0,#NX_F_FILE
  CMP r1,r0
  JMP[EQ] @nx_f_grep_run
  ADD r1,r1,r0
  MOVI r2,0
  CALL @nfd_open
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_f_bad
  ST r1,r0,#NX_F_FD
  ADD r1,r1,r0
  MOVI r2,0
  CALL @nfd_dup2
  LD r1,r0,#NX_F_FD
  CALL @nfd_close
nx_f_grep_run:
  MOVI r1,2
  LD r2,r0,#NX_F_PAT
  MOVI r3,0
  LD r4,r0,#NX_F_FLAGS
  CALL @nxc_run
  JMP @nx_f_done

nx_f_list:
  ST r0,r0,#NX_F_FLAGS
  LA r1,#NX_A1
  LD r5,r0,#NX_F_CMD
  MOVI r6,4
  CMP r5,r6
  JMP[NE] @nx_f_list_path
  LA r2,@nx_s_opt_c
  CALL @nx_streq
  CMP r1,r0
  JMP[EQ] @nx_f_list_path
  MOVI r4,4
  ST r4,r0,#NX_F_FLAGS
  LA r1,#NX_A2
nx_f_list_path:
  CALL @nx_filter_path
  ST r1,r0,#NX_F_PATH
  LD r1,r0,#NX_F_CMD
  LD r2,r0,#NX_F_PATH
  MOVI r3,0
  LD r4,r0,#NX_F_FLAGS
  CALL @nxc_run
  JMP @nx_f_done

nx_f_bad:
  LA r1,@nx_s_err
  CALL @nx_eputs
nx_f_done:
  JMP @nx_done

nx_stat:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  LA r2,#NX_STAT
  CALL @bare_fs_stat
  CMP r1,r0
  JMP[NE] @nx_cp_bad
  LA r1,#NX_STAT
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_stat_file
  LA r1,@nx_s_dir
  JMP @nx_stat_type
nx_stat_file:
  LA r1,@nx_s_file
nx_stat_type:
  CALL @nx_puts
  LA r1,@nx_s_size
  CALL @nx_puts
  LA r1,#NX_STAT
  LD r1,r1,1
  CALL @nx_dec
  LA r1,@nx_s_mode
  CALL @nx_puts
  LA r1,#NX_STAT
  LD r1,r1,2
  CALL @nx_dec
  CALL @nx_nl
  JMP @nx_done

nx_trunc:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A2
  CALL @nx_next_arg
  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_A2
  CALL @nx_atoi
  ADD r5,r1,r0
  LA r1,#NX_P1
  ADD r2,r5,r0
  CALL @bare_fs_truncate
  CMP r1,r0
  JMP[NE] @nx_cp_bad
  LA r1,@nx_s_ok
  CALL @nx_puts
  JMP @nx_done

nx_sleep:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  CALL @nx_atoi
  SVC 24
  JMP @nx_done

nx_kill:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  CALL @nx_atoi
  MOVI r2,15
  SVC 22
  CALL @nx_dec
  CALL @nx_nl
  JMP @nx_done

; env: print all stored variables as NAME=value in insertion order.
nx_env:
  LA r12,#NX_VG
  ST r0,r12,#NX_VG_ENV_IDX
nx_env_l:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_ENV_IDX
  LD r2,r12,#NX_VG_CNT
  CMP r1,r2
  JMP[GE] @nx_done
  MOVI r3,80
  MUL r4,r1,r3
  LA r5,#NX_VTAB
  ADD r5,r5,r4
  ST r5,r12,#NX_VG_ENT
  ADD r1,r5,r0
  CALL @nx_putb
  MOVI r1,61
  CALL @nx_putc
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_ENT
  ADDI r1,r1,16
  CALL @nx_putb
  CALL @nx_nl
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_ENV_IDX
  ADD r1,r1,r13
  ST r1,r12,#NX_VG_ENV_IDX
  JMP @nx_env_l

; read [NAME] - one blocking fd 0 line; strip the newline, store, EOF -> 1.
nx_read:
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[NE] @nx_read_name
  LA r1,@nx_s_reply
  SHL r1,r1,2
nx_read_name:
  LA r12,#NX_VG
  ST r1,r12,#NX_VG_RD_NAME
  MOVI r1,0
  LA r2,#NX_VVAL
  MOVI r3,63
  CALL @nfd_read
  CMP r1,r0
  JMP[EQ] @nx_read_eof
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_read_eof
  LA r12,#NX_VG
  ST r1,r12,#NX_VG_LEN
  LA r2,#NX_VVAL
  ADD r2,r2,r1
  STB r0,r2,0
  ; strip the first line terminator in the received bytes
  LA r2,#NX_VVAL
  MOVI r4,0
nx_read_lf:
  LA r12,#NX_VG
  LD r5,r12,#NX_VG_LEN
  CMP r4,r5
  JMP[GE] @nx_read_store
  LDB r6,r2,0
  MOVI r7,10
  CMP r6,r7
  JMP[NE] @nx_read_next
  STB r0,r2,0
  JMP @nx_read_store
nx_read_next:
  ADD r2,r2,r13
  ADD r4,r4,r13
  JMP @nx_read_lf
nx_read_store:
  LA r12,#NX_VG
  LD r1,r12,#NX_VG_RD_NAME
  LA r2,#NX_VVAL
  CALL @nx_var_set
  CMP r1,r0
  JMP[NE] @nx_read_eof
  MOVI r1,0
  ST r1,r0,#NX_STATUS
  JMP @nx_done
nx_read_eof:
  MOVI r1,1
  ST r1,r0,#NX_STATUS
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_sync:
  ; Persistence ABI: nfs_save -> r1=0 saved / -1 no ATA or bad store.
  CALL @nfs_save
  CMP r1,r0
  JMP[NE] @nx_sync_err
  LA r1,@nx_s_syncok
  CALL @nx_puts
  MOVI r1,0
  ST r1,r0,#NX_STATUS
  JMP @nx_done
nx_sync_err:
  LA r1,@nx_s_syncerr
  CALL @nx_eputs
  MOVI r1,1
  ST r1,r0,#NX_STATUS
  JMP @nx_done

nx_help:
  LA r1,@nx_s_help
  CALL @nx_puts
  JMP @nx_done

nx_exit:
  MOVI r1,1
  ST r1,r0,@g_quit
  JMP @nx_done

; ---------------------------------------------------------------------------
; asm FILE - assemble a packed .nas file with the in-guest nasm0, then run
; the emitted words under the in-guest n16i.  Guest PUTC goes to fd 1 and
; COM1 through nx_asm_out.
nx_asm:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#NX_A1
  CALL @nx_next_arg
  LA r1,#NX_A1
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_asm_use

  LA r1,#NX_A1
  LA r2,#NX_P1
  CALL @nx_abspath

  ; Source bytes at 0x600000; nasm0 sees the packed words at 0x180000.
  LA r1,#NX_P1
  LA r2,0x600000
  MOVI r3,0x7F00
  CALL @bare_fs_load
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_asm_nf
  ST r1,r0,#NX_LEN
  MOVI r0,0
  MOVI r13,1
  CMP r13,r0
  LA r2,0x600000
  ADD r2,r2,r1
  STB r0,r2,0
  MOVI r0,0
  MOVI r13,1
  CMP r13,r0
  LA r1,0x180000
  ST r1,r0,#V_SRCB
  LA r1,0x190000
  ST r1,r0,#V_OUTB
  LA r1,0x1A0000
  ST r1,r0,#V_LABB
  LA r1,0x1B0000
  ST r1,r0,#V_EXPB
  LA r1,0x1C0000
  ST r1,r0,#V_EXPCB
  ST r0,r0,#V_ERR
  ST r0,r0,#V_MIRR
  ST r0,r0,#V_NLAB

  MOVI r1,1
  ST r1,r0,#V_PASS
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  MOVI r5,0
  MOVI r6,0
  MOVI r7,0
  MOVI r8,0
  MOVI r9,0
  MOVI r10,0
  MOVI r11,0
  MOVI r12,0
  MOVI r0,0
  MOVI r13,1
  CMP r13,r0
  ST r14,r0,#NX_A_SP
  LA r14,0x1D0000
  ST r13,r0,#NX_A_R13
  CALL @run
  LD r14,r0,#NX_A_SP
  LD r13,r0,#NX_A_R13
  MOVI r1,2
  ST r1,r0,#V_PASS
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  MOVI r5,0
  MOVI r6,0
  MOVI r7,0
  MOVI r8,0
  MOVI r9,0
  MOVI r10,0
  MOVI r11,0
  MOVI r12,0
  MOVI r0,0
  MOVI r13,1
  CMP r13,r0
  ST r14,r0,#NX_A_SP
  LA r14,0x1D0000
  ST r13,r0,#NX_A_R13
  CALL @run
  LD r14,r0,#NX_A_SP
  LD r13,r0,#NX_A_R13
  LD r1,r0,#V_ERR
  CMP r1,r0
  JMP[NE] @nx_asm_err

  LA r1,@nx_s_asm_ok
  CALL @nx_puts
  LD r1,r0,#V_IDX
  CALL @nx_dec
  LA r1,@nx_s_words
  CALL @nx_puts
  LA r1,@nx_s_asm_ok_ser
  CALL @nx_asm_ser

  MOVI r1,0
  LA r2,0x190000
  MOVI r3,0xFFFF
  LA r4,@nx_asm_out
  ST r4,r0,@ni_outcb
  ST r14,r0,#NX_A_SP
  LA r14,0x1D0000
  ST r13,r0,#NX_A_R13
  ST r15,r0,#NX_A_R15
  CALL @n16i_run
  ST r0,r0,@ni_outcb
  LD r14,r0,#NX_A_SP
  LD r13,r0,#NX_A_R13
  LD r15,r0,#NX_A_R15
  ST r1,r0,#NX_A_STEPS
  LA r1,@nx_s_ran
  CALL @nx_puts
  LD r1,r0,#NX_A_STEPS
  CALL @nx_dec
  LA r1,@nx_s_steps
  CALL @nx_puts
  JMP @nx_asm_done

nx_asm_err:
  LA r1,@nx_s_asm_err
  CALL @nx_puts
  LD r1,r0,#V_ERR
  CALL @nx_dec
  CALL @nx_nl
  LA r1,@nx_s_asm_err_ser
  CALL @nx_asm_ser
  JMP @nx_asm_done

nx_asm_nf:
  LA r1,@nx_s_asm_nf
  CALL @nx_puts
  LA r1,@nx_s_asm_nf_ser
  CALL @nx_asm_ser
  JMP @nx_asm_done

nx_asm_use:
  LA r1,@nx_s_asm_use
  CALL @nx_puts
nx_asm_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  JMP @nx_done

; n16i PUTC hook: terminal fd 1 plus COM1, preserving r14/r15.
nx_asm_out:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_A_CH
  CALL @nx_putc
  LD r1,r0,#NX_A_CH
  PUTC r1
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; word string -> COM1 bytes
nx_asm_ser:
  SHL r1,r1,2
nx_asm_ser_l:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_asm_ser_d
  PUTC r2
  ADD r1,r1,r13
  JMP @nx_asm_ser_l
nx_asm_ser_d:
  RET

; ---------------------------------------------------------------------------
nx_root_path:
.str "/"
nx_c_cd:
.str "cd"
nx_c_pwd:
.str "pwd"
nx_c_echo:
.str "echo"
nx_c_printf:
.str "printf"
nx_c_true:
.str "true"
nx_c_false:
.str "false"
nx_c_test:
.str "test"
nx_c_cp:
.str "cp"
nx_c_mv:
.str "mv"
nx_c_touch:
.str "touch"
nx_c_rm:
.str "rm"
nx_c_mkdir:
.str "mkdir"
nx_c_rmdir:
.str "rmdir"
nx_c_ls:
.str "ls"
nx_c_cat:
.str "cat"
nx_c_wc:
.str "wc"
nx_c_stat:
.str "stat"
nx_c_trunc:
.str "truncate"
nx_c_sleep:
.str "sleep"
nx_c_kill:
.str "kill"
nx_c_env:
.str "env"
nx_c_read:
.str "read"
nx_c_head:
.str "head"
nx_c_tail:
.str "tail"
nx_c_grep:
.str "grep"
nx_c_sort:
.str "sort"
nx_c_uniq:
.str "uniq"
nx_c_jobs:
.str "jobs"
nx_c_wait:
.str "wait"

nx_s_opt_n:
.str "-n"
nx_s_opt_v:
.str "-v"
nx_s_opt_vn:
.str "-vn"
nx_s_opt_nv:
.str "-nv"
nx_s_opt_c:
.str "-c"
nx_s_job:
.str "job "
nx_s_done:
.str "done "
nx_s_bgunsup:
.str "bg: unsupported\n"
nx_s_bgfail:
.str "bg: spawn failed\n"
nx_c_sync:
.str "sync"
nx_c_help:
.str "help"
nx_c_exit:
.str "exit"
nx_c_asm:
.str "asm"
nx_s_asm_ok:
.str "asm: "
nx_s_words:
.str " words\n"
nx_s_ran:
.str "ran "
nx_s_steps:
.str " steps\n"
nx_s_asm_err:
.str "asm: error "
nx_s_asm_nf:
.str "asm: no file\n"
nx_s_asm_use:
.str "usage: asm FILE\n"
nx_s_asm_ok_ser:
.str "ASM OK\n"
nx_s_asm_err_ser:
.str "ASM ERR\n"
nx_s_asm_nf_ser:
.str "ASM NOFILE\n"

nx_s_e:
.str "-e"
nx_s_f:
.str "-f"
nx_s_d:
.str "-d"
nx_s_z:
.str "-z"
nx_s_n:
.str "-n"
nx_s_eq:
.str "="
nx_s_ne:
.str "!="
nx_s_ok:
.str "ok\n"
nx_s_removed:
.str "removed\n"
nx_s_err:
.str "error\n"
nx_s_cdbad:
.str "cd: no such directory\n"
nx_s_cpuse:
.str "usage: cp SRC DST\n"
nx_s_pipebad:
.str "pipe: cannot create\n"
nx_s_redirbad:
.str "redirect: cannot open\n"
nx_s_catbad:
.str "cat: cannot open\n"
nx_s_syncok:
.str "sync ok\n"
nx_s_syncerr:
.str "sync error\n"
nx_s_dir:
.str "dir"
nx_s_file:
.str "file"
nx_s_size:
.str " size="
nx_s_mode:
.str " mode="
nx_s_pwd:
.str "PWD="
nx_s_home:
.str "HOME=/\n"
nx_s_path:
.str "PATH=/\n"
nx_s_shell:
.str "SHELL=/nixsh\n"
nx_s_pwd_n:
.str "PWD"
nx_s_home_n:
.str "HOME"
nx_s_path_n:
.str "PATH"
nx_s_shell_n:
.str "SHELL"
nx_s_reply:
.str "REPLY"
nx_s_nixsh:
.str "/nixsh"
nx_s_help:
.str "NANIX shell (phase 1.5)\ncd pwd echo printf test true false cp mv touch rm mkdir rmdir ls cat wc stat truncate sleep kill read env sync help exit\nio: > >> < 2> 2>&1 | (sequential)\nvars: NAME=value, $NAME, read [NAME]\nlegacy: write edit cc run debug mem alloc execbig\nasm FILE (nasm0 + n16i in-guest)\n"
