; x86_64.nas - NaN-native x86-64 encoders for the 64-bit core.
; ABI: r13=1, r14=stack, r0=0, r1=output byte pointer.
; Args: r5=d r6=a r7=imm/target r8=b.
; The emitted code uses the 64-bit core's fixed guest register file at
; 0x50000 and XPC at 0x50800, with SIB absolute disp32 addressing.

.equ X64_R   0x50000
.equ X64_XPC 0x50800
.equ X64_FLAGM 0x50400
.equ X64_MASK 0x50404
.equ X64_G 0x200000
.equ X64_HALT 0x50C00

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


; target r7, fall r8, predicate n r9.
; test ecx,n; mov eax,target; mov edx,fall; cmovz eax,edx;
; mov [XPC],eax; ret
x64_jmp_cond:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x0C
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_FLAGM
  CALL @x64_32
  MOVI r2,0xF7
  CALL @x64_8
  MOVI r2,0xC1
  CALL @x64_8
  ADD r2,r9,r0
  CALL @x64_32
  MOVI r2,0xB8
  CALL @x64_8
  ADD r2,r7,r0
  CALL @x64_32
  MOVI r2,0xBA
  CALL @x64_8
  ADD r2,r8,r0
  CALL @x64_32
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0x44
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_XPC
  CALL @x64_32
  MOVI r2,0xC3
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET


; 89 0C 25 addr : R[d] = ecx
x64_store_ecx_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
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

; eax = ((R[a]+imm) & MASK)<<3 + G
x64_addr_word:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x64_8
  ADD r2,r7,r0
  CALL @x64_32
  MOVI r2,0x23
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_MASK
  CALL @x64_32
  MOVI r2,0xC1
  CALL @x64_8
  MOVI r2,0xE0
  CALL @x64_8
  MOVI r2,0x03
  CALL @x64_8
  MOVI r2,0x05
  CALL @x64_8
  LA r2,#X64_G
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; LD d,a,imm
x64_ld:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x64_addr_word
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x48
  CALL @x64_8
  MOVI r2,0x02
  CALL @x64_8
  CALL @x64_store_ecx_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ST d,a,imm
x64_st:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x64_addr_word
  ADD r8,r5,r0
  CALL @x64_load_ecx_r
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x48
  CALL @x64_8
  MOVI r2,0x02
  CALL @x64_8
  MOVI r2,0x66
  CALL @x64_8
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x00
  CALL @x64_8
  MOVI r2,0xF8
  CALL @x64_8
  MOVI r2,0x7F
  CALL @x64_8
  MOVI r2,0x66
  CALL @x64_8
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x40
  CALL @x64_8
  MOVI r2,0x06
  CALL @x64_8
  MOVI r2,0xF8
  CALL @x64_8
  MOVI r2,0x7F
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET


; LDB d,a,imm: byte address R[a]+imm; word=(addr>>2)&M; byte=addr&3
x64_ldb:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x64_8
  ADD r2,r7,r0
  CALL @x64_32
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x83
  CALL @x64_8
  MOVI r2,0xE2
  CALL @x64_8
  MOVI r2,0x03
  CALL @x64_8
  MOVI r2,0xC1
  CALL @x64_8
  MOVI r2,0xE8
  CALL @x64_8
  MOVI r2,0x02
  CALL @x64_8
  MOVI r2,0x23
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_MASK
  CALL @x64_32
  MOVI r2,0xC1
  CALL @x64_8
  MOVI r2,0xE0
  CALL @x64_8
  MOVI r2,0x03
  CALL @x64_8
  MOVI r2,0x05
  CALL @x64_8
  LA r2,#X64_G
  CALL @x64_32
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0xB6
  CALL @x64_8
  MOVI r2,0x4C
  CALL @x64_8
  MOVI r2,0x10
  CALL @x64_8
  MOVI r2,0x02
  CALL @x64_8
  CALL @x64_store_ecx_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; STB d,a,imm
