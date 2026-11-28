; kan16.xa - NaN16/NaNVM1 native core, BARE flat 32-bit x86, assembled by nasm1.
; The ONE host file; everything else is NaN16 guest code. Transcribed from src/native/nan16.s.
.base 0x10000
.code64
.equ MASKM 0x80C0
.equ NWORDS 0x80C4
.equ MBYTES 0x80C8
.equ DATAB 0x80CC
.equ RAW 0x01000000
.equ RAWG 0xF000
.equ MAXOP 0x61
.equ G 0x200000
.equ R 0x8000
.equ VGA 0xB8000
.equ FB 0xA0000
.equ VMODE 0x8066
.equ FBW 0x8068
.equ FBH 0x806C
.equ FLAGM 0x8040
.equ STEPS 0x8044
.equ MAXS 0x8048
.equ T0 0x804C
.equ KB 0x8050
.equ OB 0x8054
.equ MS 0x8058
.equ MSF 0x805C
.equ SHIFT 0x8060
.equ E0 0x8061
.equ CAPS 0x8062
.equ RHEAD 0x8064
.equ RTAIL 0x8065
.equ KRING 0x8070
.equ FBBASE 0x8090
.equ FBTOT 0x8094
.equ VBEARG 0x8098
.equ RAWKB 0x809C
.equ CPUIDR 0x80B0
; PMEM v1 boot map (spec/MEMMAP.md; values mirror src/lib/memmap_defs.nas).
.equ MM_BASE 0x3F800
.equ MM_HDR0 0x3F800
.equ MM_CNT  0x3F801
.equ MM_VER  0x3F802
.equ MM_FLG  0x3F803
.equ MM_ENT0 0x3F804
.equ MM_ENT1 0x3F805
.equ MM_ENT2 0x3F806
.equ MM_ENT3 0x3F807
.equ MM_MAGIC 0x4D454D50
.equ MM_VERSION 1
.equ MM_F_E820 1
.equ MM_MAX 64
.equ IDT 0x9000
.equ VREG 0x2000
.equ XCODE 0x30000
.equ XLEN 0x80D0
.equ XPC 0x80D4
.equ AVX2F 0x80E4
.equ N16I_BASE 0xF00000
.equ ATAFLAG 0x80E0
; KABI v0.1 control-port state (spec/KERNEL_ABI.md).  Addresses are guest
; word indices; 0xFFFFFFFF means unset.  KIN is 1 while kernel code runs.
.equ KENTRY  0x80E8
.equ KFRAME  0x80EC
.equ KTIMER  0x80F0
.equ KTIMERL 0x80F4
.equ KSTACK  0x80F8
.equ KREGIONS 0x80FC
.equ KTCB    0x8100
.equ KIN     0x8104
.equ KDATA   0x8108
.equ KSTATUS 0x810C
; SMP mailbox (AP startup is 32-bit-core only for now; x64 reports one CPU).
.equ SM_NCPU  0x5900
.equ SM_DONE  0x5904
.equ SM_MAP   0x5908
.equ BOOLP    0x5910
.equ SM_FLAGS 0x5940
core64_entry:
  CLD
  CALL @sse_init
  CALL @mem_size
  MOVL $0xF0000000,[MAXS]
  MOVL $1,[FLAGM]
  MOVL $0,[STEPS]
  MOVL $0xF0000,[DATAB]
  MOVL $0xA0000,[FBBASE]
  MOVL $64000,[FBTOT]
  MOVB $0,[RAWKB]
  MOVL $0,[XLEN]
  MOVL $0,[XPC]
  MOVL $0xFFFFFFFF,[KENTRY]
  MOVL $0,[KFRAME]
  MOVL $0,[KTIMER]
  MOVL $0,[KTIMERL]
  MOVL $0,[KSTACK]
  MOVL $0,[KREGIONS]
  MOVL $0,[KTCB]
  MOVL $0,[KIN]
  MOVL $0xF0000,[KDATA]
  MOVL $0,[KSTATUS]
  MOV $G,%EDI
  XOR %EAX,%EAX
  ; Zero the C globals/compiler-table window (first 8 MiB of payload).
  ; Higher heap/stack pages are written before they are read and calloc
  ; clears its own blocks, so a 256 MiB VM does not pay a full-RAM wipe.
  MOV [NWORDS],%ECX
  CMP $0x200000,%ECX
  JBE @z_count
  MOV $0x200000,%ECX
z_count:
  SHL $1,%ECX
  REPSTOSD
  ; clear the 1 KiB abstract vector register file
  MOV $VREG,%EDI
  XOR %EAX,%EAX
  MOV $256,%ECX
  REPSTOSD
  ; r27: full guest image from the IDE primary master at kernel+16B0.
  ; Falls back to the floppy-staged 512 KiB copy when no disk answers.
  MOVL $0,[ATAFLAG]
  CALL @ata_load_guest
  NOP
  NOP
  NOP
  NOP
  NOP
  NOP
  NOP
  NOP
  NOP
  NOP
  NOP
  NOP
  CALL @hw_init
  CALL @memmap_build
  MOV $SM_FLAGS,%EDI
  XOR %EAX,%EAX
  MOV $0x100,%ECX
  REPSTOSD
  MOVL $1,[SM_NCPU]
  MOVL $0,[SM_DONE]
  MOVL $0,[SM_MAP]
  CALL @smp_start
  XOR %ESI,%ESI
loop:
  MOV [STEPS],%EAX
  CMP [MAXS],%EAX
  JAE @done
  ADD $1,%EAX
  MOV %EAX,[STEPS]
  ; KABI timer: count guest instructions; vector cause=1 when the interval
  ; expires.  The helper lives after the fixed table/ATA regions.
  CALL @kabi_tick
  MOV %ESI,%ECX
  AND [MASKM],%ECX
  CALL @nib
  JC @gate
  ADD $1,%ESI
  SHRD $16,%EDX,%EAX
  MOV %EAX,%EBX
  SHR $24,%EBX
  CMP $0xFF,%EBX
  JE @done
  CMP $MAXOP,%EBX
  JA @badop
  MOV %EAX,%EBP
  SHR $18,%EBP
  AND $0x3C,%EBP
  MOV %EAX,%ECX
  SHR $14,%ECX
  AND $0x3C,%ECX
  MOV [R+ECX],%ECX
  MOV %EAX,%EDX
  AND $15,%EDX
  MOV [R+EDX*4],%EDX
  TEST %EBX,%EBX
  JZ @L5
  TEST %EDI,[FLAGM]
  JZ @loop
L5:
  ; 64-bit mode: load the 32-bit table entry, then jump through the
  ; zero-extended register.  A qword table load would combine two entries.
  ; The dispatch must not lose the BOOL predicate that nib left in EDI.
  MOV %EDI,[BOOLP]
  MOV [tbl+EBX*4],%EDI
  JMP %EDI
head:
  MOV %EBX,%ECX
  AND $0x7FF0,%ECX
  CMP $0x7FF0,%ECX
  JNE @L8
  MOV $0x01020000,%ECX
  BT %EBX,%ECX
  JNC @L8
  MOV %EBX,%ECX
  SHR $2,%ECX
  AND $2,%ECX
  SHR $15,%EBX
  OR %EBX,%ECX
  CLC
  RET
L8:
  STC
  RET
nib:
  MOV [G+ECX*8],%EAX
  MOV [G+4+ECX*8],%EDX
  MOV %EDX,%EBX
  SHR $16,%EBX
  CALL @head
  JC @L9
  LEA [ECX*4],%EDI
  MOV %EAX,%EBX
  BSWAP %EBX
  SHR $16,%EBX
  CALL @head
  JC @L9
  OR %ECX,%EDI
L9:
  RET
putw:
  MOV %ECX,%EDX
  AND $3,%ECX
  MOVZWL [heads+ECX*2],%ECX
  ROL $8,%CX
  PUSH %EBX
  SHL $16,%EBX
  OR %ECX,%EBX
  MOV %EBX,[G+EAX*8]
  POP %EBX
  SHR $16,%EBX
  SHR $2,%EDX
  MOVZWL [heads+EDX*2],%EDX
  SHL $16,%EDX
  OR %EDX,%EBX
  MOV %EBX,[G+4+EAX*8]
  RET
wrz:
  MOV %EBX,[R+EBP]
  TEST %EBX,%EBX
wf:
  MOV %EBX,[R+EBP]
fl:
  SETC %CL
  SETZ %AL
fl2:
  MOVZX %CL,%ECX
  MOVZX %AL,%EAX
  LEA [ECX+EAX*2],%ECX
  MOV $1,%EAX
  SHL %CL,%EAX
  MOV %EAX,[FLAGM]
  JMP @loop
st:
  MOV %EBX,[R+EBP]
  JMP @loop
stf:
  MOV %EBX,[R+EBP]
  MOVL $1,[FLAGM]
  JMP @loop
h_bool:
  MOV [BOOLP],%EDI
  XOR %EBX,%EBX
  MOV %ECX,%EAX
  OR %EDX,%EAX
  NOT %EAX
  TEST $1,%EDI
  JZ @hb1
  OR %EAX,%EBX
hb1:
  MOV %ECX,%EAX
  NOT %EAX
  AND %EDX,%EAX
  TEST $2,%EDI
  JZ @hb2
  OR %EAX,%EBX
hb2:
  MOV %EDX,%EAX
  NOT %EAX
  AND %ECX,%EAX
  TEST $4,%EDI
  JZ @hb3
  OR %EAX,%EBX
hb3:
  MOV %ECX,%EAX
  AND %EDX,%EAX
  TEST $8,%EDI
  JZ @hb4
  OR %EAX,%EBX
hb4:
  JMP @wrz
h_movi:
  MOVZWL %AX,%EBX
  JMP @st
h_movhi:
  MOVZWL [R+EBP],%EBX
  SHL $16,%EAX
  OR %EAX,%EBX
  JMP @st
h_add:
  MOV %ECX,%EBX
  ADD %EDX,%EBX
  JMP @wf
h_sub:
  MOV %ECX,%EBX
  SUB %EDX,%EBX
  JMP @wf
h_shl:
  MOV %ECX,%EBX
  MOV %EAX,%ECX
  SHL %CL,%EBX
  JMP @wrz
h_shr:
  MOV %ECX,%EBX
  MOV %EAX,%ECX
  SHR %CL,%EBX
  JMP @wrz
h_sar:
  MOV %ECX,%EBX
  MOV %EAX,%ECX
  SAR %CL,%EBX
  JMP @wrz
h_cmp:
  CMP %EDX,%ECX
  JMP @fl
h_cmps:
  CMP %EDX,%ECX
  SETZ %AL
  SETL %CL
  JMP @fl2
h_ld:
  MOVZWL %AX,%EAX
  ADD %ECX,%EAX
  AND [MASKM],%EAX
  MOV [G+2+EAX*8],%EBX
  JMP @st
h_lds:
  MOVZWL %AX,%EAX
  ADD [DATAB],%EAX
  AND [MASKM],%EAX
  MOV [G+2+EAX*8],%EBX
  JMP @st
h_sts:
  MOVZWL %AX,%EAX
  ADD [DATAB],%EAX
  AND [MASKM],%EAX
  MOV [R+EBP],%EBX
  MOV $10,%ECX
  CALL @putw
  JMP @loop
h_st:
  MOVZWL %AX,%EAX
  ADD %ECX,%EAX
  AND [MASKM],%EAX
  MOV [R+EBP],%EBX
  MOV $10,%ECX
  CALL @putw
  JMP @loop
h_stw:
  MOV %ECX,%EAX
  AND [MASKM],%EAX
  MOV [R+EBP],%EBX
  MOV %EDX,%ECX
  AND $15,%ECX
  CALL @putw
  JMP @loop
h_ldn:
  MOVZWL %AX,%EAX
  ADD %ECX,%EAX
  AND [MASKM],%EAX
  MOV %EAX,%ECX
  CALL @nib
  MOV %EDI,%EBX
  JNC @st
  OR $-1,%EBX
  JMP @st
h_jmp:
  MOVZWL %AX,%ESI
  JMP @loop
h_call:
  MOV %ESI,[R+60]
  MOVZWL %AX,%ESI
  JMP @loop
h_ret:
  MOV [R+60],%ESI
  JMP @loop
h_jmpf:
  AND $0xFFFFFF,%EAX
  MOV %EAX,%ESI
  JMP @loop
