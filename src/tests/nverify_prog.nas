; nverify_prog.nas - deterministic F14 differential fixture.
; Driver below word 8192; guest program at .org 8192.  The mode word is
; patched by tools/nverify_gate.sh: 0 = native NaN16 on the C core,
; 1 = the same guest image under src/tools/n16i.nas (raw-NaN interpreter).
; The guest deposits 32 trace words at guest word 8256 and prints
; "NV" + the final 32-bit accumulator as eight hex digits.
JMP @drv
.include "../tools/n16i.nas"
drv:
  MOVI r13,1
  LD r1,r0,@mode
  CMP r1,r0
  JMP[EQ] @gmain
  MOVI r1,@gmain
  MOVI r2,8192
  MOVI r3,8191
  CALL @n16i_run
  ST r1,r0,@res_steps
  HALT
mode:
.word 0
res_steps:
.word 0
.org 8192
gmain:
  MOVI r13,1
  MOVI r1,1            ; i = 1
  MOVI r2,0            ; acc = 0
  MOVI r3,32           ; count
  MOVI r4,8256         ; trace base in the guest window
gloop:
  MUL r5,r1,r1         ; i*i
  SHL r6,r2,5          ; acc << 5
  ADD r6,r6,r5
  MOVI r7,0x1234
  ADD r6,r6,r7
  ADD r2,r6,r0         ; acc = (acc<<5) + i*i + 0x1234
  SUB r8,r1,r13
  ADD r9,r4,r8
  ST r2,r9,0           ; trace[i-1] = acc
  ADD r1,r1,r13
  CMP r1,r3
  JMP[LE] @gloop
  MOVI r9,78           ; 'N'
  PUTC r9
  MOVI r9,86           ; 'V'
  PUTC r9
  MOVI r6,8
  ADD r9,r2,r0
gph:
  SHR r10,r9,28
  MOVI r11,15
  BOOL.8 r10,r10,r11
  MOVI r11,10
  CMP r10,r11
  JMP[LT] @gnum
  ADDI r10,r10,55      ; 'A'..'F'
  JMP @gput
gnum:
  ADDI r10,r10,48      ; '0'..'9'
gput:
  PUTC r10
  SHL r9,r9,4
  SUB r6,r6,r13
  CMP r6,r0
  JMP[NE] @gph
  MOVI r9,10
  PUTC r9
  HALT
