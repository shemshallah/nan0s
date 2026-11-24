; ndr.nas - complete an NDR after nd_emit wrote w0..w3.
; w4 = r[a], w5 = r[b], w6 = r[d] from the decoded nd_raw word.
; w7 = FNV-1a/32 over w0..w6. Preserves r11-r15.
nd_ndr_finish:
  ST r15,r0,@ndr_lnk
  LD r6,r0,@nd_raw
  ; w4 = r[a]
  SHR r7,r6,20
  MOVI r8,15
  BOOL.8 r7,r7,r8
  LD r7,r7,@nd_regs
  MOVI r8,@nd_rec
  ADDI r8,r8,4
  ST r7,r8,0
  ; w5 = r[b]
  MOVI r7,15
  BOOL.8 r7,r6,r7
  LD r7,r7,@nd_regs
  ADDI r8,r8,1
  ST r7,r8,0
  ; w6 = r[d]
  SHR r7,r6,16
  MOVI r9,15
  BOOL.8 r7,r7,r9
  LD r7,r7,@nd_regs
  ADDI r8,r8,1
  ST r7,r8,0
  ; w7 = FNV-1a/32 over w0..w6
  MOVI r1,0x9DC5
  MOVHI r1,0x811C
  MOVI r2,0x0193
  MOVHI r2,0x0100
  MOVI r3,@nd_rec
  MOVI r4,7
ndr_l:
  LD r5,r3,0
  BOOL.6 r1,r1,r5
  MUL r1,r1,r2
  ADD r3,r3,r13
  SUB r4,r4,r13
  CMP r4,r0
  JMP[NE] @ndr_l
  ST r1,r3,0
  LD r15,r0,@ndr_lnk
  RET
ndr_lnk:
.word 0
