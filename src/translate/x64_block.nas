; x64_block.nas - NaN-native 64-bit straight-line block driver.
; x64_block: r1=source NaN word ptr r2=count r3=out byte ptr r4=next pc
;            -> r1=emitted bytes (0 on unsupported op)
; Supported: MOVI, ADD, SUB.  The block ends with set-XPC + RET.
.include "x86_64.nas"

x64_block:
  ST r15,r0,@xb_ret
  ST r1,r0,@xb_src
  ST r2,r0,@xb_n
  ST r3,r0,@xb_out
  ST r3,r0,@xb_start
  ST r4,r0,@xb_next
xb_loop:
  LD r2,r0,@xb_n
  CMP r2,r0
  JMP[EQ] @xb_end
  LD r1,r0,@xb_src
  LD r5,r1,0
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
xb_adv:
  LD r1,r0,@xb_src
  ADDI r1,r1,1
  ST r1,r0,@xb_src
  LD r2,r0,@xb_n
  SUB r2,r2,r13
  ST r2,r0,@xb_n
  JMP @xb_loop
xb_end:
  LD r1,r0,@xb_out
  LD r7,r0,@xb_next
  CALL @x64_set_xpc
  CALL @x64_ret
  ST r1,r0,@xb_out
  LD r1,r0,@xb_out
  LD r2,r0,@xb_start
  SUB r1,r1,r2
  LD r15,r0,@xb_ret
  RET
xb_fail:
  MOVI r1,0
  LD r15,r0,@xb_ret
  RET

xb_ret:
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
