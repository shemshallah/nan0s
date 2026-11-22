; x86.nas - NaN-native x86-32 encoders for the block translator.
; ABI: r13=1, r14=translation stack, r0=0.  r1 is the output byte pointer
; and is advanced.  Arguments: r5=d r6=a r7=imm/target r8=b r9=predicate
; or setcc opcode.  Leaf emitters x8/x32 preserve r5-r9.  Every non-leaf
; encoder saves r15 at [r14] because CALL overwrites the link register.
;
; The emitted code uses the native core's fixed map:
;   R=0x8000 (16 guest regs), FLAGM=0x8040 (1<<k), MASKM=0x80C0,
;   XPC=0x80D4, RAW gate 0xF000..0xFFFF -> RAW=0x01000000, G=0x200000.
; FLAGM is the guest flag mask: a branch predicate n is true iff
; (FLAGM & n) != 0.  CMP/ADD/SUB/shift emit code that rewrites it.
; If a translated instruction needs a runtime path the block cannot encode
; as a straight line, the block must fail translation instead.

.equ X_R     0x8000
.equ X_FLAGM 0x8040
.equ X_MASK  0x80C0
.equ X_XPC   0x80D4
.equ X_SCR   0x80E8
.equ X_RAWG  0xF000
.equ X_RAW   0x01000000
.equ X_G     0x200000

; ---- leaf emitters -------------------------------------------------------
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

; x_addr_r: r6=reg; emit u32 address of R[reg]; clobbers r3,r4; leaf.
x_addr_r:
  SHL r3,r6,2
  LA r4,#X_R
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

; ---- guest-register load/store prefixes ---------------------------------
; 8B 05 addr -> eax = R[d]
x_mov_eax_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  ADD r6,r5,r0
  CALL @x_addr_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 8B 0D addr -> ecx = R[reg in r8]
x_mov_ecx_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x0D
  CALL @x8
  ADD r6,r8,r0
  CALL @x_addr_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 05 addr -> R[d] = eax
x_st_eax_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  ADD r6,r5,r0
  CALL @x_addr_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 0D addr -> R[d] = ecx
x_st_ecx_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0x0D
  CALL @x8
  ADD r6,r5,r0
  CALL @x_addr_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 1D addr -> R[d] = ebx
x_st_ebx_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0x1D
  CALL @x8
  ADD r6,r5,r0
  CALL @x_addr_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---- flag mask -----------------------------------------------------------
; FLAGM = 1 << (2*ZF + L).  r9 = setcc byte for L (0x92 setb, 0x9C setl).
x_flags_zl:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0x94
  CALL @x8
  MOVI r2,0xC2           ; sete dl
  CALL @x8
  MOVI r2,0x0F
  CALL @x8
  ADD r2,r9,r0
  CALL @x8
  MOVI r2,0xC1           ; setcc cl
  CALL @x8
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0xB6
  CALL @x8
  MOVI r2,0xD2           ; movzx edx,dl
  CALL @x8
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0xB6
  CALL @x8
  MOVI r2,0xC9           ; movzx ecx,cl
  CALL @x8
  MOVI r2,0x01
  CALL @x8
  MOVI r2,0xD2           ; add edx,edx
  CALL @x8
  MOVI r2,0x01
  CALL @x8
  MOVI r2,0xCA           ; add edx,ecx
  CALL @x8
  MOVI r2,0xB8
  CALL @x8
  MOVI r2,1
  CALL @x32              ; mov eax,1
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xD1           ; mov ecx,edx
  CALL @x8
  MOVI r2,0xD3
  CALL @x8
  MOVI r2,0xE0           ; shl eax,cl
  CALL @x8
  MOVI r2,0xA3
  CALL @x8
  MOVI r2,#X_FLAGM
  CALL @x32              ; mov [FLAGM],eax
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; Z-only result (L=0): same but with CL=0.
x_flags_z:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0x94
  CALL @x8
  MOVI r2,0xC2           ; sete dl
  CALL @x8
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0xB6
  CALL @x8
  MOVI r2,0xD2           ; movzx edx,dl
  CALL @x8
  MOVI r2,0x01
  CALL @x8
  MOVI r2,0xD2           ; add edx,edx
  CALL @x8
  MOVI r2,0xB8
  CALL @x8
  MOVI r2,1
  CALL @x32
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xD1
  CALL @x8
  MOVI r2,0xD3
  CALL @x8
  MOVI r2,0xE0
  CALL @x8
  MOVI r2,0xA3
  CALL @x8
  MOVI r2,#X_FLAGM
  CALL @x32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---- data movement -------------------------------------------------------
