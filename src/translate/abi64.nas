; abi64.nas - SVC/SVCRET frame emission for the NaN-coded x86-64 core.
;
; Frame: 24 guest words at the word address in control port 0x4E01.
;   0..15 r0..r15       16 pc after SVC / resume pc
;   17 flags (k)        18 0
;   19 cause (0 SVC)    20 SVC number
;   21 return/status    22 guest SP
;   23 0
;
; The emitted code reads the control ports through the native port helper:
;   0x18000 INL, 0x18100 OUTL.
; It uses only the native scratch registers; the architectural register file
; remains the 16 dwords at X64_R.


.equ X64_KIN     0x50E00
.equ X64_KENTRY  0x50E04
.equ X64_KSTACK  0x50E08
.equ X64_FRAME   0x50E0C
.equ X64_SVCNO   0x50E10
.equ X64_NEXT    0x50E14

; ---- small emitters ------------------------------------------------------
; A1 addr32 : eax = [addr]   (r2=addr)
x64_load_eax_abs:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r2,r0
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r2,r5,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; A3 addr32 : [addr] = eax   (r2=addr)
x64_store_abs_eax:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r2,r0
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r2,r5,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 0D addr32 : [addr] = ecx   (r2=addr)
x64_store_abs_ecx:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r2,r0
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x0C
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r2,r5,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; C7 05 addr32 imm32 : [addr] = imm   (r2=addr r3=imm)
x64_store_abs_imm32:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r2,r0
  ADD r6,r3,r0
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r2,r5,r0
  CALL @x64_32
  ADD r2,r6,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 87 disp32 : [edi+disp] = eax   (r3=disp)
x64_store_edi_eax_disp:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r6,r3,r0
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x87
  CALL @x64_8
  ADD r2,r6,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 8B 87 disp32 : eax = [edi+disp]   (r3=disp)
x64_load_eax_edi_disp:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r6,r3,r0
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x87
  CALL @x64_8
  ADD r2,r6,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 8F disp32 : [edi+disp] = ecx   (r3=disp)
x64_store_edi_ecx_disp:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r6,r3,r0
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0x8F
  CALL @x64_8
  ADD r2,r6,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; C7 87 disp32 imm32 : [edi+disp] = imm   (r3=disp r4=imm)
x64_store_edi_imm32_disp:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r3,r0
  ADD r6,r4,r0
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x87
  CALL @x64_8
  ADD r2,r5,r0
  CALL @x64_32
  ADD r2,r6,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; C1 E0 03 : shl eax,3
x64_shl_eax_3:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xC1
  CALL @x64_8
  MOVI r2,0xE0
  CALL @x64_8
  MOVI r2,0x03
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 89 C7 : edi = eax
x64_mov_edi_eax:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x89
  CALL @x64_8
  MOVI r2,0xC7
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 05 imm32 : eax += imm   (r2=imm)
x64_add_eax_imm32:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r2,r0
  MOVI r2,0x05
  CALL @x64_8
  ADD r2,r5,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 85 C0 : test eax,eax