h_callf:
  MOV %ESI,[R+60]
  AND $0xFFFFFF,%EAX
  MOV %EAX,%ESI
  JMP @loop
h_jmpr:
  MOV %ECX,%ESI
  JMP @loop
h_callr:
  MOV %ESI,[R+60]
  MOV %ECX,%ESI
  JMP @loop
h_nop:
  JMP @loop
h_vpoke:
  MOVZXB [VMODE],%EAX
  CMP $1,%EAX
  JE @vp_gfx
  CMP $2000,%ECX
  JAE @loop
  MOV [R+EBP],%EBX
  MOV %BX,[VGA+ECX*2]
  JMP @loop
vp_gfx:
  CMP [FBTOT],%ECX
  JAE @loop
  MOV [R+EBP],%EBX
  MOV [FBBASE],%EDI
  ADD %ECX,%EDI
  MOV %BL,[EDI]
  JMP @loop
h_vpeek:
  MOVZXB [VMODE],%EAX
  CMP $1,%EAX
  JE @vpk_gfx
  CMP $2000,%ECX
  JAE @loop
  MOVZWL [VGA+ECX*2],%EBX
  JMP @st
vpk_gfx:
  CMP [FBTOT],%ECX
  JAE @loop
  MOV [FBBASE],%EDI
  ADD %ECX,%EDI
  MOVZXB [EDI],%EBX
  JMP @st
h_bswapm:
  MOVZWL %AX,%EAX
  ADD %ECX,%EAX
  AND [MASKM],%EAX
  MOV [G+EAX*8],%ECX
  MOV [G+4+EAX*8],%EDX
  BSWAP %ECX
  BSWAP %EDX
  MOV %EDX,[G+EAX*8]
  MOV %ECX,[G+4+EAX*8]
  JMP @loop
h_putc:
  MOV [R+EBP],%EBX
  MOV %BL,[OB]
  CALL @out1
  JMP @loop
out1:
  MOV $0x3FD,%EDX
oL1:
  IN %DX,%AL
  TEST $0x20,%AL
  JZ @oL1
  MOV $0x3F8,%EDX
  MOVZXB [OB],%EAX
  OUT %AL,%DX
  RET
h_dispq:
  MOVZXB [VMODE],%EAX
  CMP $1,%EAX
  JNE @dq_text
  MOV $0x1300C800,%EBX
  JMP @st
dq_text:
  MOV $0x31950,%EBX
  JMP @st
h_dispset:
  MOV [R+EBP],%EAX
  CMP $0xFFFF0000,%EAX
  JAE @sd_raw
  CMP $0x10000,%EAX
  JAE @sd_vbe
  AND $255,%EAX
  CMP $0x13,%EAX
  JE @sd13
  CALL @vbe_off
  XOR %EBX,%EBX
  MOV %BL,[VMODE]
  MOV $0xA0000,%EBX
  MOV %EBX,[FBBASE]
  MOV $80,%EBX
  MOV %EBX,[FBW]
  MOV $25,%EBX
  MOV %EBX,[FBH]
  XOR %EAX,%EAX
  MOV $1000,%ECX
  MOV $VGA,%EDI
  CLD
  REPSTOSD
  JMP @loop
sd13:
  CALL @vbe_off
  MOV $1,%EBX
  MOV %BL,[VMODE]
  MOV $0xA0000,%EBX
  MOV %EBX,[FBBASE]
  MOV $64000,%EBX
  MOV %EBX,[FBTOT]
  MOV $320,%EBX
  MOV %EBX,[FBW]
  MOV $200,%EBX
  MOV %EBX,[FBH]
  XOR %EAX,%EAX
  MOV $16000,%ECX
  MOV $FB,%EDI
  CLD
  REPSTOSD
  JMP @loop
sd_raw:
  MOVZXB %AL,%EAX
  MOV %AL,[RAWKB]
  MOVB $0,[RHEAD]
  MOVB $0,[RTAIL]
  JMP @loop
sd_vbe:
  MOV %EAX,[VBEARG]
  MOV $4,%EBX
  XOR %EAX,%EAX
  CALL @dispi
  MOV $3,%EBX
  MOV $8,%EAX
  CALL @dispi
  MOV $1,%EBX
  MOV [VBEARG],%EAX
  SHR $16,%EAX
  CALL @dispi
  MOV $2,%EBX
  MOV [VBEARG],%EAX
  AND $0xFFFF,%EAX
  CALL @dispi
  MOV $4,%EBX
  MOV $0x41,%EAX
  CALL @dispi
  MOV $0xE0000000,%EBX
  XOR %ECX,%ECX
pci_l:
  MOV %ECX,%EAX
  SHL $11,%EAX
  OR $0x80000008,%EAX
  MOV %EAX,%EDI
  MOV $0xCF8,%EDX
  OUT %EAX,%DX
  MOV $0xCFC,%EDX
  IN %DX,%EAX
  SHR $16,%EAX
  CMP $0x300,%EAX
  JNE @pci_n
  MOV %EDI,%EAX
  ADD $8,%EAX
  MOV $0xCF8,%EDX
  OUT %EAX,%DX
  MOV $0xCFC,%EDX
  IN %DX,%EAX
  AND $0xFFFFFFF0,%EAX
  JZ @pci_x
  MOV %EAX,%EBX
  JMP @pci_x
pci_n:
  ADD $1,%ECX
  CMP $32,%ECX
  JB @pci_l
pci_x:
  MOV %EBX,[FBBASE]
  MOV $1,%EBX
  MOV %BL,[VMODE]
  MOV [VBEARG],%EAX
  SHR $16,%EAX
  MOV %EAX,[FBW]
  MOV [VBEARG],%EBX
  AND $0xFFFF,%EBX
  MOV %EBX,[FBH]
  IMUL %EAX,%EBX
  MOV %EBX,[FBTOT]
  MOV %EBX,%ECX
  SHR $2,%ECX
  MOV [FBBASE],%EDI
  XOR %EAX,%EAX
  CLD
  REPSTOSD
  JMP @loop
vbe_off:
  MOV [FBBASE],%EAX
  CMP $0xA0000,%EAX
  JE @vo_ret
  MOV $4,%EBX
  XOR %EAX,%EAX
  CALL @dispi
vo_ret:
  RET
dispi:
  PUSH %EAX
  MOV $0x1CE,%EDX
  MOV %EBX,%EAX
  .byte 0x66
  OUT %AX,%DX
  POP %EAX
  MOV $0x1CF,%EDX
  .byte 0x66
  OUT %AX,%DX
  RET
h_fbinfo:
  MOV [FBW],%EBX
  SHL $16,%EBX
  MOV [FBH],%EAX
  OR %EAX,%EBX
  JMP @st
h_vsync:
  MOVZXB [VMODE],%EAX
  CMP $1,%EAX
  JNE @loop
  MOV $0x3DA,%DX
vs1:
  IN %DX,%AL
  TEST $8,%AL
  JZ @vs1
vs2:
  IN %DX,%AL
  TEST $8,%AL
  JNZ @vs2
  JMP @loop
h_fbcopy:
  MOV %ECX,%EAX
  MOV %EDX,%EBX
  MOV [R+EBP],%ECX
  JECXZ @loop
  PUSH %ESI
  MOV [FBBASE],%ESI
  ADD %EBX,%ESI
  MOV [FBBASE],%EDI
  ADD %EAX,%EDI
  MOV %ECX,%EBX
  SHR $2,%ECX
  CLD
  REPMOVSD
  MOV %EBX,%ECX
  AND $3,%ECX
  .byte 0xF3,0xA4
  POP %ESI
  JMP @loop
h_fbfill:
  MOV %ECX,%EDI
  MOV [R+EBP],%ECX
  MOV %EDX,%EAX
  AND $255,%EAX
  MOV %EAX,%EBX
  SHL $8,%EBX
  OR %EBX,%EAX
  MOV %EAX,%EBX
  SHL $16,%EBX
  OR %EBX,%EAX
  ADD [FBBASE],%EDI
  MOV %ECX,%EBX
  SHR $2,%ECX
  CLD
  REPSTOSD
  MOV %EBX,%ECX
  AND $3,%ECX
  .byte 0xF3,0xAA
  JMP @loop
h_cpuid:
  MOV %ECX,%EAX
  MOV %EDX,%EDI
  AND $3,%EDI
  CMP $0x4E4D00FF,%EAX
  JNE @hc_real
  TEST %EDI,%EDI
  JZ @hc_mask
  CMP $1,%EDI
  JE @hc_words
  CMP $2,%EDI
  JE @hc_flags
  MOV [NWORDS],%EBX
  SHL $2,%EBX
  JMP @st
hc_mask:
  MOV [MASKM],%EBX
  JMP @st
hc_words:
  MOV [NWORDS],%EBX
  JMP @st
hc_flags:
  MOV $0x4E160001,%EBX
  MOVZXB [AVX2F],%EAX
  TEST %EAX,%EAX
  JZ @hc_flags_x
  OR $0x100,%EBX
hc_flags_x:
  JMP @st
hc_real:
  PUSH %ESI
  XOR %ECX,%ECX
  .byte 0x0F,0xA2
  MOV %EAX,[CPUIDR]
  MOV %EBX,[CPUIDR+4]
  MOV %ECX,[CPUIDR+8]
  MOV %EDX,[CPUIDR+12]
  MOV [CPUIDR+EDI*4],%EBX
  POP %ESI
  JMP @st
h_rdtsc:
  .byte 0x0F,0x31
  MOV %EAX,%EBX
  TEST %ECX,%ECX
  JZ @st
  MOV %EDX,%EBX
  JMP @st
h_outb:
  MOV [R+EBP],%EAX
  MOV %ECX,%EDX
  AND $0xFFFF,%EDX
  OUT %AL,%DX
  JMP @loop
h_inb:
  MOV %ECX,%EDX
  AND $0xFFFF,%EDX
  IN %DX,%AL
  XOR %EBX,%EBX
  MOV %AL,%BL
  JMP @st
h_outw:
  MOV [R+EBP],%EAX
  AND $0xFFFF,%EAX
  MOV %ECX,%EDX
  AND $0xFFFF,%EDX
  .byte 0x66
  OUT %AX,%DX
  JMP @loop
h_inw:
  MOV %ECX,%EDX
  AND $0xFFFF,%EDX
  .byte 0x66
  IN %DX,%AX
  XOR %EBX,%EBX
  MOV %AX,%BX
  JMP @st
h_outsw:
  PUSH %ESI
  MOV %ECX,%EDI
  MOV %EDX,%EBX
  SHL $3,%EBX
  ADD $G,%EBX
  ADD $2,%EBX
  MOV [R+EBP],%ECX
  JECXZ @osw_done
osw_l:
  MOVZWL [EBX],%EAX
  MOV %EDI,%EDX
  .byte 0x66
  OUT %AX,%DX
  ADD $8,%EBX
  SUB $1,%ECX
  JNZ @osw_l
osw_done:
  POP %ESI
  JMP @loop
h_outl:
  JMP @h_outl_full

h_inl:
  JMP @h_inl_full

h_mul:
  MOV %ECX,%EBX
  IMUL %EDX,%EBX
  JMP @wrz
h_mulh:
  MOV %ECX,%EAX
  IMUL %EDX
  MOV %EDX,%EBX
  JMP @wrz
h_mulhu:
  MOV %ECX,%EAX
  MUL %EDX
  MOV %EDX,%EBX
  JMP @wrz
h_div:
  TEST %EDX,%EDX
  JZ @z0
  CMP $-1,%EDX
  JNE @dv1
  MOV %ECX,%EBX
  NEG %EBX
  JMP @wrz
dv1:
  MOV %EDX,%EBX
  MOV %ECX,%EAX
  CLTD
  IDIV %EBX
  MOV %EAX,%EBX
  JMP @wrz
h_mod:
  TEST %EDX,%EDX
  JZ @zx
  CMP $-1,%EDX
  JNE @md1
  XOR %EBX,%EBX
  JMP @wrz
md1:
  MOV %EDX,%EBX
  MOV %ECX,%EAX
  CLTD
  IDIV %EBX
  MOV %EDX,%EBX
  JMP @wrz
h_divu:
  TEST %EDX,%EDX
  JZ @z0
  MOV %EDX,%EBX
  MOV %ECX,%EAX
  XOR %EDX,%EDX
  DIV %EBX
  MOV %EAX,%EBX
  JMP @wrz
