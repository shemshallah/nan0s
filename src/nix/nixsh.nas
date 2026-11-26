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
; Phase 1: cwd, argv tokenisation, builtins and core file commands.  Pipes,
; redirection, variables and job control are the next slice.
;
; ABI: r0=0, r13=1, r14=stack (grows up), r15=link.

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
.equ NX_BUF     0x1000000            ; 0x8000 bytes
.equ NX_P1      0x1010000
.equ NX_P2      0x1010100
.equ NX_CWD     0x1010200
.equ NX_CMD     0x1010300
.equ NX_A1      0x1010400
.equ NX_A2      0x1010500
.equ NX_A3      0x1010600
.equ NX_NAME    0x1010700
.equ NX_FMT     0x1010800

; ---------------------------------------------------------------------------
nx_main:
  MOVI r13,1
  LA r14,#NX_STACK
  LA r1,@nx_root_path
  SHL r1,r1,2
  LA r2,#NX_CWD
  CALL @nx_copy
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
; nx_run - parse FNB and dispatch one line.
nx_run:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#FNB
  LA r2,#NX_CMD
  CALL @nx_next_token
  ST r1,r0,#NX_SCAN
  LA r1,#NX_CMD
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_done

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
  LA r2,@nx_c_env
  CALL @nx_streq
  CMP r1,r0
  JMP[NE] @nx_env
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

  ; Everything not ported yet keeps the existing GUI/NANIX command handler.
  CALL @fs_dispatch
nx_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Byte/string helpers.
nx_putc:                                  ; r1=char
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  LD r1,r0,@tk_id
  LD r2,r14,1
  CALL @vc_putc
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_puts:                                  ; r1=word string
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  LD r1,r0,@tk_id
  LD r2,r14,1
  CALL @vc_puts
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

nx_putb:                                  ; r1=byte string
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NX_PTR
nx_pb_l:
  LD r1,r0,#NX_PTR
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @nx_pb_d
  ADD r1,r1,r13
  ST r1,r0,#NX_PTR
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

nx_dec:                                   ; r1=value
  ST r15,r14,0
  ADDI r14,r14,9
  ADD r5,r1,r0
  CALL @fs_putdec
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

; nx_next_token r1=scan byte, r2=dest byte -> r1=scan after token.
nx_next_token:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
nx_nt_skip:
  LD r1,r14,1
  LDB r3,r1,0
  MOVI r4,32
  CMP r3,r4
  JMP[NE] @nx_nt_start
  ADD r1,r1,r13
  ST r1,r14,1
  JMP @nx_nt_skip
nx_nt_start:
  CMP r3,r0
  JMP[NE] @nx_nt_copy
  STB r0,r2,0
  JMP @nx_nt_d
nx_nt_copy:
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r14,1
  ADD r2,r2,r13
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nx_nt_end
  MOVI r4,32
  CMP r3,r4
  JMP[EQ] @nx_nt_end
  JMP @nx_nt_copy
nx_nt_end:
  STB r0,r2,0
nx_nt_d:
  LD r1,r14,1
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

; nx_abspath r1=arg byte, r2=dest byte -> r1=dest byte.
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
  JMP @nx_done
nx_cd_bad:
  LA r1,@nx_s_cdbad
  CALL @nx_puts
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
  CALL @nx_puts
  JMP @nx_done
nx_cp_bad:
  LA r1,@nx_s_err
  CALL @nx_puts
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
  LA r2,#NX_P1
  CALL @nx_abspath
  LA r1,#NX_P1
  LA r2,#NX_BUF
  MOVI r3,0x8000
  CALL @bare_fs_load
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nx_cp_bad
  ST r1,r0,#NX_LEN
  MOVI r1,0
  ST r1,r0,#NX_IDX
nx_cat_l:
  LD r1,r0,#NX_IDX
  LD r2,r0,#NX_LEN
  CMP r1,r2
  JMP[GE] @nx_cat_d
  LA r3,#NX_BUF
  ADD r3,r3,r1
  LDB r4,r3,0
  ADD r1,r4,r0
  CALL @nx_putc
  LD r1,r0,#NX_IDX
  ADD r1,r1,r13
  ST r1,r0,#NX_IDX
  JMP @nx_cat_l
nx_cat_d:
  CALL @nx_nl
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

nx_env:
  LA r1,@nx_s_pwd
  CALL @nx_puts
  LA r1,#NX_CWD
  CALL @nx_putb
  CALL @nx_nl
  LA r1,@nx_s_home
  CALL @nx_puts
  LA r1,@nx_s_path
  CALL @nx_puts
  LA r1,@nx_s_shell
  CALL @nx_puts
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
nx_c_help:
.str "help"
nx_c_exit:
.str "exit"

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
nx_s_help:
.str "NANIX shell (phase 1)\ncd pwd echo printf test true false cp mv touch rm mkdir rmdir ls cat stat truncate sleep kill env help exit\nlegacy: write edit cc run debug mem alloc execbig\n"