x64_stb:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x64_8
  ADD r2,r7,r0
  CALL @x64_32
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x83
  CALL @x64_8
  MOVI r2,0xE2
  CALL @x64_8
  MOVI r2,0x03
  CALL @x64_8
  MOVI r2,0xC1
  CALL @x64_8
  MOVI r2,0xE8
  CALL @x64_8
  MOVI r2,0x02
  CALL @x64_8
  MOVI r2,0x23
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_MASK
  CALL @x64_32
  MOVI r2,0xC1
  CALL @x64_8
  MOVI r2,0xE0
  CALL @x64_8
  MOVI r2,0x03
  CALL @x64_8
  MOVI r2,0x05
  CALL @x64_8
  LA r2,#X64_G
  CALL @x64_32
  CALL @x64_load_ecx_r
  MOVI r2,0x88
  CALL @x64_8
  MOVI r2,0x4C
  CALL @x64_8
  MOVI r2,0x10
  CALL @x64_8
  MOVI r2,0x02
  CALL @x64_8
  MOVI r2,0x66
  CALL @x64_8
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x00
  CALL @x64_8
  MOVI r2,0xF8
  CALL @x64_8
  MOVI r2,0x7F
  CALL @x64_8
  MOVI r2,0x66
  CALL @x64_8
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x40
  CALL @x64_8
  MOVI r2,0x06
  CALL @x64_8
  MOVI r2,0xF8
  CALL @x64_8
  MOVI r2,0x7F
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET


; HALT: set the native stop flag at 0x50C00 and return
x64_halt:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_HALT
  CALL @x64_32
  MOVI r2,1
  CALL @x64_32
  MOVI r2,0xC3
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET


; jump to guest register R[a]; r9 = a.  Emits:
;   8B 04 25 R[a] ; 89 04 25 XPC ; C3
x64_jump_reg:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r9,r0
  CALL @x64_addr
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_XPC
  CALL @x64_32
  MOVI r2,0xC3
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; CALL: R15 = next; XPC = target; RET
; r7 = target, r8 = next
x64_call:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r5,15
  ADD r7,r8,r0
  CALL @x64_movi
  ADD r7,r10,r0
  CALL @x64_set_xpc
  CALL @x64_ret
  SUB r14,r14,r13
  LD r15,r14,0
  RET


; 89 14 25 addr : R[d] = edx
x64_store_edx_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x14
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r5,r0
  CALL @x64_addr
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 3C 25 addr : R[d] = edi
x64_store_edi_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x3C
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r5,r0
  CALL @x64_addr
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; BOOL terms over eax=A, ecx=B, accumulating in edi.
x64_bool_t1:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x09
  CALL @x64_8
  MOVI r2,0xCA
  CALL @x64_8
  MOVI r2,0xF7
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  MOVI r2,0x09
  CALL @x64_8
  MOVI r2,0xD7
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

x64_bool_t2:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0xF7
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  MOVI r2,0x21
  CALL @x64_8
  MOVI r2,0xCA
  CALL @x64_8
  MOVI r2,0x09
  CALL @x64_8
  MOVI r2,0xD7
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

x64_bool_t3:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xCA
  CALL @x64_8
  MOVI r2,0xF7
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  MOVI r2,0x21
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x09
  CALL @x64_8
  MOVI r2,0xD7
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

x64_bool_t4:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xC2
  CALL @x64_8
  MOVI r2,0x21
  CALL @x64_8
  MOVI r2,0xCA
  CALL @x64_8
  MOVI r2,0x09
  CALL @x64_8
  MOVI r2,0xD7
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; BOOL d,a,b with n = predicate nibble.
; r5=d r6=a r8=b r9=n
x64_bool:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r8,r0
  CALL @x64_load_ecx_r
  MOVI r2,0x31
  CALL @x64_8
  MOVI r2,0xFF
  CALL @x64_8
  MOVI r11,1
  BOOL.8 r11,r9,r11
  CMP r11,r0
  JMP[EQ] @x64_bool_t1_skip
  CALL @x64_bool_t1
