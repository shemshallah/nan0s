; n16dbg.nas - serial monitor for the NANDBG step core. Written in NaN16.
;
; This is the first usable front end: a target at word 8192, the full core at
; word 0, the disassembler below the target, and a small command loop on COM1.
; It is deliberately serial-first: the 80x25 pane UI is the next stage, but the
; control model is complete enough to step, run, break and inspect.
;
; commands:
;   s  step one instruction          r  run to break/fault/halt/budget
;   b  toggle breakpoint at PC       p  print registers
;   d  disassemble 4 words at PC     x  dump 8 words at PC
;   q  leave
.org 0
JMP @main
.include "core.nas"
.include "../tools/disasm.nas"
.include "undo_stub.nas"

dis_out:
  PUTC r9
  RET

main:
  MOVI r13,1
  CALL @nd_reset
  MOVI r1,8192
  ST r1,r0,@nd_pc
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_brk
  MOVI r1,@s_banner
  CALL @nd_puts

mon_loop:
  MOVI r1,@s_prompt
  CALL @nd_puts
  KEY r1
  MOVI r2,255
  BOOL.8 r1,r1,r2
  MOVI r2,115
  CMP r1,r2
  JMP[EQ] @cmd_s
  MOVI r2,114
  CMP r1,r2
  JMP[EQ] @cmd_r
  MOVI r2,98
  CMP r1,r2
  JMP[EQ] @cmd_b
  MOVI r2,103
  CMP r1,r2
  JMP[EQ] @cmd_g
  MOVI r2,119
  CMP r1,r2
  JMP[EQ] @cmd_w
  MOVI r2,108
  CMP r1,r2
  JMP[EQ] @cmd_l
  MOVI r2,116
  CMP r1,r2
  JMP[EQ] @cmd_t
  MOVI r2,109
  CMP r1,r2
  JMP[EQ] @cmd_m
  MOVI r2,111
  CMP r1,r2
  JMP[EQ] @cmd_ndp
  MOVI r2,100
  CMP r1,r2
  JMP[EQ] @cmd_d
  MOVI r2,120
  CMP r1,r2
  JMP[EQ] @cmd_x
  MOVI r2,118
  CMP r1,r2
  JMP[EQ] @cmd_v
  MOVI r2,102
  CMP r1,r2
  JMP[EQ] @cmd_f
  MOVI r2,110
  CMP r1,r2
  JMP[EQ] @cmd_n
  MOVI r2,112
  CMP r1,r2
  JMP[EQ] @cmd_p
  MOVI r2,113
  CMP r1,r2
  JMP[EQ] @cmd_q
  JMP @mon_loop

cmd_s:
  CALL @nd_step
  CALL @mon_status
  JMP @mon_loop

cmd_r:
  LA r1,1000000
  CALL @nd_run
  CALL @mon_status
  JMP @mon_loop

cmd_b:
  LD r1,r0,@nd_brk
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @cmd_b_set
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_brk
  MOVI r1,@s_bpoff
  CALL @nd_puts
  JMP @mon_loop
cmd_b_set:
  LD r1,r0,@nd_pc
  ST r1,r0,@nd_brk
  MOVI r1,@s_bp
  CALL @nd_puts
  LD r1,r0,@nd_pc
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @mon_loop

cmd_g:
  MOVI r1,@s_addr
  CALL @nd_puts
  CALL @mon_readhex
  ST r1,r0,@nd_pc
  MOVI r1,@s_pc
  CALL @nd_puts
  LD r1,r0,@nd_pc
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @mon_loop

cmd_w:
  MOVI r1,@s_waddr
  CALL @nd_puts
  CALL @mon_readhex
  LD r2,r0,@nd_watch
  CMP r1,r2
  JMP[EQ] @cmd_w_off
  ST r1,r0,@nd_watch
  MOVI r1,@s_w
  CALL @nd_puts
  LD r1,r0,@nd_watch
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @mon_loop
cmd_w_off:
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_watch
  MOVI r1,@s_woff
  CALL @nd_puts
  JMP @mon_loop

cmd_l:
  MOVI r1,@s_hist
  CALL @nd_puts
  LD r8,r0,@nd_hi
  MOVI r2,16
  SUB r8,r8,r2
  MOVI r2,4095
  BOOL.8 r8,r8,r2
  MOVI r9,0
cl_loop:
  LA r1,0x32000
  ADD r1,r1,r8
  LD r1,r1,0
  MOVI r4,0xFFFF
  BOOL.8 r1,r1,r4
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  ADD r8,r8,r13
  MOVI r2,4095
  BOOL.8 r8,r8,r2
  ADD r9,r9,r13
  MOVI r2,16
  CMP r9,r2
  JMP[LT] @cl_loop
  MOVI r1,10
  PUTC r1
  JMP @mon_loop

