; core.nas - reusable full NaN16 step core for NANDBG. Written entirely in NaN16.
;
; This is the engine, not the proof. It executes one target instruction per
; nd_step(), returns a status word, and converts gate/bad-op traps into typed
; records instead of halting the machine. The target is never modified.
;
; API:
;   nd_reset                 clear target registers/pc/flags/steps/shadow stack
;   nd_step                  execute one instruction; r1 = status
;   nd_run(max)              execute up to max more instructions; r1 = status
;   nd_emit / nd_rec_print   8-word typed diagnostic record (NDR)
;
; status: 0 OK, 1 HALT, 2 BREAK, 3 FAULT, 4 BUDGET, 5 WAIT_KEY
; cells: nd_gb (word base), nd_mask, nd_pc, nd_k, nd_brk
;        nd_regs[16], nd_steps, nd_rec[8]
;
; Register map while running (same as n16i): r10=GB, r11=guest k, r12=guest pc,
; r13=1. Per step: r2=class n, r3=payload, r4=op/result, r5=d, r6=a, r7=imm,
; r8=A, r9=B. Guest registers live at @nd_regs.
;
; Host use: MUL/DIVU/FP/vector ops are the host's own NaN16 instructions. The
; step core is a guest; it does not add native code. Vector state is kept in
; nd_vreg and the host vector file is used as a scratch execution unit.
;
; I/O policy: PUTC passes through; KEY returns WAIT_KEY and rewinds instead of
; blocking; TICK is deterministic (steps/1000). DISP/FB/ports pass through in
; this revision; the mediator stage buffers them.

; =============================================================================
; type helpers
; =============================================================================
nd_quiet:
  MOVI r2,10
  BOOL.14 r1,r1,r2
  RET

nd_raise:
  MOVI r2,5
  BOOL.8 r1,r1,r2
  RET

nd_sev:
  SHR r1,r1,2
  RET

nd_dom:
  MOVI r2,3
  BOOL.8 r1,r1,r2
  RET

; nd_type_letters: r1 = type. Prints severity/domain tag to COM1.
nd_type_letters:
  ST r15,r0,@nd_tllnk
  ST r1,r0,@nd_tln
  CALL @nd_sev
  MOVI r2,@nd_sev_ch
  ADD r1,r1,r2
  LD r1,r1,0
  PUTC r1
  LD r1,r0,@nd_tln
  CALL @nd_dom
  MOVI r2,@nd_dom_ch
  ADD r1,r1,r2
  LD r1,r1,0
  PUTC r1
  LD r15,r0,@nd_tllnk
  RET
nd_tllnk:
.word 0
nd_tln:
.word 0
nd_sev_ch:
.word 70,80,87,73
nd_dom_ch:
.word 67,77,68,83

; nd_puthex: r1=value r2=digits -> COM1
nd_puthex:
  ST r15,r0,@nd_phlnk
  ST r1,r0,@nd_phv
  ST r2,r0,@nd_phn
  CMP r2,r0
  JMP[EQ] @nd_phend
  MOVI r3,1
  SUB r3,r2,r3
  MOVI r4,@nd_phpow
  ADD r4,r4,r3
  LD r4,r4,0
  MUL r1,r1,r4
  ST r1,r0,@nd_phv
nd_phloop:
  LD r2,r0,@nd_phn
  CMP r2,r0
  JMP[EQ] @nd_phend
  LD r1,r0,@nd_phv
  SHR r3,r1,28
  SHL r1,r1,4
  ST r1,r0,@nd_phv
  MOVI r4,48
  ADD r4,r4,r3
  MOVI r5,10
  CMP r3,r5
  MOVI r6,7
  ADD[GE] r4,r4,r6
  PUTC r4
  LD r2,r0,@nd_phn
  SUB r2,r2,r13
  ST r2,r0,@nd_phn
  JMP @nd_phloop
nd_phend:
  LD r15,r0,@nd_phlnk
  RET
nd_phlnk:
.word 0
nd_phv:
.word 0
nd_phn:
.word 0
nd_phpow:
.word 268435456,16777216,1048576,65536,4096,256,16,1

nd_puts:
  ST r15,r0,@nd_pslnk
  ST r1,r0,@nd_psa
nd_psw:
  LD r1,r0,@nd_psa
  LD r2,r1,0
  MOVI r3,4
nd_psc:
  MOVI r4,255
  BOOL.8 r5,r2,r4
  CMP r5,r0
  JMP[EQ] @nd_psend
  PUTC r5
  SHR r2,r2,8
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nd_psc
  LD r1,r0,@nd_psa
  ADD r1,r1,r13
  ST r1,r0,@nd_psa
  JMP @nd_psw
nd_psend:
  LD r15,r0,@nd_pslnk
  RET
nd_pslnk:
.word 0
nd_psa:
.word 0

; =============================================================================
; typed record (header, site, payload, class)
; =============================================================================
nd_emit:
  ST r15,r0,@nd_nelnk
  ST r1,r0,@nd_nen
  ST r2,r0,@nd_necode
  ST r3,r0,@nd_nesite
  ST r4,r0,@nd_nelo
  ST r5,r0,@nd_nehi
  LD r6,r0,@nd_necode
  SHL r6,r6,24
  LD r7,r0,@nd_seq
  LA r8,0xFFFFFF
  BOOL.8 r7,r7,r8
  BOOL.14 r6,r6,r7
  MOVI r9,@nd_rec
  LD r1,r0,@nd_nen
  STW r6,r9,r1
  ; count this type for the live matrix
  LA r6,@nd_counts
  ADD r6,r6,r1
  LD r7,r6,0
  ADD r7,r7,r13
  ST r7,r6,0
  LD r6,r0,@nd_nesite
  BOOL.8 r6,r6,r8
  MOVI r9,@nd_rec
  ADD r9,r9,r13
  STW r6,r9,r1
  MOVI r9,@nd_rec
  MOVI r8,2
  ADD r9,r9,r8
  MOVI r1,10
  LD r6,r0,@nd_nelo
  STW r6,r9,r1
  ADD r9,r9,r13
  LD r6,r0,@nd_nehi
  STW r6,r9,r1
  ; complete w4-w7, then append the 8-word NDR to the log ring
  CALL @nd_ndr_finish
  LD r6,r0,@nd_li
  SHL r7,r6,3
  LA r8,0x31000
  ADD r7,r7,r8
  MOVI r8,@nd_rec
  MOVI r5,8
