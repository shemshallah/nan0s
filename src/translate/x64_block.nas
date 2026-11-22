; x64_block.nas - NaN-native 64-bit straight-line block driver.
; x64_block: r1=source NaN word ptr r2=count r3=out byte ptr r4=next pc
;            -> r1=emitted bytes (0 on unsupported op)
; Supported: MOVI, ADD, SUB.  The block ends with set-XPC + RET.
.include "x86_64.nas"

x64_block:
  ST r15,r0,@xb_retaddr
  ST r1,r0,@xb_src
  ST r2,r0,@xb_n
  ST r3,r0,@xb_out
  ST r3,r0,@xb_start
  ST r4,r0,@xb_next
  MOVI r11,0
  ST r11,r0,@xb_endflag
xb_loop:
  LD r2,r0,@xb_n
  CMP r2,r0
  JMP[EQ] @xb_end
  LD r1,r0,@xb_src
  LD r5,r1,0
  LDN r11,r1,0
  ST r11,r0,@xb_np
  SHR r7,r5,24
  SHR r8,r5,20
  MOVI r11,15
  BOOL.8 r8,r8,r11
  SHR r9,r5,16
  BOOL.8 r9,r9,r11
  MOVI r10,0xFFFF
  BOOL.8 r10,r5,r10
  MOVI r11,15
  BOOL.8 r12,r10,r11
  MOVI r11,0xFF
  CMP r7,r11
  JMP[EQ] @xb_halt
  MOVI r11,0
  CMP r7,r11
  JMP[EQ] @xb_bool
  MOVI r11,0x20
  CMP r7,r11
  JMP[EQ] @xb_mul
  MOVI r11,0x21
  CMP r7,r11
  JMP[EQ] @xb_mulh
  MOVI r11,0x22
  CMP r7,r11
  JMP[EQ] @xb_mulhu
  MOVI r11,0x23
  CMP r7,r11
  JMP[EQ] @xb_div
  MOVI r11,0x24
  CMP r7,r11
  JMP[EQ] @xb_mod
  MOVI r11,0x25
  CMP r7,r11
  JMP[EQ] @xb_divu
  MOVI r11,0x26
  CMP r7,r11
  JMP[EQ] @xb_modu
  MOVI r11,0x2D
  CMP r7,r11
  JMP[EQ] @xb_bcopy
  MOVI r11,0x2E
  CMP r7,r11
  JMP[EQ] @xb_bfill
  MOVI r11,0x14
  CMP r7,r11
  JMP[EQ] @xb_bswapm
  MOVI r11,0x16
  CMP r7,r11
  JMP[EQ] @xb_stw
  MOVI r11,0x17
  CMP r7,r11
  JMP[EQ] @xb_ldn
  MOVI r11,0x30
  CMP r7,r11
  JMP[EQ] @xb_fadd
  MOVI r11,0x31
  CMP r7,r11
  JMP[EQ] @xb_fsub
  MOVI r11,0x32
  CMP r7,r11
  JMP[EQ] @xb_fmul
  MOVI r11,0x33
  CMP r7,r11
  JMP[EQ] @xb_fdiv
  MOVI r11,0x34
  CMP r7,r11
  JMP[EQ] @xb_fsqrt
  MOVI r11,0x35
  CMP r7,r11
  JMP[EQ] @xb_fcmp
  MOVI r11,0x36
  CMP r7,r11
  JMP[EQ] @xb_cvtif
  MOVI r11,0x37
  CMP r7,r11
  JMP[EQ] @xb_cvtfi
  MOVI r11,0x0B
  CMP r7,r11
  JMP[EQ] @xb_call
  MOVI r11,0x2C
  CMP r7,r11
  JMP[EQ] @xb_callr
  MOVI r11,0x0C
  CMP r7,r11
  JMP[EQ] @xb_ret
  MOVI r11,0x0D
  CMP r7,r11
  JMP[EQ] @xb_jmpr
  MOVI r11,0x0F
  CMP r7,r11
  JMP[EQ] @xb_adv
  MOVI r11,0x0A
  CMP r7,r11
  JMP[EQ] @xb_jmp
  MOVI r11,1
  CMP r7,r11
  JMP[EQ] @xb_movi
  MOVI r11,3
  CMP r7,r11
  JMP[EQ] @xb_add
  MOVI r11,4
  CMP r7,r11
  JMP[EQ] @xb_sub
  MOVI r11,2
  CMP r7,r11
  JMP[EQ] @xb_movhi
  MOVI r11,0x29
  CMP r7,r11
  JMP[EQ] @xb_addi
  MOVI r11,5
  CMP r7,r11
  JMP[EQ] @xb_shl
  MOVI r11,6
  CMP r7,r11
  JMP[EQ] @xb_shr
  MOVI r11,0x27
  CMP r7,r11
  JMP[EQ] @xb_sar
  MOVI r11,8
  CMP r7,r11
  JMP[EQ] @xb_ld
  MOVI r11,9
  CMP r7,r11
  JMP[EQ] @xb_st
  MOVI r11,0x2A
  CMP r7,r11
  JMP[EQ] @xb_ldb
  MOVI r11,0x2B
  CMP r7,r11
  JMP[EQ] @xb_stb
  MOVI r11,7
  CMP r7,r11
  JMP[EQ] @xb_cmp
  MOVI r11,0x28
  CMP r7,r11
  JMP[EQ] @xb_cmps
  JMP @xb_fail