cmd_t:
  MOVI r1,@s_stack
  CALL @nd_puts
  LD r8,r0,@nd_cd
  CMP r8,r0
  JMP[EQ] @ct_empty
ct_loop:
  SUB r8,r8,r13
  MOVI r1,@nd_cs
  ADD r1,r1,r8
  LD r1,r1,0
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  CMP r8,r0
  JMP[NE] @ct_loop
  MOVI r1,10
  PUTC r1
  JMP @mon_loop
ct_empty:
  MOVI r1,@s_empty
  CALL @nd_puts
  JMP @mon_loop

cmd_f:
  MOVI r3,0x9DC5
  MOVHI r3,0x811C
  MOVI r4,0x0193
  MOVHI r4,0x0100
  LA r1,0x32000
  MOVI r2,4096
cf_l:
  LD r5,r1,0
  BOOL.6 r3,r3,r5
  MUL r3,r3,r4
  ADDI r1,r1,1
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @cf_l
  ST r3,r0,@hseal_v
  MOVI r1,@s_hseal
  CALL @nd_puts
  LD r1,r0,@hseal_v
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @mon_loop

cmd_v:
  LD r8,r0,@nd_li
  SUB r8,r8,r13
  MOVI r9,15
  BOOL.8 r8,r8,r9
  SHL r8,r8,3
  MOVI r9,0
cv_loop:
  LA r4,0x31000
  ADD r4,r4,r8
  ADD r4,r4,r9
  LD r5,r4,0
  LA r6,0x31800
  ADD r6,r6,r8
  ADD r6,r6,r9
  LD r7,r6,0
  LA r4,@ndr_scratch
  ST r7,r4,0
  BSWAPM r4,0
  LD r7,r4,0
  CMP r7,r5
  JMP[NE] @cv_bad
  ADD r9,r9,r13
  MOVI r4,8
  CMP r9,r4
  JMP[LT] @cv_loop
  MOVI r1,@s_mok
  CALL @nd_puts
  JMP @mon_loop
cv_bad:
  MOVI r1,@s_mbad
  CALL @nd_puts
  JMP @mon_loop

cmd_n:
  MOVI r1,@s_ndr
  CALL @nd_puts
  MOVI r8,0
cn_loop:
  MOVI r1,@nd_rec
  ADD r1,r1,r8
  LD r1,r1,0
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  ADD r8,r8,r13
  MOVI r2,8
  CMP r8,r2
  JMP[LT] @cn_loop
  MOVI r1,10
  PUTC r1
  JMP @mon_loop

cmd_m:
  MOVI r8,0
cm_row:
  MOVI r1,@s_tmat
  CALL @nd_puts
  MOVI r9,0
cm_col:
  MOVI r1,0
  ADD r1,r8,r0
  CALL @nd_type_letters
  MOVI r1,58
  PUTC r1
  MOVI r1,@nd_counts
  ADD r1,r1,r8
  LD r1,r1,0
  MOVI r2,2
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  ADD r8,r8,r13
  ADD r9,r9,r13
  MOVI r7,4
  CMP r9,r7
  JMP[LT] @cm_col
  MOVI r1,10
  PUTC r1
  MOVI r7,16
  CMP r8,r7
  JMP[LT] @cm_row
  JMP @mon_loop

; read up to four hex digits from KEY, terminated by CR/LF. r1 = value.
mon_readhex:
  ST r15,r0,@rh_lnk
  MOVI r1,0
  ST r1,r0,@rh_v
  MOVI r8,0
rh_loop:
  KEY r1
  MOVI r2,255
  BOOL.8 r1,r1,r2
  MOVI r2,13
  CMP r1,r2
  JMP[EQ] @rh_done
  MOVI r2,10
  CMP r1,r2
  JMP[EQ] @rh_done
  MOVI r2,8
  CMP r1,r2
  JMP[EQ] @rh_back
  MOVI r2,4
  CMP r8,r2
  JMP[GE] @rh_loop
  CALL @mon_hexval
  CMP r2,r0
  JMP[EQ] @rh_loop
  LD r3,r0,@rh_v
  SHL r3,r3,4
  BOOL.14 r3,r3,r1
  ST r3,r0,@rh_v
  ADD r8,r8,r13
  JMP @rh_loop
rh_back:
  CMP r8,r0
  JMP[EQ] @rh_loop
  LD r3,r0,@rh_v
  SHR r3,r3,4
  ST r3,r0,@rh_v
  SUB r8,r8,r13
  JMP @rh_loop