nd_logcp:
  LDN r9,r8,0
  LD r1,r8,0
  STW r1,r7,r9
  ADDI r8,r8,1
  ADDI r7,r7,1
  SUB r5,r5,r13
  CMP r5,r0
  JMP[NE] @nd_logcp
  ; twin block: same words, then BSWAPM each mirror word in place
  SHL r7,r6,3
  LA r4,0x31100
  ADD r7,r7,r4
  MOVI r8,@nd_rec
  MOVI r5,8
nd_logm:
  LDN r9,r8,0
  LD r1,r8,0
  STW r1,r7,r9
  BSWAPM r7,0
  ADDI r8,r8,1
  ADDI r7,r7,1
  SUB r5,r5,r13
  CMP r5,r0
  JMP[NE] @nd_logm
  ADD r6,r6,r13
  MOVI r7,15
  BOOL.8 r6,r6,r7
  ST r6,r0,@nd_li
  LD r6,r0,@nd_seq
  ADD r6,r6,r13
  ST r6,r0,@nd_seq
  LD r15,r0,@nd_nelnk
  RET
nd_nelnk:
.word 0
nd_nen:
.word 0
nd_necode:
.word 0
nd_nesite:
.word 0
nd_nelo:
.word 0
nd_nehi:
.word 0

nd_rec_print:
  ST r15,r0,@nd_prlnk
  MOVI r1,33
  PUTC r1
  MOVI r1,68
  PUTC r1
  MOVI r1,@nd_rec
  LDN r1,r1,0
  CALL @nd_type_letters
  MOVI r1,64
  PUTC r1
  LD r1,r0,@nd_rec
  SHR r1,r1,24
  MOVI r2,2
  CALL @nd_puthex
  MOVI r1,@nd_rec
  ADD r1,r1,r13
  LD r1,r1,0
  LA r2,0xFFFFFF
  BOOL.8 r1,r1,r2
  MOVI r2,6
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  MOVI r1,87
  PUTC r1
  MOVI r1,61
  PUTC r1
  MOVI r1,@nd_rec
  MOVI r2,3
  ADD r1,r1,r2
  LD r1,r1,0
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,@nd_rec
  MOVI r2,2
  ADD r1,r1,r2
  LD r1,r1,0
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  LD r15,r0,@nd_prlnk
  RET
nd_prlnk:
.word 0

; =============================================================================
; reset and run
; =============================================================================
nd_reset:
  MOVI r1,0
  MOVI r2,0
nd_rl:
  ST r0,r2,@nd_regs
  ADD r2,r2,r13
  MOVI r3,16
  CMP r2,r3
  JMP[LT] @nd_rl
  MOVI r1,1
  MOVI r2,13
  ST r1,r2,@nd_regs
  ST r0,r0,@nd_pc
  ST r0,r0,@nd_k
  ST r0,r0,@nd_steps
  ST r0,r0,@nd_status
  ST r0,r0,@nd_reason
  ST r0,r0,@nd_seq
  ST r0,r0,@nd_cd
  ST r0,r0,@nd_hi
  ST r0,r0,@nd_urec
  ST r0,r0,@nd_ui
  ST r0,r0,@nd_ud
  LA r1,0x32000
  MOVI r2,0
  MOVI r3,4096
  BFILL r1,r2,r3
  RET

nd_run:
  ST r15,r0,@nd_rnlnk
  LD r2,r0,@nd_steps
  ADD r2,r2,r1
  ST r2,r0,@nd_rlimit
nd_rnloop:
  LD r1,r0,@nd_steps
  LD r2,r0,@nd_rlimit
  CMP r1,r2
  JMP[GE] @nd_rnbudget
  LD r1,r0,@nd_pc
  LD r2,r0,@nd_brk
  CMP r1,r2
  JMP[EQ] @nd_rnbreak
  LD r3,r0,@nd_bpn
  MOVI r4,0
nd_bpscan:
  CMP r4,r3
  JMP[GE] @nd_bpdone
  LD r5,r4,@nd_bpt
  CMP r1,r5
  JMP[EQ] @nd_rnbreak
  ADD r4,r4,r13
  JMP @nd_bpscan
nd_bpdone:
  CALL @nd_step
  LD r2,r0,@nd_status
  CMP r2,r0
  JMP[EQ] @nd_rnloop
  ADD r1,r2,r0
  LD r15,r0,@nd_rnlnk
  RET
nd_rnbreak:
  ; log the breakpoint as an INFO/CORE record
  LD r1,r0,@nd_pc
  CALL @nd_addr
  ST r1,r0,@nd_waddr
  LD r4,r1,0
  LDN r5,r1,0
  MOVI r1,12
  MOVI r2,2
  LD r3,r0,@nd_pc
  CALL @nd_emit
  CALL @nd_rec_print
  MOVI r1,2
  ST r1,r0,@nd_status
  MOVI r1,2
  ST r1,r0,@nd_reason
  MOVI r1,2
  LD r15,r0,@nd_rnlnk
  RET
nd_rnbudget:
  MOVI r1,4
  ST r1,r0,@nd_status
  MOVI r1,4
  LD r15,r0,@nd_rnlnk
  RET
nd_rnlnk:
.word 0
nd_rlimit:
.word 0

; =============================================================================
; one step
; =============================================================================
nd_step:
  ST r15,r0,@nd_lnk
  MOVI r5,0
  ST r5,r0,@nd_reason
  MOVI r5,1
  ST r5,r0,@nd_left
  LD r10,r0,@nd_gb
  LD r11,r0,@nd_k
  LD r12,r0,@nd_pc
  MOVI r13,1
  CALL @nd_usave
; ---- fetch / gate / predicate / decode ---------------------------------------
nd_loop:
  LD r5,r0,@nd_left
  CMP r5,r0
  JMP[EQ] @nd_exit_ok
  SUB r5,r5,r13
  ST r5,r0,@nd_left
  ST r12,r0,@nd_at
  LD r5,r0,@nd_hi
  LA r6,0x32000
  ADD r6,r6,r5
  ST r12,r6,0
  ADD r5,r5,r13
  MOVI r6,4095
  BOOL.8 r5,r5,r6
  ST r5,r0,@nd_hi
  ADD r1,r12,r0
  CALL @nd_addr
  ST r1,r0,@nd_waddr
  ADD r12,r12,r13
  MOVI r4,65535
  BOOL.8 r12,r12,r4
  LD r4,r0,@nd_steps
  ADD r4,r4,r13
  ST r4,r0,@nd_steps
  LDN r2,r1,0
  ST r2,r0,@nd_curn
  LD r3,r1,0
  ST r3,r0,@nd_raw
  MOVI r4,16
  CMP r2,r4
  JMP[GE] @nd_trapg
  SHR r4,r3,24
  MOVI r5,255
  CMP r4,r5
  JMP[EQ] @nd_halt
  MOVI r5,0x61
  CMP r4,r5
  JMP[GT] @nd_trapo
  CMP r4,r0
  JMP[EQ] @nd_dec
  LD r5,r11,@nd_bit
  BOOL.8 r5,r5,r2
  CMP r5,r0
  JMP[EQ] @nd_loop