h_modu:
  TEST %EDX,%EDX
  JZ @zx
  MOV %EDX,%EBX
  MOV %ECX,%EAX
  XOR %EDX,%EDX
  DIV %EBX
  MOV %EDX,%EBX
  JMP @wrz
z0:
  XOR %EBX,%EBX
  JMP @zf
zx:
  MOV %ECX,%EBX
zf:
  MOV %EBX,[R+EBP]
  MOVL $8,[FLAGM]
  JMP @loop
h_addi:
  MOVSXW %AX,%EBX
  ADD %ECX,%EBX
  JMP @wf
h_ldb:
  MOVZWL %AX,%EAX
  ADD %ECX,%EAX
  CMP $RAWG,%EAX
  JB @ldb_norm
  CMP $0x10000,%EAX
  JAE @ldb_norm
  SUB $RAWG,%EAX
  MOVZXB [RAW+EAX],%EBX
  JMP @st
ldb_norm:
  MOV %EAX,%ECX
  SHR $2,%EAX
  AND [MASKM],%EAX
  MOV [G+2+EAX*8],%EBX
  SHL $3,%ECX
  SHR %CL,%EBX
  MOVZX %BL,%EBX
  JMP @st
h_stb:
  MOVZWL %AX,%EAX
  ADD %ECX,%EAX
  CMP $RAWG,%EAX
  JB @stb_norm
  CMP $0x10000,%EAX
  JAE @stb_norm
  SUB $RAWG,%EAX
  MOVZXB [R+EBP],%EDX
  MOVB %DL,[RAW+EAX]
  JMP @loop
stb_norm:
  MOV %EAX,%ECX
  SHL $3,%ECX
  SHR $2,%EAX
  AND [MASKM],%EAX
  MOV [G+2+EAX*8],%EBX
  MOV $255,%EDX
  SHL %CL,%EDX
  NOT %EDX
  AND %EDX,%EBX
  MOVZXB [R+EBP],%EDX
  SHL %CL,%EDX
  OR %EDX,%EBX
  MOV $10,%ECX
  CALL @putw
  JMP @loop
h_bcopy:
  MOV %ECX,%EAX
  AND [MASKM],%EAX
  MOV [R+EBP],%EBX
  AND [MASKM],%EBX
  MOV %EDX,%ECX
  JECXZ @bc3
  MOV %EBX,%EDI
  SUB %EAX,%EDI
  AND [MASKM],%EDI
  CMP %ECX,%EDI
  JB @bc2
bc1:
  MOVQ [G+EAX*8],%XMM0
  MOVQ %XMM0,[G+EBX*8]
  ADD $1,%EAX
  AND [MASKM],%EAX
  ADD $1,%EBX
  AND [MASKM],%EBX
  LOOP @bc1
bc3:
  JMP @loop
bc2:
  LEA [-1+EAX+ECX],%EAX
  AND [MASKM],%EAX
  LEA [-1+EBX+ECX],%EBX
  AND [MASKM],%EBX
bc4:
  MOVQ [G+EAX*8],%XMM0
  MOVQ %XMM0,[G+EBX*8]
  SUB $1,%EAX
  AND [MASKM],%EAX
  SUB $1,%EBX
  AND [MASKM],%EBX
  LOOP @bc4
  JMP @loop
h_bfill:
  MOV %ECX,[T0]
  MOV %EDX,%EDI
  MOV [R+EBP],%EAX
bf1:
  TEST %EDI,%EDI
  JZ @loop
  AND [MASKM],%EAX
  MOV [T0],%EBX
  MOV $10,%ECX
  CALL @putw
  ADD $1,%EAX
  SUB $1,%EDI
  JMP @bf1
; DP4B: four signed i8 lanes in each payload, exact int32 dot product.
h_dp4b:
  PUSH %ESI
  XOR %EBX,%EBX
  MOVSX %CL,%EAX
  MOVSX %DL,%ESI
  IMUL %ESI,%EAX
  ADD %EAX,%EBX
  SHR $8,%ECX
  SHR $8,%EDX
  MOVSX %CL,%EAX
  MOVSX %DL,%ESI
  IMUL %ESI,%EAX
  ADD %EAX,%EBX
  SHR $8,%ECX
  SHR $8,%EDX
  MOVSX %CL,%EAX
  MOVSX %DL,%ESI
  IMUL %ESI,%EAX
  ADD %EAX,%EBX
  SHR $8,%ECX
  SHR $8,%EDX
  MOVSX %CL,%EAX
  MOVSX %DL,%ESI
  IMUL %ESI,%EAX
  ADD %EAX,%EBX
  POP %ESI
  JMP @wf

; ---- 512-bit abstract vectors (native scalar reference lowering) ----

; ---- NaN-native translator shim: unpack and execute x86 bytes ----
h_codelen:
  MOV %ECX,[XLEN]
  JMP @loop
h_execn:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV [XLEN],%EBP
  MOV %ECX,%ESI
  MOV $XCODE,%EDI
xe_l:
  CMP $0,%EBP
  JE @xe_call
  MOV %ESI,%ECX
  CALL @v_ldb_byte
  MOVB %BL,[EDI]
  ADD $1,%ESI
  ADD $1,%EDI
  SUB $1,%EBP
  JMP @xe_l
xe_call:
  MOV $XCODE,%EBX
  .byte 0xFF,0xD3              ; call ebx
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  MOV [XPC],%ESI
  JMP @loop
h_vzero:
  PUSH %ESI
  PUSH %EDI
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  XOR %EAX,%EAX
  MOV $16,%ECX
  REPSTOSD
  POP %EDI
  POP %ESI
  JMP @loop
h_vbcast:
  PUSH %EDI
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV %ECX,%EAX
  MOV $16,%ECX
  REPSTOSD
  POP %EDI
  JMP @loop
h_vdp4b:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV %EAX,%EBX
  SHR $20,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV $4,%ECX
vdp_l:
  .byte 0xF3,0x0F,0x6F,0x06      ; movdqu xmm0,[esi]
  .byte 0xF3,0x0F,0x6F,0x17      ; movdqu xmm2,[edi]
  .byte 0x66,0x0F,0xEF,0xE4      ; pxor xmm4,xmm4
  .byte 0x66,0x0F,0x6F,0xC8      ; movdqa xmm1,xmm0
  .byte 0x66,0x0F,0x64,0xE1      ; pcmpgtb xmm4,xmm1 (negative mask)
  .byte 0x66,0x0F,0x60,0xCC      ; punpcklbw xmm1,xmm4 (A low words)
  .byte 0x66,0x0F,0xEF,0xED      ; pxor xmm5,xmm5
  .byte 0x66,0x0F,0x6F,0xDA      ; movdqa xmm3,xmm2
  .byte 0x66,0x0F,0x64,0xEB      ; pcmpgtb xmm5,xmm3
  .byte 0x66,0x0F,0x60,0xDD      ; punpcklbw xmm3,xmm5 (B low words)
  .byte 0x66,0x0F,0xF5,0xCB      ; pmaddwd xmm1,xmm3
  .byte 0x66,0x0F,0x6F,0xF1      ; movdqa xmm6,xmm1
  .byte 0x66,0x0F,0x70,0xF6,0xB1 ; pshufd xmm6,xmm6,0xb1
  .byte 0x66,0x0F,0xFE,0xCE      ; paddd xmm1,xmm6
  .byte 0x66,0x0F,0x70,0xC9,0x08 ; pshufd xmm1,xmm1,0x08
  .byte 0x66,0x0F,0x6F,0xF1      ; movdqa xmm6,xmm1 (save low lanes)
  .byte 0x66,0x0F,0xEF,0xE4      ; pxor xmm4,xmm4
  .byte 0x66,0x0F,0x6F,0xC8      ; movdqa xmm1,xmm0
  .byte 0x66,0x0F,0x64,0xE1      ; pcmpgtb xmm4,xmm1
  .byte 0x66,0x0F,0x68,0xCC      ; punpckhbw xmm1,xmm4 (A high words)
  .byte 0x66,0x0F,0xEF,0xED      ; pxor xmm5,xmm5
  .byte 0x66,0x0F,0x6F,0xDA      ; movdqa xmm3,xmm2
  .byte 0x66,0x0F,0x64,0xEB      ; pcmpgtb xmm5,xmm3
  .byte 0x66,0x0F,0x68,0xDD      ; punpckhbw xmm3,xmm5 (B high words)
  .byte 0x66,0x0F,0xF5,0xCB      ; pmaddwd xmm1,xmm3
  .byte 0x66,0x0F,0x6F,0xF9      ; movdqa xmm7,xmm1
  .byte 0x66,0x0F,0x70,0xFF,0xB1 ; pshufd xmm7,xmm7,0xb1
  .byte 0x66,0x0F,0xFE,0xCF      ; paddd xmm1,xmm7
  .byte 0x66,0x0F,0x70,0xC9,0x08 ; pshufd xmm1,xmm1,0x08
  .byte 0x66,0x0F,0x6C,0xF1      ; punpcklqdq xmm6,xmm1 (low,high)
  .byte 0xF3,0x0F,0x7F,0x33      ; movdqu [ebx],xmm6
  ADD $16,%ESI
  ADD $16,%EDI
  ADD $16,%EBX
  SUB $1,%ECX
  JNZ @vdp_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vget:
  MOV %EAX,%ECX
  SHR $16,%ECX
  AND $15,%ECX
  SHL $6,%ECX
  ADD $VREG,%ECX
  MOVZWL %AX,%EDX
  AND $15,%EDX
  SHL $2,%EDX
  ADD %EDX,%ECX
  MOV [ECX],%EBX
  MOV %EBX,[R+EBP]
  JMP @loop
h_vset:
  MOV %ECX,%EDX
  MOV %EAX,%ECX
  SHR $20,%ECX
  AND $15,%ECX
  SHL $6,%ECX
  ADD $VREG,%ECX
  MOVZWL %AX,%EAX
  AND $15,%EAX
  SHL $2,%EAX
  ADD %EAX,%ECX
  MOV %EDX,[ECX]
  JMP @loop

h_vadd8:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $64,%ECX
va8_l:
  MOVZXB [ESI],%EAX
  MOVZXB [EBX],%EDX
  ADD %EDX,%EAX
  MOVB %AL,[EDI]
  ADD $1,%ESI
  ADD $1,%EBX
  ADD $1,%EDI
  SUB $1,%ECX
  JNZ @va8_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vsub8:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $64,%ECX
vs8_l:
  MOVZXB [ESI],%EAX
  MOVZXB [EBX],%EDX
  SUB %EDX,%EAX
  MOVB %AL,[EDI]
  ADD $1,%ESI
  ADD $1,%EBX
  ADD $1,%EDI
  SUB $1,%ECX
  JNZ @vs8_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vadd32:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $16,%ECX
va32_l:
  MOV [ESI],%EAX
  MOV [EBX],%EDX
  ADD %EDX,%EAX
  MOV %EAX,[EDI]
  ADD $4,%ESI
  ADD $4,%EBX
  ADD $4,%EDI
  SUB $1,%ECX
  JNZ @va32_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vsub32:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $16,%ECX
vs32_l:
  MOV [ESI],%EAX
  MOV [EBX],%EDX
  SUB %EDX,%EAX
  MOV %EAX,[EDI]
  ADD $4,%ESI
  ADD $4,%EBX
  ADD $4,%EDI
  SUB $1,%ECX
  JNZ @vs32_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vmul32:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $16,%ECX
vm32_l:
  MOV [ESI],%EAX
  MOV [EBX],%EDX
  IMUL %EDX,%EAX
  MOV %EAX,[EDI]
  ADD $4,%ESI
  ADD $4,%EBX
  ADD $4,%EDI
  SUB $1,%ECX
  JNZ @vm32_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop

h_vload:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %ECX,%ESI
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $64,%EBP
vl_l:
  MOV %ESI,%ECX
  CALL @v_ldb_byte
  MOVB %BL,[EDI]
  ADD $1,%ESI
  ADD $1,%EDI
  SUB $1,%EBP
  JNZ @vl_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
v_ldb_byte:
  MOV %ECX,%EAX
  SHR $2,%EAX
  AND [MASKM],%EAX
  MOV [G+2+EAX*8],%EBX
  SHL $3,%ECX
  SHR %CL,%EBX
  MOVZX %BL,%EBX
  RET