rh_done:
  LD r1,r0,@rh_v
  LD r15,r0,@rh_lnk
  RET
rh_lnk:
.word 0
rh_v:
.word 0

; r1 = ASCII -> r1 = nibble, r2 = 1 valid / 0 invalid
mon_hexval:
  MOVI r2,0
  MOVI r3,48
  CMP r1,r3
  JMP[LT] @hv_low
  MOVI r3,57
  CMP r1,r3
  JMP[GT] @hv_upper
  MOVI r3,48
  SUB r1,r1,r3
  MOVI r2,1
  RET
hv_upper:
  MOVI r3,65
  CMP r1,r3
  JMP[LT] @hv_low
  MOVI r3,70
  CMP r1,r3
  JMP[GT] @hv_low
  MOVI r3,55
  SUB r1,r1,r3
  MOVI r2,1
  RET
hv_low:
  MOVI r3,97
  CMP r1,r3
  JMP[LT] @hv_no
  MOVI r3,102
  CMP r1,r3
  JMP[GT] @hv_no
  MOVI r3,87
  SUB r1,r1,r3
  MOVI r2,1
  RET
hv_no:
  MOVI r2,0
  RET

cmd_p:
  CALL @mon_regs
  JMP @mon_loop

cmd_d:
  LD r1,r0,@nd_pc
  MOVI r2,4
  CALL @dis_range
  JMP @mon_loop

cmd_x:
  LD r1,r0,@nd_pc
  MOVI r2,8
  CALL @dis_range
  JMP @mon_loop

cmd_q:
  HALT

; print status and pc:  S=<hex> PC=<hex>
mon_status:
  ST r15,r0,@ms_lnk
  MOVI r1,83
  PUTC r1
  MOVI r1,61
  PUTC r1
  LD r1,r0,@nd_status
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  MOVI r1,80
  PUTC r1
  MOVI r1,67
  PUTC r1
  MOVI r1,61
  PUTC r1
  LD r1,r0,@nd_pc
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  LD r15,r0,@ms_lnk
  RET
ms_lnk:
.word 0

; print K and R0..R15 in two rows of eight
mon_regs:
  ST r15,r0,@mr_lnk
  MOVI r1,75
  PUTC r1
  MOVI r1,61
  PUTC r1
  LD r1,r0,@nd_k
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  MOVI r8,0
mr_loop:
  MOVI r1,82
  PUTC r1
  ADD r1,r8,r0
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,61
  PUTC r1
  ADD r1,r8,r0
  LD r1,r1,@nd_regs
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  ADD r8,r8,r13
  MOVI r7,7
  BOOL.8 r6,r8,r7
  CMP r6,r0
  JMP[NE] @mr_next
  MOVI r1,10
  PUTC r1
mr_next:
  MOVI r7,16
  CMP r8,r7
  JMP[LT] @mr_loop
  LD r15,r0,@mr_lnk
  RET
mr_lnk:
.word 0

s_ndr:
.str "NDR "
s_hseal:
.str "HSEAL "
hseal_v:
.word 0
s_mok:
.str "MIRROR OK\n"
s_mbad:
.str "MIRROR BAD\n"
ndr_scratch:
.word 0
s_banner:
.str "NANDBG MONITOR - s step  r run  b break  g goto  w watch  l hist  t stack  m types  p regs  d dis  x dump  n ndr  v mirror  f seal  o ndp  q quit\n"
s_prompt:
.str "> "
s_bp:
.str "BP="
s_bpoff:
.str "BP=off\n"
s_addr:
.str "addr> "
s_waddr:
.str "watch> "
s_pc:
.str "PC="
s_w:
.str "W="
s_woff:
.str "W=off\n"
s_hist:
.str "HIST "
s_stack:
.str "STACK "
s_empty:
.str "empty\n"
s_tmat:
.str "TYPES "

; =============================================================================
; target: a counted loop followed by a marker byte
; =============================================================================
.org 8192
target:
  MOVI r13,1
  MOVI r1,0
tloop:
  ADD r1,r1,r13
  MOVI r2,10
  CMP r1,r2
  JMP[LT] @tloop
  MOVI r4,0x3000
  ST r1,r4,0
  MOVI r3,0xAA
  HALT

; ---- NDP text transport: H hello, R read, W write, S step, U run, E event, Q quit ----
cmd_ndp:
  MOVI r1,@s_ndp_start
  CALL @nd_puts
  CALL @ndp_loop
  JMP @mon_loop

ndp_loop:
  ST r15,r0,@ndp_lnk