nd_dec:
  SHR r5,r3,20
  MOVI r6,15
  BOOL.8 r5,r5,r6
  SHR r6,r3,16
  MOVI r7,15
  BOOL.8 r6,r6,r7
  MOVI r7,65535
  BOOL.8 r7,r3,r7
  MOVI r8,15
  BOOL.8 r9,r7,r8
  LD r8,r6,@nd_regs
  LD r9,r9,@nd_regs
  LD r14,r4,@nd_optab
  JMPR r14
; ---- common tails ------------------------------------------------------------
nd_t_st:
  ST r4,r5,@nd_regs
  JMP @nd_loop
nd_t_fk:
  MOVI[GT] r11,0
  MOVI[LT] r11,1
  MOVI[EQ] r11,2
  MOVI.8 r11,3
  JMP @nd_loop
nd_t_stf:
  MOVI[GT] r11,0
  MOVI[LT] r11,1
  MOVI[EQ] r11,2
  MOVI.8 r11,3
  ST r4,r5,@nd_regs
  JMP @nd_loop
; ---- halt, exits, and traps -------------------------------------------------
nd_halt:
  JMP @nd_exit_halt

nd_exit_ok:
  ST r11,r0,@nd_k
  ST r12,r0,@nd_pc
  MOVI r1,0
  ST r1,r0,@nd_status
  LD r15,r0,@nd_lnk
  RET

nd_exit_halt:
  ST r11,r0,@nd_k
  ST r12,r0,@nd_pc
  MOVI r1,1
  ST r1,r0,@nd_status
  MOVI r1,0
  ST r1,r0,@nd_reason
  LD r15,r0,@nd_lnk
  RET

; KEY with an empty ring does not block the debugger. Rewind the pc so the
; instruction is re-executed when a key is available; nd_run returns WAIT_KEY.
nd_exit_wait:
  LD r1,r0,@nd_at
  ST r1,r0,@nd_pc
  MOVI r1,5
  ST r1,r0,@nd_status
  LD r15,r0,@nd_lnk
  RET

nd_exit_fault:
  ST r11,r0,@nd_k
  ST r12,r0,@nd_pc
  MOVI r1,3
  ST r1,r0,@nd_status
  LD r15,r0,@nd_lnk
  RET

nd_exit_break:
  ST r11,r0,@nd_k
  ST r12,r0,@nd_pc
  MOVI r1,2
  ST r1,r0,@nd_status
  MOVI r1,3
  ST r1,r0,@nd_reason
  LD r15,r0,@nd_lnk
  RET

nd_trapg:
  MOVI r1,0
  MOVI r2,0x10
  ADD r3,r12,r0
  LD r4,r0,@nd_raw
  LD r5,r0,@nd_curn
  CALL @nd_emit
  CALL @nd_rec_print
  JMP @nd_exit_fault

nd_trapo:
  MOVI r1,0
  MOVI r2,0x20
  ADD r3,r12,r0
  LD r4,r0,@nd_raw
  LD r5,r0,@nd_curn
  CALL @nd_emit
  CALL @nd_rec_print
  JMP @nd_exit_fault

nd_h_bad:
  MOVI r1,0
  MOVI r2,0x21
  ADD r3,r12,r0
  LD r4,r0,@nd_raw
  LD r5,r0,@nd_curn
  CALL @nd_emit
  CALL @nd_rec_print
  JMP @nd_exit_fault

nd_h_hostext:
  MOVI r1,0
  MOVI r2,0x22
  ADD r3,r12,r0
  LD r4,r0,@nd_raw
  LD r5,r0,@nd_curn
  CALL @nd_emit
  CALL @nd_rec_print
  JMP @nd_exit_fault
; ---- address map: guest word address -> host word address -------------------
nd_addr:
  LD r2,r0,@nd_map_lo
  LD r3,r0,@nd_map_hi
  CMP r2,r3
  JMP[GE] @nd_addr_plain
  CMP r1,r2
  JMP[LT] @nd_addr_plain
  CMP r1,r3
  JMP[GE] @nd_addr_plain
  SUB r1,r1,r2
  LD r2,r0,@nd_map_dst
  ADD r1,r1,r2
  RET
nd_addr_plain:
  LD r2,r0,@nd_mask
  BOOL.8 r1,r1,r2
  LD r2,r0,@nd_gb
  ADD r1,r1,r2
  RET
; ---- address helper: r14 = host word addr of guest (r8+r7) ---------------------
nd_ea:
  ST r15,r0,@nd_ealnk
  ADD r1,r8,r7
  CALL @nd_addr
  ADD r14,r1,r0
  LD r15,r0,@nd_ealnk
  RET
nd_ealnk:
.word 0
; r14 = host word addr of guest address in r8 (no offset)
nd_ea0:
  ST r15,r0,@nd_ea0lnk
  ADD r1,r8,r0
  CALL @nd_addr
  ADD r14,r1,r0
  LD r15,r0,@nd_ea0lnk
  RET
nd_ea0lnk:
.word 0

; ---- shadow call stack ------------------------------------------------------
; nd_push(r1=return pc); nd_pop() unwinds; both preserve the handler's state.
nd_push:
  ST r15,r0,@nd_pushlnk
  ST r1,r0,@nd_pushv
  LD r2,r0,@nd_cd
  MOVI r3,64
  CMP r2,r3
  JMP[GE] @nd_depth
  MOVI r3,@nd_cs
  ADD r3,r3,r2
  LD r1,r0,@nd_pushv
  ST r1,r3,0
  ADD r2,r2,r13
  ST r2,r0,@nd_cd
  LD r15,r0,@nd_pushlnk
  RET
nd_pushlnk:
.word 0
nd_pushv:
.word 0