xb_movi:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r7,r10,r0
  CALL @x64_movi
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_add:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x64_add
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_sub:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x64_sub
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_movhi:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r7,r10,r0
  CALL @x64_movhi
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_addi:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_addi
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_shl:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_shl
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_shr:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_shr
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_sar:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_sar
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_cmp:
  LD r1,r0,@xb_out
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x92
  CALL @x64_cmp
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_cmps:
  LD r1,r0,@xb_out
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x9C
  CALL @x64_cmp
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_call:
  LD r1,r0,@xb_out
  ADD r7,r10,r0
  LD r8,r0,@xb_next
  CALL @x64_call
  ST r1,r0,@xb_out
  JMP @xb_ended

xb_callr:
  LD r1,r0,@xb_out
  MOVI r5,15
  LD r7,r0,@xb_next
  CALL @x64_movi
  ST r1,r0,@xb_out
  ADD r9,r9,r0
  CALL @x64_jump_reg
  ST r1,r0,@xb_out
  JMP @xb_ended

xb_ret:
  LD r1,r0,@xb_out
  MOVI r9,15
  CALL @x64_jump_reg
  ST r1,r0,@xb_out
  JMP @xb_ended

xb_jmpr:
  LD r1,r0,@xb_out
  ADD r9,r9,r0
  CALL @x64_jump_reg
  ST r1,r0,@xb_out
  JMP @xb_ended

xb_bool:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  LD r9,r0,@xb_np
  CALL @x64_bool
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_mul:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x64_mul
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_mulh:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x64_mulh
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_mulhu:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x64_mulhu
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_div:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x23
  CALL @x64_divmod
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_mod:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x24
  CALL @x64_divmod
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_divu:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x25
  CALL @x64_divmod
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_modu:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x26
  CALL @x64_divmod
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_fadd:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x30
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_fsub:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x31
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_fmul:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x32
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_fdiv:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x33
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_fsqrt:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  MOVI r8,0
  MOVI r9,0x34
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_cvtif:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  MOVI r8,0
  MOVI r9,0x36
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_cvtfi:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  MOVI r8,0
  MOVI r9,0x37
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_fcmp:
  LD r1,r0,@xb_out
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x35
  CALL @x64_fp
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_bswapm:
  LD r1,r0,@xb_out
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_bswapm
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_stw:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r7,0
  CALL @x64_stw
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_ldn:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_ldn
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_bcopy:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x64_bcopy
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_bfill:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x64_bfill
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_halt:
  LD r1,r0,@xb_out
  CALL @x64_halt
  ST r1,r0,@xb_out
  JMP @xb_ended

xb_jmp:
  LD r4,r0,@xb_np
  MOVI r11,15
  CMP r4,r11
  JMP[EQ] @xb_jmp_u
  CMP r4,r0
  JMP[EQ] @xb_adv
  LD r1,r0,@xb_out
  ADD r7,r10,r0
  LD r8,r0,@xb_next
  ADD r9,r4,r0
  CALL @x64_jmp_cond
  ST r1,r0,@xb_out
  JMP @xb_ended
xb_jmp_u:
  LD r1,r0,@xb_out
  ADD r7,r10,r0
  CALL @x64_set_xpc
  CALL @x64_ret
  ST r1,r0,@xb_out
xb_ended:
  MOVI r11,1
  ST r11,r0,@xb_endflag
  JMP @xb_adv


xb_ld:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_ld
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_st:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_st
  ST r1,r0,@xb_out
  JMP @xb_adv

xb_ldb:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_ldb
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_stb:
  LD r1,r0,@xb_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x64_stb
  ST r1,r0,@xb_out
  JMP @xb_adv
xb_adv:
  LD r1,r0,@xb_src
  ADDI r1,r1,1
  ST r1,r0,@xb_src
  LD r2,r0,@xb_n
  SUB r2,r2,r13
  ST r2,r0,@xb_n
  JMP @xb_loop
xb_end:
  LD r11,r0,@xb_endflag
  CMP r11,r0
  JMP[NE] @xb_done
  LD r1,r0,@xb_out
  LD r7,r0,@xb_next
  CALL @x64_set_xpc
  CALL @x64_ret
  ST r1,r0,@xb_out
xb_done:
  LD r1,r0,@xb_out
  LD r2,r0,@xb_start
  SUB r1,r1,r2
  LD r15,r0,@xb_retaddr
  RET
xb_fail:
  LD r1,r0,@xb_out
  MOVI r9,0x4F
  CALL @x64_trap
  ST r1,r0,@xb_out
  JMP @xb_ended

xb_retaddr:
  .word 0
xb_src:
  .word 0
xb_n:
  .word 0
xb_out:
  .word 0
xb_start:
  .word 0
xb_next:
  .word 0
xb_np:
  .word 0
xb_endflag:
  .word 0