h_vstore:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %ECX,%ESI
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $64,%EBP
vs_l:
  MOVZXB [EDI],%EDX
  MOV %ESI,%ECX
  CALL @v_stb_byte
  ADD $1,%ESI
  ADD $1,%EDI
  SUB $1,%EBP
  JNZ @vs_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
v_stb_byte:
  MOV %ECX,%EAX
  SHL $3,%ECX
  SHR $2,%EAX
  AND [MASKM],%EAX
  MOV [G+2+EAX*8],%EBX
  PUSH %EDX
  MOV $255,%EDX
  SHL %CL,%EDX
  NOT %EDX
  AND %EDX,%EBX
  POP %EDX
  SHL %CL,%EDX
  OR %EDX,%EBX
  MOV $10,%ECX
  CALL @putw
  RET
h_fadd:
  MOVD %ECX,%XMM0
  MOVD %EDX,%XMM1
  ADDSS %XMM1,%XMM0
  JMP @fres
h_fsub:
  MOVD %ECX,%XMM0
  MOVD %EDX,%XMM1
  SUBSS %XMM1,%XMM0
  JMP @fres
h_fmul:
  MOVD %ECX,%XMM0
  MOVD %EDX,%XMM1
  MULSS %XMM1,%XMM0
  JMP @fres
h_fdiv:
  TEST $0x7FFFFFFF,%EDX
  JNZ @fd1
  MOV %ECX,%EBX
  AND $0x7FFFFFFF,%EBX
  JZ @fnan
  CMP $0x7F800000,%EBX
  JA @fnan
fd1:
  MOVD %ECX,%XMM0
  MOVD %EDX,%XMM1
  DIVSS %XMM1,%XMM0
fres:
  MOVD %XMM0,%EBX
  JMP @stf
fnan:
  MOV $0x7FC00000,%EBX
  JMP @stf
h_fsqrt:
  MOVD %ECX,%XMM0
  XORPS %XMM1,%XMM1
  UCOMISS %XMM1,%XMM0
  JP @fnan
  JB @fnan
  SQRTSS %XMM0,%XMM0
  JMP @fres
h_fcmp:
  MOVD %ECX,%XMM0
  MOVD %EDX,%XMM1
  UCOMISS %XMM1,%XMM0
  JP @fc1
  JMP @fl
fc1:
  MOVL $8,[FLAGM]
  JMP @loop
h_cvtif:
  CVTSI2SS %ECX,%XMM0
  JMP @fres
h_cvtfi:
  MOVD %ECX,%XMM0
  XOR %EBX,%EBX
  UCOMISS %XMM0,%XMM0
  JP @wrz
  CVTTSS2SI %XMM0,%EBX
  CMP $0x80000000,%EBX
  JNE @wrz
  TEST %ECX,%ECX
  JS @wrz
  MOV $0x7FFFFFFF,%EBX
  JMP @wrz
gate:
  ADD $1,%ESI
  MOV $0x47,%EAX
  JMP @trap
badop:
  MOV $0x4F,%EAX
trap:
  PUSH %EAX
  MOVB $0x21,[OB]
  CALL @out1
  POP %EAX
  MOV %AL,[OB]
  CALL @out1
  MOV $12,%ECX
tr1:
  MOV %ESI,%EDX
  SHR %CL,%EDX
  SHR $4,%EDX
  JZ @tr2
  ADD $4,%ECX
  JMP @tr1
tr2:
  MOV %ESI,%EDX
  SHR %CL,%EDX
  AND $15,%EDX
  MOVZXB [hexd+EDX],%EAX
  MOV %AL,[OB]
  PUSH %ECX
  CALL @out1
  POP %ECX
  SUB $4,%ECX
  JNS @tr2
done:
  CLI
dn1:
  HLT
  JMP @dn1
sse_init:
  MOV $1,%EAX
  .byte 0x0F,0xA2
  MOV %EDX,%EAX
  AND $0x5000000,%EAX
  CMP $0x5000000,%EAX
  JNE @sse_no
  .byte 0x48,0x0F,0x20,0xC0
  AND $0xFFFFFFFB,%EAX
  OR $2,%EAX
  .byte 0x48,0x0F,0x22,0xC0
  .byte 0x48,0x0F,0x20,0xE0
  OR $0x600,%EAX
  .byte 0x48,0x0F,0x22,0xE0
  ; AVX2 needs OSXSAVE+AVX (CPUID.1:ECX) and AVX2 (CPUID.7:EBX bit5)
  MOV $1,%EAX
  XOR %ECX,%ECX
  .byte 0x0F,0xA2
  MOV %ECX,%EAX
  AND $0x14000000,%EAX       ; XSAVE + AVX
  CMP $0x14000000,%EAX
  JNE @sse_no
  MOV $7,%EAX
  XOR %ECX,%ECX
  .byte 0x0F,0xA2
  BT $5,%EBX
  JNC @sse_no
  .byte 0x48,0x0F,0x20,0xE0       ; mov eax,cr4
  OR $0x40000,%EAX           ; OSXSAVE
  .byte 0x48,0x0F,0x22,0xE0       ; mov cr4,eax
  XOR %ECX,%ECX
  MOV $7,%EAX                ; x87|SSE|AVX
  XOR %EDX,%EDX
  .byte 0x0F,0x01,0xD1       ; xsetbv
  MOVB $1,[AVX2F]
sse_no:
  RET
hw_init:
  RET
  MOV $IDT,%EDI
  XOR %EAX,%EAX
  MOV $512,%ECX
  REPSTOSD
  MOV $IDT,%EDI
  MOV $xs,%EAX
  MOV $32,%EBX
e1:
  CALL @mkgate
  ADD $4,%EAX
  SUB $1,%EBX
  JNZ @e1
  MOV $0x9100,%EDI
  MOV $irq0,%EAX
  CALL @mkgate
  MOV $irq1,%EAX
  CALL @mkgate
  MOV $irets,%EAX
  MOV $0x9138,%EDI
  CALL @mkgate
  MOV $0x9178,%EDI
  CALL @mkgate
  LIDT [idtr]
  MOV $16,%ECX
fl8:
  IN $0x64,%AL
  TEST $1,%AL
  JZ @fl9
  IN $0x60,%AL
  SUB $1,%ECX
  JNZ @fl8
fl9:
  MOV $ptab,%ESI
p1:
  MOVZXB [ESI],%EDX
  TEST %EDX,%EDX
  JZ @p2
  MOVZXB [ESI+1],%EAX
  OUT %AL,%DX
  OUT %AL,$0x80
  ADD $2,%ESI
  JMP @p1
p2:
  STI
  RET
mkgate:
  MOV %EAX,%EDX
  AND $0xFFFF,%EDX
  OR $0x80000,%EDX
  MOV %EDX,[EDI]
  MOV %EAX,%EDX
  AND $0xFFFF0000,%EDX
  OR $0x8E00,%EDX
  MOV %EDX,[EDI+4]
  ADD $8,%EDI
  RET
xs:
  .byte 0x6A,0,0xEB,124
  .byte 0x6A,1,0xEB,120
  .byte 0x6A,2,0xEB,116
  .byte 0x6A,3,0xEB,112
  .byte 0x6A,4,0xEB,108
  .byte 0x6A,5,0xEB,104
  .byte 0x6A,6,0xEB,100
  .byte 0x6A,7,0xEB,96
  .byte 0x6A,8,0xEB,92
  .byte 0x6A,9,0xEB,88
  .byte 0x6A,10,0xEB,84
  .byte 0x6A,11,0xEB,80
  .byte 0x6A,12,0xEB,76
  .byte 0x6A,13,0xEB,72
  .byte 0x6A,14,0xEB,68
  .byte 0x6A,15,0xEB,64
  .byte 0x6A,16,0xEB,60
  .byte 0x6A,17,0xEB,56
  .byte 0x6A,18,0xEB,52
  .byte 0x6A,19,0xEB,48
  .byte 0x6A,20,0xEB,44
  .byte 0x6A,21,0xEB,40
  .byte 0x6A,22,0xEB,36
  .byte 0x6A,23,0xEB,32
  .byte 0x6A,24,0xEB,28
  .byte 0x6A,25,0xEB,24
  .byte 0x6A,26,0xEB,20
  .byte 0x6A,27,0xEB,16
  .byte 0x6A,28,0xEB,12
  .byte 0x6A,29,0xEB,8
  .byte 0x6A,30,0xEB,4
  .byte 0x6A,31,0xEB,0
xc:
  POP %ESI
  MOV $0x58,%EAX
  JMP @trap
irq0:
  PUSH %EAX
  ADDL $65526,[MSF]
  MOV [MSF],%EAX
  SHR $16,%EAX
  ANDL $0xFFFF,[MSF]
  ADD %EAX,[MS]
  MOV $0x20,%AL
  OUT %AL,$0x20
  POP %EAX
irets:
  .byte 0xCF
irq1:
  PUSH %EAX
  PUSH %EBX
  PUSH %ECX
  PUSH %EDX
  XOR %EAX,%EAX
  IN $0x60,%AL
  CMPB $0,[RAWKB]
  JNE @kraw
  CMP $0xE0,%EAX
  JNE @k1
  MOVB $1,[E0]
  JMP @kx
k1:
  MOVZXB [E0],%EBX
  TEST $0x80,%EAX
  JNZ @kbrk
  TEST %EBX,%EBX
  JNZ @kext
  CMP $0x2A,%EAX
  JE @kshd
  CMP $0x36,%EAX
  JE @kshd
  CMP $0x3A,%EAX
  JE @kcap
  MOVZXB [SHIFT],%ECX
  MOVZXB [ktab+EAX],%EBX
  LEA [EBX-97],%EDX
  CMP $26,%EDX
  JAE @k3
  MOVZXB [CAPS],%EDX
  XOR %EDX,%ECX
k3:
  SHL $7,%ECX
  MOVZXB [ktab+ECX+EAX],%EBX
  JMP @kpush
kraw:
  MOV %EAX,%EBX
  MOVZXB [RTAIL],%EAX
  LEA [EAX+1],%ECX
  AND $15,%ECX
  MOVZXB [RHEAD],%EDX
  CMP %EDX,%ECX
  JE @kx
  MOV %BL,[KRING+EAX]
  MOV %CL,[RTAIL]
  JMP @kx
kext:
  MOVZXB [ktab+256+EAX],%EBX
  JMP @kpush
kshd:
  MOVB $1,[SHIFT]
  JMP @kx0
kcap:
  XORB $1,[CAPS]
  JMP @kx0
kbrk:
  TEST %EBX,%EBX
  JNZ @kx0
  AND $0x7F,%EAX
  CMP $0x2A,%EAX
  JE @kshu
  CMP $0x36,%EAX
  JNE @kx0
kshu:
  MOVB $0,[SHIFT]
  JMP @kx0
kpush:
  TEST %EBX,%EBX
  JZ @kx0
  MOVZXB [RTAIL],%EAX
  LEA [EAX+1],%ECX
  AND $15,%ECX
  MOVZXB [RHEAD],%EDX
  CMP %EDX,%ECX
  JE @kfull
  MOV %BL,[KRING+EAX]
  MOV %CL,[RTAIL]
kfull:
kx0:
  MOVB $0,[E0]
kx:
  MOV $0x20,%AL
  OUT %AL,$0x20
  POP %EDX
  POP %ECX
  POP %EBX
  POP %EAX
  .byte 0xCF
h_key:
kb1:
  MOVZXB [RHEAD],%EAX
  MOVZXB [RTAIL],%EDX
  CMP %EDX,%EAX
  JNE @kb2
  HLT
  JMP @kb1
kb2:
  MOVZXB [KRING+EAX],%EBX
  ADD $1,%EAX
  AND $15,%EAX
  MOV %AL,[RHEAD]
  JMP @st
h_keyq:
  XOR %EBX,%EBX
  MOVZXB [RHEAD],%EAX
  MOVZXB [RTAIL],%EDX
  CMP %EDX,%EAX
  JE @st
  JMP @kb2
h_tick:
  MOV [MS],%EBX
  JMP @st
idtr:
  .word 2047
  .long 0x9000