nd_pop:
  ST r15,r0,@nd_poplnk
  LD r2,r0,@nd_cd
  CMP r2,r0
  JMP[EQ] @nd_depth
  SUB r2,r2,r13
  ST r2,r0,@nd_cd
  MOVI r3,@nd_cs
  ADD r3,r3,r2
  LD r1,r3,0
  LD r15,r0,@nd_poplnk
  RET
nd_poplnk:
.word 0

nd_depth:
  MOVI r1,0
  MOVI r2,0x42
  ADD r3,r12,r0
  LD r4,r0,@nd_raw
  LD r5,r0,@nd_curn
  CALL @nd_emit
  CALL @nd_rec_print
  JMP @nd_exit_fault

; ---- write containment and watchpoint --------------------------------------
; r1 = host word address. Fault if outside [nd_wlo, nd_whi).
nd_wguard:
  LD r2,r0,@nd_wlo
  CMP r1,r2
  JMP[LT] @nd_wg_bad
  LD r2,r0,@nd_whi
  CMP r1,r2
  JMP[GE] @nd_wg_bad
  RET
nd_wg_bad:
  ST r1,r0,@nd_badaddr
  JMP @nd_mem_fault

; r1 = host word address, r2 = value about to be written.
nd_watch_check:
  LD r3,r0,@nd_watch
  CMP r3,r1
  JMP[EQ] @nd_watch_hit
  LD r3,r0,@nd_wpn
  ST r3,r0,@nd_wi
nd_wpscan:
  LD r3,r0,@nd_wi
  CMP r3,r0
  JMP[EQ] @nd_wpdone
  SUB r3,r3,r13
  ST r3,r0,@nd_wi
  LD r3,r3,@nd_wpt
  CMP r3,r1
  JMP[EQ] @nd_watch_hit
  JMP @nd_wpscan
nd_wpdone:
  RET

nd_watch_hit:
  ST r1,r0,@nd_badaddr
  ST r2,r0,@nd_wval
  LD r4,r1,0
  ST r4,r0,@nd_wold
  MOVI r1,13
  MOVI r2,3
  ADD r3,r12,r0
  LD r4,r0,@nd_wold
  LD r5,r0,@nd_wval
  CALL @nd_emit
  CALL @nd_rec_print
  LD r12,r0,@nd_at
  JMP @nd_exit_break

nd_mem_fault:
  MOVI r1,0x40
  ST r1,r0,@nd_reason
  MOVI r1,1
  MOVI r2,0x40
  ADD r3,r12,r0
  LD r4,r0,@nd_badaddr
  MOVI r5,0
  CALL @nd_emit
  CALL @nd_rec_print
  JMP @nd_exit_fault
; ---- handlers: core ----------------------------------------------------------
nd_h_bool:
  MOVI r4,0
  MOVI r14,1
  BOOL.8 r14,r2,r14
  CMP r14,r0
  JMP[EQ] @nd_b2
  BOOL.1 r1,r8,r9
  BOOL.14 r4,r4,r1
nd_b2:
  MOVI r14,2
  BOOL.8 r14,r2,r14
  CMP r14,r0
  JMP[EQ] @nd_b3
  BOOL.2 r1,r8,r9
  BOOL.14 r4,r4,r1
nd_b3:
  MOVI r14,4
  BOOL.8 r14,r2,r14
  CMP r14,r0
  JMP[EQ] @nd_b4
  BOOL.4 r1,r8,r9
  BOOL.14 r4,r4,r1
nd_b4:
  MOVI r14,8
  BOOL.8 r14,r2,r14
  CMP r14,r0
  JMP[EQ] @nd_b5
  BOOL.8 r1,r8,r9
  BOOL.14 r4,r4,r1
nd_b5:
  CMP r4,r0
  JMP @nd_t_stf
nd_h_movi:
  ADD r4,r7,r0
  JMP @nd_t_st
nd_h_movhi:
  LD r4,r5,@nd_regs
  MOVI r14,65535
  BOOL.8 r4,r4,r14
  SHL r14,r7,16
  BOOL.14 r4,r4,r14
  JMP @nd_t_st
nd_h_add:
  ADD r4,r8,r9
  JMP @nd_t_stf
nd_h_sub:
  SUB r4,r8,r9
  JMP @nd_t_stf
nd_h_shl:
  MOVI r14,31
  BOOL.8 r14,r7,r14
  LD r14,r14,@nd_pow2
  MUL r4,r8,r14
  JMP @nd_t_stf
nd_h_shr:
  MOVI r14,31
  BOOL.8 r14,r7,r14
  LD r14,r14,@nd_pow2
  DIVU r4,r8,r14
  JMP @nd_t_stf
nd_h_cmp:
  CMP r8,r9
  JMP @nd_t_fk
nd_h_ld:
  CALL @nd_ea
  LD r4,r14,0
  JMP @nd_t_st
nd_h_st:
  CALL @nd_ea
  ADD r1,r14,r0
  CALL @nd_wguard
  LD r4,r5,@nd_regs
  ADD r2,r4,r0
  ADD r1,r14,r0
  CALL @nd_watch_check
  ST r4,r0,@nd_badaddr
  ADD r1,r14,r0
  CALL @nd_uwr
  LD r4,r0,@nd_badaddr
  ST r4,r14,0
  JMP @nd_loop
nd_h_jmp:
  ADD r12,r7,r0
  JMP @nd_loop
nd_h_call:
  ADD r1,r12,r0
  CALL @nd_push
  MOVI r14,15
  ST r12,r14,@nd_regs
  ADD r12,r7,r0
  JMP @nd_loop
nd_h_ret:
  CALL @nd_pop
  MOVI r14,15
  LD r12,r14,@nd_regs
  MOVI r14,65535
  BOOL.8 r12,r12,r14
  JMP @nd_loop
nd_h_jmpr:
  MOVI r14,65535
  BOOL.8 r12,r8,r14
  JMP @nd_loop
nd_h_nop:
  JMP @nd_loop
nd_h_vpoke:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[EQ] @nd_vp_pass
  MOVI r1,2000
  CMP r8,r1
  JMP[GE] @nd_loop
  LD r4,r5,@nd_regs
  LD r1,r0,@nd_tbuf
  ADD r1,r1,r8
  ST r4,r1,0
  JMP @nd_loop
nd_vp_pass:
  LD r4,r5,@nd_regs
  VPOKE r4,r8
  JMP @nd_loop