ndp_key:
  KEY r1
  MOVI r2,72
  CMP r1,r2
  JMP[EQ] @ndp_hello
  MOVI r2,82
  CMP r1,r2
  JMP[EQ] @ndp_read
  MOVI r2,87
  CMP r1,r2
  JMP[EQ] @ndp_write
  MOVI r2,83
  CMP r1,r2
  JMP[EQ] @ndp_step
  MOVI r2,85
  CMP r1,r2
  JMP[EQ] @ndp_run
  MOVI r2,69
  CMP r1,r2
  JMP[EQ] @ndp_event
  MOVI r2,81
  CMP r1,r2
  JMP[EQ] @ndp_quit
  MOVI r1,@s_ndp_bad
  CALL @nd_puts
  JMP @ndp_key
ndp_hello:
  MOVI r1,@s_ndp_hello
  CALL @nd_puts
  JMP @ndp_key
ndp_read:
  MOVI r2,4
  CALL @ndp_hex
  ST r1,r0,@ndp_a
  CALL @nd_addr
  LD r2,r1,0
  ST r2,r0,@ndp_v
  MOVI r1,@s_ndp_r
  CALL @nd_puts
  LD r1,r0,@ndp_a
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  LD r1,r0,@ndp_v
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @ndp_key
ndp_write:
  MOVI r2,4
  CALL @ndp_hex
  ST r1,r0,@ndp_a
  MOVI r2,8
  CALL @ndp_hex
  ST r1,r0,@ndp_v
  LD r1,r0,@ndp_a
  CALL @nd_addr
  LD r2,r0,@ndp_v
  MOVI r3,10
  STW r2,r1,r3
  MOVI r1,@s_ndp_w
  CALL @nd_puts
  LD r1,r0,@ndp_a
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @ndp_key
ndp_step:
  CALL @nd_step
  ST r1,r0,@ndp_s
  LD r1,r0,@nd_pc
  ST r1,r0,@ndp_a
  MOVI r1,@s_ndp_s
  CALL @nd_puts
  LD r1,r0,@ndp_s
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  LD r1,r0,@ndp_a
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @ndp_key
ndp_run:
  MOVI r1,1000
  CALL @nd_run
  ST r1,r0,@ndp_s
  LD r1,r0,@nd_pc
  ST r1,r0,@ndp_a
  MOVI r1,@s_ndp_u
  CALL @nd_puts
  LD r1,r0,@ndp_s
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  LD r1,r0,@ndp_a
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  JMP @ndp_key
ndp_event:
  MOVI r1,@s_ndp_ndr
  CALL @nd_puts
  MOVI r8,0
ndp_ev_l:
  MOVI r1,@nd_rec
  ADD r1,r1,r8
  LD r1,r1,0
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  ADD r8,r8,r13
  MOVI r2,8
  CMP r8,r2
  JMP[LT] @ndp_ev_l
  MOVI r1,10
  PUTC r1
  JMP @ndp_key
ndp_quit:
  MOVI r1,@s_ndp_bye
  CALL @nd_puts
  LD r15,r0,@ndp_lnk
  RET

; r2 = hex digit count -> r1
ndp_hex:
  MOVI r1,0
  ADD r9,r2,r0
nh_l:
  KEY r3
  MOVI r5,48
  CMP r3,r5
  JMP[LT] @nh_alpha
  MOVI r5,57
  CMP r3,r5
  JMP[GT] @nh_alpha
  MOVI r5,48
  SUB r4,r3,r5
  JMP @nh_digit
nh_alpha:
  MOVI r5,65
  CMP r3,r5
  JMP[LT] @nh_lower
  MOVI r5,70
  CMP r3,r5
  JMP[GT] @nh_lower
  MOVI r5,55
  SUB r4,r3,r5
  JMP @nh_digit
nh_lower:
  MOVI r5,97
  CMP r3,r5
  JMP[LT] @nh_bad
  MOVI r5,102
  CMP r3,r5
  JMP[GT] @nh_bad
  MOVI r5,87
  SUB r4,r3,r5
nh_digit:
  SHL r1,r1,4
  BOOL.14 r1,r1,r4
  SUB r9,r9,r13
  CMP r9,r0
  JMP[NE] @nh_l
  RET
nh_bad:
  MOVI r1,0
  RET

ndp_lnk:
.word 0
ndp_a:
.word 0
ndp_v:
.word 0
ndp_s:
.word 0
s_ndp_start:
.str "NDP\n"
s_ndp_hello:
.str "NDP1\n"
s_ndp_bad:
.str "ERR\n"
s_ndp_bye:
.str "BYE\n"
s_ndp_r:
.str "R "
s_ndp_w:
.str "W "
s_ndp_s:
.str "S "
s_ndp_u:
.str "U "
s_ndp_ndr:
.str "NDR "