x64_bool_t1_skip:
  MOVI r11,2
  BOOL.8 r11,r9,r11
  CMP r11,r0
  JMP[EQ] @x64_bool_t2_skip
  CALL @x64_bool_t2
x64_bool_t2_skip:
  MOVI r11,4
  BOOL.8 r11,r9,r11
  CMP r11,r0
  JMP[EQ] @x64_bool_t3_skip
  CALL @x64_bool_t3
x64_bool_t3_skip:
  MOVI r11,8
  BOOL.8 r11,r9,r11
  CMP r11,r0
  JMP[EQ] @x64_bool_t4_skip
  CALL @x64_bool_t4
x64_bool_t4_skip:
  ADD r5,r10,r0
  CALL @x64_store_edi_r
  MOVI r2,0x85
  CALL @x64_8
  MOVI r2,0xFF
  CALL @x64_8
  CALL @x64_flags_z
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; MUL/MULH/MULHU: r5=d r6=a r8=b; r9 = 0x24 (MUL) or 0x2C (IMUL)
x64_mul_common:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r11,r9,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  MOVI r2,0xF7
  CALL @x64_8
  ADD r2,r11,r0
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r8,r0
  CALL @x64_addr
  ADD r5,r10,r0
  CALL @x64_store_eax_r
  MOVI r2,0x85
  CALL @x64_8
  MOVI r2,0xC0
  CALL @x64_8
  CALL @x64_flags_z
  SUB r14,r14,r13
  LD r15,r14,0
  RET

x64_mul:
  MOVI r9,0x24
  JMP @x64_mul_common
x64_mulh:
  MOVI r9,0x2C
  JMP @x64_mul_high
x64_mulhu:
  MOVI r9,0x24
x64_mul_high:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r11,r9,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  MOVI r2,0xF7
  CALL @x64_8
  ADD r2,r11,r0
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r8,r0
  CALL @x64_addr
  ADD r5,r10,r0
  CALL @x64_store_edx_r
  MOVI r2,0x85
  CALL @x64_8
  MOVI r2,0xD2
  CALL @x64_8
  CALL @x64_flags_z
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

; emit r3 bytes from r2 (LSB first)
x64_emitn:
  ST r15,r14,0
  ADD r14,r14,r13
x64_emitn_loop:
  CMP r3,r0
  JMP[EQ] @x64_emitn_done
  STB r2,r1,0
  SHR r2,r2,8
  ADDI r1,r1,1
  SUB r3,r3,r13
  JMP @x64_emitn_loop
x64_emitn_done:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; DIV/MOD/DIVU/MODU: r5=d r6=a r8=b r9=opcode.
; Branchless special cases: B==0 and B==-1 use divisor 1 and select the
; architectural result afterwards.  k=3 when B==0.
x64_divmod:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r8,r0
  CALL @x64_load_ecx_r
  MOVI r2,0xC689
  MOVHI r2,0
  MOVI r3,2
  CALL @x64_emitn
  MOVI r2,0xCF89
  MOVHI r2,0
  MOVI r3,2
  CALL @x64_emitn
  MOVI r2,0x8941
  MOVHI r2,0x00C8
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0xBA41
  MOVHI r2,0x0001
  MOVI r3,6
  CALL @x64_emitn
  MOVI r2,0xF983
  MOVHI r2,0
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F45
  MOVHI r2,0xC244
  MOVI r3,4
  CALL @x64_emitn
  MOVI r11,0x23
  CMP r9,r11
  JMP[EQ] @x64_div_signed
  MOVI r11,0x24
  CMP r9,r11
  JMP[EQ] @x64_div_signed
  JMP @x64_div_unsigned
x64_div_signed:
  MOVI r2,0xF983
  MOVHI r2,0x00FF
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F45
  MOVHI r2,0xC244
  MOVI r3,4
  CALL @x64_emitn
  MOVI r2,0x0099
  MOVHI r2,0
  MOVI r3,1
  CALL @x64_emitn
  MOVI r2,0xF741
  MOVHI r2,0x00F8
  MOVI r3,3
  CALL @x64_emitn
  JMP @x64_div_select