nd_h_vpeek:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[EQ] @nd_vpk_pass
  MOVI r1,2000
  CMP r8,r1
  JMP[GE] @nd_vpk_zero
  LD r1,r0,@nd_tbuf
  ADD r1,r1,r8
  LD r4,r1,0
  JMP @nd_t_st
nd_vpk_zero:
  MOVI r4,0
  JMP @nd_t_st
nd_vpk_pass:
  VPEEK r4,r8
  JMP @nd_t_st
nd_h_key:
  KEYQ r4
  CMP r4,r0
  JMP[NE] @nd_t_st
  JMP @nd_exit_wait
nd_h_tick:
  LD r4,r0,@nd_steps
  MOVI r14,1000
  DIVU r4,r4,r14
  JMP @nd_t_st
nd_h_bswapm:
  CALL @nd_ea
  ADD r1,r14,r0
  CALL @nd_uwr
  BSWAPM r14,0
  JMP @nd_loop
nd_h_putc:
  JMP @nd_putc_cap
nd_h_stw:
  CALL @nd_ea0
  ADD r1,r14,r0
  CALL @nd_wguard
  LD r4,r5,@nd_regs
  ADD r2,r4,r0
  ADD r1,r14,r0
  CALL @nd_watch_check
  LD r4,r5,@nd_regs
  ST r4,r0,@nd_badaddr
  ADD r1,r14,r0
  CALL @nd_uwr
  LD r4,r0,@nd_badaddr
  STW r4,r14,r9
  JMP @nd_loop
nd_h_ldn:
  CALL @nd_ea
  LDN r4,r14,0
  JMP @nd_t_st
nd_h_dispq:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[EQ] @nd_dq_pass
  LA r4,0x00031950
  JMP @nd_t_st
nd_dq_pass:
  DISPQ r4
  JMP @nd_t_st
nd_h_dispset:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[NE] @nd_loop
  LD r4,r5,@nd_regs
  DISPSET r4
  JMP @nd_loop
nd_h_keyq:
  KEYQ r4
  JMP @nd_t_st
nd_h_beep:
  LD r4,r5,@nd_regs
  BEEP r4
  JMP @nd_loop
; ---- handlers: integer ext -----------------------------------------------------
nd_h_mul:
  MUL r4,r8,r9
  JMP @nd_t_stf
nd_h_mulh:
  MULH r4,r8,r9
  JMP @nd_t_stf
nd_h_mulhu:
  MULHU r4,r8,r9
  JMP @nd_t_stf
nd_h_div:
  DIV r4,r8,r9
  JMP @nd_t_stf
nd_h_mod:
  MOD r4,r8,r9
  JMP @nd_t_stf
nd_h_divu:
  DIVU r4,r8,r9
  JMP @nd_t_stf
nd_h_modu:
  MODU r4,r8,r9
  JMP @nd_t_stf
nd_h_sar:
  MOVI r14,31
  BOOL.8 r14,r7,r14
  LD r14,r14,@nd_pow2
  SHR r2,r8,31
  CMP r2,r0
  JMP[NE] @nd_sar_n
  DIVU r4,r8,r14
  JMP @nd_sar_f
nd_sar_n:
  BOOL.3 r2,r8,r8
  DIVU r2,r2,r14
  BOOL.3 r4,r2,r2
nd_sar_f:
  CMP r4,r0
  JMP @nd_t_stf
nd_h_cmps:
  CMPS r8,r9
  JMP @nd_t_fk
nd_h_addi:
  MOVI r14,32768
  BOOL.8 r14,r7,r14
  CMP r14,r0
  JMP[EQ] @nd_ai
  MOVHI r7,65535
nd_ai:
  ADD r4,r8,r7
  JMP @nd_t_stf
nd_h_ldb:
  ADD r14,r8,r7
  SHR r2,r14,2
  LD r1,r0,@nd_mask
  BOOL.8 r2,r2,r1
  ADD r2,r2,r10
  LD r3,r2,0
  MOVI r1,3
  BOOL.8 r1,r14,r1
  LD r1,r1,@nd_bpow
  DIVU r4,r3,r1
  MOVI r14,255
  BOOL.8 r4,r4,r14
  JMP @nd_t_st
nd_h_stb:
  ADD r14,r8,r7
  SHR r2,r14,2
  LD r1,r0,@nd_mask
  BOOL.8 r2,r2,r1
  ADD r2,r2,r10
  MOVI r1,3
  BOOL.8 r1,r14,r1
  LD r1,r1,@nd_bpow
  LD r3,r2,0
  MOVI r4,255
  MUL r4,r4,r1
  BOOL.4 r3,r3,r4
  LD r4,r5,@nd_regs
  MOVI r14,255
  BOOL.8 r4,r4,r14
  MUL r4,r4,r1
  BOOL.14 r3,r3,r4
  ST r2,r0,@nd_badaddr
  ST r3,r0,@nd_wval
  ADD r1,r2,r0
  CALL @nd_wguard
  LD r1,r0,@nd_badaddr
  LD r2,r0,@nd_wval
  CALL @nd_watch_check
  LD r1,r0,@nd_badaddr
  CALL @nd_uwr
  LD r2,r0,@nd_badaddr
  LD r3,r0,@nd_wval
  ST r3,r2,0
  JMP @nd_loop
nd_h_callr:
  ADD r1,r12,r0
  CALL @nd_push
  MOVI r14,15
  ST r12,r14,@nd_regs
  MOVI r14,65535
  BOOL.8 r12,r8,r14
  JMP @nd_loop
; BCOPY d,a,b : guest mem[r[d]..+r[b]) = mem[r[a]..+r[b])  memmove, classes preserved
nd_h_bcopy:
  LD r1,r5,@nd_regs
  CMP r9,r0
  JMP[EQ] @nd_loop
  CALL @nd_ubulk
  LD r1,r5,@nd_regs
  CMP r1,r8
  JMP[GT] @nd_bc_back
  MOVI r2,0
nd_bc_f:
  ADD r3,r8,r2
  ADD r4,r1,r2
  ST r1,r0,@nd_bc_dst
  ST r2,r0,@nd_bc_i
  CALL @nd_cp1
  LD r1,r0,@nd_bc_dst
  LD r2,r0,@nd_bc_i
  ADD r2,r2,r13
  CMP r2,r9
  JMP[LT] @nd_bc_f
  JMP @nd_loop
nd_bc_back:
  ADD r2,r9,r0
