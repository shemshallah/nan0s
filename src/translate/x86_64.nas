; x86_64.nas - NaN-native x86-64 encoders for the 64-bit core.
; ABI: r13=1, r14=stack, r0=0, r1=output byte pointer.
; Args: r5=d r6=a r7=imm/target r8=b.
; The emitted code uses the 64-bit core's fixed guest register file at
; 0x50000 and XPC at 0x50800, with SIB absolute disp32 addressing.

.equ X64_R   0x50000
.equ X64_XPC 0x50800
.equ X64_FLAGM 0x50400

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


; 8B 04 25 a | 8B 0C 25 b | 29 C8 | 89 04 25 d
x64_sub:
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
  MOVI r2,0x29
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


; 8B 04 25 addr : eax = R[d]
x64_load_eax_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
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

; 8B 0C 25 addr : ecx = R[d]
x64_load_ecx_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x0C
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r5,r0
  CALL @x64_addr
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 04 25 addr : R[d] = eax
x64_store_eax_r:
  ST r15,r14,0
  ADD r14,r14,r13
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

; FLAGM = 1 << (2Z + L); r9 = setcc byte for L (0x92 setb, 0x9C setl)
x64_flags_zl:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0x94
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x0F
  CALL @x64_8
  ADD r2,r9,r0
  CALL @x64_8
  MOVI r2,0xC1
  CALL @x64_8
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0xB6
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0xB6
  CALL @x64_8
  MOVI r2,0xC9
  CALL @x64_8
  MOVI r2,0x01
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  MOVI r2,0x01
  CALL @x64_8
  MOVI r2,0xCA
  CALL @x64_8
  MOVI r2,0xB8
  CALL @x64_8
  MOVI r2,1
  CALL @x64_32
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xD1
  CALL @x64_8
  MOVI r2,0xD3
  CALL @x64_8
  MOVI r2,0xE0
  CALL @x64_8
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_FLAGM
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; Z-only result (L=0)
x64_flags_z:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0x94
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0xB6
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  MOVI r2,0x01
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  MOVI r2,0xB8
  CALL @x64_8
  MOVI r2,1
  CALL @x64_32
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xD1
  CALL @x64_8
  MOVI r2,0xD3
  CALL @x64_8
  MOVI r2,0xE0
  CALL @x64_8
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_FLAGM
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; MOVHI d,imm = (R[d] & 0xFFFF) | (imm<<16)
x64_movhi:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x64_load_eax_r
  MOVI r2,0x25
  CALL @x64_8
  MOVI r2,0xFF
  CALL @x64_8
  MOVI r2,0xFF
  CALL @x64_8
  MOVI r2,0x00
  CALL @x64_8
  MOVI r2,0x00
  CALL @x64_8
  MOVI r2,0x0D
  CALL @x64_8
  SHL r2,r7,16
  CALL @x64_32
  CALL @x64_store_eax_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ADDI d,a,imm
x64_addi:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x64_8
  SHL r2,r7,16
  SAR r2,r2,16
  CALL @x64_32
  CALL @x64_store_eax_r
  MOVI r9,0x92
  CALL @x64_flags_zl
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; shifts: d,a,imm
x64_shl:
  MOVI r11,0xE0
  JMP @x64_shift
x64_shr:
  MOVI r11,0xE8
  JMP @x64_shift
x64_sar:
  MOVI r11,0xF8
x64_shift:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r10,r0
  MOVI r2,0xC1
  CALL @x64_8
  ADD r2,r11,r0
  CALL @x64_8
  ADD r2,r7,r0
  CALL @x64_8
  CALL @x64_store_eax_r
  CALL @x64_flags_z
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; CMP/CMPS: a,b; r9=setcc for L
x64_cmp:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r8,r0
  CALL @x64_load_ecx_r
  MOVI r2,0x39
  CALL @x64_8
  MOVI r2,0xC8
  CALL @x64_8
  CALL @x64_flags_zl
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