x64_div_unsigned:
  MOVI r2,0xD231
  MOVHI r2,0
  MOVI r3,2
  CALL @x64_emitn
  MOVI r2,0xF741
  MOVHI r2,0x00F0
  MOVI r3,3
  CALL @x64_emitn
x64_div_select:
  MOVI r11,0x23
  CMP r9,r11
  JMP[EQ] @x64_div_q
  MOVI r11,0x25
  CMP r9,r11
  JMP[EQ] @x64_div_q
  MOVI r2,0x8941
  MOVHI r2,0x00D1
  MOVI r3,3
  CALL @x64_emitn
  JMP @x64_div_special
x64_div_q:
  MOVI r2,0x8941
  MOVHI r2,0x00C1
  MOVI r3,3
  CALL @x64_emitn
x64_div_special:
  MOVI r2,0x8941
  MOVHI r2,0x00F3
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0xF741
  MOVHI r2,0x00DB
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x3145
  MOVHI r2,0x00D2
  MOVI r3,3
  CALL @x64_emitn
  MOVI r11,0x23
  CMP r9,r11
  JMP[NE] @x64_div_trymod
  MOVI r2,0xFF83
  MOVHI r2,0
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F45
  MOVHI r2,0xCA44
  MOVI r3,4
  CALL @x64_emitn
  MOVI r2,0xF983
  MOVHI r2,0x00FF
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F45
  MOVHI r2,0xCB44
  MOVI r3,4
  CALL @x64_emitn
  JMP @x64_div_store
x64_div_trymod:
  MOVI r11,0x24
  CMP r9,r11
  JMP[NE] @x64_div_trydivu
  MOVI r2,0xFF83
  MOVHI r2,0x00FF
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F45
  MOVHI r2,0xCB44
  MOVI r3,4
  CALL @x64_emitn
  MOVI r2,0xFF83
  MOVHI r2,0
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F44
  MOVHI r2,0xCE44
  MOVI r3,4
  CALL @x64_emitn
  JMP @x64_div_store
x64_div_trydivu:
  MOVI r11,0x25
  CMP r9,r11
  JMP[NE] @x64_div_modu
  MOVI r2,0xFF83
  MOVHI r2,0
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F45
  MOVHI r2,0xCA44
  MOVI r3,4
  CALL @x64_emitn
  JMP @x64_div_store
x64_div_modu:
  MOVI r2,0xFF83
  MOVHI r2,0
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0F44
  MOVHI r2,0xCE44
  MOVI r3,4
  CALL @x64_emitn
x64_div_store:
  MOVI r2,0x8944
  MOVHI r2,0x250C
  MOVI r3,4
  CALL @x64_emitn
  ADD r6,r10,r0
  CALL @x64_addr
  MOVI r2,0x8545
  MOVHI r2,0x00C9
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x940F
  MOVHI r2,0x00C2
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0xB60F
  MOVHI r2,0x00D2
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0xD201
  MOVHI r2,0
  MOVI r3,2
  CALL @x64_emitn
  MOVI r2,0x01B8
  MOVHI r2,0
  MOVI r3,5
  CALL @x64_emitn
  MOVI r2,0xD189
  MOVHI r2,0
  MOVI r3,2
  CALL @x64_emitn
  MOVI r2,0xE0D3
  MOVHI r2,0
  MOVI r3,2
  CALL @x64_emitn
  MOVI r2,0xFF83
  MOVHI r2,0
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x08B9
  MOVHI r2,0
  MOVI r3,5
  CALL @x64_emitn
  MOVI r2,0x440F
  MOVHI r2,0x00C1
  MOVI r3,3
  CALL @x64_emitn
  MOVI r2,0x0489
  MOVHI r2,0x0025
  MOVI r3,3
  CALL @x64_emitn
  LA r2,#X64_FLAGM
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET
