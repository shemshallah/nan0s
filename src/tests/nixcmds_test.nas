; nixcmds_test.nas - standalone S1 gate for src/lib/nixcmds.nas.
;
; A four-entry in-memory NANIX fd shim feeds synthetic inputs to the real
; head/tail/grep/sort/uniq code and captures fd 1/fd 2.  Expected outputs are
; byte-compared; every case prints an exact PASS/FAIL line and the final line
; is "PASS nixcmds" or "FAIL nixcmds".
;
; shim: fd 0 and fd 3 read T_INPTR/T_INPLEN/T_INPOS
;       fd 1 appends to T_OBUF, fd 2 appends to T_EBUF
;       nfd_open always succeeds with fd 3 (the path itself is not inspected)
;
; ABI: r0=0, r13=1, r14=software stack, r15=link.
.org 0
JMP @main
.include "../lib/nixcmds.nas"

.equ T_STACK  0x4000
.equ T_OBUF   0x1400000
.equ T_EBUF   0x1404000
.equ T_BIG    0x1500000

.equ T_INPTR  0x1100
.equ T_INPLEN 0x1101
.equ T_INPOS  0x1102
.equ T_OLEN   0x1103
.equ T_ELEN   0x1104
.equ T_FAILS  0x1105
.equ T_NAME   0x1106
.equ T_EXP    0x1107
.equ T_RC     0x1108
.equ T_EXPTR  0x1109
.equ T_EXPLEN 0x110A
.equ T_TMP    0x110B

; ---------------------------------------------------------------------------
; Minimal NANIX fd shim for the gate.
nfd_open:                                  ; r1=path r2=flags -> fd 3
  MOVI r1,3
  RET

nfd_read:                                  ; r1=fd r2=dst r3=len -> bytes/-1
  ST r15,r14,0
  ADD r14,r14,r13
  CMP r1,r0
  JMP[EQ] @nfr_okfd
  MOVI r4,3
  CMP r1,r4
  JMP[NE] @nfr_bad
nfr_okfd:
  LD r4,r0,#T_INPOS
  LD r5,r0,#T_INPLEN
  CMP r4,r5
  JMP[GE] @nfr_zero
  SUB r5,r5,r4
  CMP r5,r3
  JMP[LE] @nfr_fit
  ADD r5,r3,r0
nfr_fit:
  LD r6,r0,#T_INPTR
  ADD r6,r6,r4
  MOVI r7,0
nfr_loop:
  CMP r7,r5
  JMP[GE] @nfr_done
  LDB r8,r6,0
  STB r8,r2,0
  ADD r6,r6,r13
  ADD r2,r2,r13
  ADD r7,r7,r13
  JMP @nfr_loop
nfr_done:
  ADD r4,r4,r5
  ST r4,r0,#T_INPOS
  ADD r1,r5,r0
  JMP @nfr_d
nfr_zero:
  MOVI r1,0
  JMP @nfr_d
nfr_bad:
  LA r1,0xFFFFFFFF
nfr_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

nfd_write:                                 ; r1=fd r2=src r3=len -> bytes/-1
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r4,1
  CMP r1,r4
  JMP[EQ] @nfw_out
  MOVI r4,2
  CMP r1,r4
  JMP[EQ] @nfw_err
  JMP @nfw_bad
nfw_out:
  LA r5,#T_OBUF
  LA r6,#T_OLEN
  JMP @nfw_go
nfw_err:
  LA r5,#T_EBUF
  LA r6,#T_ELEN
nfw_go:
  LD r7,r6,0
  ADD r8,r5,r7
  MOVI r9,0
nfw_loop:
  CMP r9,r3
  JMP[GE] @nfw_done
  LDB r10,r2,0
  STB r10,r8,0
  ADD r2,r2,r13
  ADD r8,r8,r13
  ADD r9,r9,r13
  JMP @nfw_loop
nfw_done:
  ADD r7,r7,r9
  ST r7,r6,0
  ADD r1,r9,r0
  JMP @nfw_d
nfw_bad:
  LA r1,0xFFFFFFFF
nfw_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

nfd_close:                                 ; r1=fd -> 0
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; Test helpers.
t_input:                                   ; r1=input ptr r2=len
  ST r1,r0,#T_INPTR
  ST r2,r0,#T_INPLEN
  ST r0,r0,#T_INPOS
  ST r0,r0,#T_OLEN
  ST r0,r0,#T_ELEN
  RET

t_run:                                     ; r1=cmd r2=arg1 r3=arg2 r4=flags
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @nxc_run
  ST r1,r0,#T_RC
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

t_puts:                                    ; r1=word string label
  ST r15,r14,0
  ADDI r14,r14,9
  SHL r1,r1,2
t_ps_loop:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @t_ps_done
  PUTC r2
  ADD r1,r1,r13
  JMP @t_ps_loop
t_ps_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

t_putn:                                    ; r1=byte ptr r2=len
  MOVI r3,0
t_pn_loop:
  CMP r3,r2
  JMP[GE] @t_pn_done
  LDB r4,r1,0
  PUTC r4
  ADD r1,r1,r13
  ADD r3,r3,r13
  JMP @t_pn_loop
t_pn_done:
  RET

t_okline:                                  ; r1=name word label
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#T_NAME
  MOVI r2,80
  PUTC r2
  MOVI r2,65
  PUTC r2
  MOVI r2,83
  PUTC r2
  MOVI r2,83
  PUTC r2
  MOVI r2,32
  PUTC r2
  LD r1,r0,#T_NAME
  CALL @t_puts
  MOVI r2,10
  PUTC r2
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

t_failline:                                ; r1=name word label
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#T_NAME
  LD r1,r0,#T_FAILS
  ADD r1,r1,r13
  ST r1,r0,#T_FAILS
  MOVI r2,70
  PUTC r2
  MOVI r2,65
  PUTC r2
  MOVI r2,73
  PUTC r2
  MOVI r2,76
  PUTC r2
  MOVI r2,32
  PUTC r2
  LD r1,r0,#T_NAME
  CALL @t_puts
  MOVI r2,10
  PUTC r2
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

t_check:                                   ; r1=name word label r2=expected word label
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#T_NAME
  SHL r2,r2,2
  ST r2,r0,#T_EXPTR
  ADD r1,r2,r0
  CALL @nxc_strlen
  ST r1,r0,#T_EXPLEN
  LD r3,r0,#T_RC
  CMP r3,r0
  JMP[NE] @t_chk_fail
  LD r4,r0,#T_OLEN
  CMP r1,r4
  JMP[NE] @t_chk_fail
  LD r5,r0,#T_EXPTR
  LA r6,#T_OBUF
  MOVI r7,0
t_chk_loop:
  CMP r7,r1
  JMP[GE] @t_chk_pass
  ADD r8,r5,r7
  LDB r9,r8,0
  ADD r8,r6,r7
  LDB r10,r8,0
  CMP r9,r10
  JMP[NE] @t_chk_fail
  ADD r7,r7,r13
  JMP @t_chk_loop
t_chk_pass:
  LD r1,r0,#T_NAME
  CALL @t_okline
  JMP @t_chk_done
t_chk_fail:
  LD r1,r0,#T_NAME
  CALL @t_failline
  ; diagnostic detail: got bytes then expected bytes
  MOVI r2,32
  PUTC r2
  MOVI r2,32
  PUTC r2
  MOVI r2,103
  PUTC r2
  MOVI r2,111
  PUTC r2
  MOVI r2,116
  PUTC r2
  MOVI r2,58
  PUTC r2
  MOVI r2,32
  PUTC r2
  LA r1,#T_OBUF
  LD r2,r0,#T_OLEN
  CALL @t_putn
  MOVI r2,10
  PUTC r2
  MOVI r2,32
  PUTC r2
  MOVI r2,32
  PUTC r2
  MOVI r2,119
  PUTC r2
  MOVI r2,97
  PUTC r2
  MOVI r2,110
  PUTC r2
  MOVI r2,116
  PUTC r2
  MOVI r2,58
  PUTC r2
  MOVI r2,32
  PUTC r2
  LD r1,r0,#T_EXPTR
  LD r2,r0,#T_EXPLEN
  CALL @t_putn
  MOVI r2,10
  PUTC r2
t_chk_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
main:
  MOVI r13,1
  LA r14,#T_STACK
  MOVI r0,0

  ; ---- head default (first 10 of 12) ----
  LA r1,@t_data_a
  SHL r1,r1,2
  MOVI r2,48
  CALL @t_input
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_head_def
  LA r2,@t_exp_head_def
  CALL @t_check

  ; ---- head -n 2 from a named "file" (fd 3) ----
  LA r1,@t_data_a
  SHL r1,r1,2
  MOVI r2,48
  CALL @t_input
  LA r2,@t_path_a
  SHL r2,r2,2
  LA r3,@t_arg_n2
  SHL r3,r3,2
  MOVI r1,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_head_n2
  LA r2,@t_exp_head_n2
  CALL @t_check

  ; ---- head -n 0 ----
  LA r1,@t_data_a
  SHL r1,r1,2
  MOVI r2,48
  CALL @t_input
  LA r3,@t_arg_n0
  SHL r3,r3,2
  MOVI r1,0
  MOVI r2,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_head_n0
  LA r2,@t_exp_empty
  CALL @t_check

  ; ---- tail default (last 10 of 12) ----
  LA r1,@t_data_a
  SHL r1,r1,2
  MOVI r2,48
  CALL @t_input
  MOVI r1,1
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_tail_def
  LA r2,@t_exp_tail_def
  CALL @t_check

  ; ---- tail -n 3 ----
  LA r1,@t_data_a
  SHL r1,r1,2
  MOVI r2,48
  CALL @t_input
  LA r3,@t_arg_n3
  SHL r3,r3,2
  MOVI r1,1
  MOVI r2,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_tail_n3
  LA r2,@t_exp_tail_n3
  CALL @t_check

  ; ---- tail with empty input ----
  LA r1,@t_data_empty
  SHL r1,r1,2
  MOVI r2,0
  CALL @t_input
  MOVI r1,1
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_tail_empty
  LA r2,@t_exp_empty
  CALL @t_check

  ; ---- grep fixed string ----
  LA r1,@t_data_b
  SHL r1,r1,2
  MOVI r2,32
  CALL @t_input
  MOVI r1,2
  LA r2,@t_pat_apple
  SHL r2,r2,2
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_grep
  LA r2,@t_exp_grep
  CALL @t_check

  ; ---- grep -v -n ----
  LA r1,@t_data_b
  SHL r1,r1,2
  MOVI r2,32
  CALL @t_input
  MOVI r1,2
  LA r2,@t_pat_apple
  SHL r2,r2,2
  MOVI r3,0
  MOVI r4,3
  CALL @t_run
  LA r1,@t_name_grep_vn
  LA r2,@t_exp_grep_vn
  CALL @t_check

  ; ---- grep with an empty pattern matches every line ----
  LA r1,@t_data_b
  SHL r1,r1,2
  MOVI r2,32
  CALL @t_input
  MOVI r1,2
  LA r2,@t_pat_empty
  SHL r2,r2,2
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_grep_empty
  LA r2,@t_exp_data_b
  CALL @t_check

  ; ---- sort ----
  LA r1,@t_data_b
  SHL r1,r1,2
  MOVI r2,32
  CALL @t_input
  MOVI r1,3
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_sort
  LA r2,@t_exp_sort
  CALL @t_check

  ; ---- uniq ----
  LA r1,@t_data_b
  SHL r1,r1,2
  MOVI r2,32
  CALL @t_input
  MOVI r1,4
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LA r1,@t_name_uniq
  LA r2,@t_exp_uniq
  CALL @t_check

  ; ---- uniq -c ----
  LA r1,@t_data_b
  SHL r1,r1,2
  MOVI r2,32
  CALL @t_input
  MOVI r1,4
  MOVI r2,0
  MOVI r3,0
  MOVI r4,4
  CALL @t_run
  LA r1,@t_name_uniq_c
  LA r2,@t_exp_uniq_c
  CALL @t_check

  ; ---- sort must reject input above 32768 bytes before writing ----
  LA r5,#T_BIG
  MOVI r6,0x8001
  MOVI r7,97
