; ndbg_diff_body.nas - deterministic differential target for the NANDBG core.
; It is included at word 8192 by both a native wrapper and a stepped wrapper.
; It prints an 8-digit checksum and halts. No TICK, KEY, ports or clock: only
; deterministic instructions, so native and stepped serial transcripts must be
; byte-identical.
tgt_start:
  MOVI r13,1
  MOVI r10,0

  ; ---- integer arithmetic and flags -----------------------------------------
  MOVI r1,7
  MOVI r2,3
  ADD r3,r1,r2
  ADD r10,r10,r3
  SUB r3,r1,r2
  ADD r10,r10,r3
  MUL r3,r1,r2
  ADD r10,r10,r3
  DIVU r3,r1,r2
  ADD r10,r10,r3
  MODU r3,r1,r2
  ADD r10,r10,r3
  SHL r3,r1,2
  ADD r10,r10,r3
  SHR r3,r3,1
  ADD r10,r10,r3
  SAR r3,r1,1
  ADD r10,r10,r3
  MOVI r4,1
  SUB r4,r4,r1          ; -6
  MOVI r5,2
  DIV r6,r4,r5          ; -3
  ADD r10,r10,r6
  MOD r6,r4,r5          ; 0
  ADD r10,r10,r6
  CMPS r4,r1            ; -6 < 7 -> k=1
  MOVI[LT] r6,1
  MOVI[GE] r6,2
  ADD r10,r10,r6
  CMP r1,r2             ; 7 > 3
  MOVI[GT] r6,4
  MOVI[LE] r6,8
  ADD r10,r10,r6
  ADDI r6,r1,5
  ADD r10,r10,r6

  ; MOVHI + high multiplies
  MOVI r7,1
  MOVHI r7,1            ; 0x00010000
  MULH r6,r7,r7         ; 1
  ADD r10,r10,r6
  MULHU r6,r7,r7        ; 1
  ADD r10,r10,r6

  MOVI r1,65
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; all 16 BOOL truth tables
  MOVI r1,0xCCCC
  MOVHI r1,0xCCCC
  MOVI r2,0xAAAA
  MOVHI r2,0xAAAA
  BOOL.0 r3,r1,r2
  ADD r10,r10,r3
  BOOL.1 r3,r1,r2
  ADD r10,r10,r3
  BOOL.2 r3,r1,r2
  ADD r10,r10,r3
  BOOL.3 r3,r1,r2
  ADD r10,r10,r3
  BOOL.4 r3,r1,r2
  ADD r10,r10,r3
  BOOL.5 r3,r1,r2
  ADD r10,r10,r3
  BOOL.6 r3,r1,r2
  ADD r10,r10,r3
  BOOL.7 r3,r1,r2
  ADD r10,r10,r3
  BOOL.8 r3,r1,r2
  ADD r10,r10,r3
  BOOL.9 r3,r1,r2
  ADD r10,r10,r3
  BOOL.10 r3,r1,r2
  ADD r10,r10,r3
  BOOL.11 r3,r1,r2
  ADD r10,r10,r3
  BOOL.12 r3,r1,r2
  ADD r10,r10,r3
  BOOL.13 r3,r1,r2
  ADD r10,r10,r3
  BOOL.14 r3,r1,r2
  ADD r10,r10,r3
  BOOL.15 r3,r1,r2
  ADD r10,r10,r3

  ; ---- memory and class ops -------------------------------------------------
  MOVI r8,0x3000
  MOVI r1,0x5678
  MOVHI r1,0x1234       ; 0x12345678
  ST r1,r8,0
  LD r7,r8,0
  ADD r10,r10,r7
  LDN r9,r8,0           ; 10
  ADD r10,r10,r9
  MOVI r9,15
  STW r1,r8,r9
  LDN r9,r8,8           ; 15
  ADD r10,r10,r9
  LD r7,r8,8
  ADD r10,r10,r7
  BSWAPM r8,0
  BSWAPM r8,0
  LA r9,0x10000
  LDB r7,r9,0
  ADD r10,r10,r7
  MOVI r2,0x55
  STB r2,r9,1
  LDB r7,r9,1
  ADD r10,r10,r7
  MOVI r1,0x3000
  MOVI r2,0x3100
  MOVI r3,4
  BCOPY r2,r1,r3
  MOVI r4,0xAA
  MOVI r5,0x3200
  MOVI r6,4
  BFILL r5,r4,r6
  LD r7,r5,0
  ADD r10,r10,r7

  MOVI r1,66
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; ---- calls, indirect calls and far branches ------------------------------
  CALL @tgt_sub
  MOVI r1,@tgt_sub
  CALLR r1
  MOVI r1,@tgt_afterj
  JMPR r1
tgt_never:
  HALT
