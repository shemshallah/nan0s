; smp_ap_test.nas - native AP bring-up + real APIC ids, end to end.
;
; The 32-bit core starts APs via INIT-SIPI-SIPI before the guest runs.  Each
; AP sets its LAPIC-id bit in the SM_FLAGS bitmap with a locked update.  The
; guest reads the logical CPU count (0x4E0F) and the AP bitmap (0x4E0E),
; prints "S<ncpu>A<bitmap>C<cpu-id>", and requires the bitmap to match the
; CPU count.  With -smp 1 the same guest must print S1A00000000C0; with -smp 2
; S2A00000002C0; with -smp 4 S4A0000000EC0.
.org 0
MOVI r13,1
MOVI r14,0xE000
MOVI r1,83
PUTC r1
MOVI r1,0x4E0F
INL r2,r1
ADD r10,r2,r0
ADDI r1,r2,48
PUTC r1
MOVI r1,65
PUTC r1
MOVI r1,0x4E0E
INL r1,r1
CALL @hex8
MOVI r1,67
PUTC r1
MOVI r1,0x4E08
INL r1,r1
ADDI r1,r1,48
PUTC r1
MOVI r1,10
PUTC r1
; cpu id must be 0 on the BSP
MOVI r1,0x4E08
INL r1,r1
CMP r1,r0
JMP[NE] @bad
; expected bitmap = (1<<ncpu)-2
CMP r10,r13
JMP[EQ] @chk1
MOVI r4,2
CMP r10,r4
JMP[EQ] @chk2
MOVI r4,4
CMP r10,r4
JMP[EQ] @chk4
JMP @bad
chk1:
MOVI r5,0
JMP @chk
chk2:
MOVI r5,2
JMP @chk
chk4:
MOVI r5,14
chk:
MOVI r1,0x4E0E
INL r1,r1
CMP r1,r5
JMP[NE] @bad
MOVI r1,79
PUTC r1
MOVI r1,75
PUTC r1
MOVI r1,10
PUTC r1
HALT
bad:
MOVI r1,33
PUTC r1
MOVI r1,10
PUTC r1
HALT
hex8:
MOVI r2,8
hex8_l:
ADD r3,r1,r0
SHR r3,r3,28
MOVI r4,10
CMP r3,r4
JMP[LT] @hex8_d
ADDI r3,r3,7
hex8_d:
ADDI r3,r3,48
PUTC r3
SHL r1,r1,4
ADDI r2,r2,0xFFFF
JMP[NE] @hex8_l
RET
.org 0x10000
