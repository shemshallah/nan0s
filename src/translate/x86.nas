; x86.nas - NaN-native x86-32 encoders for the block translator.
; r13 must be 1.  r1 is always the output byte pointer and is advanced.
; Only the always-executed integer subset is encoded here; flags/predication
; are the next stage.  Absolute guest addresses are fixed by the S1 map:
; R = 0x8000, XPC = 0x80D4.

.equ X_R   0x8000
.equ X_XPC 0x80D4

; x8: r1=out r2=byte -> r1=out+1
x8:
  STB r2,r1,0
  ADD r1,r1,r13
  RET

; x32: r1=out r2=u32 -> r1=out+4
x32:
  STB r2,r1,0
  SHR r3,r2,8
  STB r3,r1,1
  SHR r3,r2,16
  STB r3,r1,2
  SHR r3,r2,24
  STB r3,r1,3
  ADDI r1,r1,4
  RET

; x86_movi_mem: r1=out r2=guest reg r3=imm32 -> r1
; C7 05 <addr> <imm32>   mov dword [addr], imm32
x86_movi_mem:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,@xm_d
  ST r3,r0,@xm_v
  MOVI r2,0xC7
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  LD r2,r0,@xm_d
  SHL r2,r2,2
  LA r3,@x_r
  LD r3,r3,0
  ADD r2,r2,r3
  CALL @x32
  LD r2,r0,@xm_v
  CALL @x32
  SUB r14,r14,r13
  LD r15,r14,0
  RET
xm_d:
  .word 0
xm_v:
  .word 0
x_r:
  .word #X_R

; x86_add: r1=out r2=d r3=a r4=b -> r1
; 8B 05 a | 8B 0D b | 01 C8 | 89 05 d
x86_add:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,@xa_d
  ST r3,r0,@xa_a
  ST r4,r0,@xa_b
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  LD r2,r0,@xa_a
  SHL r2,r2,2
  LA r3,@x_r
  LD r3,r3,0
  ADD r2,r2,r3
  CALL @x32
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x0D
  CALL @x8
  LD r2,r0,@xa_b
  SHL r2,r2,2
  LA r3,@x_r
  LD r3,r3,0
  ADD r2,r2,r3
  CALL @x32
  MOVI r2,0x01
  CALL @x8
  MOVI r2,0xC8
  CALL @x8
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  LD r2,r0,@xa_d
  SHL r2,r2,2
  LA r3,@x_r
  LD r3,r3,0
  ADD r2,r2,r3
  CALL @x32
  SUB r14,r14,r13
  LD r15,r14,0
  RET
xa_d:
  .word 0
xa_a:
  .word 0
xa_b:
  .word 0

; x86_sub: same but 29 C8 (sub eax,ecx)
x86_sub:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,@xs_d
  ST r3,r0,@xs_a
  ST r4,r0,@xs_b
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  LD r2,r0,@xs_a
  SHL r2,r2,2
  LA r3,@x_r
  LD r3,r3,0
  ADD r2,r2,r3
  CALL @x32
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x0D
  CALL @x8
  LD r2,r0,@xs_b
  SHL r2,r2,2
  LA r3,@x_r
  LD r3,r3,0
  ADD r2,r2,r3
  CALL @x32
  MOVI r2,0x29
  CALL @x8
  MOVI r2,0xC8
  CALL @x8
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  LD r2,r0,@xs_d
  SHL r2,r2,2
  LA r3,@x_r
  LD r3,r3,0
  ADD r2,r2,r3
  CALL @x32
  SUB r14,r14,r13
  LD r15,r14,0
  RET
xs_d:
  .word 0
xs_a:
  .word 0
xs_b:
  .word 0

; x86_set_xpc: r1=out r2=next guest word -> r1
; C7 05 <XPC> <next>
x86_set_xpc:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,@xp_n
  MOVI r2,0xC7
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  LA r2,#X_XPC
  CALL @x32
  LD r2,r0,@xp_n
  CALL @x32
  SUB r14,r14,r13
  LD r15,r14,0
  RET
xp_n:
  .word 0

x86_ret:
  MOVI r2,0xC3
  JMP @x8