ptab:
  .byte 0x20,0x11,0xA0,0x11,0x21,0x20,0xA1,0x28,0x21,4,0xA1,2,0x21,1,0xA1,1,0x43,0x36,0x40,0xA9,0x40,4,0x21,0xFC,0xA1,0xFF,0,0
.org 0x3000
heads:
  .word 0x7FF1,0xFFF1,0x7FF8,0xFFF8
hexd:
  .str "0123456789ABCDEF"
ktab:
  .byte 0,27,49,50,51,52,53,54,55,56,57,48,45,61,8,9
  .byte 113,119,101,114,116,121,117,105,111,112,91,93,13,0,97,115
  .byte 100,102,103,104,106,107,108,59,39,96,0,92,122,120,99,118
  .byte 98,110,109,44,46,47,0,42,0,32,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,27,33,64,35,36,37,94,38,42,40,41,95,43,8,9
  .byte 81,87,69,82,84,89,85,73,79,80,123,125,13,0,65,83
  .byte 68,70,71,72,74,75,76,58,34,126,0,124,90,88,67,86
  .byte 66,78,77,60,62,63,0,42,0,32,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,132,128,134,0,130,0,131,0,133
  .byte 129,135,136,137,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tbl:
  .long @h_bool,@h_movi,@h_movhi,@h_add,@h_sub,@h_shl,@h_shr,@h_cmp,@h_ld,@h_st,@h_jmp,@h_call,@h_ret,@h_jmpr,@badop,@h_nop
  .long @h_vpoke,@h_vpeek,@h_key,@h_tick,@h_bswapm,@h_putc,@h_stw,@h_ldn,@h_dispq,@h_dispset,@h_keyq,@h_nop,@h_lds,@h_sts,@badop,@badop
  .long @h_mul,@h_mulh,@h_mulhu,@h_div,@h_mod,@h_divu,@h_modu,@h_sar,@h_cmps,@h_addi,@h_ldb,@h_stb,@h_callr,@h_bcopy,@h_bfill,@h_nop
  .long @h_fadd,@h_fsub,@h_fmul,@h_fdiv,@h_fsqrt,@h_fcmp,@h_cvtif,@h_cvtfi,@h_jmpf,@h_callf
  .long @h_fbinfo,@h_vsync,@h_fbcopy,@h_fbfill,@h_outb,@h_inb,@h_inw,@h_outw,@h_outsw,@h_outl,@h_cpuid,@h_rdtsc
  .long @badop,@badop,@badop,@badop,@h_dp4b
  .long @badop,@h_vdp4b4,@h_inl,@h_svc,@h_svcret
  .long @h_vzero,@h_vbcast,@h_vload_sse2,@h_vstore_sse2,@h_vadd8_disp,@h_vsub8_disp,@h_vadd32_disp,@h_vsub32_disp,@h_vmul32_disp,@h_vdp4b_disp,@badop,@badop,@badop,@badop,@h_vget,@h_vset
  .long @h_codelen,@h_execn


; ---- memory discovery: E820 -> runtime word mask --------------------
; Picks the largest power-of-two word count whose bytes fit above G in the
; highest usable RAM region below 4 GiB.  Falls back to the BIOS KB count,
; then to the historical 4M words.  CPUID 0x4E4D00FF exposes the result.
mem_size:
  PUSH %EBX
  PUSH %ECX
  PUSH %EDX
  PUSH %ESI
  PUSH %EDI
  MOVZWL [0x5FC],%ECX
  TEST %ECX,%ECX
  JZ @ms_bios
  MOV $0x600,%ESI
  XOR %EBX,%EBX
ms_loop:
  MOV [ESI+16],%EAX
  CMP $1,%EAX
  JNE @ms_next
  MOV [ESI+4],%EAX
  TEST %EAX,%EAX
  JNZ @ms_next
  MOV [ESI],%EAX
  ADD [ESI+8],%EAX
  JC @ms_clamp
  CMP %EBX,%EAX
  JBE @ms_next
  MOV %EAX,%EBX
  JMP @ms_next
ms_clamp:
  MOV $0xFFFFFFFF,%EBX
ms_next:
  ADD $24,%ESI
  SUB $1,%ECX
  JNZ @ms_loop
  JMP @ms_have
ms_bios:
  MOV $0x68,%EAX
  MOV %AL,[OB]
  CALL @out1
  MOVZWL [0x413],%EBX
  SHL $10,%EBX
ms_have:
  CMP $0x400000,%EBX
  JBE @ms_min
  SUB $G,%EBX
  SHR $3,%EBX
  MOV $0x10000000,%EAX
ms_pow:
  CMP %EAX,%EBX
  JAE @ms_done
  SHR $1,%EAX
  JMP @ms_pow
ms_done:
  CMP $0x400000,%EAX
  JAE @ms_store
ms_min:
  MOV $0x400000,%EAX
ms_store:
  MOV %EAX,[NWORDS]
  SUB $1,%EAX
  MOV %EAX,[MASKM]
  POP %EDI
  POP %ESI
  POP %EDX
  POP %ECX
  POP %EBX
  RET