x64_test_eax_eax:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x85
  CALL @x64_8
  MOVI r2,0xC0
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 3D FF FF FF FF : cmp eax,-1
x64_cmp_eax_ffff:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x3D
  CALL @x64_8
  MOVI r2,0xFF
  CALL @x64_8
  CALL @x64_8
  CALL @x64_8
  MOVI r2,0xFF
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; B8 01 00 00 00 : eax = 1
x64_mov_eax_1:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xB8
  CALL @x64_8
  MOVI r2,1
  CALL @x64_8
  MOVI r2,0
  CALL @x64_8
  CALL @x64_8
  MOVI r2,0
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 0F BC C8 : bsf ecx,eax
x64_bsf_ecx_eax:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x0F
  CALL @x64_8
  MOVI r2,0xBC
  CALL @x64_8
  MOVI r2,0xC8
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 83 E0 03 : and eax,3
x64_and_eax_3:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x83
  CALL @x64_8
  MOVI r2,0xE0
  CALL @x64_8
  MOVI r2,0x03
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; B9 01 00 00 00 : ecx = 1
x64_mov_ecx_1:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xB9
  CALL @x64_8
  MOVI r2,1
  CALL @x64_8
  MOVI r2,0
  CALL @x64_8
  CALL @x64_8
  MOVI r2,0
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; D3 E1 : shl ecx,cl
x64_shl_ecx_cl:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xD3
  CALL @x64_8
  MOVI r2,0xE1
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; 21-byte trap: TRAP=0x4F; HALT=1; RET
x64_trap_only:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r5,r0,@ABI_TRAPCODE
  LA r2,#X64_TRAP
  LD r3,r0,@ABI_TRAPCODE
  CALL @x64_store_abs_imm32
  LA r2,#X64_HALT
  MOVI r3,1
  CALL @x64_store_abs_imm32
  CALL @x64_ret
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; BB 00 81 01 00 FF D3 : call OUTL helper at 0x18100
x64_port_helper_out:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0xBB
  CALL @x64_8
  LA r2,0x18100
  CALL @x64_32
  MOVI r2,0xFF
  CALL @x64_8
  MOVI r2,0xD3
  CALL @x64_8
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; BA port32 ; call 0x18000 : eax = inl(port)
x64_port_in_const:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r2,r0
  MOVI r2,0xBA
  CALL @x64_8
  ADD r2,r5,r0
  CALL @x64_32
  CALL @x64_port_helper
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---- SVC ---------------------------------------------------------------
; x64_svc r7=svc number r8=next pc r1=out -> r1=out
x64_svc:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r7,r0,@ABI_SVCNO
  ST r8,r0,@ABI_NEXT

  ; if in_kernel != 0, trap
  LA r2,#X64_KIN
  CALL @x64_load_eax_abs
  CALL @x64_test_eax_eax
  MOVI r2,0x74                 ; jz over trap
  CALL @x64_8
  MOVI r2,21
  CALL @x64_8
  MOVI r5,0x41
  CALL @x64_trap_only

  ; kentry = inl(0x4E00); unset traps
  MOVI r2,0x4E00
  CALL @x64_port_in_const
  CALL @x64_cmp_eax_ffff
  MOVI r2,0x75                 ; jne over trap
  CALL @x64_8
  MOVI r2,21
  CALL @x64_8
  MOVI r5,0x42
  CALL @x64_trap_only
  LA r2,#X64_KENTRY
  CALL @x64_store_abs_eax

  ; frame = inl(0x4E01); unset traps
  MOVI r2,0x4E01
  CALL @x64_port_in_const
  CALL @x64_cmp_eax_ffff
  MOVI r2,0x75
  CALL @x64_8
  MOVI r2,21
  CALL @x64_8
  MOVI r5,0x43
  CALL @x64_trap_only
  LA r2,#X64_FRAME
  CALL @x64_store_abs_eax

  ; kstack = inl(0x4E03)
  MOVI r2,0x4E03
  CALL @x64_port_in_const
  LA r2,#X64_KSTACK
  CALL @x64_store_abs_eax

  ; edi = G + frame*8
  LA r2,#X64_FRAME
  CALL @x64_load_eax_abs
  CALL @x64_shl_eax_3
  LA r2,0x200000
  CALL @x64_add_eax_imm32
  CALL @x64_mov_edi_eax

  ; save r0..r15, each payload + integer class head
  MOVI r10,0
  MOVI r11,16
abi_svc_rl:
  CMP r10,r11
  JMP[EQ] @abi_svc_rd
  LA r2,#X64_R
  SHL r3,r10,2
  ADD r2,r2,r3
  CALL @x64_load_eax_abs
  SHL r3,r10,3
  ADDI r3,r3,2
  CALL @x64_store_edi_eax_disp
  ADDI r10,r10,1
  JMP @abi_svc_rl