; C7 05 <R+d> <imm32>
x86_movi_mem:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xC7
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  ADD r6,r5,r0
  CALL @x_addr_r
  ADD r2,r7,r0
  CALL @x32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; eax=R[d]; and eax,0xFFFF; or eax,imm<<16; R[d]=eax
x86_movhi:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x_mov_eax_r
  MOVI r2,0x25
  CALL @x8
  MOVI r2,0xFFFF
  CALL @x32
  ; emit 0D <imm32>
  MOVI r2,0x0D
  CALL @x8
  SHL r2,r7,16
  CALL @x32
  CALL @x_st_eax_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---- integer ALU ---------------------------------------------------------
; eax=R[a]; ecx=R[b]; add/sub; R[d]=eax; flags
x86_add:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  ADD r5,r10,r0
  CALL @x_mov_ecx_r
  MOVI r2,0x01
  CALL @x8
  MOVI r2,0xC8
  CALL @x8
  CALL @x_st_eax_r
  MOVI r9,0x92
  CALL @x_flags_zl
  SUB r14,r14,r13
  LD r15,r14,0
  RET

x86_sub:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  ADD r5,r10,r0
  CALL @x_mov_ecx_r
  MOVI r2,0x29
  CALL @x8
  MOVI r2,0xC8
  CALL @x8
  CALL @x_st_eax_r
  MOVI r9,0x92
  CALL @x_flags_zl
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; add eax,sext(imm); flags ZL
x86_addi:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x8
  SHL r2,r7,16
  SAR r2,r2,16
  CALL @x32
  CALL @x_st_eax_r
  MOVI r9,0x92
  CALL @x_flags_zl
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; shifts: eax=R[a]; shift by imm8; R[d]=eax; flags Z only
x86_shl:
  MOVI r11,0xE0
  JMP @x_shift
x86_shr:
  MOVI r11,0xE8
  JMP @x_shift
x86_sar:
  MOVI r11,0xF8
x_shift:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  ADD r5,r10,r0
  MOVI r2,0xC1
  CALL @x8
  ADD r2,r11,r0
  CALL @x8
  ADD r2,r7,r0
  CALL @x8
  CALL @x_st_eax_r
  CALL @x_flags_z
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; cmp eax,ecx; r9=setcc for L
x86_cmp:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  CALL @x_mov_ecx_r
  MOVI r2,0x39
  CALL @x8
  MOVI r2,0xC8
  CALL @x8
  CALL @x_flags_zl
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---- memory --------------------------------------------------------------
; eax = R[a] + imm; eax = (eax & M)<<3 + G
x_addr_word:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x8
  ADD r2,r7,r0
  CALL @x32
  MOVI r2,0x23
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  MOVI r2,#X_MASK
  CALL @x32
  MOVI r2,0xC1
  CALL @x8
  MOVI r2,0xE0
  CALL @x8
  MOVI r2,0x03
  CALL @x8
  MOVI r2,0x05
  CALL @x8
  LA r2,#X_G
  CALL @x32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; LD d,a,imm
x86_ld:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x_addr_word
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x48
  CALL @x8
  MOVI r2,0x02
  CALL @x8
  CALL @x_st_ecx_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ST d,a,imm: store payload + force both heads to 0x7FF8 (n=10)