; ---- r27: ATA guest loader (kernel+0x1900, 174 bytes; guest LBA 129) ----
; The gold bytes are authoritative. The routine selects the primary master,
; reads ceil(LMAX/64) sectors from LBA 129 into flat guest memory G, and
; falls back to the floppy-staged 512 KiB copy at 0x20000 when no IDE answers.
.org 0x4000
; ATA guest loader at kernel+0x1900: authoritative gold bytes (the source form did not
; reproduce the branch-relaxed encoding; nasm1 output is verified by
; tools/xgold.sh against this table.
ata_load_guest:
  ; Select the primary master and probe its status.
  MOV $0x1F6,%DX
  MOV $0xA0,%AL
  OUT %AL,%DX
  MOV $0x1F7,%DX
  IN %DX,%AL
  IN %DX,%AL
  IN %DX,%AL
  IN %DX,%AL
  IN %DX,%AL
  CMP $0,%AL
  JE @ata_fallback
  CMP $0xFF,%AL
  JE @ata_fallback
  ; LMAX is the guest word count written at boot-sector byte 504.
  MOV [0x7DF8],%EAX
  TEST %EAX,%EAX
  JZ @ata_fallback
  ADD $0x3F,%EAX
  SHR $6,%EAX
  MOV %EAX,%EBP
  MOV $0x81,%EBX
  MOV $0x200000,%EDI
ata_sector:
  MOV %EBX,%EAX
  SHR $24,%EAX
  AND $0x0F,%AL
  OR $0xE0,%AL
  MOV $0x1F6,%DX
  OUT %AL,%DX
  MOV $0x1F7,%DX
  IN %DX,%AL
  IN %DX,%AL
  IN %DX,%AL
  IN %DX,%AL
  MOV $0x1F2,%DX
  MOV $1,%AL
  OUT %AL,%DX
  MOV $0x1F3,%DX
  MOV %EBX,%EAX
  OUT %AL,%DX
  MOV $0x1F4,%DX
  MOV %EBX,%EAX
  SHR $8,%EAX
  OUT %AL,%DX
  MOV $0x1F5,%DX
  MOV %EBX,%EAX
  SHR $16,%EAX
  OUT %AL,%DX
  MOV $0x1F7,%DX
  MOV $0x20,%AL
  OUT %AL,%DX
ata_wait:
  IN %DX,%AL
  TEST $0x80,%AL
  JNZ @ata_wait
ata_drq:
  IN %DX,%AL
  TEST $0x08,%AL
  JZ @ata_drq
  MOV $0x1F0,%DX
  MOV $0x80,%ECX
  .byte 0xF3,0x6D
  ADD $1,%EBX
  SUB $1,%EBP
  JNZ @ata_sector
  RET
ata_fallback:
  MOV $0x20000,%ESI
  MOV $0x200000,%EDI
  MOV $0x20000,%ECX
  .byte 0xF3,0xA5
  RET

; ---- SSE2 tier for the packed vector arithmetic (appended after the
; fixed .org regions so the kernel code window stays intact) ----
h_vadd8_sse2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $4,%ECX
va8s_l:
  .byte 0xF3,0x0F,0x6F,0x06
  .byte 0xF3,0x0F,0x6F,0x0B
  .byte 0x66,0x0F,0xFC,0xC1
  .byte 0xF3,0x0F,0x7F,0x07
  ADD $16,%ESI
  ADD $16,%EBX
  ADD $16,%EDI
  SUB $1,%ECX
  JNZ @va8s_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vsub8_sse2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $4,%ECX
vs8s_l:
  .byte 0xF3,0x0F,0x6F,0x06
  .byte 0xF3,0x0F,0x6F,0x0B
  .byte 0x66,0x0F,0xF8,0xC1
  .byte 0xF3,0x0F,0x7F,0x07
  ADD $16,%ESI
  ADD $16,%EBX
  ADD $16,%EDI
  SUB $1,%ECX
  JNZ @vs8s_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vadd32_sse2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $4,%ECX
va32s_l:
  .byte 0xF3,0x0F,0x6F,0x06
  .byte 0xF3,0x0F,0x6F,0x0B
  .byte 0x66,0x0F,0xFE,0xC1
  .byte 0xF3,0x0F,0x7F,0x07
  ADD $16,%ESI
  ADD $16,%EBX
  ADD $16,%EDI
  SUB $1,%ECX
  JNZ @va32s_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vsub32_sse2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $4,%ECX
vs32s_l:
  .byte 0xF3,0x0F,0x6F,0x06
  .byte 0xF3,0x0F,0x6F,0x0B
  .byte 0x66,0x0F,0xFA,0xC1
  .byte 0xF3,0x0F,0x7F,0x07
  ADD $16,%ESI
  ADD $16,%EBX
  ADD $16,%EDI
  SUB $1,%ECX
  JNZ @vs32s_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vmul32_sse2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $4,%ECX
vm32s_l:
  .byte 0xF3,0x0F,0x6F,0x06
  .byte 0xF3,0x0F,0x6F,0x1B
  .byte 0x66,0x0F,0x6F,0xD0
  .byte 0x66,0x0F,0xF4,0xC3
  .byte 0x66,0x0F,0x73,0xD2,0x20
  .byte 0x66,0x0F,0x73,0xD3,0x20
  .byte 0x66,0x0F,0xF4,0xD3
  .byte 0x66,0x0F,0x70,0xC0,0x08
  .byte 0x66,0x0F,0x70,0xD2,0x08
  .byte 0x66,0x0F,0x62,0xC2
  .byte 0xF3,0x0F,0x7F,0x07
  ADD $16,%ESI
  ADD $16,%EBX
  ADD $16,%EDI
  SUB $1,%ECX
  JNZ @vm32s_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop

; ---- SSE2 VLOAD/VSTORE fast paths -------------------------------------
; Aligned, normal-G, non-wrapping ranges use dword gather/scatter. Every
; other case restores the saved registers and jumps to the exact byte
; handler above.
h_vload_sse2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  TEST $3,%ECX
  JNZ @vl_slow
  MOV %ECX,%EDX
  CMP $RAWG,%EDX
  JB @vl_ok
  CMP $0x10000,%EDX
  JB @vl_slow
vl_ok:
  MOV %ECX,%EDX
  SHR $2,%EDX
  AND [MASKM],%EDX
  MOV [MASKM],%EBX
  SUB $15,%EBX
  CMP %EBX,%EDX
  JA @vl_slow
  MOV %EAX,%ESI
  SHR $20,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EDX,%EBX
  SHL $3,%EBX
  ADD $G+2,%EBX
  MOV %ESI,%EDI
  MOV $4,%EBP
vl_g:
  .byte 0x66,0x0F,0x6E,0x03      ; movd xmm0,[ebx]
  .byte 0x66,0x0F,0x6E,0x4B,0x08 ; movd xmm1,[ebx+8]
  .byte 0x66,0x0F,0x62,0xC1      ; punpckldq xmm0,xmm1
  .byte 0x66,0x0F,0x6E,0x4B,0x10 ; movd xmm1,[ebx+16]
  .byte 0x66,0x0F,0x6E,0x53,0x18 ; movd xmm2,[ebx+24]
  .byte 0x66,0x0F,0x62,0xCA      ; punpckldq xmm1,xmm2
  .byte 0x66,0x0F,0x6C,0xC1      ; punpcklqdq xmm0,xmm1
  .byte 0xF3,0x0F,0x7F,0x07      ; movdqu [edi],xmm0
  ADD $32,%EBX
  ADD $16,%EDI
  SUB $1,%EBP
  JNZ @vl_g
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
vl_slow:
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @h_vload

h_vstore_sse2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  TEST $3,%ECX
  JNZ @vs_slow
  MOV %ECX,%EDX
  CMP $RAWG,%EDX
  JB @vs_ok
  CMP $0x10000,%EDX
  JB @vs_slow
vs_ok:
  MOV %ECX,%EDX
  SHR $2,%EDX
  AND [MASKM],%EDX
  MOV [MASKM],%EBX
  SUB $15,%EBX
  CMP %EBX,%EDX
  JA @vs_slow
  MOV %EAX,%ESI
  SHR $20,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EDX,%EBX
  SHL $3,%EBX
  ADD $G+2,%EBX
  MOV %ESI,%EDI
  MOV $4,%EBP
vs_g:
  .byte 0xF3,0x0F,0x6F,0x07      ; movdqu xmm0,[edi]
  .byte 0x66,0x0F,0x7E,0x03      ; movd [ebx],xmm0
  .byte 0x66,0x0F,0x73,0xD8,0x04 ; psrldq xmm0,4
  .byte 0x66,0x0F,0x7E,0x43,0x08 ; movd [ebx+8],xmm0
  .byte 0x66,0x0F,0x73,0xD8,0x04
  .byte 0x66,0x0F,0x7E,0x43,0x10 ; movd [ebx+16],xmm0
  .byte 0x66,0x0F,0x73,0xD8,0x04
  .byte 0x66,0x0F,0x7E,0x43,0x18 ; movd [ebx+24],xmm0
  ADD $32,%EBX
  ADD $16,%EDI
  SUB $1,%EBP
  JNZ @vs_g
  MOV %ECX,%EBX
  SHR $2,%EBX
  AND [MASKM],%EBX
  SHL $3,%EBX
  ADD $G,%EBX
  MOV $16,%ECX
vs_h:
  .byte 0x66,0xC7,0x03,0xF8,0x7F    ; mov word [ebx],0x7FF8
  .byte 0x66,0xC7,0x43,0x06,0xF8,0x7F ; mov word [ebx+6],0x7FF8
  ADD $8,%EBX
  SUB $1,%ECX
  JNZ @vs_h
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
vs_slow:
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @h_vstore

; ---- AVX2 tier: VDP4B 256-bit dispatch --------------------------------
h_vdp4b_disp:
  MOVZXB [AVX2F],%EDX
  TEST %EDX,%EDX
  JNZ @h_vdp4b_avx2
  JMP @h_vdp4b

h_vdp4b_avx2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV %EAX,%EBX
  SHR $20,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV $2,%ECX
vdp_a_l:
  .byte 0xC5,0xFE,0x6F,0x06      ; vmovdqu ymm0,[esi]
  .byte 0xC5,0xFE,0x6F,0x17      ; vmovdqu ymm2,[edi]
  .byte 0xC5,0xDD,0xEF,0xE4      ; vpxor ymm4,ymm4,ymm4
  .byte 0xC5,0xFD,0x6F,0xC8      ; vmovdqa ymm1,ymm0
  .byte 0xC5,0xDD,0x64,0xE1      ; vpcmpgtb ymm4,ymm4,ymm1
  .byte 0xC5,0xF5,0x60,0xCC      ; vpunpcklbw ymm1,ymm1,ymm4
  .byte 0xC5,0xD5,0xEF,0xED      ; vpxor ymm5,ymm5,ymm5
  .byte 0xC5,0xFD,0x6F,0xDA      ; vmovdqa ymm3,ymm2
  .byte 0xC5,0xD5,0x64,0xEB      ; vpcmpgtb ymm5,ymm5,ymm3
  .byte 0xC5,0xE5,0x60,0xDD      ; vpunpcklbw ymm3,ymm3,ymm5
  .byte 0xC5,0xF5,0xF5,0xCB      ; vpmaddwd ymm1,ymm1,ymm3
  .byte 0xC5,0xFD,0x6F,0xF1      ; vmovdqa ymm6,ymm1
  .byte 0xC5,0xFD,0x70,0xF6,0xB1 ; vpshufd ymm6,ymm6,0xB1
  .byte 0xC5,0xF5,0xFE,0xCE      ; vpaddd ymm1,ymm1,ymm6
  .byte 0xC5,0xFD,0x70,0xC9,0x08 ; vpshufd ymm1,ymm1,0x08
  .byte 0xC5,0xFD,0x6F,0xF1      ; vmovdqa ymm6,ymm1
  .byte 0xC5,0xDD,0xEF,0xE4      ; vpxor ymm4,ymm4,ymm4
  .byte 0xC5,0xFD,0x6F,0xC8      ; vmovdqa ymm1,ymm0
  .byte 0xC5,0xDD,0x64,0xE1      ; vpcmpgtb ymm4,ymm4,ymm1
  .byte 0xC5,0xF5,0x68,0xCC      ; vpunpckhbw ymm1,ymm1,ymm4
  .byte 0xC5,0xD5,0xEF,0xED      ; vpxor ymm5,ymm5,ymm5
  .byte 0xC5,0xFD,0x6F,0xDA      ; vmovdqa ymm3,ymm2
  .byte 0xC5,0xD5,0x64,0xEB      ; vpcmpgtb ymm5,ymm5,ymm3
  .byte 0xC5,0xE5,0x68,0xDD      ; vpunpckhbw ymm3,ymm3,ymm5
  .byte 0xC5,0xF5,0xF5,0xCB      ; vpmaddwd ymm1,ymm1,ymm3
  .byte 0xC5,0xFD,0x6F,0xF9      ; vmovdqa ymm7,ymm1
  .byte 0xC5,0xFD,0x70,0xFF,0xB1 ; vpshufd ymm7,ymm7,0xB1
  .byte 0xC5,0xF5,0xFE,0xCF      ; vpaddd ymm1,ymm1,ymm7
  .byte 0xC5,0xFD,0x70,0xC9,0x08 ; vpshufd ymm1,ymm1,0x08
  .byte 0xC5,0xCD,0x6C,0xF1      ; vpunpcklqdq ymm6,ymm6,ymm1
  .byte 0xC5,0xFE,0x7F,0x33      ; vmovdqu [ebx],ymm6
  ADD $32,%ESI
  ADD $32,%EDI
  ADD $32,%EBX
  SUB $1,%ECX
  JNZ @vdp_a_l
  .byte 0xC5,0xF8,0x77           ; vzeroupper
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop

; ---- AVX2 packed arithmetic and runtime dispatch ----
h_vadd8_disp:
  MOVZXB [AVX2F],%EDX
  TEST %EDX,%EDX
  JNZ @h_vadd8_avx2
  JMP @h_vadd8_sse2
h_vsub8_disp:
  MOVZXB [AVX2F],%EDX
  TEST %EDX,%EDX
  JNZ @h_vsub8_avx2
  JMP @h_vsub8_sse2
h_vadd32_disp:
  MOVZXB [AVX2F],%EDX
  TEST %EDX,%EDX
  JNZ @h_vadd32_avx2
  JMP @h_vadd32_sse2
h_vsub32_disp:
  MOVZXB [AVX2F],%EDX
  TEST %EDX,%EDX
  JNZ @h_vsub32_avx2
  JMP @h_vsub32_sse2
h_vmul32_disp:
  MOVZXB [AVX2F],%EDX
  TEST %EDX,%EDX
  JNZ @h_vmul32_avx2
  JMP @h_vmul32_sse2
h_vadd8_avx2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $2,%ECX
va8a_l:
  .byte 0xC5,0xFE,0x6F,0x06      ; vmovdqu ymm0,[esi]
  .byte 0xC5,0xFE,0x6F,0x0B      ; vmovdqu ymm1,[ebx]
  .byte 0xC5,0xFD,0xFC,0xC1      ; vpaddb ymm0,ymm0,ymm1
  .byte 0xC5,0xFE,0x7F,0x07      ; vmovdqu [edi],ymm0
  ADD $32,%ESI
  ADD $32,%EBX
  ADD $32,%EDI
  SUB $1,%ECX
  JNZ @va8a_l
  .byte 0xC5,0xF8,0x77           ; vzeroupper
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vsub8_avx2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $2,%ECX
vs8a_l:
  .byte 0xC5,0xFE,0x6F,0x06
  .byte 0xC5,0xFE,0x6F,0x0B
  .byte 0xC5,0xFD,0xF8,0xC1      ; vpsubb
  .byte 0xC5,0xFE,0x7F,0x07
  ADD $32,%ESI
  ADD $32,%EBX
  ADD $32,%EDI
  SUB $1,%ECX
  JNZ @vs8a_l
  .byte 0xC5,0xF8,0x77           ; vzeroupper
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vadd32_avx2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $2,%ECX
va32a_l:
  .byte 0xC5,0xFE,0x6F,0x06
  .byte 0xC5,0xFE,0x6F,0x0B
  .byte 0xC5,0xFD,0xFE,0xC1      ; vpaddd
  .byte 0xC5,0xFE,0x7F,0x07
  ADD $32,%ESI
  ADD $32,%EBX
  ADD $32,%EDI
  SUB $1,%ECX
  JNZ @va32a_l
  .byte 0xC5,0xF8,0x77           ; vzeroupper
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vsub32_avx2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $2,%ECX
vs32a_l:
  .byte 0xC5,0xFE,0x6F,0x06
  .byte 0xC5,0xFE,0x6F,0x0B
  .byte 0xC5,0xFD,0xFA,0xC1      ; vpsubd
  .byte 0xC5,0xFE,0x7F,0x07
  ADD $32,%ESI
  ADD $32,%EBX
  ADD $32,%EDI
  SUB $1,%ECX
  JNZ @vs32a_l
  .byte 0xC5,0xF8,0x77           ; vzeroupper
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop
h_vmul32_avx2:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  SHR $20,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV $2,%ECX
vm32a_l:
  .byte 0xC5,0xFE,0x6F,0x06      ; vmovdqu ymm0,[esi]
  .byte 0xC5,0xFE,0x6F,0x1B      ; vmovdqu ymm3,[ebx]
  .byte 0xC5,0xFD,0x6F,0xD0      ; vmovdqa ymm2,ymm0
  .byte 0xC5,0xFD,0xF4,0xC3      ; vpmuludq ymm0,ymm0,ymm3
  .byte 0xC5,0xED,0x73,0xD2,0x20 ; vpsrlq ymm2,ymm2,32
  .byte 0xC5,0xE5,0x73,0xD3,0x20 ; vpsrlq ymm3,ymm3,32
  .byte 0xC5,0xED,0xF4,0xD3      ; vpmuludq ymm2,ymm2,ymm3
  .byte 0xC5,0xFD,0x70,0xC0,0x08 ; vpshufd ymm0,ymm0,0x08
  .byte 0xC5,0xFD,0x70,0xD2,0x08 ; vpshufd ymm2,ymm2,0x08
  .byte 0xC5,0xFD,0x62,0xC2      ; vpunpckldq ymm0,ymm0,ymm2
  .byte 0xC5,0xFE,0x7F,0x07      ; vmovdqu [edi],ymm0
  ADD $32,%ESI
  ADD $32,%EBX
  ADD $32,%EDI
  SUB $1,%ECX
  JNZ @vm32a_l
  .byte 0xC5,0xF8,0x77           ; vzeroupper
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop

; ---- VDP4B4: 8 signed Q4 weights x 8 signed i8 activations per lane ----
; Activations are Vb (low 4 bytes) plus V(b+1) (high 4 bytes).  Scalar
; exact reference; SSE2/AVX2 lowering is a later tier.
h_vdp4b4:
  PUSH %ESI
  PUSH %EDI
  PUSH %EBX
  PUSH %EBP
  MOV %EAX,%ESI
  SHR $16,%ESI
  AND $15,%ESI
  SHL $6,%ESI
  ADD $VREG,%ESI
  MOV %EAX,%EBX
  AND $15,%EBX
  SHL $6,%EBX
  ADD $VREG,%EBX
  MOV %EAX,%EDI
  AND $15,%EDI
  ADD $1,%EDI
  AND $15,%EDI
  SHL $6,%EDI
  ADD $VREG,%EDI
  MOV %EAX,%EBP
  SHR $20,%EBP
  AND $15,%EBP
  SHL $6,%EBP
  ADD $VREG,%EBP
  MOV $16,%ECX
vq4_l:
  PUSH %ECX
  MOV [ESI],%EAX
  MOV [EBX],%EDX
  MOV [EDI],%ECX
  CALL @v_q4dot
  MOV %EAX,[EBP]
  POP %ECX
  ADD $4,%ESI
  ADD $4,%EBX
  ADD $4,%EDI
  ADD $4,%EBP
  SUB $1,%ECX
  JNZ @vq4_l
  POP %EBP
  POP %EBX
  POP %EDI
  POP %ESI
  JMP @loop

; eax=weight dword, edx=act0 dword, ecx=act1 dword -> eax=dot
v_q4dot:
  PUSH %EBX
  PUSH %ESI
  PUSH %EDI
  PUSH %EBP
  MOV %EAX,%EBX
  MOV %EDX,%ESI
  MOV %ECX,%EDI
  XOR %EBP,%EBP
  MOV $4,%ECX
q4a_l:
  MOV %EBX,%EAX
  AND $0xF,%EAX
  TEST $8,%AL
  JZ @q4a_p
  SUB $16,%EAX
q4a_p:
  MOV %ESI,%EDX
  AND $0xFF,%EDX
  SHL $24,%EDX
  SAR $24,%EDX
  IMUL %EDX,%EAX
  ADD %EAX,%EBP
  SHR $4,%EBX
  SHR $8,%ESI
  SUB $1,%ECX
  JNZ @q4a_l
  MOV $4,%ECX
q4b_l:
  MOV %EBX,%EAX
  AND $0xF,%EAX
  TEST $8,%AL
  JZ @q4b_p
  SUB $16,%EAX
q4b_p:
  MOV %EDI,%EDX
  AND $0xFF,%EDX
  SHL $24,%EDX
  SAR $24,%EDX
  IMUL %EDX,%EAX
  ADD %EAX,%EBP
  SHR $4,%EBX
  SHR $8,%EDI
  SUB $1,%ECX
  JNZ @q4b_l
  MOV %EBP,%EAX
  POP %EBP
  POP %EDI
  POP %ESI
  POP %EBX
  RET

; ---- r33: E820 -> PMEM v1 boot map at guest word 0x3F800 ----
; Copies type 1/2/3/4 E820 ranges clipped to the guest word window
; [G, G+NWORDS*8), in BIOS order (ascending on IEEE 1275 systems).
; Runs after the guest image load and before the interpreter enters pc 0.
; putw writes a complete NaN word (payload + class heads), so consumers can
; use ordinary LD.  No PAE/bank state is touched here.
memmap_build:
  PUSH %EBX
  PUSH %ECX
  PUSH %EDX
  PUSH %ESI
  PUSH %EDI
  PUSH %EBP
  MOV $MM_HDR0,%EAX
  MOV $MM_MAGIC,%EBX
  MOV $10,%ECX
  CALL @putw
  MOV $MM_CNT,%EAX
  XOR %EBX,%EBX
  MOV $10,%ECX
  CALL @putw
  MOV $MM_VER,%EAX
  MOV $MM_VERSION,%EBX
  MOV $10,%ECX
  CALL @putw
  MOV $MM_FLG,%EAX
  MOV $MM_F_E820,%EBX
  MOV $10,%ECX
  CALL @putw
  XOR %EDI,%EDI
  MOVZWL [0x5FC],%ECX
  TEST %ECX,%ECX
  JZ @mb_none
  MOV $0x600,%ESI
mb_loop:
  MOV [NWORDS],%EBP
  SHL $3,%EBP
  ADD $G,%EBP
  MOV [ESI+16],%EAX
  CMP $1,%EAX
  JB @mb_next
  CMP $4,%EAX
  JA @mb_next
  CMP $MM_MAX,%EDI
  JAE @mb_next
  MOV [ESI+4],%EDX
  TEST %EDX,%EDX
  JNZ @mb_next
  MOV [ESI],%EDX
  MOV [ESI+8],%EBX
  MOV [ESI+12],%EAX
  TEST %EAX,%EAX
  JNZ @mb_lenbig
  ADD %EDX,%EBX
  JC @mb_lenbig
  JMP @mb_clip
mb_lenbig:
  MOV $0xFFFFFFFF,%EBX
mb_clip:
  CMP $G,%EDX
  JAE @mb_start_ok
  MOV $G,%EDX
mb_start_ok:
  CMP %EBP,%EBX
  JBE @mb_end_ok
  MOV %EBP,%EBX
mb_end_ok:
  CMP %EBX,%EDX
  JAE @mb_next
  MOV %EDX,%EBP
  SUB $G,%EBP
  SHR $3,%EBP
  SUB %EDX,%EBX
  SHR $3,%EBX
  JZ @mb_next
  PUSH %ECX
  PUSH %EBX
  MOV %EDI,%EDX
  SHL $2,%EDX
  ADD $MM_ENT0,%EDX
  MOV %EDX,%EAX
  MOV %EBP,%EBX
  MOV $10,%ECX
  CALL @putw
  POP %EBX
  MOV %EDI,%EDX
  SHL $2,%EDX
  ADD $MM_ENT1,%EDX
  MOV %EDX,%EAX
  MOV $10,%ECX
  CALL @putw
  MOV [ESI+16],%EBX
  MOV %EDI,%EDX
  SHL $2,%EDX
  ADD $MM_ENT2,%EDX
  MOV %EDX,%EAX
  MOV $10,%ECX
  CALL @putw
  MOV %EDI,%EDX
  SHL $2,%EDX
  ADD $MM_ENT3,%EDX
  MOV %EDX,%EAX
  XOR %EBX,%EBX
  MOV $10,%ECX
  CALL @putw
  POP %ECX
  ADD $1,%EDI
mb_next:
  ADD $24,%ESI
  SUB $1,%ECX
  JNZ @mb_loop
mb_none:
  TEST %EDI,%EDI
  JNZ @mb_count
  MOV $MM_ENT0,%EAX
  XOR %EBX,%EBX
  MOV $10,%ECX
  CALL @putw
  MOV $MM_ENT1,%EAX
  MOV [NWORDS],%EBX
  MOV $10,%ECX
  CALL @putw
  MOV $MM_ENT2,%EAX
  MOV $1,%EBX
  MOV $10,%ECX
  CALL @putw
  MOV $MM_ENT3,%EAX
  XOR %EBX,%EBX
  MOV $10,%ECX
  CALL @putw
  MOV $1,%EDI
mb_count:
  MOV $MM_CNT,%EAX
  MOV %EDI,%EBX
  MOV $10,%ECX
  CALL @putw
  POP %EBP
  POP %EDI
  POP %ESI
  POP %EDX
  POP %ECX
  POP %EBX
  RET

; ---- KABI v0.1 trap path (native side of spec/KERNEL_ABI.md) ----------------
; Frame words are ordinary guest words: payload at +2, valid heads.  putw
; writes them, LD/LDB in the kernel reads them.  The interpreter keeps the
; guest register file in R; ESI is the guest pc (already advanced past the
; trapping instruction when a handler runs).
h_svc:
  PUSH %EAX
  MOV [KENTRY],%EAX
  CMP $0xFFFFFFFF,%EAX
  JE @badop
  MOV [KIN],%EAX
  TEST %EAX,%EAX
  JNZ @badop
  MOV [KFRAME],%EDI
  XOR %EBP,%EBP
hsv_l:
  MOV [R+EBP*4],%EBX
  MOV %EDI,%EAX
  ADD %EBP,%EAX
  CALL @putw
  ADD $1,%EBP
  CMP $16,%EBP
  JB @hsv_l
  MOV %ESI,%EBX
  MOV %EDI,%EAX
  ADD $16,%EAX
  CALL @putw
  MOV [FLAGM],%EBX
  MOV %EDI,%EAX
  ADD $17,%EAX
  CALL @putw
  XOR %EBX,%EBX
  MOV %EDI,%EAX
  ADD $18,%EAX
  CALL @putw
  MOV %EDI,%EAX
  ADD $19,%EAX
  CALL @putw
  POP %EBX
  AND $0xFFFF,%EBX
  MOV %EDI,%EAX
  ADD $20,%EAX
  CALL @putw
  XOR %EBX,%EBX
  MOV %EDI,%EAX
  ADD $21,%EAX
  CALL @putw
  MOV [R+56],%EBX
  MOV %EDI,%EAX
  ADD $22,%EAX
  CALL @putw
  XOR %EBX,%EBX
  MOV %EDI,%EAX
  ADD $23,%EAX
  CALL @putw
  MOV [KSTACK],%EBX
  CMP $0xFFFFFFFF,%EBX
  JE @hsv_nostk
  MOV %EBX,[R+56]
hsv_nostk:
  MOVL $1,[KIN]
  MOV [KENTRY],%ESI
  JMP @loop

h_svcret:
  MOV [KIN],%EAX
  TEST %EAX,%EAX
  JZ @badop
  MOV [KFRAME],%EDI
  XOR %EBP,%EBP
hsvr_l:
  MOV %EDI,%EAX
  ADD %EBP,%EAX
  MOV [G+2+EAX*8],%EBX
  MOV %EBX,[R+EBP*4]
  ADD $1,%EBP
  CMP $16,%EBP
  JB @hsvr_l
  MOV %EDI,%EAX
  ADD $16,%EAX
  MOV [G+2+EAX*8],%ESI
  MOV %EDI,%EAX
  ADD $17,%EAX
  MOV [G+2+EAX*8],%EBX
  MOV %EBX,[FLAGM]
  MOV %EDI,%EAX
  ADD $19,%EAX
  MOV [G+2+EAX*8],%EBX
  TEST $3,%EBX
  JNZ @hsvr_noret
  MOV %EDI,%EAX
  ADD $21,%EAX
  MOV [G+2+EAX*8],%EBX
  MOV %EBX,[R+4]
hsvr_noret:
  MOVL $0,[KIN]
  MOVL $0,[KSTATUS]
  JMP @loop

kabi_irq:
  MOV [KFRAME],%EDI
  XOR %EBP,%EBP
kirq_l:
  MOV [R+EBP*4],%EBX
  MOV %EDI,%EAX
  ADD %EBP,%EAX
  CALL @putw
  ADD $1,%EBP
  CMP $16,%EBP
  JB @kirq_l
  MOV %ESI,%EBX
  MOV %EDI,%EAX
  ADD $16,%EAX
  CALL @putw
  MOV [FLAGM],%EBX
  MOV %EDI,%EAX
  ADD $17,%EAX
  CALL @putw
  XOR %EBX,%EBX
  MOV %EDI,%EAX
  ADD $18,%EAX
  CALL @putw
  MOV $1,%EBX
  MOV %EDI,%EAX
  ADD $19,%EAX
  CALL @putw
  XOR %EBX,%EBX
  MOV %EDI,%EAX
  ADD $20,%EAX
  CALL @putw
  MOV %EDI,%EAX
  ADD $21,%EAX
  CALL @putw
  MOV [R+56],%EBX
  MOV %EDI,%EAX
  ADD $22,%EAX
  CALL @putw
  XOR %EBX,%EBX
  MOV %EDI,%EAX
  ADD $23,%EAX
  CALL @putw
  MOV [KSTACK],%EBX
  CMP $0xFFFFFFFF,%EBX
  JE @kirq_nostk
  MOV %EBX,[R+56]
kirq_nostk:
  MOVL $1,[KIN]
  MOV [KENTRY],%ESI
  RET

; Full KABI port handlers, kept after the fixed .org regions.
h_outl_full:
  MOV [R+EBP],%EAX
  MOV %ECX,%EDX
  AND $0xFFFF,%EDX
  CMP $0x4E00,%EDX
  JB @ol_raw
  CMP $0x4E0F,%EDX
  JA @ol_raw
  ; 0x4E08..0x4E0F are the nansmp/SMP services, not KABI entry ports.
  ; Skip the KENTRY/KIN gate so a product with a real kernel entry can use
  ; the atomic and CPU services.
  CMP $0x4E08,%EDX
  JAE @ol_store
  MOV [KENTRY],%EBX
  CMP $0xFFFFFFFF,%EBX
  JE @ol_store
  MOV [KIN],%EBX
  TEST %EBX,%EBX
  JZ @badop
ol_store:
  CMP $0x4E00,%EDX
  JE @ol_kentry
  CMP $0x4E01,%EDX
  JE @ol_kframe
  CMP $0x4E02,%EDX
  JE @ol_ktimer
  CMP $0x4E03,%EDX
  JE @ol_kstack
  CMP $0x4E04,%EDX
  JE @ol_kregions
  CMP $0x4E05,%EDX
  JE @ol_ktcb
  CMP $0x4E06,%EDX
  JE @loop
  CMP $0x4E08,%EDX
  JE @loop
  CMP $0x4E09,%EDX
  JE @loop
  CMP $0x4E0A,%EDX
  JE @ol_ipi
  CMP $0x4E0B,%EDX
  JE @ol_cas
  CMP $0x4E0C,%EDX
  JE @ol_fadd
  CMP $0x4E0D,%EDX
  JE @ol_fence
  CMP $0x4E0E,%EDX
  JE @loop
  CMP $0x4E0F,%EDX
  JE @loop
  MOV %EAX,[KDATA]
  MOV %EAX,[DATAB]
  JMP @loop
ol_kentry:
  MOV %EAX,[KENTRY]
  JMP @loop
ol_kframe:
  MOV %EAX,[KFRAME]
  JMP @loop
ol_ktimer:
  MOV %EAX,[KTIMER]
  MOV %EAX,[KTIMERL]
  JMP @loop
ol_kstack:
  MOV %EAX,[KSTACK]
  JMP @loop
ol_kregions:
  MOV %EAX,[KREGIONS]
  JMP @loop
ol_ktcb:
  MOV %EAX,[KTCB]
  JMP @loop
ol_ipi:
  MOVL $0,[KDATA]
  JMP @loop
ol_fence:
  .byte 0x0F,0xAE,0xF0
  MOVL $0,[KDATA]
  JMP @loop
; nansmp CAS: EAX=descriptor {addr,expected,new}; payload is at word+2
ol_cas:
  PUSH %ESI
  PUSH %EDI
  MOV %EAX,%ESI
  MOV [G+ESI*8+2],%EBX
  MOV [G+ESI*8+10],%EAX
  MOV [G+ESI*8+18],%ECX
  ; LOCK CMPXCHG ECX,[G+EBX*8+2]  (payload at word+2)
  .byte 0xF0,0x0F,0xB1,0x0C,0xDD,0x02,0x00,0x20,0x00
  MOV %EAX,[KDATA]
  POP %EDI
  POP %ESI
  JMP @loop
; nansmp fetch-add: EAX=descriptor {addr,delta}
ol_fadd:
  PUSH %ESI
  PUSH %EDI
  MOV %EAX,%ESI
  MOV [G+ESI*8+2],%EBX
  MOV [G+ESI*8+10],%ECX
  ; LOCK XADD ECX,[G+EBX*8+2]  (payload at word+2)
  .byte 0xF0,0x0F,0xC1,0x0C,0xDD,0x02,0x00,0x20,0x00
  MOV %ECX,[KDATA]
  POP %EDI
  POP %ESI
  JMP @loop
ol_raw:
  OUT %EAX,%DX
  JMP @loop

h_inl_full:
  MOV %ECX,%EDX
  AND $0xFFFF,%EDX
  CMP $0x4E00,%EDX
  JB @il_raw
  CMP $0x4E0F,%EDX
  JA @il_raw
  CMP $0x4E00,%EDX
  JE @il_kentry
  CMP $0x4E01,%EDX
  JE @il_kframe
  CMP $0x4E02,%EDX
  JE @il_ktimer
  CMP $0x4E03,%EDX
  JE @il_kstack
  CMP $0x4E04,%EDX
  JE @il_kregions
  CMP $0x4E05,%EDX
  JE @il_ktcb
  CMP $0x4E06,%EDX
  JE @il_status
  CMP $0x4E08,%EDX
  JE @il_cpu
  CMP $0x4E09,%EDX
  JE @il_steps
  CMP $0x4E0A,%EDX
  JE @il_zero
  CMP $0x4E0B,%EDX
  JE @il_kdata
  CMP $0x4E0C,%EDX
  JE @il_kdata
  CMP $0x4E0D,%EDX
  JE @il_zero
  CMP $0x4E0E,%EDX
  JE @il_apmap
  CMP $0x4E0F,%EDX
  JE @il_ncpu
  MOV [KDATA],%EBX
  JMP @st
il_apmap:
  MOV [SM_MAP],%EBX
  JMP @st
il_ncpu:
  MOV [SM_NCPU],%EBX
  JMP @st
il_kentry:
  MOV [KENTRY],%EBX
  JMP @st
il_kframe:
  MOV [KFRAME],%EBX
  JMP @st
il_ktimer:
  MOV [KTIMER],%EBX
  JMP @st
il_kstack:
  MOV [KSTACK],%EBX
  JMP @st
il_kregions:
  MOV [KREGIONS],%EBX
  JMP @st
il_ktcb:
  MOV [KTCB],%EBX
  JMP @st
il_status:
  MOV [KSTATUS],%EBX
  JMP @st
il_cpu:
  XOR %EBX,%EBX
  JMP @st
il_steps:
  MOV [STEPS],%EBX
  JMP @st
il_zero:
  XOR %EBX,%EBX
  JMP @st
il_kdata:
  MOV [KDATA],%EBX
  JMP @st
il_raw:
  IN %DX,%EAX
  MOV %EAX,%EBX
  JMP @st

kabi_tick:
  MOV [KTIMER],%EAX
  TEST %EAX,%EAX
  JZ @kt_ret
  MOV [KENTRY],%EBX
  CMP $0xFFFFFFFF,%EBX
  JE @kt_ret
  MOV [KIN],%EBX
  TEST %EBX,%EBX
  JNZ @kt_ret
  MOV [KTIMERL],%EBX
  SUB $1,%EBX
  MOV %EBX,[KTIMERL]
  JNZ @kt_ret
  MOV %EAX,[KTIMERL]
  CALL @kabi_irq
kt_ret:
  RET

; ---- x64 SMP startup: x2APIC INIT-SIPI-SIPI + long-mode AP trampoline ----
; The AP starts in real mode at 0x6000, builds PAE/long mode with the BSP's
; identity PML4 at 0x30000, and reports its CPUID initial APIC id before
; parking.  Guest execution on x64 APs is a later step.
smp_start:
  PUSH %EAX
  PUSH %EBX
  PUSH %ECX
  PUSH %EDX
  PUSH %ESI
  PUSH %EDI
  MOV $1,%EAX
  XOR %ECX,%ECX
  .byte 0x0F,0xA2             ; cpuid.1
  MOV %EBX,%EDX
  SHR $16,%EDX
  AND $0xFF,%EDX
  TEST %EDX,%EDX
  JNZ @smp_x_have
  MOV $1,%EDX
smp_x_have:
  MOV %EDX,[SM_NCPU]
  CMP $1,%EDX
  JBE @smp_x_out
  MOV $ap_stub,%ESI
  MOV $0x6000,%EDI
  MOV $0x200,%ECX
  REPMOVSD
  ; Map the xAPIC window at 0xFEE00000 with a 2 MiB page.  The boot shim's
  ; tables cover 0..1 GiB in PDPT[0]; PDPT[3] gets a private PD2 at 0x33000.
  MOVL $0x33003,[0x31018]
  MOVL $0,[0x3101C]
  MOV $0x33000,%EDI
  XOR %EAX,%EAX
  MOV $0x400,%ECX
  REPSTOSD
  MOVL $0xFEE00083,[0x33000+0xFB8]
  MOVL $0,[0x33000+0xFBC]
  ; enable xAPIC (IA32_APIC_BASE bit 11) and the spurious vector.  Long mode
  ; sign-extends absolute disp32 operands, so use a zero-extended base.
  MOV $0x1B,%ECX
  .byte 0x0F,0x32
  OR $0x800,%EAX
  .byte 0x0F,0x30
  MOV $0xFEE00000,%EBX
  MOVL $0x1FF,[EBX+0xF0]
  MOVL $0,[EBX+0x310]
  ; INIT all-excluding-self
  MOVL $0x000C4500,[EBX+0x300]
  CALL @smp_x_delivery
  MOV $0x200000,%ECX
  CALL @smp_x_delay
  ; SIPI vector 6 twice
  MOVL $0x000C4606,[EBX+0x300]
  CALL @smp_x_delivery
  MOV $0x200000,%ECX
  CALL @smp_x_delay
  MOVL $0x000C4606,[EBX+0x300]
  CALL @smp_x_delivery
  MOV $0x4000000,%EDI
smp_x_poll:
  MOV [SM_DONE],%EAX
  MOV [SM_NCPU],%EBX
  SUB $1,%EBX
  CMP %EBX,%EAX
  JE @smp_x_ready
  SUB $1,%EDI
  JNZ @smp_x_poll
  JMP @smp_x_out
smp_x_ready:
  MOV $SM_FLAGS,%ESI
  MOV [SM_NCPU],%EBX
  XOR %EDI,%EDI
smp_x_pack_l:
  CMP %EBX,%EDI
  JAE @smp_x_out
  MOV [ESI+EDI*4],%EAX
  TEST %EAX,%EAX
  JZ @smp_x_pack_n
  MOV $1,%EAX
  MOV %EDI,%ECX
  SHL %CL,%EAX
  MOV [SM_MAP],%EDX
  OR %EAX,%EDX
  MOV %EDX,[SM_MAP]
smp_x_pack_n:
  ADD $1,%EDI
  JMP @smp_x_pack_l
smp_x_out:
  POP %EDI
  POP %ESI
  POP %EDX
  POP %ECX
  POP %EBX
  POP %EAX
  RET
smp_x_delay:
  SUB $1,%ECX
  JNZ @smp_x_delay
  RET
smp_x_delivery:
  MOV $0x100000,%ECX
smp_x_dl:
  MOV [EBX+0x300],%EAX
  TEST $0x1000,%EAX
  JZ @smp_x_dd
  SUB $1,%ECX
  JNZ @smp_x_dl
smp_x_dd:
  RET

; AP long-mode blob: 0x6000 real-mode stub, 0x6100 GDT, 0x6200 PM32,
; 0x6300 long mode.
.align 512
ap_stub:
  .code16
  CLI
  XOR %AX,%AX
  MOV %AX,%DS
  MOV %AX,%ES
  MOV %AX,%SS
  MOV $0x5800,%SP
  IN $0x92,%AL
  OR $2,%AL
  OUT %AL,$0x92
  LGDT [0x6120]
  MOV %CR0,%EAX
  OR $1,%EAX
  MOV %EAX,%CR0
  LJMP $8,$0x6200
  .align 256
ap_gdt:
  .long 0,0
  .long 0x0000FFFF,0x00CF9A00
  .long 0x0000FFFF,0x00CF9200
  .long 0x0000FFFF,0x00AF9A00
ap_gdtr:
  .word 31
  .long 0x6100
  .align 512
ap_pm32:
  .code32
  MOV $0x10,%AX
  MOV %AX,%DS
  MOV %AX,%ES
  MOV %AX,%SS
  MOV $0x30000,%EAX
  MOV %EAX,%CR3
  .byte 0x0F,0x20,0xE0      ; mov eax,cr4
  OR $0x20,%EAX             ; PAE
  .byte 0x0F,0x22,0xE0      ; mov cr4,eax
  MOV $0xC0000080,%ECX
  .byte 0x0F,0x32           ; rdmsr EFER
  OR $0x100,%EAX            ; LME
  .byte 0x0F,0x30
  MOV %CR0,%EAX
  OR $0x80000001,%EAX       ; PG|PE
  MOV %EAX,%CR0
  LJMP $0x18,$0x6400
  .align 512
ap64:
  .code64
  MOV $0x10,%AX
  MOV %AX,%DS
  MOV %AX,%ES
  MOV %AX,%SS
  MOV %AX,%FS
  MOV %AX,%GS
  MOV $0x7C000,%ESP
  MOV $1,%EAX
  XOR %ECX,%ECX
  .byte 0x0F,0xA2           ; cpuid.1
  SHR $24,%EBX
  MOV %EBX,%EDI
  SHL $2,%EDI
  ADD $SM_FLAGS,%EDI
  MOVL $1,[EDI]
  MOV $SM_DONE,%EBX
  .byte 0xF0,0xFF,0x03      ; lock inc dword [rbx]
ap_halt:
  CLI
  HLT
  JMP @ap_halt