t_big_fill:
  CMP r6,r0
  JMP[EQ] @t_big_ready
  STB r7,r5,0
  ADD r5,r5,r13
  SUB r6,r6,r13
  JMP @t_big_fill
t_big_ready:
  LA r1,#T_BIG
  MOVI r2,0x8001
  CALL @t_input
  MOVI r1,3
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  CALL @t_run
  LD r2,r0,#T_RC
  LA r3,0xFFFFFFFF
  CMP r2,r3
  JMP[NE] @t_big_fail
  LD r2,r0,#T_ELEN
  CMP r2,r0
  JMP[EQ] @t_big_fail
  LA r1,@t_name_bound
  CALL @t_okline
  JMP @t_big_done
t_big_fail:
  LA r1,@t_name_bound
  CALL @t_failline
t_big_done:

  ; ---- final summary ----
  LD r1,r0,#T_FAILS
  CMP r1,r0
  JMP[NE] @t_final_fail
  LA r1,@t_name_all
  CALL @t_okline
  HALT
t_final_fail:
  LA r1,@t_name_all
  CALL @t_failline
  HALT

; ---------------------------------------------------------------------------
; Test data and expected output.
t_data_a:
.str "l01\nl02\nl03\nl04\nl05\nl06\nl07\nl08\nl09\nl10\nl11\nl12\n"
t_data_b:
.str "cherry\napple\napple\nbanana\napple\n"
t_data_empty:
.str ""

t_path_a:
.str "data"
t_arg_n2:
.str "-n 2"
t_arg_n3:
.str "-n3"
t_arg_n0:
.str "0"
t_pat_apple:
.str "apple"
t_pat_empty:
.str ""

t_exp_head_def:
.str "l01\nl02\nl03\nl04\nl05\nl06\nl07\nl08\nl09\nl10\n"
t_exp_head_n2:
.str "l01\nl02\n"
t_exp_tail_def:
.str "l03\nl04\nl05\nl06\nl07\nl08\nl09\nl10\nl11\nl12\n"
t_exp_tail_n3:
.str "l10\nl11\nl12\n"
t_exp_empty:
.str ""
t_exp_data_b:
.str "cherry\napple\napple\nbanana\napple\n"
t_exp_grep:
.str "apple\napple\napple\n"
t_exp_grep_vn:
.str "1:cherry\n4:banana\n"
t_exp_sort:
.str "apple\napple\napple\nbanana\ncherry\n"
t_exp_uniq:
.str "cherry\napple\nbanana\napple\n"
t_exp_uniq_c:
.str "1 cherry\n2 apple\n1 banana\n1 apple\n"

t_name_head_def:
.str "head default"
t_name_head_n2:
.str "head -n 2 file"
t_name_head_n0:
.str "head -n 0"
t_name_tail_def:
.str "tail default"
t_name_tail_n3:
.str "tail -n 3"
t_name_tail_empty:
.str "tail empty"
t_name_grep:
.str "grep fixed"
t_name_grep_vn:
.str "grep -v -n"
t_name_grep_empty:
.str "grep empty"
t_name_sort:
.str "sort"
t_name_uniq:
.str "uniq"
t_name_uniq_c:
.str "uniq -c"
t_name_bound:
.str "sort too-large"
t_name_all:
.str "nixcmds"