x86_st:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x_addr_word
  ADD r8,r5,r0
  CALL @x_mov_ecx_r
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0x48
  CALL @x8
  MOVI r2,0x02
  CALL @x8
  MOVI r2,0x66
  CALL @x8
  MOVI r2,0xC7
  CALL @x8
  MOVI r2,0x00
  CALL @x8
  MOVI r2,0xF8
  CALL @x8
  MOVI r2,0x7F
  CALL @x8
  MOVI r2,0x66
  CALL @x8
  MOVI r2,0xC7
  CALL @x8
  MOVI r2,0x40
  CALL @x8
  MOVI r2,0x06
  CALL @x8
  MOVI r2,0xF8
  CALL @x8
  MOVI r2,0x7F
  CALL @x8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; LDB d,a,imm: byte address A+imm, RAW window selectable without branches.
x86_ldb:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x8
  ADD r2,r7,r0
  CALL @x32
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xC2           ; mov edx,eax
  CALL @x8
  MOVI r2,0x83
  CALL @x8
  MOVI r2,0xE2
  CALL @x8
  MOVI r2,0x03           ; and edx,3
  CALL @x8
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xC6           ; mov esi,eax
  CALL @x8
  MOVI r2,0xC1
  CALL @x8
  MOVI r2,0xEE
  CALL @x8
  MOVI r2,0x02           ; shr esi,2
  CALL @x8
  MOVI r2,0x23
  CALL @x8
  MOVI r2,0x35
  CALL @x8
  MOVI r2,#X_MASK
  CALL @x32              ; and esi,[MASK]
  MOVI r2,0xC1
  CALL @x8
  MOVI r2,0xE6
  CALL @x8
  MOVI r2,0x03           ; shl esi,3
  CALL @x8
  MOVI r2,0x81
  CALL @x8
  MOVI r2,0xC6
  CALL @x8
  LA r2,#X_G
  CALL @x32              ; add esi,G
  MOVI r2,0x8D
  CALL @x8
  MOVI r2,0x4C
  CALL @x8
  MOVI r2,0x16
  CALL @x8
  MOVI r2,0x02           ; lea ecx,[esi+edx+2]
  CALL @x8
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xC5           ; mov ebp,eax
  CALL @x8
  MOVI r2,0x81
  CALL @x8
  MOVI r2,0xED
  CALL @x8
  MOVI r2,#X_RAWG
  CALL @x32              ; sub ebp,RAWG
  MOVI r2,0x81
  CALL @x8
  MOVI r2,0xFD
  CALL @x8
  MOVI r2,0x00
  CALL @x8
  MOVI r2,0x10
  CALL @x8
  MOVI r2,0x00
  CALL @x8
  MOVI r2,0x00           ; cmp ebp,0x1000
  CALL @x8
  MOVI r2,0x8D
  CALL @x8
  MOVI r2,0xAD
  CALL @x8
  LA r2,#X_RAW
  CALL @x32              ; lea ebp,[ebp+RAW]
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0x42
  CALL @x8
  MOVI r2,0xCD           ; cmovb ecx,ebp
  CALL @x8
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0xB6
  CALL @x8
  MOVI r2,0x19           ; movzx ebx,[ecx]
  CALL @x8
  CALL @x_st_ebx_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; STB d,a,imm: byte store, RAW-capable; heads forced unless in RAW window.
x86_stb:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  ADD r5,r10,r0
  MOVI r2,0x05
  CALL @x8
  ADD r2,r7,r0
  CALL @x32
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xC2
  CALL @x8
  MOVI r2,0x83
  CALL @x8
  MOVI r2,0xE2
  CALL @x8
  MOVI r2,0x03
  CALL @x8
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xC6
  CALL @x8
  MOVI r2,0xC1
  CALL @x8
  MOVI r2,0xEE
  CALL @x8
  MOVI r2,0x02           ; shr esi,2
  CALL @x8
  MOVI r2,0x23
  CALL @x8
  MOVI r2,0x35
  CALL @x8
  MOVI r2,#X_MASK
  CALL @x32
  MOVI r2,0xC1
  CALL @x8
  MOVI r2,0xE6
  CALL @x8
  MOVI r2,0x03
  CALL @x8
  MOVI r2,0x81
  CALL @x8
  MOVI r2,0xC6
  CALL @x8
  LA r2,#X_G
  CALL @x32
  MOVI r2,0x8D
  CALL @x8
  MOVI r2,0x4C
  CALL @x8
  MOVI r2,0x16
  CALL @x8
  MOVI r2,0x02
  CALL @x8
  MOVI r2,0x89
  CALL @x8
  MOVI r2,0xC5           ; mov ebp,eax
  CALL @x8
  MOVI r2,0x81
  CALL @x8
  MOVI r2,0xED
  CALL @x8
  MOVI r2,#X_RAWG
  CALL @x32
  MOVI r2,0x81
  CALL @x8
  MOVI r2,0xFD
  CALL @x8
  MOVI r2,0x00
  CALL @x8
  MOVI r2,0x10
  CALL @x8
  MOVI r2,0x00
  CALL @x8
  MOVI r2,0x00
  CALL @x8
  MOVI r2,0x8D
  CALL @x8
  MOVI r2,0xAD
  CALL @x8
  LA r2,#X_RAW
  CALL @x32
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0x42
  CALL @x8
  MOVI r2,0xCD           ; cmovb ecx,ebp
  CALL @x8
  MOVI r2,0xBD
  CALL @x8
  MOVI r2,#X_SCR
  CALL @x32              ; mov ebp,X_SCR
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0x43
  CALL @x8
  MOVI r2,0xEE           ; cmovae ebp,esi
  CALL @x8
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x1D
  CALL @x8
  ADD r6,r5,r0
  CALL @x_addr_r         ; mov ebx,[R+d]
  MOVI r2,0x88
  CALL @x8
  MOVI r2,0x19           ; mov [ecx],bl
  CALL @x8
  MOVI r2,0x66
  CALL @x8
  MOVI r2,0xC7
  CALL @x8
  MOVI r2,0x45
  CALL @x8
  MOVI r2,0x00
  CALL @x8
  MOVI r2,0xF8
  CALL @x8
  MOVI r2,0x7F           ; mov word [ebp],0x7FF8
  CALL @x8
  MOVI r2,0x66
  CALL @x8
  MOVI r2,0xC7
  CALL @x8
  MOVI r2,0x45
  CALL @x8
  MOVI r2,0x06
  CALL @x8
  MOVI r2,0xF8
  CALL @x8
  MOVI r2,0x7F           ; mov word [ebp+6],0x7FF8
  CALL @x8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---- branches ------------------------------------------------------------
; mov eax,target; mov [XPC],eax; ret
x86_jmp:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xB8
  CALL @x8
  ADD r2,r7,r0
  CALL @x32
  MOVI r2,0xA3
  CALL @x8
  MOVI r2,#X_XPC
  CALL @x32
  MOVI r2,0xC3
  CALL @x8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; conditional: take iff (FLAGM & n) != 0.  target r7, fallthrough r8, n r9.
x86_jmp_cond:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x8
  MOVI r2,0x0D
  CALL @x8
  MOVI r2,#X_FLAGM
  CALL @x32
  MOVI r2,0xF7
  CALL @x8
  MOVI r2,0xC1
  CALL @x8
  ADD r2,r9,r0
  CALL @x32              ; test ecx,n
  MOVI r2,0xB8
  CALL @x8
  ADD r2,r7,r0
  CALL @x32              ; mov eax,target
  MOVI r2,0xBA
  CALL @x8
  ADD r2,r8,r0
  CALL @x32              ; mov edx,fall
  MOVI r2,0x0F
  CALL @x8
  MOVI r2,0x44
  CALL @x8
  MOVI r2,0xC2           ; cmovz eax,edx
  CALL @x8
  MOVI r2,0xA3
  CALL @x8
  MOVI r2,#X_XPC
  CALL @x32
  MOVI r2,0xC3
  CALL @x8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; pc = R[a]
x86_jmpr:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r6,r0
  CALL @x_mov_eax_r
  MOVI r2,0xA3
  CALL @x8
  MOVI r2,#X_XPC
  CALL @x32
  MOVI r2,0xC3
  CALL @x8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; pc = r15
x86_ret:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r5,15
  CALL @x_mov_eax_r
  MOVI r2,0xA3
  CALL @x8
  MOVI r2,#X_XPC
  CALL @x32
  MOVI r2,0xC3
  CALL @x8
  SUB r14,r14,r13
  LD r15,r14,0
  RET
