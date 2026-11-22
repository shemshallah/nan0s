; block.nas - NaN-native straight-line translator driver.
; xt_block_x86: r1=source NaN word ptr r2=count r3=output byte ptr r4=next pc
;              -> r1=emitted bytes (0 on unsupported op)
; Only MOVI/ADD/SUB are accepted in this first stage; the emitted block ends
; with "mov [XPC],next_pc; ret".  The native core unpacks and executes it.
.include "x86.nas"

xt_block_x86:
  ST r15,r0,@xt_ret
  ST r1,r0,@xt_src
  ST r2,r0,@xt_n
  ST r3,r0,@xt_out
  ST r3,r0,@xt_start
  ST r4,r0,@xt_next
xt_loop:
  LD r2,r0,@xt_n
  CMP r2,r0
  JMP[EQ] @xt_end
  LD r1,r0,@xt_src
  LD r5,r1,0
  SHR r6,r5,24
  MOVI r7,1
  CMP r6,r7
  JMP[EQ] @xt_movi
  MOVI r7,3
  CMP r6,r7
  JMP[EQ] @xt_add
  MOVI r7,4
  CMP r6,r7
  JMP[EQ] @xt_sub
  JMP @xt_fail
xt_movi:
  SHR r2,r5,20
  MOVI r7,15
  BOOL.8 r2,r2,r7
  MOVI r7,0xFFFF
  BOOL.8 r3,r5,r7
  LD r1,r0,@xt_out
  CALL @x86_movi_mem
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_add:
  SHR r2,r5,20
  MOVI r7,15
  BOOL.8 r2,r2,r7
  SHR r3,r5,16
  MOVI r7,15
  BOOL.8 r3,r3,r7
  MOVI r7,15
  BOOL.8 r4,r5,r7
  LD r1,r0,@xt_out
  CALL @x86_add
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_sub:
  SHR r2,r5,20
  MOVI r7,15
  BOOL.8 r2,r2,r7
  SHR r3,r5,16
  MOVI r7,15
  BOOL.8 r3,r3,r7
  MOVI r7,15
  BOOL.8 r4,r5,r7
  LD r1,r0,@xt_out
  CALL @x86_sub
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_adv:
  LD r1,r0,@xt_src
  ADDI r1,r1,1
  ST r1,r0,@xt_src
  LD r2,r0,@xt_n
  SUB r2,r2,r13
  ST r2,r0,@xt_n
  JMP @xt_loop
xt_end:
  LD r1,r0,@xt_out
  LD r2,r0,@xt_next
  CALL @x86_set_xpc
  ST r1,r0,@xt_out
  CALL @x86_ret
  ST r1,r0,@xt_out
  LD r1,r0,@xt_out
  LD r2,r0,@xt_start
  SUB r1,r1,r2
  LD r15,r0,@xt_ret
  RET
xt_fail:
  MOVI r1,0
  LD r15,r0,@xt_ret
  RET
xt_ret:
  .word 0
xt_src:
  .word 0
xt_n:
  .word 0
xt_out:
  .word 0
xt_start:
  .word 0
xt_next:
  .word 0