abi_svc_rd:

  ; frame[16] = next pc
  MOVI r3,130
  LD r4,r0,@ABI_NEXT
  CALL @x64_store_edi_imm32_disp

  ; frame[17] = k (bsf of FLAGM, 0 -> 0)
  LA r2,#X64_FLAGM
  CALL @x64_load_eax_abs
  CALL @x64_test_eax_eax
  MOVI r2,0x75
  CALL @x64_8
  MOVI r2,5
  CALL @x64_8
  CALL @x64_mov_eax_1
  CALL @x64_bsf_ecx_eax
  MOVI r3,138
  CALL @x64_store_edi_ecx_disp

  ; frame[18]=0, [19]=cause 0, [20]=svc, [21]=0, [23]=0
  MOVI r3,146
  MOVI r4,0
  CALL @x64_store_edi_imm32_disp
  MOVI r3,154
  MOVI r4,0
  CALL @x64_store_edi_imm32_disp
  MOVI r3,162
  LD r4,r0,@ABI_SVCNO
  CALL @x64_store_edi_imm32_disp
  MOVI r3,170
  MOVI r4,0
  CALL @x64_store_edi_imm32_disp
  MOVI r3,186
  MOVI r4,0
  CALL @x64_store_edi_imm32_disp

  ; frame[22] = saved guest SP (frame[14])
  MOVI r3,114
  CALL @x64_load_eax_edi_disp
  MOVI r3,178
  CALL @x64_store_edi_eax_disp

  ; in_kernel = 1
  LA r2,#X64_KIN
  MOVI r3,1
  CALL @x64_store_abs_imm32

  ; r14 = kstack unless UNSET
  LA r2,#X64_KSTACK
  CALL @x64_load_eax_abs
  CALL @x64_cmp_eax_ffff
  MOVI r2,0x74                 ; je over the store
  CALL @x64_8
  MOVI r2,5
  CALL @x64_8
  LA r2,0x50038
  CALL @x64_store_abs_eax

  ; XPC = kentry
  LA r2,#X64_KENTRY
  CALL @x64_load_eax_abs
  LA r2,#X64_XPC
  CALL @x64_store_abs_eax

  CALL @x64_ret
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---- SVCRET ------------------------------------------------------------
; x64_svcret r1=out -> r1=out
x64_svcret:
  ST r15,r14,0
  ADD r14,r14,r13

  ; if in_kernel == 0, trap
  LA r2,#X64_KIN
  CALL @x64_load_eax_abs
  CALL @x64_test_eax_eax
  MOVI r2,0x75                 ; jnz over trap
  CALL @x64_8
  MOVI r2,21
  CALL @x64_8
  MOVI r5,0x44
  CALL @x64_trap_only

  ; frame = inl(0x4E01); unset traps
  MOVI r2,0x4E01
  CALL @x64_port_in_const
  CALL @x64_cmp_eax_ffff
  MOVI r2,0x75
  CALL @x64_8
  MOVI r2,21
  CALL @x64_8
  MOVI r5,0x45
  CALL @x64_trap_only

  CALL @x64_shl_eax_3
  LA r2,0x200000
  CALL @x64_add_eax_imm32
  CALL @x64_mov_edi_eax

  ; restore r0..r15
  MOVI r10,0
  MOVI r11,16
abi_svcret_rl:
  CMP r10,r11
  JMP[EQ] @abi_svcret_rd
  SHL r3,r10,3
  ADDI r3,r3,2
  CALL @x64_load_eax_edi_disp
  LA r2,#X64_R
  SHL r3,r10,2
  ADD r2,r2,r3
  CALL @x64_store_abs_eax
  ADDI r10,r10,1
  JMP @abi_svcret_rl
abi_svcret_rd:

  ; XPC = frame[16]
  MOVI r3,130
  CALL @x64_load_eax_edi_disp
  LA r2,#X64_XPC
  CALL @x64_store_abs_eax

  ; FLAGM = 1 << (frame[17] & 3)
  MOVI r3,138
  CALL @x64_load_eax_edi_disp
  CALL @x64_and_eax_3
  CALL @x64_mov_ecx_1
  CALL @x64_shl_ecx_cl
  LA r2,#X64_FLAGM
  CALL @x64_store_abs_ecx

  ; if cause == 0, r1 = frame[21]
  MOVI r3,154
  CALL @x64_load_eax_edi_disp
  CALL @x64_and_eax_3
  CALL @x64_test_eax_eax
  MOVI r2,0x75                 ; jnz over r1 return
  CALL @x64_8
  MOVI r2,11
  CALL @x64_8
  MOVI r3,170
  CALL @x64_load_eax_edi_disp
  LA r2,0x50004
  CALL @x64_store_abs_eax

  ; in_kernel = 0
  LA r2,#X64_KIN
  MOVI r3,0
  CALL @x64_store_abs_imm32

  CALL @x64_ret
  SUB r14,r14,r13
  LD r15,r14,0
  RET

ABI_PORT:
  .word 0
ABI_SVCNO:
  .word 0
ABI_NEXT:
  .word 0
ABI_TRAPCODE:
  .word 0