tgt_afterj:
  JMPF @tgt_far
tgt_never2:
  HALT
tgt_far:
  CALLF @tgt_sub

  MOVI r1,67
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; ---- float ops ------------------------------------------------------------
  MOVI r1,5
  CVTIF r2,r1           ; 5.0
  MOVI r3,2
  CVTIF r4,r3           ; 2.0
  FADD r5,r2,r4         ; 7.0
  CVTFI r6,r5
  ADD r10,r10,r6
  FSUB r5,r2,r4         ; 3.0
  CVTFI r6,r5
  ADD r10,r10,r6
  FMUL r5,r2,r4         ; 10.0
  CVTFI r6,r5
  ADD r10,r10,r6
  FDIV r5,r2,r4         ; 2.5 -> 2
  CVTFI r6,r5
  ADD r10,r10,r6
  MOVI r1,4
  CVTIF r2,r1
  FSQRT r5,r2           ; 2.0
  CVTFI r6,r5
  ADD r10,r10,r6
  FCMP r2,r2
  MOVI[EQ] r6,1
  MOVI[NE] r6,0
  ADD r10,r10,r6
  MOVI r1,0
  CVTIF r2,r1
  FEXP r5,r2            ; 1.0
  CVTFI r6,r5
  ADD r10,r10,r6
  FTANH r5,r2           ; 0.0
  CVTFI r6,r5
  ADD r10,r10,r6
  MOVI r1,1
  CVTIF r2,r1
  FLOG r5,r2            ; 0.0
  CVTFI r6,r5
  ADD r10,r10,r6

  MOVI r1,68
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; ---- DP4B ----------------------------------------------------------------
  MOVI r1,0x0304
  MOVHI r1,0x0102       ; bytes 4,3,2,1
  MOVI r2,0x0403
  MOVHI r2,0x0201       ; bytes 1,2,3,4
  DP4B r3,r1,r2         ; 20
  ADD r10,r10,r3

  MOVI r1,69
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; ---- vector file ----------------------------------------------------------
  MOVI r1,0x0403
  MOVHI r1,0x0201       ; 0x01020304
  VBCAST r0,r1
  VGET r3,r0,0
  ADD r10,r10,r3
  VGET r3,r0,15
  ADD r10,r10,r3
  MOVI r2,5
  VSET r0,r2,1
  VGET r3,r0,1
  ADD r10,r10,r3

  MOVI r1,71
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  MOVI r1,1
  VBCAST r1,r1          ; V1 all ones (32-bit lanes)
  MOVI r2,2
  VBCAST r2,r2          ; V2 all twos
  VADD32 r3,r1,r2
  VGET r4,r3,0
  ADD r10,r10,r4
  VSUB32 r3,r2,r1
  VGET r4,r3,0
  ADD r10,r10,r4
  VMUL32 r3,r1,r2
  VGET r4,r3,0
  ADD r10,r10,r4

  MOVI r1,72
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex
  VADD8 r3,r1,r2
  VGET r4,r3,0
  ADD r10,r10,r4
  VSUB8 r3,r2,r1
  VGET r4,r3,0
  ADD r10,r10,r4
  VDP4B r3,r1,r2
  VGET r4,r3,0
  ADD r10,r10,r4

  MOVI r1,73
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; VLOAD/VSTORE round-trip through real memory
  LA r6,0x20000
  VSTORE r1,r6
  VZERO r7
  VLOAD r7,r6
  VGET r4,r7,0
  ADD r10,r10,r4

  MOVI r1,74
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; VDP4B4: q4 weights x i8 activations
  VZERO r1
  VZERO r2
  VZERO r3
  MOVI r1,0x1111
  MOVHI r1,0x1111
  VSET r1,r1,0
  MOVI r2,0x0101
  MOVHI r2,0x0101
  VSET r2,r2,0
  VSET r3,r2,0
  VDP4B4 r4,r1,r2
  VGET r5,r4,0
  ADD r10,r10,r5

  MOVI r1,70
  PUTC r1
  ADD r1,r10,r0
  CALL @tgt_puthex

  ; ---- print checksum -------------------------------------------------------
  ADD r1,r10,r0
  CALL @tgt_puthex
  HALT

tgt_sub:
  ADDI r10,r10,1
  RET

; print r1 as 8 hex digits plus newline
tgt_puthex:
  MOVI r8,8
tph_loop:
  SHR r2,r1,28
  SHL r1,r1,4
  MOVI r3,48
  ADD r3,r3,r2
  MOVI r4,10
  CMP r2,r4
  MOVI r5,7
  ADD[GE] r3,r3,r5
  PUTC r3
  SUB r8,r8,r13
  CMP r8,r0
  JMP[NE] @tph_loop
  MOVI r1,10
  PUTC r1
  RET