nd_bc_b:
  SUB r2,r2,r13
  ADD r3,r8,r2
  ADD r4,r1,r2
  ST r1,r0,@nd_bc_dst
  ST r2,r0,@nd_bc_i
  CALL @nd_cp1
  LD r1,r0,@nd_bc_dst
  LD r2,r0,@nd_bc_i
  CMP r2,r0
  JMP[NE] @nd_bc_b
  JMP @nd_loop
; r3 = guest src addr, r4 = guest dst addr -> copy one word with its class (clobbers r3,r4,r14)
nd_cp1:
  ST r15,r0,@nd_cplnk
  LD r14,r0,@nd_mask
  BOOL.8 r3,r3,r14
  ADD r3,r3,r10
  BOOL.8 r4,r4,r14
  ADD r4,r4,r10
  LDN r14,r3,0
  ST r14,r0,@nd_wcls
  LD r3,r3,0
  ST r3,r0,@nd_wval
  ST r4,r0,@nd_badaddr
  ADD r1,r4,r0
  CALL @nd_wguard
  LD r1,r0,@nd_badaddr
  LD r2,r0,@nd_wval
  CALL @nd_watch_check
  LD r1,r0,@nd_badaddr
  LD r2,r0,@nd_wval
  LD r3,r0,@nd_wcls
  STW r2,r1,r3
  LD r15,r0,@nd_cplnk
  RET
nd_cplnk:
.word 0
; BFILL d,a,b : guest mem[r[d]..+r[b]) = +q/+q words, payload r[a]
nd_h_bfill:
  LD r1,r5,@nd_regs
  CMP r9,r0
  JMP[EQ] @nd_loop
  CALL @nd_ubulk
  LD r1,r5,@nd_regs
  MOVI r2,0
nd_bf:
  ADD r4,r1,r2
  LD r14,r0,@nd_mask
  BOOL.8 r4,r4,r14
  ADD r4,r4,r10
  ST r2,r0,@nd_vi
  ST r4,r0,@nd_badaddr
  ADD r1,r4,r0
  CALL @nd_wguard
  LD r1,r0,@nd_badaddr
  ADD r2,r8,r0
  CALL @nd_watch_check
  LD r2,r0,@nd_vi
  LD r4,r0,@nd_badaddr
  ST r8,r4,0
  ADD r2,r2,r13
  CMP r2,r9
  JMP[LT] @nd_bf
  JMP @nd_loop
; ---- handlers: float and hardware pass-through -----------------------------------
nd_h_fadd:
  FADD r4,r8,r9
  JMP @nd_t_stf
nd_h_fsub:
  FSUB r4,r8,r9
  JMP @nd_t_stf
nd_h_fmul:
  FMUL r4,r8,r9
  JMP @nd_t_stf
nd_h_fdiv:
  FDIV r4,r8,r9
  JMP @nd_t_stf
nd_h_fsqrt:
  FSQRT r4,r8
  JMP @nd_t_stf
nd_h_fcmp:
  FCMP r8,r9
  JMP @nd_t_fk
nd_h_cvtif:
  CVTIF r4,r8
  JMP @nd_t_stf
nd_h_cvtfi:
  CVTFI r4,r8
  JMP @nd_t_stf
nd_h_cpuid:
  MOVI r4,0
  JMP @nd_t_st
nd_h_rdtsc:
  LD r4,r0,@nd_steps
  JMP @nd_t_st
nd_h_fexp:
  FEXP r4,r8
  JMP @nd_t_stf
nd_h_ftanh:
  FTANH r4,r8
  JMP @nd_t_stf
nd_h_flog:
  FLOG r4,r8
  JMP @nd_t_stf
nd_h_nop2:
  JMP @nd_loop
nd_h_fbinfo:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[EQ] @nd_fbi_pass
  LA r4,0x00500019
  JMP @nd_t_st
nd_fbi_pass:
  FBINFO r4
  JMP @nd_t_st
nd_h_vsync:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[NE] @nd_loop
  VSYNC
  JMP @nd_loop
nd_h_fbcopy:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[NE] @nd_loop
  LD r4,r5,@nd_regs
  FBCOPY r4,r8,r9
  JMP @nd_loop
nd_h_fbfill:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[NE] @nd_loop
  LD r4,r5,@nd_regs
  FBFILL r4,r8,r9
  JMP @nd_loop
nd_h_outb:
  LD r4,r5,@nd_regs
  OUTB r4,r8
  JMP @nd_loop
nd_h_inb:
  INB r4,r8
  JMP @nd_t_st
nd_h_inw:
  INW r4,r8
  JMP @nd_t_st
nd_h_outw:
  LD r4,r5,@nd_regs
  OUTW r4,r8
  JMP @nd_loop
nd_h_outsw:
  LD r4,r5,@nd_regs
  OUTSW r4,r8,r9
  JMP @nd_loop
nd_h_outl:
  LD r4,r5,@nd_regs
  OUTL r4,r8
  JMP @nd_loop

; ---- far branches and DP4B ---------------------------------------------------
nd_h_jmpf:
  LA r14,0xFFFFFF
  BOOL.8 r12,r3,r14
  JMP @nd_loop

nd_h_callf:
  ADD r1,r12,r0
  CALL @nd_push
  MOVI r14,15
  ST r12,r14,@nd_regs
  LA r14,0xFFFFFF
  LD r3,r0,@nd_raw
  BOOL.8 r12,r3,r14
  JMP @nd_loop

nd_h_dp4b:
  DP4B r4,r8,r9
  JMP @nd_t_stf

; ---- vector helpers ---------------------------------------------------------
; nd_gbaddr: r1 = guest byte address -> r1 = host byte address
nd_gbaddr:
  ST r15,r0,@nd_galnk
  ST r1,r0,@nd_ga
  SHR r1,r1,2
  CALL @nd_addr
  SHL r1,r1,2
  MOVI r3,3
  LD r2,r0,@nd_ga
  BOOL.8 r2,r2,r3
  ADD r1,r1,r2
  LD r15,r0,@nd_galnk
  RET
nd_galnk:
.word 0
nd_ga:
.word 0

; nd_vbase: r1 = vector index -> r1 = host byte address of its 64-byte file
nd_vbase:
  MOVI r2,64
  MUL r1,r1,r2
  LA r2,@nd_vreg
  SHL r2,r2,2
  ADD r1,r1,r2
  RET

; load guest vector r1 into host V0 / V1 / V2
nd_vload0:
  ST r15,r0,@nd_v0lnk
  CALL @nd_vbase
  VLOAD r0,r1
  LD r15,r0,@nd_v0lnk
  RET
