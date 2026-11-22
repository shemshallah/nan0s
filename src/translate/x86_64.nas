; x86_64.nas - NaN-native x86-64 encoders for the 64-bit core.
; ABI: r13=1, r14=stack, r0=0, r1=output byte pointer.
; Args: r5=d r6=a r7=imm/target r8=b.
; The emitted code uses the 64-bit core's fixed guest register file at
; 0x50000 and XPC at 0x50800, with SIB absolute disp32 addressing.

.equ X64_R   0x50000
.equ X64_XPC 0x50800

; x64_8: r1=out r2=byte -> r1=out+1
x64_8:
  STB r2,r1,0
  ADD r1,r1,r13
  RET

; x64_32: r1=out r2=u32 -> r1=out+4
x64_32:
  STB r2,r1,0
  SHR r3,r2,8
  STB r3,r1,1
  SHR r3,r2,16
  STB r3,r1,2
  SHR r3,r2,24
  STB r3,r1,3
  ADDI r1,r1,4
  RET

; x64_addr: r6=reg -> emit 0x50000+4*reg as disp32
x64_addr:
  SHL r3,r6,2
  LA r4,#X64_R
  ADD r3,r3,r4
  STB r3,r1,0
  SHR r4,r3,8
  STB r4,r1,1
  SHR r4,r3,16
  STB r4,r1,2
  SHR r4,r3,24
  STB r4,r1,3
  ADDI r1,r1,4
  RET

; C7 04 25 <addr32> <imm32> : mov dword [addr], imm32
x64_movi:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r5,r0
  CALL @x64_addr
  ADD r2,r7,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 8B 04 25 a | 8B 0C 25 b | 01 C8 | 89 04 25 d
x64_add:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r6,r0
  CALL @x64_addr
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x0C
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r8,r0
  CALL @x64_addr
  MOVI r2,0x01
  CALL @x64_8
  MOVI r2,0xC8
  CALL @x64_8
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r5,r0
  CALL @x64_addr
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; C7 04 25 <XPC> <next>
x64_set_xpc:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_XPC
  CALL @x64_32
  ADD r2,r7,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

x64_ret:
  MOVI r2,0xC3
  JMP @x64_8