nd_v0lnk:
.word 0
nd_vload1:
  ST r15,r0,@nd_v1lnk
  CALL @nd_vbase
  VLOAD r1,r1
  LD r15,r0,@nd_v1lnk
  RET
nd_v1lnk:
.word 0
nd_vload2:
  ST r15,r0,@nd_v2lnk
  CALL @nd_vbase
  VLOAD r2,r1
  LD r15,r0,@nd_v2lnk
  RET
nd_v2lnk:
.word 0

; store host V0 / V2 / V3 to guest vector r1
nd_vstore0:
  ST r15,r0,@nd_vs0lnk
  CALL @nd_vbase
  VSTORE r0,r1
  LD r15,r0,@nd_vs0lnk
  RET
nd_vs0lnk:
.word 0
nd_vstore2:
  ST r15,r0,@nd_vs2lnk
  CALL @nd_vbase
  VSTORE r2,r1
  LD r15,r0,@nd_vs2lnk
  RET
nd_vs2lnk:
.word 0
nd_vstore3:
  ST r15,r0,@nd_vs3lnk
  CALL @nd_vbase
  VSTORE r3,r1
  LD r15,r0,@nd_vs3lnk
  RET
nd_vs3lnk:
.word 0

; ---- vector ops -------------------------------------------------------------
nd_h_vzero:
  CALL @nd_ubulk
  VZERO r0
  ADD r1,r5,r0
  CALL @nd_vstore0
  JMP @nd_loop

nd_h_vbcast:
  CALL @nd_ubulk
  VBCAST r0,r8
  ADD r1,r5,r0
  CALL @nd_vstore0
  JMP @nd_loop

nd_h_vload:
  CALL @nd_ubulk
  LD r1,r0,@nd_gb
  CMP r1,r0
  JMP[NE] @nd_h_vload_slow
  LD r1,r0,@nd_map_lo
  LD r2,r0,@nd_map_hi
  CMP r1,r2
  JMP[LT] @nd_h_vload_slow
  VLOAD r0,r8
  ADD r1,r5,r0
  CALL @nd_vstore0
  JMP @nd_loop
nd_h_vload_slow:
  ST r8,r0,@nd_vA
  ST r5,r0,@nd_vd
  ST r0,r0,@nd_vi
nd_h_vload_l:
  LD r1,r0,@nd_vi
  MOVI r2,64
  CMP r1,r2
  JMP[GE] @nd_loop
  LD r1,r0,@nd_vA
  LD r2,r0,@nd_vi
  ADD r1,r1,r2
  CALL @nd_gbaddr
  LDB r4,r1,0
  ST r4,r0,@nd_vbyte
  LD r1,r0,@nd_vd
  CALL @nd_vbase
  LD r2,r0,@nd_vi
  ADD r1,r1,r2
  LD r4,r0,@nd_vbyte
  STB r4,r1,0
  LD r1,r0,@nd_vi
  ADD r1,r1,r13
  ST r1,r0,@nd_vi
  JMP @nd_h_vload_l

nd_h_vstore:
  CALL @nd_ubulk
  LD r1,r0,@nd_gb
  CMP r1,r0
  JMP[NE] @nd_h_vstore_slow
  LD r1,r0,@nd_map_lo
  LD r2,r0,@nd_map_hi
  CMP r1,r2
  JMP[LT] @nd_h_vstore_slow
  ST r8,r0,@nd_vA
  SHR r1,r8,2
  LD r2,r0,@nd_mask
  BOOL.8 r1,r1,r2
  CALL @nd_wguard
  LD r1,r0,@nd_vA
  ADDI r1,r1,63
  SHR r1,r1,2
  LD r2,r0,@nd_mask
  BOOL.8 r1,r1,r2
  CALL @nd_wguard
  ADD r1,r5,r0
  CALL @nd_vload0
  LD r8,r0,@nd_vA
  VSTORE r0,r8
  JMP @nd_loop
nd_h_vstore_slow:
  ST r8,r0,@nd_vA
  ST r5,r0,@nd_vd
  ST r0,r0,@nd_vi
nd_h_vstore_l:
  LD r1,r0,@nd_vi
  MOVI r2,64
  CMP r1,r2
  JMP[GE] @nd_loop
  LD r1,r0,@nd_vd
  CALL @nd_vbase
  LD r2,r0,@nd_vi
  ADD r1,r1,r2
  LDB r4,r1,0
  ST r4,r0,@nd_vbyte
  LD r1,r0,@nd_vA
  LD r2,r0,@nd_vi
  ADD r1,r1,r2
  CALL @nd_gbaddr
  ST r1,r0,@nd_va2
  SHR r1,r1,2
  CALL @nd_wguard
  LD r1,r0,@nd_va2
  LD r4,r0,@nd_vbyte
  STB r4,r1,0
  LD r1,r0,@nd_vi
  ADD r1,r1,r13
  ST r1,r0,@nd_vi
  JMP @nd_h_vstore_l

; load A and B into V0/V1, execute, store V2 to D.
nd_h_vadd8:
  CALL @nd_ubulk
  ADD r1,r6,r0
  CALL @nd_vload0
  MOVI r1,15
  BOOL.8 r1,r7,r1
  CALL @nd_vload1
  VADD8 r2,r0,r1
  ADD r1,r5,r0
  CALL @nd_vstore2
  JMP @nd_loop

nd_h_vsub8:
  CALL @nd_ubulk
  ADD r1,r6,r0
  CALL @nd_vload0
  MOVI r1,15
  BOOL.8 r1,r7,r1
  CALL @nd_vload1
  VSUB8 r2,r0,r1
  ADD r1,r5,r0
  CALL @nd_vstore2
  JMP @nd_loop

nd_h_vadd32:
  CALL @nd_ubulk
  ADD r1,r6,r0
  CALL @nd_vload0
  MOVI r1,15
  BOOL.8 r1,r7,r1
  CALL @nd_vload1
  VADD32 r2,r0,r1
  ADD r1,r5,r0
  CALL @nd_vstore2
  JMP @nd_loop

nd_h_vsub32:
  CALL @nd_ubulk
  ADD r1,r6,r0
  CALL @nd_vload0
  MOVI r1,15
  BOOL.8 r1,r7,r1
  CALL @nd_vload1
  VSUB32 r2,r0,r1
  ADD r1,r5,r0
  CALL @nd_vstore2
  JMP @nd_loop

nd_h_vmul32:
  CALL @nd_ubulk
  ADD r1,r6,r0
  CALL @nd_vload0
  MOVI r1,15
  BOOL.8 r1,r7,r1
  CALL @nd_vload1
  VMUL32 r2,r0,r1
  ADD r1,r5,r0
  CALL @nd_vstore2
  JMP @nd_loop

nd_h_vdp4b:
  CALL @nd_ubulk
  ADD r1,r6,r0
  CALL @nd_vload0
  MOVI r1,15
  BOOL.8 r1,r7,r1
  CALL @nd_vload1
  VDP4B r2,r0,r1
  ADD r1,r5,r0
  CALL @nd_vstore2
  JMP @nd_loop

nd_h_vdp4b4:
  CALL @nd_ubulk
  ADD r1,r6,r0
  CALL @nd_vload0
  MOVI r1,15
  BOOL.8 r1,r7,r1
  ST r1,r0,@nd_vb
  CALL @nd_vload1
  LD r1,r0,@nd_vb
  ADD r1,r1,r13
  MOVI r2,15
  BOOL.8 r1,r1,r2
  CALL @nd_vload2
  VDP4B4 r3,r0,r1
  ADD r1,r5,r0
  CALL @nd_vstore3
  JMP @nd_loop

nd_h_vget:
  MOVI r1,15
  BOOL.8 r7,r7,r1
  ADD r1,r6,r0
  SHL r1,r1,4
  LA r2,@nd_vreg
  ADD r1,r1,r2
  ADD r1,r1,r7
  LD r4,r1,0
  JMP @nd_t_st

nd_h_vset:
  CALL @nd_ubulk
  MOVI r1,15
  BOOL.8 r7,r7,r1
  ADD r1,r5,r0
  SHL r1,r1,4
  LA r2,@nd_vreg
  ADD r1,r1,r2
  ADD r1,r1,r7
  ST r8,r1,0
  JMP @nd_loop

; ---- state and tables ------------------------------------------------------------
nd_lnk:
.word 0
nd_gb:
.word 0
nd_map_lo:
.word 0
nd_map_hi:
.word 0
nd_map_dst:
.word 0
nd_mask:
.word 0xFFFF
nd_steps:
.word 0
nd_pc:
.word 0
nd_k:
.word 0
nd_brk:
.word 0xFFFFFFFF
nd_status:
.word 0
nd_reason:
.word 0
nd_seq:
.word 0
nd_left:
.word 0
nd_at:
.word 0
nd_waddr:
.word 0
nd_curn:
.word 0
nd_raw:
.word 0
nd_rec:
.word 0,0,0,0,0,0,0,0
nd_counts:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nd_li:
.word 0
nd_bpn:
.word 0
nd_bpt:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nd_iocap:
.word 0
nd_tbuf:
.word 0
nd_wpn:
.word 0
nd_wi:
.word 0
nd_wpt:
.word 0,0,0,0,0,0,0,0
nd_cd:
.word 0
nd_hi:
.word 0
nd_wlo:
.word 8192
nd_whi:
.word 0xFFFFFFFF
nd_watch:
.word 0xFFFFFFFF
nd_badaddr:
.word 0
nd_wval:
.word 0
nd_wold:
.word 0
nd_bc_dst:
.word 0
nd_bc_i:
.word 0
nd_wcls:
.word 0
nd_vA:
.word 0
nd_vd:
.word 0
nd_vi:
.word 0
nd_vbyte:
.word 0
nd_va2:
.word 0
nd_vb:
.word 0
nd_cs:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nd_regs:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nd_vreg:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nd_bit:
.word 1,2,4,8
nd_bpow:
.word 1,256,65536,16777216
nd_pow2:
.word 1,2,4,8,16,32,64,128,256,512,1024,2048,4096,8192,16384,32768
.word 65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648
nd_optab:
.word @nd_h_bool,@nd_h_movi,@nd_h_movhi,@nd_h_add,@nd_h_sub,@nd_h_shl,@nd_h_shr,@nd_h_cmp
.word @nd_h_ld,@nd_h_st,@nd_h_jmp,@nd_h_call,@nd_h_ret,@nd_h_jmpr,@nd_h_bad,@nd_h_nop
.word @nd_h_vpoke,@nd_h_vpeek,@nd_h_key,@nd_h_tick,@nd_h_bswapm,@nd_h_putc,@nd_h_stw,@nd_h_ldn
.word @nd_h_dispq,@nd_h_dispset,@nd_h_keyq,@nd_h_beep,@nd_h_bad,@nd_h_bad,@nd_h_bad,@nd_h_bad
.word @nd_h_mul,@nd_h_mulh,@nd_h_mulhu,@nd_h_div,@nd_h_mod,@nd_h_divu,@nd_h_modu,@nd_h_sar
.word @nd_h_cmps,@nd_h_addi,@nd_h_ldb,@nd_h_stb,@nd_h_callr,@nd_h_bcopy,@nd_h_bfill,@nd_h_nop2
.word @nd_h_fadd,@nd_h_fsub,@nd_h_fmul,@nd_h_fdiv,@nd_h_fsqrt,@nd_h_fcmp,@nd_h_cvtif,@nd_h_cvtfi
.word @nd_h_jmpf,@nd_h_callf,@nd_h_fbinfo,@nd_h_vsync,@nd_h_fbcopy,@nd_h_fbfill,@nd_h_outb,@nd_h_inb
.word @nd_h_inw,@nd_h_outw,@nd_h_outsw,@nd_h_outl,@nd_h_cpuid,@nd_h_rdtsc,@nd_h_fexp,@nd_h_ftanh
.word @nd_h_flog,@nd_h_bad,@nd_h_dp4b,@nd_h_bad,@nd_h_vdp4b4,@nd_h_bad,@nd_h_bad,@nd_h_bad
.word @nd_h_vzero,@nd_h_vbcast,@nd_h_vload,@nd_h_vstore,@nd_h_vadd8,@nd_h_vsub8,@nd_h_vadd32,@nd_h_vsub32
.word @nd_h_vmul32,@nd_h_vdp4b,@nd_h_bad,@nd_h_bad,@nd_h_bad,@nd_h_bad,@nd_h_vget,@nd_h_vset
.word @nd_h_hostext,@nd_h_hostext

; ---- undo recording state (ring at host word 0x30000) ----------------------
nd_urec:
.word 0
nd_ui:
.word 0
nd_ud:
.word 0
nd_ubase:
.word 0

.include "ndr.nas"
