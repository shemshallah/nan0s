; nasm.nas - unified NaN assembler.  Mode 0 (NaN words) is nasm0's ABI:
; set V_SRCB/V_OUTB/V_LABB/V_EXPB/V_EXPCB and call run.  Mode 1 (x86 bytes)
; starts at _start and uses the fixed SRC/OUT/LAB/STACK layout.
JMP @x1__start
; nasm0 - the NaN16 assembler written in NaN16 (round 08). Reads packed source text (4 chars/word, LE, NUL-terminated)
; at #SRC and emits NaN words (STW) at #OUT. Two passes over the SAME parser: pass 1 counts words and defines labels
; (unresolved @refs read 0), pass 2 stores. Every stored word is mirror-checked: BSWAPM, LDN must equal rot2(n), BSWAPM back.
; Region bases (SRC/OUT/LAB/EXP/EXPC) are 32-bit values in VARS (V_SRCB..), so buffers may live anywhere in a flat NaN memory.
; Conventions: r0=0 r13=1 r14=SP(grows up) r15=link. Every routine clobbers r1..r9 ONLY; r10..r12 survive calls.
; Grammar v0: label:  .word expr,..  .org expr  .str "..." (\n \r \t \0 \\ \")  .equ NAME expr  MNEM[.N|[PRED]] operands
; operands: rN  | expr = term{(+|-)term}  term = decimal | 0xHEX | @label | #EQU ; unary '-' allowed. Hash h=(h<<5)+h+c from 5381.
.equ SRC 2048
.equ EXP 5120
.equ EXPC 6144
.equ VARS 6272
.equ OUT 6400
.equ LAB 7424
.equ STACK 7936
.equ V_PASS 6272
.equ V_IDX 6273
.equ V_CW 6274
.equ V_CN 6275
.equ V_SRCP 6276
.equ V_PB 6277
.equ V_NLAB 6278
.equ V_ERR 6279
.equ V_MIRR 6280
.equ V_OP 6281
.equ V_FORM 6282
.equ V_N 6283
.equ V_D 6284
.equ V_A 6285
.equ V_I 6286
.equ V_ACC 6287
.equ V_SGN 6288
.equ V_H 6289
.equ V_EXPN 6290
.equ V_FIRST 6291
.equ V_DIFF 6292
.equ V_SRCB 6293
.equ V_OUTB 6294
.equ V_LABB 6295
.equ V_EXPB 6296
.equ V_EXPCB 6297
; ---- run: one full pass over the source (V_PASS = 1 or 2 set by caller)
run:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#V_SRCB
ST r2,r0,#V_SRCP
ST r0,r0,#V_CN
ST r0,r0,#V_PB
ST r0,r0,#V_IDX
pl:
CALL @nextc
CMP r1,r0
JMP[EQ] @pdone
MOVI r4,10
CMP r1,r4
JMP[EQ] @pl
MOVI r4,59
CMP r1,r4
JMP[EQ] @pskip
MOVI r4,46
CMP r1,r4
JMP[EQ] @pdir
CALL @rdhash1
CALL @getc
MOVI r4,58
CMP r1,r4
JMP[EQ] @plabel
CALL @ungetc
CALL @do_ins
JMP @pl
pskip:
CALL @skipline
JMP @pl
plabel:
LD r2,r0,#V_PASS
CMP r2,r13
JMP[NE] @pskip
LD r8,r0,#V_IDX
CALL @define
JMP @pskip
pdir:
CALL @rdhash
MOVI r6,@dirs
MOVI r7,2
CALL @look
CMP r1,r0
JMP[EQ] @pbad
LD r2,r1,1
CMP r2,r13
JMP[EQ] @d_word
MOVI r4,2
CMP r2,r4
JMP[EQ] @d_str
MOVI r4,4
CMP r2,r4
JMP[EQ] @d_org
JMP @d_equ
pbad:
LD r2,r0,#V_ERR
ADD r2,r2,r13
ST r2,r0,#V_ERR
JMP @pskip
pdone:
SUB r14,r14,r13
LD r15,r14,0
RET
; ---- directives
d_word:
CALL @expr
MOVI r1,10
BOOL.12 r2,r8,r8
CALL @emit
CALL @nextc
MOVI r4,44
CMP r1,r4
JMP[EQ] @d_word
CALL @ungetc
JMP @pskip
d_equ:
CALL @nextc
CALL @rdhash1
ST r5,r0,#V_H
CALL @expr
LD r5,r0,#V_H
LD r2,r0,#V_PASS
CMP r2,r13
JMP[NE] @pskip
CALL @define
JMP @pskip
; .org expr - pad to an absolute word index (both passes)
d_org:
CALL @expr
LD r2,r0,#V_IDX
CMP r8,r2
JMP[LT] @pbad
LD r3,r0,#V_PASS
MOVI r4,2
CMP r3,r4
JMP[NE] @org_set
org_pad:
LD r2,r0,#V_IDX
CMP r2,r8
JMP[GE] @org_set
MOVI r1,10
MOVI r2,0
CALL @emit
JMP @org_pad
org_set:
ST r8,r0,#V_IDX
JMP @pskip
d_str:
CALL @nextc
MOVI r10,0
MOVI r11,0
ds1:
CALL @getc
CMP r1,r0
JMP[EQ] @ds_end
MOVI r4,34
CMP r1,r4
JMP[EQ] @ds_end
MOVI r4,92
CMP r1,r4
JMP[NE] @ds_put
CALL @getc
MOVI r4,110
CMP r1,r4
MOVI[EQ] r1,10
MOVI r4,114
CMP r1,r4
MOVI[EQ] r1,13
MOVI r4,116
CMP r1,r4
MOVI[EQ] r1,9
MOVI r4,48
CMP r1,r4
MOVI[EQ] r1,0
ds_put:
CALL @spush
JMP @ds1
ds_end:
MOVI r1,0
CALL @spush
ds_pad:
CMP r11,r0
JMP[EQ] @pskip
MOVI r1,0
CALL @spush
JMP @ds_pad
; spush: r1=char; r10=acc r11=count. Packs LE: acc=(acc>>8)|(c<<24); at 4 chars emits a +q/+q data word.
spush:
SHR r10,r10,8
SHL r2,r1,24
BOOL.14 r10,r10,r2
ADD r11,r11,r13
MOVI r4,4
CMP r11,r4
RET[NE]
ST r15,r14,0
ADD r14,r14,r13
MOVI r1,10
BOOL.12 r2,r10,r10
CALL @emit
SUB r14,r14,r13
LD r15,r14,0
MOVI r10,0
MOVI r11,0
RET
; ---- instruction: r5 = mnemonic hash
do_ins:
ST r15,r14,0
ADD r14,r14,r13
MOVI r6,@mnem
MOVI r7,3
CALL @look
CMP r1,r0
JMP[EQ] @di_err
LD r2,r1,1
ST r2,r0,#V_OP
LD r2,r1,2
ST r2,r0,#V_FORM
MOVI r2,15
ST r2,r0,#V_N
ST r0,r0,#V_D
ST r0,r0,#V_A
ST r0,r0,#V_I
CALL @getc
MOVI r4,46
CMP r1,r4
JMP[EQ] @di_dot
MOVI r4,91
CMP r1,r4
JMP[EQ] @di_pred
CALL @ungetc
JMP @dl
di_dot:
CALL @getc
CALL @tnum
ST r8,r0,#V_N
JMP @dl
di_pred:
CALL @rdhash
MOVI r6,@preds
MOVI r7,2
CALL @look
CMP r1,r0
JMP[EQ] @di_err
LD r2,r1,1
ST r2,r0,#V_N
CALL @getc
dl:
LD r9,r0,#V_FORM
MOVI r4,15
BOOL.8 r10,r9,r4
CMP r10,r0
JMP[EQ] @de
SHR r9,r9,4
ST r9,r0,#V_FORM
CALL @nextc
MOVI r4,44
CMP r1,r4
JMP[NE] @dl1
CALL @nextc
dl1:
MOVI r4,4
CMP r10,r4
JMP[EQ] @dl_imm
MOVI r4,5
CMP r10,r4
JMP[EQ] @dl_imm
CALL @getc
CALL @tnum
JMP @dl_set
dl_imm:
CALL @ungetc
CALL @expr
dl_set:
MOVI r4,5
CMP r10,r4
JMP[NE] @dls0
SHR r4,r8,16
MOVI r5,15
BOOL.8 r4,r4,r5
ST r4,r0,#V_A
SHR r4,r8,20
BOOL.8 r4,r4,r5
ST r4,r0,#V_D
JMP @dls3
dls0:
MOVI r4,1
CMP r10,r4
JMP[NE] @dls2
ST r8,r0,#V_D
JMP @dl
dls2:
MOVI r4,2
CMP r10,r4
JMP[NE] @dls3
ST r8,r0,#V_A
JMP @dl
dls3:
ST r8,r0,#V_I
JMP @dl
de:
LD r1,r0,#V_OP
SHL r2,r1,24
LD r3,r0,#V_D
SHL r3,r3,20
BOOL.14 r2,r2,r3
LD r3,r0,#V_A
SHL r3,r3,16
BOOL.14 r2,r2,r3
LD r3,r0,#V_I
MOVI r4,65535
BOOL.8 r3,r3,r4
BOOL.14 r2,r2,r3
LD r1,r0,#V_N
CALL @emit
LD r1,r0,#V_OP
SHR r1,r1,8
CMP r1,r0
JMP[EQ] @di_x
LD r3,r0,#V_D
SHL r3,r3,20
MOVI r2,512
SHL r2,r2,16
BOOL.14 r2,r2,r3
LD r3,r0,#V_I
SHR r3,r3,16
MOVI r4,65535
BOOL.8 r3,r3,r4
BOOL.14 r2,r2,r3
LD r1,r0,#V_N
CALL @emit
di_x:
CALL @skipline
SUB r14,r14,r13
LD r15,r14,0
RET
di_err:
LD r2,r0,#V_ERR
ADD r2,r2,r13
ST r2,r0,#V_ERR
JMP @di_x
; ---- emit: r1=class n, r2=payload. Always counts; pass 2 also STW + mirror check. clobbers r3..r6
emit:
LD r3,r0,#V_IDX
ADD r4,r3,r13
ST r4,r0,#V_IDX
LD r4,r0,#V_PASS
MOVI r5,2
CMP r4,r5
RET[NE]
LD r4,r0,#V_OUTB
ADD r3,r3,r4
STW r2,r3,r1
BSWAPM r3,0
LDN r4,r3,0
BSWAPM r3,0
MOVI r5,3
BOOL.8 r5,r1,r5
SHL r5,r5,2
SHR r6,r1,2
BOOL.14 r5,r5,r6
CMP r4,r5
RET[EQ]
LD r4,r0,#V_MIRR
ADD r4,r4,r13
ST r4,r0,#V_MIRR
RET
; ---- define: r5=hash r8=value -> label/equ table (2 words/entry, hash 0 ends). pass 1 only
define:
LD r2,r0,#V_NLAB
SHL r3,r2,1
LD r4,r0,#V_LABB
ADD r3,r3,r4
ST r5,r3,0
ST r8,r3,1
ADD r2,r2,r13
ST r2,r0,#V_NLAB
ST r0,r3,2
RET
; ---- look: r5=hash r6=table r7=stride -> r1=entry address or 0
look:
LD r2,r6,0
CMP r2,r0
JMP[EQ] @lk0
CMP r2,r5
JMP[EQ] @lk2
ADD r6,r6,r7
JMP @look
lk0:
MOVI r1,0
RET
lk2:
BOOL.12 r1,r6,r6
RET
; ---- expr: reads from stream, r8 = value. term = @label | #EQU | number, joined by + -, unary - allowed
expr:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,#V_ACC
ST r0,r0,#V_SGN
CALL @nextc
MOVI r4,45
CMP r1,r4
JMP[NE] @ex_t
ST r13,r0,#V_SGN
CALL @nextc
ex_t:
CALL @term
LD r2,r0,#V_SGN
CMP r2,r0
JMP[EQ] @ex_a
SUB r8,r0,r8
ex_a:
LD r2,r0,#V_ACC
ADD r2,r2,r8
ST r2,r0,#V_ACC
CALL @nextc
MOVI r4,43
CMP r1,r4
JMP[EQ] @ex_p
MOVI r4,45
CMP r1,r4
JMP[EQ] @ex_m
CALL @ungetc
LD r8,r0,#V_ACC
SUB r14,r14,r13
LD r15,r14,0
RET
ex_p:
ST r0,r0,#V_SGN
CALL @nextc
JMP @ex_t
ex_m:
ST r13,r0,#V_SGN
CALL @nextc
JMP @ex_t
; term: r1 = first char (consumed) -> r8
term:
ST r15,r14,0
ADD r14,r14,r13
MOVI r4,64
CMP r1,r4
JMP[EQ] @tm_l
MOVI r4,35
CMP r1,r4
JMP[EQ] @tm_l
CALL @tnum
JMP @tm_x
tm_l:
CALL @rdhash
LD r6,r0,#V_LABB
MOVI r7,2
CALL @look
CMP r1,r0
JMP[EQ] @tm_miss
LD r8,r1,1
JMP @tm_x
tm_miss:
MOVI r8,0
LD r2,r0,#V_PASS
MOVI r3,2
CMP r2,r3
JMP[NE] @tm_x
LD r2,r0,#V_ERR
ADD r2,r2,r13
ST r2,r0,#V_ERR
tm_x:
SUB r14,r14,r13
LD r15,r14,0
RET
; ---- tnum: r1 = first digit (consumed). decimal or 0xHEX -> r8; the terminator is pushed back
tnum:
ST r15,r14,0
ADD r14,r14,r13
MOVI r8,0
MOVI r4,48
CMP r1,r4
JMP[NE] @tn_d
CALL @getc
MOVI r4,120
CMP r1,r4
JMP[EQ] @tn_h
tn_d:
MOVI r4,48
CMP r1,r4
JMP[LT] @tn_e
MOVI r4,58
CMP r1,r4
JMP[GE] @tn_e
MOVI r4,48
SUB r1,r1,r4
SHL r5,r8,3
SHL r6,r8,1
ADD r8,r5,r6
ADD r8,r8,r1
CALL @getc
JMP @tn_d
tn_h:
CALL @getc
MOVI r4,48
CMP r1,r4
JMP[LT] @tn_e
MOVI r4,58
CMP r1,r4
JMP[LT] @th_d
MOVI r4,65
CMP r1,r4
JMP[LT] @tn_e
MOVI r4,71
CMP r1,r4
JMP[LT] @th_u
MOVI r4,97
CMP r1,r4
JMP[LT] @tn_e
MOVI r4,103
CMP r1,r4
JMP[GE] @tn_e
MOVI r4,87
JMP @th_a
th_u:
MOVI r4,55
JMP @th_a
th_d:
MOVI r4,48
th_a:
SUB r1,r1,r4
SHL r8,r8,4
ADD r8,r8,r1
JMP @tn_h
tn_e:
CALL @ungetc
SUB r14,r14,r13
LD r15,r14,0
RET
; ---- rdhash1 (r1 = first char already read) / rdhash (fresh): r5 = hash of [A-Za-z0-9_]*, terminator pushed back
rdhash1:
ST r15,r14,0
ADD r14,r14,r13
MOVI r5,5381
JMP @rh_a
rdhash:
ST r15,r14,0
ADD r14,r14,r13
MOVI r5,5381
rh1:
CALL @getc
CALL @isid
CMP r6,r0
JMP[EQ] @rh2
rh_a:
SHL r6,r5,5
ADD r5,r6,r5
ADD r5,r5,r1
JMP @rh1
rh2:
CALL @ungetc
SUB r14,r14,r13
LD r15,r14,0
RET
; ---- isid: r1 char -> r6 = 1 if [0-9A-Z_a-z] else 0 (clobbers r7)
isid:
MOVI r6,1
MOVI r7,48
CMP r1,r7
JMP[LT] @isn
MOVI r7,58
CMP r1,r7
RET[LT]
MOVI r7,65
CMP r1,r7
JMP[LT] @isn
MOVI r7,91
CMP r1,r7
RET[LT]
MOVI r7,95
CMP r1,r7
RET[EQ]
MOVI r7,97
CMP r1,r7
JMP[LT] @isn
MOVI r7,123
CMP r1,r7
RET[LT]
isn:
MOVI r6,0
RET
; ---- source reader. getc -> r1 (0 at end; clobbers r2,r3). ungetc: push r1 back. nextc: next non-blank (space/tab/CR) char.
getc:
LD r2,r0,#V_PB
CMP r2,r0
JMP[EQ] @gc1
ST r0,r0,#V_PB
SUB r1,r2,r13
RET
gc1:
LD r2,r0,#V_CN
CMP r2,r0
JMP[NE] @gc2
LD r3,r0,#V_SRCP
LD r1,r3,0
ST r1,r0,#V_CW
ADD r3,r3,r13
ST r3,r0,#V_SRCP
MOVI r2,4
gc2:
SUB r2,r2,r13
ST r2,r0,#V_CN
LD r1,r0,#V_CW
SHR r3,r1,8
ST r3,r0,#V_CW
MOVI r3,255
BOOL.8 r1,r1,r3
RET
ungetc:
ADD r2,r1,r13
ST r2,r0,#V_PB
RET
nextc:
ST r15,r14,0
ADD r14,r14,r13
nx1:
CALL @getc
MOVI r4,32
CMP r1,r4
JMP[EQ] @nx1
MOVI r4,9
CMP r1,r4
JMP[EQ] @nx1
MOVI r4,13
CMP r1,r4
JMP[EQ] @nx1
SUB r14,r14,r13
LD r15,r14,0
RET
skipline:
ST r15,r14,0
ADD r14,r14,r13
sk1:
CALL @getc
CMP r1,r0
JMP[EQ] @skx
MOVI r4,10
CMP r1,r4
JMP[NE] @sk1
skx:
SUB r14,r14,r13
LD r15,r14,0
RET

.include "nasm0_tables.nas"
; ---- x86 backend (nasm1), namespaced x1_/Z1_ ----
; nasm1 — x86 emitter written in NaN16 (round 16). Two-pass, branch-relaxing, flat byte output.
; Input: x86 source text (4 chars/word LE, NUL-terminated) at SRC. Output: raw bytes at OUT.
; stdout: 'Y' or 'N' (errors), newline, then the emitted bytes via PUTC.
; Language: see spec/NANASM1_SPEC.md. Registers EAX..EDI AX..DI AL..BH XMM0-7 CR0 CR2 CR3 ES..GS.
; Operands: $expr | [disp+REG*scale] | @label | REG.  Directives: .byte .word .long .str .equ
; .org .align .base .code16 .code32
.equ Z1_SRC 0x20000
.equ Z1_OUT 0x100000
.equ Z1_LAB 0x140000
.equ Z1_LONGB 0x141000
.equ Z1_STACK 0x1F0000
.equ Z1_V_PASS 0x4000
.equ Z1_V_PC 0x4001
.equ Z1_V_BASE 0x4002
.equ Z1_V_ERR 0x4003
.equ Z1_V_NLAB 0x4004
.equ Z1_V_REDO 0x4005
.equ Z1_V_BRN 0x4006
.equ Z1_V_MODE 0x4007
.equ Z1_V_SRCP 0x4008
.equ Z1_V_CW 0x4009
.equ Z1_V_CN 0x400A
.equ Z1_V_PB 0x400B
.equ Z1_V_OBP 0x400C
.equ Z1_V_SRCB 0x400D
.equ Z1_V_OUTB 0x400E
.equ Z1_V_LABB 0x400F
.equ Z1_V_LONGB 0x4010
.equ Z1_V_ACC 0x4011
.equ Z1_V_SGN 0x4012
.equ Z1_V_H 0x4013
.equ Z1_V_SZ 0x4014
.equ Z1_V_OPN 0x4015
.equ Z1_V_AUX0 0x4016
.equ Z1_V_MB 0x4017
.equ Z1_V_MI 0x4018
.equ Z1_V_MS 0x4019
.equ Z1_V_MD 0x401A
.equ Z1_V_MR 0x401B
.equ Z1_V_BT 0x401C
.equ Z1_V_BS 0x401D
.equ Z1_V_BL 0x401E
.equ Z1_V_BLN 0x401F
.equ Z1_V_TMP 0x4020
.equ Z1_V_TMPX 0x4021
.equ Z1_V_AUX1 0x4022
.equ Z1_V_AUX2 0x4023
.equ Z1_V_ESITE 0x4024
.equ Z1_OPBASE 0x4030
x1__start:
  MOVI r0,0
  MOVI r13,1
  MOVI r14,0x0000
  MOVHI r14,0x001F
  ST r0,r0,#Z1_V_BASE
  ST r0,r0,#Z1_V_ERR
  ST r0,r0,#Z1_V_ESITE
  ST r0,r0,#Z1_V_NLAB
  MOVI r4,1
  ST r4,r0,#Z1_V_MODE
  MOVI r4,0x0000
  MOVHI r4,0x0002
  ST r4,r0,#Z1_V_SRCB
  MOVI r4,0x0000
  MOVHI r4,0x0010
  ST r4,r0,#Z1_V_OUTB
  MOVI r4,0x0000
  MOVHI r4,0x0014
  ST r4,r0,#Z1_V_LABB
  MOVI r4,0x1000
  MOVHI r4,0x0014
  ST r4,r0,#Z1_V_LONGB
  CALL @x1_pass1
  CALL @x1_pass1
x1_iter:
  CALL @x1_pass1
  LD r4,r0,#Z1_V_REDO
  CMP r4,r0
  JMP[NE] @x1_iter
  CALL @x1_pass2
  LD r1,r0,#Z1_V_ERR
  MOVI r2,89
  CMP r1,r0
  MOVI[NE] r2,78
  PUTC r2
  MOVI r1,10
  PUTC r1
  LD r1,r0,#Z1_V_ERR
  CMP r1,r0
  JMP[EQ] @x1_noerr
  MOVI r1,0x45
  PUTC r1
  LD r1,r0,#Z1_V_ESITE
  PUTC r1
  SHR r1,r1,8
  PUTC r1
  SHR r1,r1,8
  PUTC r1
  SHR r1,r1,8
  PUTC r1
x1_noerr:
  LD r3,r0,#Z1_V_OUTB
  SHL r3,r3,2
  LD r4,r0,#Z1_V_PC
x1_dump:
  CMP r4,r0
  JMP[EQ] @x1_halt
  LDB r1,r3,0
  PUTC r1
  ADDI r3,r3,1
  SUB r4,r4,r13
  JMP @x1_dump
x1_halt:
  HALT
x1_pass1:
  ST r13,r0,#Z1_V_PASS
  JMP @x1_pass
x1_pass2:
  MOVI r4,2
  ST r4,r0,#Z1_V_PASS
  LD r2,r0,#Z1_V_OUTB
  SHL r2,r2,2
  ST r2,r0,#Z1_V_OBP
x1_pass:
  ST r0,r0,#Z1_V_PC
  ST r0,r0,#Z1_V_CN
  ST r0,r0,#Z1_V_PB
  ST r0,r0,#Z1_V_BRN
  ST r0,r0,#Z1_V_REDO
  LD r2,r0,#Z1_V_SRCB
  ST r2,r0,#Z1_V_SRCP
x1_run:
  ST r15,r14,0
  ADD r14,r14,r13
x1_pl:
  CALL @x1_nextc
  CMP r1,r0
  JMP[EQ] @x1_pdone
  MOVI r4,10
  CMP r1,r4
  JMP[EQ] @x1_pl
  MOVI r4,59
  CMP r1,r4
  JMP[EQ] @x1_pskip
  JMP @x1_pstmt
x1_pstmt:
  MOVI r4,46
  CMP r1,r4
  JMP[EQ] @x1_pdir
  CALL @x1_rdhash1
  CALL @x1_getc
  MOVI r4,58
  CMP r1,r4
  JMP[EQ] @x1_plabel
  CALL @x1_ungetc
  CALL @x1_do_ins
  JMP @x1_pl
x1_pskip:
  CALL @x1_skipline
  JMP @x1_pl
x1_plabel:
  LD r2,r0,#Z1_V_BASE
  LD r3,r0,#Z1_V_PC
  ADD r8,r2,r3
  CALL @x1_define
  CALL @x1_nextc
x1_pl_ws:
  MOVI r4,32
  CMP r1,r4
  JMP[NE] @x1_pl_chk
  CALL @x1_nextc
  JMP @x1_pl_ws
x1_pl_chk:
  CMP r1,r0
  JMP[EQ] @x1_pl_done
  MOVI r4,10
  CMP r1,r4
  JMP[EQ] @x1_pl_done
  JMP @x1_pstmt
x1_pl_done:
  CALL @x1_ungetc
  JMP @x1_pskip
x1_pdir:
  CALL @x1_rdhash
  MOVI r6,@x1_dirs
  MOVI r7,3
  CALL @x1_look
  CMP r1,r0
  JMP[EQ] @x1_perr
  LD r12,r1,1
  JMPR r12
x1_perr:
  CALL @x1_bump_err
  JMP @x1_pskip
x1_pdone:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_do_ins:
  MOVI r6,@x1_mnem
  MOVI r7,3
  CALL @x1_look
  CMP r1,r0
  JMP[EQ] @x1_di_err
  LD r12,r1,1
  LD r2,r1,2
  ST r2,r0,#Z1_V_AUX0
  ST r0,r0,#Z1_V_SZ
  ST r0,r0,#Z1_V_OPN
  CALL @x1_nextc
  CMP r1,r0
  JMP[EQ] @x1_di_go
  MOVI r4,10
  CMP r1,r4
  JMP[EQ] @x1_di_nl
  MOVI r4,59
  CMP r1,r4
  JMP[EQ] @x1_di_nl
  CALL @x1_ungetc
  JMP @x1_di_op
x1_di_nl:
  CALL @x1_ungetc
  JMP @x1_di_go
x1_di_op:
  CALL @x1_parseop
  LD r4,r0,#Z1_V_OPN
  ADD r4,r4,r13
  ST r4,r0,#Z1_V_OPN
  CALL @x1_nextc
  MOVI r4,44
  CMP r1,r4
  JMP[EQ] @x1_di_op
  CALL @x1_ungetc
x1_di_go:
  JMPR r12
x1_di_err:
  CALL @x1_bump_err
x1_endins:
  CALL @x1_skipline
  JMP @x1_pl
x1_parseop:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x1_nextc
  MOVI r4,37
  CMP r1,r4
  JMP[NE] @x1_op_np
  CALL @x1_nextc
x1_op_np:
  MOVI r4,36
  CMP r1,r4
  JMP[EQ] @x1_op_imm
  MOVI r4,91
  CMP r1,r4
  JMP[EQ] @x1_op_mem
  MOVI r4,64
  CMP r1,r4
  JMP[EQ] @x1_op_expr
  MOVI r4,35
  CMP r1,r4
  JMP[EQ] @x1_op_expr
  CALL @x1_rdhash1
  MOVI r6,@x1_regs
  MOVI r7,2
  CALL @x1_look
  CMP r1,r0
  JMP[EQ] @x1_op_err
  LD r5,r1,1
  CALL @x1_slot
  ST r13,r3,0
  ST r5,r3,1
  JMP @x1_op_done
x1_op_imm:
  CALL @x1_expr
  ADD r5,r8,r0
  CALL @x1_slot
  MOVI r4,2
  ST r4,r3,0
  ST r5,r3,1
  JMP @x1_op_done
x1_op_expr:
  CALL @x1_ungetc
  CALL @x1_expr
  ADD r5,r8,r0
  CALL @x1_slot
  MOVI r4,2
  ST r4,r3,0
  ST r5,r3,1
  JMP @x1_op_done
x1_op_mem:
  CALL @x1_memparse
  CALL @x1_slot
  MOVI r4,3
  ST r4,r3,0
  LD r5,r0,#Z1_V_MB
  ST r5,r3,2
  LD r5,r0,#Z1_V_MI
  ST r5,r3,3
  LD r5,r0,#Z1_V_MS
  ST r5,r3,4
  LD r5,r0,#Z1_V_MD
  ST r5,r3,5
  JMP @x1_op_done
x1_op_err:
  CALL @x1_bump_err
x1_op_done:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_slot:
  LD r3,r0,#Z1_V_OPN
  SHL r3,r3,3
  ADDI r3,r3,#Z1_OPBASE
  RET
x1_memparse:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r4,0xFF
  ST r4,r0,#Z1_V_MB
  ST r4,r0,#Z1_V_MI
  ST r13,r0,#Z1_V_MS
  ST r0,r0,#Z1_V_MD
  ST r0,r0,#Z1_V_TMPX
x1_ml:
  CALL @x1_nextc
  MOVI r4,93
  CMP r1,r4
  JMP[EQ] @x1_mdone
  MOVI r4,43
  CMP r1,r4
  JMP[EQ] @x1_mplus
  MOVI r4,45
  CMP r1,r4
  JMP[EQ] @x1_mminus
  MOVI r4,48
  CMP r1,r4
  JMP[LT] @x1_mident
  MOVI r4,58
  CMP r1,r4
  JMP[LT] @x1_mnum
x1_mident:
  MOVI r4,37
  CMP r1,r4
  JMP[EQ] @x1_mpct
  MOVI r4,64
  CMP r1,r4
  JMP[EQ] @x1_mat
  MOVI r4,35
  CMP r1,r4
  JMP[EQ] @x1_mat
  JMP @x1_mregid
x1_mat:
  CALL @x1_rdhash
  LD r6,r0,#Z1_V_LABB
  MOVI r7,2
  CALL @x1_look
  JMP @x1_mlab2
x1_mlab2:
  CMP r1,r0
  JMP[EQ] @x1_mmiss
  LD r8,r1,1
  JMP @x1_mnum2
x1_mmiss:
  MOVI r8,0
  LD r2,r0,#Z1_V_PASS
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @x1_mnum2
  CALL @x1_bump_err
  JMP @x1_mnum2
x1_mpct:
  CALL @x1_nextc
  JMP @x1_mregid
x1_mregid:
  CALL @x1_rdhash1
  MOVI r6,@x1_regs
  MOVI r7,2
  CALL @x1_look
  CMP r1,r0
  JMP[NE] @x1_mregfound
  LD r6,r0,#Z1_V_LABB
  MOVI r7,2
  CALL @x1_look
  JMP @x1_mlab2
x1_mregfound:
  LD r5,r1,1
  CALL @x1_nextc
  MOVI r4,42
  CMP r1,r4
  JMP[EQ] @x1_mscale
  CALL @x1_ungetc
  MOVI r6,1
  JMP @x1_massign
x1_mscale:
  ST r5,r0,#Z1_V_TMPX
  CALL @x1_nextc
  CALL @x1_tnum
  ADD r6,r8,r0
  LD r5,r0,#Z1_V_TMPX
  JMP @x1_massign
x1_massign:
  ADD r1,r5,r0
  CALL @x1_rf
  ADD r5,r1,r0
  MOVI r4,1
  CMP r6,r4
  JMP[EQ] @x1_mreg1
  ST r6,r0,#Z1_V_MS
  ST r5,r0,#Z1_V_MI
  JMP @x1_mafter
x1_mreg1:
  LD r4,r0,#Z1_V_MB
  MOVI r7,0xFF
  CMP r4,r7
  JMP[NE] @x1_midx1
  ST r5,r0,#Z1_V_MB
  JMP @x1_mafter
x1_midx1:
  ST r5,r0,#Z1_V_MI
  JMP @x1_mafter
x1_mnum:
  CALL @x1_tnum
  JMP @x1_mnum2
x1_mnum2:
  LD r4,r0,#Z1_V_TMPX
  CMP r4,r0
  JMP[EQ] @x1_mnum3
  SUB r8,r0,r8
x1_mnum3:
  LD r4,r0,#Z1_V_MD
  ADD r4,r4,r8
  ST r4,r0,#Z1_V_MD
  JMP @x1_mafter
x1_mplus:
  ST r0,r0,#Z1_V_TMPX
  JMP @x1_ml
x1_mminus:
  ST r13,r0,#Z1_V_TMPX
  JMP @x1_ml
x1_mafter:
  CALL @x1_nextc
  MOVI r4,43
  CMP r1,r4
  JMP[EQ] @x1_mplus
  MOVI r4,45
  CMP r1,r4
  JMP[EQ] @x1_mminus
  MOVI r4,93
  CMP r1,r4
  JMP[EQ] @x1_mdone
  CALL @x1_bump_err
x1_mdone:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_bump_err:
  LD r1,r0,#Z1_V_ESITE
  CMP r1,r0
  JMP[NE] @x1_be_have
  LD r1,r0,#Z1_V_SRCP
  ST r1,r0,#Z1_V_ESITE
x1_be_have:
  LD r1,r0,#Z1_V_ERR
  ADD r1,r1,r13
  ST r1,r0,#Z1_V_ERR
  RET
x1_emitb:
  LD r2,r0,#Z1_V_PC
  ADD r2,r2,r13
  ST r2,r0,#Z1_V_PC
  LD r3,r0,#Z1_V_PASS
  MOVI r4,2
  CMP r3,r4
  RET[NE]
  LD r3,r0,#Z1_V_OBP
  STB r1,r3,0
  ADD r3,r3,r13
  ST r3,r0,#Z1_V_OBP
  RET
x1_emitw:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,#Z1_V_TMP
  MOVI r4,255
  BOOL.8 r1,r2,r4
  CALL @x1_emitb
  LD r1,r0,#Z1_V_TMP
  SHR r1,r1,8
  CALL @x1_emitb
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_emitd:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,#Z1_V_TMP
  CALL @x1_emitw
  LD r2,r0,#Z1_V_TMP
  SHR r2,r2,16
  CALL @x1_emitw
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_prefix:
  MOVI r4,2
  CMP r1,r4
  JMP[EQ] @x1_pf2
  MOVI r4,4
  CMP r1,r4
  JMP[NE] @x1_pfx
  LD r4,r0,#Z1_V_MODE
  CMP r4,r0
  JMP[EQ] @x1_pf66
  RET
x1_pf2:
  LD r4,r0,#Z1_V_MODE
  CMP r4,r0
  JMP[EQ] @x1_pfx
x1_pf66:
  MOVI r1,0x66
  JMP @x1_emitb
x1_pfx:
  RET
x1_rf:
  MOVI r4,15
  BOOL.8 r1,r1,r4
  RET
x1_fits8:
  ADD r2,r1,r0
  MOVI r4,0xFF80
  MOVHI r4,0xFFFF
  CMPS r2,r4
  JMP[LT] @x1_f8n
  MOVI r4,127
  CMPS r2,r4
  JMP[GT] @x1_f8n
  MOVI r9,1
  RET
x1_f8n:
  MOVI r9,0
  RET
x1_sz_of:
  LD r2,r0,#Z1_V_SZ
  CMP r2,r0
  JMP[NE] @x1_sz_o
  LD r3,r0,#Z1_V_OPN
  MOVI r5,0
x1_sz_l:
  CMP r5,r3
  JMP[EQ] @x1_sz_z
  SHL r6,r5,3
  ADDI r6,r6,#Z1_OPBASE
  LD r7,r6,0
  MOVI r4,1
  CMP r7,r4
  JMP[NE] @x1_sz_n
  LD r7,r6,1
  SHR r7,r7,4
  MOVI r4,2
  CMP r7,r4
  JMP[GT] @x1_sz_n
  MOVI r4,0
  CMP r7,r4
  JMP[EQ] @x1_sz_1
  MOVI r4,1
  CMP r7,r4
  JMP[EQ] @x1_sz_2
  MOVI r1,4
  RET
x1_sz_1:
  MOVI r1,1
  RET
x1_sz_2:
  MOVI r1,2
  RET
x1_sz_n:
  ADD r5,r5,r13
  JMP @x1_sz_l
x1_sz_z:
  MOVI r1,0
  RET
x1_sz_o:
  ADD r1,r2,r0
  RET
x1_sz_op:
  SHL r3,r2,3
  ADDI r3,r3,#Z1_OPBASE
  LD r4,r3,0
  MOVI r5,1
  CMP r4,r5
  JMP[NE] @x1_so_z
  LD r4,r3,1
  SHR r4,r4,4
  MOVI r5,0
  CMP r4,r5
  JMP[EQ] @x1_so_1
  MOVI r5,1
  CMP r4,r5
  JMP[EQ] @x1_so_2
  MOVI r1,4
  RET
x1_so_1:
  MOVI r1,1
  RET
x1_so_2:
  MOVI r1,2
  RET
x1_so_z:
  MOVI r1,0
  RET
x1_define:
  ST r15,r14,0
  ADD r14,r14,r13
  LD r6,r0,#Z1_V_LABB
  MOVI r7,2
  CALL @x1_look
  CMP r1,r0
  JMP[NE] @x1_df_set
  LD r2,r0,#Z1_V_NLAB
  MOVI r4,511
  CMP r2,r4
  JMP[GE] @x1_df_full
  SHL r3,r2,1
  LD r4,r0,#Z1_V_LABB
  ADD r3,r3,r4
  ST r5,r3,0
  ST r8,r3,1
  ADD r2,r2,r13
  ST r2,r0,#Z1_V_NLAB
  ST r0,r3,2
  JMP @x1_df_x
x1_df_set:
  ST r8,r1,1
  JMP @x1_df_x
x1_df_full:
  CALL @x1_bump_err
x1_df_x:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_look:
  LD r2,r6,0
  CMP r2,r0
  JMP[EQ] @x1_lk0
  CMP r2,r5
  JMP[EQ] @x1_lk2
  ADD r6,r6,r7
  JMP @x1_look
x1_lk0:
  MOVI r1,0
  RET
x1_lk2:
  BOOL.12 r1,r6,r6
  RET
x1_expr:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r0,r0,#Z1_V_ACC
  ST r0,r0,#Z1_V_SGN
  CALL @x1_nextc
  MOVI r4,45
  CMP r1,r4
  JMP[NE] @x1_ex_t
  ST r13,r0,#Z1_V_SGN
  CALL @x1_nextc
x1_ex_t:
  CALL @x1_term
  LD r2,r0,#Z1_V_SGN
  CMP r2,r0
  JMP[EQ] @x1_ex_a
  SUB r8,r0,r8
x1_ex_a:
  LD r2,r0,#Z1_V_ACC
  ADD r2,r2,r8
  ST r2,r0,#Z1_V_ACC
  CALL @x1_nextc
  MOVI r4,43
  CMP r1,r4
  JMP[EQ] @x1_ex_p
  MOVI r4,45
  CMP r1,r4
  JMP[EQ] @x1_ex_m
  CALL @x1_ungetc
  LD r8,r0,#Z1_V_ACC
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_ex_p:
  ST r0,r0,#Z1_V_SGN
  CALL @x1_nextc
  JMP @x1_ex_t
x1_ex_m:
  ST r13,r0,#Z1_V_SGN
  CALL @x1_nextc
  JMP @x1_ex_t
x1_term:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r4,48
  CMP r1,r4
  JMP[LT] @x1_tm_l
  MOVI r4,58
  CMP r1,r4
  JMP[LT] @x1_tm_num
  JMP @x1_tm_l
x1_tm_num:
  CALL @x1_tnum
  JMP @x1_tm_x
x1_tm_l:
  MOVI r4,64
  CMP r1,r4
  JMP[EQ] @x1_tm_lab
  MOVI r4,35
  CMP r1,r4
  JMP[EQ] @x1_tm_lab
  CALL @x1_rdhash1
  JMP @x1_tm_lk
x1_tm_lab:
  CALL @x1_rdhash
x1_tm_lk:
  LD r6,r0,#Z1_V_LABB
  MOVI r7,2
  CALL @x1_look
  CMP r1,r0
  JMP[EQ] @x1_tm_miss
  LD r8,r1,1
  JMP @x1_tm_x
x1_tm_miss:
  MOVI r8,0
  LD r2,r0,#Z1_V_PASS
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @x1_tm_x
  CALL @x1_bump_err
x1_tm_x:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_tnum:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r8,0
  MOVI r4,48
  CMP r1,r4
  JMP[NE] @x1_tn_d
  CALL @x1_getc
  MOVI r4,120
  CMP r1,r4
  JMP[EQ] @x1_tn_h
x1_tn_d:
  MOVI r4,48
  CMP r1,r4
  JMP[LT] @x1_tn_e
  MOVI r4,58
  CMP r1,r4
  JMP[GE] @x1_tn_e
  MOVI r4,48
  SUB r1,r1,r4
  SHL r5,r8,3
  SHL r6,r8,1
  ADD r8,r5,r6
  ADD r8,r8,r1
  CALL @x1_getc
  JMP @x1_tn_d
x1_tn_h:
  CALL @x1_getc
  MOVI r4,48
  CMP r1,r4
  JMP[LT] @x1_tn_e
  MOVI r4,58
  CMP r1,r4
  JMP[LT] @x1_th_d
  MOVI r4,65
  CMP r1,r4
  JMP[LT] @x1_tn_e
  MOVI r4,71
  CMP r1,r4
  JMP[LT] @x1_th_u
  MOVI r4,97
  CMP r1,r4
  JMP[LT] @x1_tn_e
  MOVI r4,103
  CMP r1,r4
  JMP[GE] @x1_tn_e
  MOVI r4,87
  JMP @x1_th_a
x1_th_u:
  MOVI r4,55
  JMP @x1_th_a
x1_th_d:
  MOVI r4,48
x1_th_a:
  SUB r1,r1,r4
  SHL r8,r8,4
  ADD r8,r8,r1
  JMP @x1_tn_h
x1_tn_e:
  CALL @x1_ungetc
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_rdhash1:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r5,5381
  JMP @x1_rh_a
x1_rdhash:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r5,5381
x1_rh1:
  CALL @x1_getc
  CALL @x1_isid
  CMP r6,r0
  JMP[EQ] @x1_rh2
x1_rh_a:
  MOVI r6,97
  CMP r1,r6
  JMP[LT] @x1_rh_b
  MOVI r6,123
  CMP r1,r6
  JMP[GE] @x1_rh_b
  MOVI r6,32
  SUB r1,r1,r6
x1_rh_b:
  SHL r6,r5,5
  ADD r5,r6,r5
  ADD r5,r5,r1
  JMP @x1_rh1
x1_rh2:
  CALL @x1_ungetc
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_isid:
  MOVI r6,1
  MOVI r7,48
  CMP r1,r7
  JMP[LT] @x1_isn
  MOVI r7,58
  CMP r1,r7
  RET[LT]
  MOVI r7,65
  CMP r1,r7
  JMP[LT] @x1_isn
  MOVI r7,91
  CMP r1,r7
  RET[LT]
  MOVI r7,95
  CMP r1,r7
  RET[EQ]
  MOVI r7,97
  CMP r1,r7
  JMP[LT] @x1_isn
  MOVI r7,123
  CMP r1,r7
  RET[LT]
x1_isn:
  MOVI r6,0
  RET
x1_getc:
  LD r2,r0,#Z1_V_PB
  CMP r2,r0
  JMP[EQ] @x1_gc1
  ST r0,r0,#Z1_V_PB
  SUB r1,r2,r13
  RET
x1_gc1:
  LD r2,r0,#Z1_V_CN
  CMP r2,r0
  JMP[NE] @x1_gc2
  LD r3,r0,#Z1_V_SRCP
  LD r1,r3,0
  ST r1,r0,#Z1_V_CW
  ADD r3,r3,r13
  ST r3,r0,#Z1_V_SRCP
  MOVI r2,4
x1_gc2:
  SUB r2,r2,r13
  ST r2,r0,#Z1_V_CN
  LD r1,r0,#Z1_V_CW
  SHR r3,r1,8
  ST r3,r0,#Z1_V_CW
  MOVI r3,255
  BOOL.8 r1,r1,r3
  RET
x1_ungetc:
  ADD r2,r1,r13
  ST r2,r0,#Z1_V_PB
  RET
x1_nextc:
  ST r15,r14,0
  ADD r14,r14,r13
x1_nx1:
  CALL @x1_getc
  MOVI r4,32
  CMP r1,r4
  JMP[EQ] @x1_nx1
  MOVI r4,9
  CMP r1,r4
  JMP[EQ] @x1_nx1
  MOVI r4,13
  CMP r1,r4
  JMP[EQ] @x1_nx1
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_skipline:
  ST r15,r14,0
  ADD r14,r14,r13
x1_sk1:
  CALL @x1_getc
  CMP r1,r0
  JMP[EQ] @x1_skx
  MOVI r4,10
  CMP r1,r4
  JMP[NE] @x1_sk1
x1_skx:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_h_byte1:
  LD r1,r0,#Z1_V_AUX0
  CALL @x1_emitb
  JMP @x1_endins
x1_h_rep:
  MOVI r1,0xF3
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  CALL @x1_emitb
  JMP @x1_endins
x1_e_form:
  CALL @x1_bump_err
  JMP @x1_endins
x1_m_movb:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_m_mov
x1_m_movw:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  JMP @x1_m_mov
x1_m_movl:
  MOVI r4,4
  ST r4,r0,#Z1_V_SZ
  JMP @x1_m_mov
x1_m_mov:
  CALL @x1_sz_of
  ADD r11,r1,r0
  LD r2,r0,#Z1_V_OPN
  MOVI r4,2
  CMP r2,r4
  JMP[NE] @x1_e_form
  LD r4,r0,#Z1_OPBASE
  LD r5,r0,#Z1_OPBASE+1
  LD r6,r0,#Z1_OPBASE+8
  LD r7,r0,#Z1_OPBASE+9
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_mv_imm
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_mv_reg
  MOVI r8,3
  CMP r4,r8
  JMP[EQ] @x1_mv_mem
  JMP @x1_e_form
x1_mv_imm:
  ADD r10,r5,r0
  MOVI r8,1
  CMP r6,r8
  JMP[EQ] @x1_mv_ir
  MOVI r8,3
  CMP r6,r8
  JMP[EQ] @x1_mv_im
  JMP @x1_e_form
x1_mv_ir:
  ADD r1,r7,r0
  SHR r1,r1,4
  MOVI r8,5
  CMP r1,r8
  JMP[EQ] @x1_e_form
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  ADD r1,r7,r0
  CALL @x1_rf
  ADD r12,r1,r0
  MOVI r1,0xB0
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_ir_op
  ADDI r1,r1,8
x1_mv_ir_op:
  ADD r1,r1,r12
  CALL @x1_emitb
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_ir8
  MOVI r8,2
  CMP r11,r8
  JMP[EQ] @x1_mv_ir16
  ADD r2,r10,r0
  CALL @x1_emitd
  JMP @x1_endins
x1_mv_ir8:
  ADD r1,r10,r0
  CALL @x1_emitb
  JMP @x1_endins
x1_mv_ir16:
  ADD r2,r10,r0
  CALL @x1_emitw
  JMP @x1_endins
x1_mv_im:
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0xC6
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_im_op
  ADDI r1,r1,1
x1_mv_im_op:
  CALL @x1_emitb
  MOVI r1,0
  MOVI r2,1
  CALL @x1_enc_rm
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_im8
  MOVI r8,2
  CMP r11,r8
  JMP[EQ] @x1_mv_im16
  ADD r2,r10,r0
  CALL @x1_emitd
  JMP @x1_endins
x1_mv_im8:
  ADD r1,r10,r0
  CALL @x1_emitb
  JMP @x1_endins
x1_mv_im16:
  ADD r2,r10,r0
  CALL @x1_emitw
  JMP @x1_endins
x1_mv_reg:
  ADD r10,r5,r0
  ADD r1,r5,r0
  SHR r1,r1,4
  MOVI r8,5
  CMP r1,r8
  JMP[EQ] @x1_mv_sreg_st
  MOVI r8,4
  CMP r1,r8
  JMP[EQ] @x1_mv_cr_st
  MOVI r8,1
  CMP r6,r8
  JMP[EQ] @x1_mv_rr
  MOVI r8,3
  CMP r6,r8
  JMP[EQ] @x1_mv_rm
  JMP @x1_e_form
x1_mv_rr:
  ADD r1,r7,r0
  SHR r1,r1,4
  MOVI r8,5
  CMP r1,r8
  JMP[EQ] @x1_mv_sreg_ld
  MOVI r8,4
  CMP r1,r8
  JMP[EQ] @x1_mv_cr_ld
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x88
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_rr_op
  ADDI r1,r1,1
x1_mv_rr_op:
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_rm:
  LD r1,r0,#Z1_OPBASE+10
  MOVI r8,0xFF
  CMP r1,r8
  JMP[NE] @x1_mv_rm_n
  LD r1,r0,#Z1_OPBASE+11
  CMP r1,r8
  JMP[NE] @x1_mv_rm_n
  ADD r1,r10,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[NE] @x1_mv_rm_n
  ADD r1,r11,r0
  CALL @x1_prefix
  LD r8,r0,#Z1_V_MODE
  MOVI r9,2
  CMP r8,r9
  JMP[NE] @x1_mv_ms_noaddr
  MOVI r1,0x67
  CALL @x1_emitb
x1_mv_ms_noaddr:
  MOVI r1,0xA2
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_ms_op
  ADDI r1,r1,1
x1_mv_ms_op:
  CALL @x1_emitb
  LD r2,r0,#Z1_OPBASE+13
  LD r8,r0,#Z1_V_MODE
  CMP r8,r0
  JMP[EQ] @x1_mv_ms_w
  CALL @x1_emitd
  JMP @x1_endins
x1_mv_ms_w:
  CALL @x1_emitw
  JMP @x1_endins
x1_mv_rm_n:
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x88
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_rm_op
  ADDI r1,r1,1
x1_mv_rm_op:
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_sreg_st:
  MOVI r1,0x8C
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_cr_st:
  LD r8,r0,#Z1_V_MODE
  MOVI r9,2
  CMP r8,r9
  JMP[NE] @x1_mv_cr_st_nw
  MOVI r1,0x48
  CALL @x1_emitb
x1_mv_cr_st_nw:
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x20
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_sreg_ld:
  MOVI r1,0x8E
  CALL @x1_emitb
  ADD r1,r7,r0
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_cr_ld:
  LD r8,r0,#Z1_V_MODE
  MOVI r9,2
  CMP r8,r9
  JMP[NE] @x1_mv_cr_ld_nw
  MOVI r1,0x48
  CALL @x1_emitb
x1_mv_cr_ld_nw:
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x22
  CALL @x1_emitb
  ADD r1,r7,r0
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_mem:
  ADD r10,r5,r0
  MOVI r8,1
  CMP r6,r8
  JMP[EQ] @x1_mv_mr
  JMP @x1_e_form
x1_mv_mr:
  ADD r1,r7,r0
  SHR r1,r1,4
  MOVI r8,5
  CMP r1,r8
  JMP[EQ] @x1_mv_sreg_ld2
  MOVI r8,4
  CMP r1,r8
  JMP[EQ] @x1_mv_cr_ld2
  LD r1,r0,#Z1_OPBASE+2
  MOVI r8,0xFF
  CMP r1,r8
  JMP[NE] @x1_mv_mr_n
  LD r1,r0,#Z1_OPBASE+3
  CMP r1,r8
  JMP[NE] @x1_mv_mr_n
  ADD r1,r7,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[NE] @x1_mv_mr_n
  ADD r1,r11,r0
  CALL @x1_prefix
  LD r8,r0,#Z1_V_MODE
  MOVI r9,2
  CMP r8,r9
  JMP[NE] @x1_mv_ml_noaddr
  MOVI r1,0x67
  CALL @x1_emitb
x1_mv_ml_noaddr:
  MOVI r1,0xA0
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_ml_op
  ADDI r1,r1,1
x1_mv_ml_op:
  CALL @x1_emitb
  LD r2,r0,#Z1_OPBASE+5
  LD r8,r0,#Z1_V_MODE
  CMP r8,r0
  JMP[EQ] @x1_mv_ml_w
  CALL @x1_emitd
  JMP @x1_endins
x1_mv_ml_w:
  CALL @x1_emitw
  JMP @x1_endins
x1_mv_mr_n:
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x8A
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_mv_mr_op
  ADDI r1,r1,1
x1_mv_mr_op:
  CALL @x1_emitb
  ADD r1,r7,r0
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_sreg_ld2:
  MOVI r1,0x8E
  CALL @x1_emitb
  ADD r1,r7,r0
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mv_cr_ld2:
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x22
  CALL @x1_emitb
  ADD r1,r7,r0
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_movzxb:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_movzx
x1_m_movzxw:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  MOVI r4,0xB7
  ST r4,r0,#Z1_V_AUX0
  JMP @x1_h_movzx
x1_m_movsxw:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  MOVI r4,0xBF
  ST r4,r0,#Z1_V_AUX0
  JMP @x1_h_movsx
x1_h_movzx:
  CALL @x1_sz_of
  ADD r11,r1,r0
  CMP r11,r0
  JMP[EQ] @x1_e_form
  LD r4,r0,#Z1_V_AUX0
  CMP r4,r0
  JMP[NE] @x1_zx_have
  LD r4,r0,#Z1_OPBASE+1
  SHR r4,r4,4
  MOVI r8,0
  CMP r4,r8
  MOVI r4,0xB6
  MOVI[NE] r4,0xB7
x1_zx_have:
  ST r4,r0,#Z1_V_TMPX
  LD r4,r0,#Z1_OPBASE+9
  SHR r4,r4,4
  MOVI r8,1
  CMP r4,r8
  JMP[NE] @x1_zx_n
  MOVI r1,0x66
  CALL @x1_emitb
x1_zx_n:
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_V_TMPX
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_h_movsx:
  CALL @x1_sz_of
  ADD r11,r1,r0
  CMP r11,r0
  JMP[EQ] @x1_e_form
  LD r4,r0,#Z1_V_AUX0
  CMP r4,r0
  JMP[NE] @x1_sx_have
  LD r4,r0,#Z1_OPBASE+1
  SHR r4,r4,4
  MOVI r8,0
  CMP r4,r8
  MOVI r4,0xBE
  MOVI[NE] r4,0xBF
x1_sx_have:
  ST r4,r0,#Z1_V_TMPX
  LD r4,r0,#Z1_OPBASE+9
  SHR r4,r4,4
  MOVI r8,1
  CMP r4,r8
  JMP[NE] @x1_sx_n
  MOVI r1,0x66
  CALL @x1_emitb
x1_sx_n:
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_V_TMPX
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_enc_rm:
  ST r15,r14,0
  ADD r14,r14,r13
  SHL r3,r2,3
  ADDI r3,r3,#Z1_OPBASE
  LD r4,r3,0
  ; code64 absolute memory: mod=00 r/m=100 SIB(0x25) disp32.
  LD r8,r0,#Z1_V_MODE
  MOVI r9,2
  CMP r8,r9
  JMP[NE] @x1_er_not64abs
  MOVI r5,3
  CMP r4,r5
  JMP[NE] @x1_er_not64abs
  LD r5,r3,2
  LD r6,r3,3
  MOVI r7,0xFF
  CMP r6,r7
  JMP[NE] @x1_er_not64abs
  CMP r5,r7
  JMP[EQ] @x1_er_abs64
  CMP r5,r0
  JMP[NE] @x1_er_not64abs
x1_er_abs64:
  LD r9,r3,5
  SHL r1,r1,3
  MOVI r5,0x04
  BOOL.14 r1,r1,r5
  CALL @x1_emitb
  MOVI r1,0x25
  CALL @x1_emitb
  ADD r2,r9,r0
  CALL @x1_emitd
  JMP @x1_er_x
x1_er_not64abs:
  MOVI r5,1
  CMP r4,r5
  JMP[NE] @x1_er_mem
  LD r4,r3,1
  MOVI r5,15
  BOOL.8 r4,r4,r5
  SHL r1,r1,3
  MOVI r5,0xC0
  BOOL.14 r1,r1,r5
  BOOL.14 r1,r1,r4
  CALL @x1_emitb
  JMP @x1_er_x
x1_er_mem:
  LD r4,r3,2
  LD r5,r3,3
  LD r6,r3,4
  LD r7,r3,5
  ST r4,r0,#Z1_V_MB
  ST r5,r0,#Z1_V_MI
  ST r6,r0,#Z1_V_MS
  ST r7,r0,#Z1_V_MD
  ST r1,r0,#Z1_V_MR
  MOVI r8,0xFF
  CMP r4,r8
  JMP[NE] @x1_er_hb
  CMP r5,r8
  JMP[NE] @x1_er_io
  LD r8,r0,#Z1_V_MODE
  CMP r8,r0
  JMP[EQ] @x1_er_a16
  LD r1,r0,#Z1_V_MR
  SHL r1,r1,3
  MOVI r8,0x05
  BOOL.14 r1,r1,r8
  CALL @x1_emitb
  LD r2,r0,#Z1_V_MD
  CALL @x1_emitd
  JMP @x1_er_x
x1_er_a16:
  LD r1,r0,#Z1_V_MR
  SHL r1,r1,3
  MOVI r8,0x06
  BOOL.14 r1,r1,r8
  CALL @x1_emitb
  LD r2,r0,#Z1_V_MD
  CALL @x1_emitw
  JMP @x1_er_x
x1_er_io:
  LD r1,r0,#Z1_V_MR
  SHL r1,r1,3
  MOVI r8,0x04
  BOOL.14 r1,r1,r8
  CALL @x1_emitb
  LD r1,r0,#Z1_V_MS
  SHR r1,r1,1
  MOVI r5,4
  CMP r1,r5
  MOVI[EQ] r1,3
  SHL r1,r1,6
  LD r5,r0,#Z1_V_MI
  SHL r5,r5,3
  BOOL.14 r1,r1,r5
  MOVI r8,5
  BOOL.14 r1,r1,r8
  CALL @x1_emitb
  LD r2,r0,#Z1_V_MD
  CALL @x1_emitd
  JMP @x1_er_x
x1_er_hb:
  MOVI r8,0xFF
  CMP r5,r8
  JMP[NE] @x1_er_bb
  LD r9,r0,#Z1_V_MB
  LD r7,r0,#Z1_V_MD
  CMP r7,r0
  JMP[NE] @x1_er_bd
  MOVI r8,5
  CMP r9,r8
  JMP[EQ] @x1_er_b0
  LD r1,r0,#Z1_V_MR
  SHL r1,r1,3
  BOOL.14 r1,r1,r9
  CALL @x1_emitb
  JMP @x1_er_x
x1_er_bd:
  ADD r1,r7,r0
  CALL @x1_fits8
  CMP r9,r0
  JMP[EQ] @x1_er_b32
x1_er_b0:
  LD r9,r0,#Z1_V_MB
  LD r1,r0,#Z1_V_MR
  SHL r1,r1,3
  MOVI r8,0x40
  BOOL.14 r1,r1,r8
  BOOL.14 r1,r1,r9
  CALL @x1_emitb
  LD r1,r0,#Z1_V_MD
  CALL @x1_emitb
  JMP @x1_er_x
x1_er_b32:
  LD r9,r0,#Z1_V_MB
  LD r1,r0,#Z1_V_MR
  SHL r1,r1,3
  MOVI r8,0x80
  BOOL.14 r1,r1,r8
  BOOL.14 r1,r1,r9
  CALL @x1_emitb
  LD r2,r0,#Z1_V_MD
  CALL @x1_emitd
  JMP @x1_er_x
x1_er_bb:
  LD r5,r0,#Z1_V_MI
  MOVI r8,4
  CMP r5,r8
  JMP[EQ] @x1_er_bad
  LD r7,r0,#Z1_V_MD
  LD r9,r0,#Z1_V_MB
  CMP r7,r0
  JMP[NE] @x1_er_bbd
  MOVI r8,5
  CMP r9,r8
  JMP[EQ] @x1_er_bb0
  MOVI r8,0
  JMP @x1_er_bsib
x1_er_bbd:
  ADD r1,r7,r0
  CALL @x1_fits8
  CMP r9,r0
  JMP[EQ] @x1_er_bb32
x1_er_bb0:
  MOVI r8,0x40
  JMP @x1_er_bsib
x1_er_bb32:
  MOVI r8,0x80
x1_er_bsib:
  LD r1,r0,#Z1_V_MR
  SHL r1,r1,3
  MOVI r5,0x04
  BOOL.14 r1,r1,r5
  BOOL.14 r1,r1,r8
  CALL @x1_emitb
  LD r1,r0,#Z1_V_MS
  SHR r1,r1,1
  MOVI r5,4
  CMP r1,r5
  MOVI[EQ] r1,3
  SHL r1,r1,6
  LD r5,r0,#Z1_V_MI
  SHL r5,r5,3
  BOOL.14 r1,r1,r5
  LD r5,r0,#Z1_V_MB
  BOOL.14 r1,r1,r5
  CALL @x1_emitb
  MOVI r5,0
  CMP r8,r5
  JMP[EQ] @x1_er_x
  MOVI r5,0x40
  CMP r8,r5
  JMP[EQ] @x1_er_bs8
  LD r2,r0,#Z1_V_MD
  CALL @x1_emitd
  JMP @x1_er_x
x1_er_bs8:
  LD r1,r0,#Z1_V_MD
  CALL @x1_emitb
  JMP @x1_er_x
x1_er_bad:
  CALL @x1_bump_err
x1_er_x:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_branch:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r8,r0,#Z1_V_BT
  ST r9,r0,#Z1_V_BS
  ST r10,r0,#Z1_V_BL
  ST r11,r0,#Z1_V_BLN
  LD r4,r0,#Z1_V_BRN
  ADD r4,r4,r13
  ST r4,r0,#Z1_V_BRN
  SUB r4,r4,r13
  SHL r5,r4,3
  LD r2,r0,#Z1_V_LONGB
  ADD r6,r2,r5
  LD r6,r6,0
  LD r8,r0,#Z1_V_BT
  CMP r8,r0
  JMP[EQ] @x1_br_short
  LD r7,r0,#Z1_V_BASE
  LD r1,r0,#Z1_V_PC
  ADD r7,r7,r1
  ADDI r7,r7,2
  SUB r1,r8,r7
  CALL @x1_fits8
  CMP r6,r0
  JMP[NE] @x1_br_long
  CMP r9,r0
  JMP[EQ] @x1_br_grow
x1_br_short:
  LD r1,r0,#Z1_V_BS
  CALL @x1_emitb
  LD r7,r0,#Z1_V_BASE
  LD r1,r0,#Z1_V_PC
  ADD r7,r7,r1
  ADDI r7,r7,1
  LD r8,r0,#Z1_V_BT
  SUB r1,r8,r7
  CALL @x1_emitb
  JMP @x1_br_x
x1_br_grow:
  LD r4,r0,#Z1_V_BRN
  SUB r4,r4,r13
  SHL r5,r4,3
  LD r2,r0,#Z1_V_LONGB
  ADD r5,r2,r5
  ST r13,r5,0
  MOVI r4,1
  ST r4,r0,#Z1_V_REDO
x1_br_long:
  LD r11,r0,#Z1_V_BLN
  MOVI r8,6
  CMP r11,r8
  JMP[NE] @x1_br_l5
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_V_BL
  CALL @x1_emitb
  JMP @x1_br_r32
x1_br_l5:
  LD r1,r0,#Z1_V_BL
  CALL @x1_emitb
x1_br_r32:
  LD r7,r0,#Z1_V_BASE
  LD r1,r0,#Z1_V_PC
  ADD r7,r7,r1
  ADDI r7,r7,4
  LD r8,r0,#Z1_V_BT
  SUB r2,r8,r7
  CALL @x1_emitd
x1_br_x:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
x1_h_alu:
  LD r4,r0,#Z1_V_AUX0
  MOVI r5,0xFF
  BOOL.8 r5,r4,r5
  ST r5,r0,#Z1_V_AUX1
  SHR r4,r4,8
  ST r4,r0,#Z1_V_AUX2
  CALL @x1_sz_of
  ADD r11,r1,r0
  CMP r11,r0
  JMP[EQ] @x1_e_form
  LD r4,r0,#Z1_OPBASE
  LD r5,r0,#Z1_OPBASE+1
  LD r6,r0,#Z1_OPBASE+8
  LD r7,r0,#Z1_OPBASE+9
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_alu_r
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_alu_i
  MOVI r8,3
  CMP r4,r8
  JMP[EQ] @x1_alu_m
  JMP @x1_e_form
x1_alu_r:
  ADD r10,r5,r0
  ADD r1,r11,r0
  CALL @x1_prefix
  LD r1,r0,#Z1_V_AUX2
  MOVI r8,1
  CMP r11,r8
  JMP[NE] @x1_alu_r_op
  ADDI r1,r1,0
  JMP @x1_alu_r_em
x1_alu_r_op:
  ADDI r1,r1,1
x1_alu_r_em:
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_alu_m:
  ADD r10,r7,r0
  ADD r1,r11,r0
  CALL @x1_prefix
  LD r1,r0,#Z1_V_AUX2
  MOVI r8,1
  CMP r11,r8
  JMP[NE] @x1_alu_m_op
  ADDI r1,r1,2
  JMP @x1_alu_m_em
x1_alu_m_op:
  ADDI r1,r1,3
x1_alu_m_em:
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_alu_i:
  ADD r10,r5,r0
  MOVI r8,1
  CMP r6,r8
  JMP[EQ] @x1_alu_ir
  MOVI r8,3
  CMP r6,r8
  JMP[EQ] @x1_alu_im
  JMP @x1_e_form
x1_alu_ir:
  MOVI r8,1
  CMP r11,r8
  JMP[NE] @x1_alu_ir_w
  ADD r1,r7,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[EQ] @x1_alu_acc8
  JMP @x1_alu_i8
x1_alu_ir_w:
  ADD r1,r10,r0
  CALL @x1_fits8
  CMP r9,r0
  JMP[NE] @x1_alu_i83
  ADD r1,r7,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[EQ] @x1_alu_accw
  JMP @x1_alu_i32
x1_alu_im:
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_alu_i8
  ADD r1,r10,r0
  CALL @x1_fits8
  CMP r9,r0
  JMP[NE] @x1_alu_i83
  JMP @x1_alu_i32
x1_alu_acc8:
  ADD r1,r11,r0
  CALL @x1_prefix
  LD r1,r0,#Z1_V_AUX2
  ADDI r1,r1,4
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_emitb
  JMP @x1_endins
x1_alu_accw:
  ADD r1,r11,r0
  CALL @x1_prefix
  LD r1,r0,#Z1_V_AUX2
  ADDI r1,r1,5
  CALL @x1_emitb
  MOVI r8,2
  CMP r11,r8
  JMP[EQ] @x1_alu_ae16
  ADD r2,r10,r0
  CALL @x1_emitd
  JMP @x1_endins
x1_alu_ae16:
  ADD r2,r10,r0
  CALL @x1_emitw
  JMP @x1_endins
x1_alu_i8:
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x80
  CALL @x1_emitb
  JMP @x1_alu_ib
x1_alu_i83:
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x83
  CALL @x1_emitb
x1_alu_ib:
  LD r1,r0,#Z1_V_AUX1
  MOVI r2,1
  CALL @x1_enc_rm
  ADD r1,r10,r0
  CALL @x1_emitb
  JMP @x1_endins
x1_alu_i32:
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x81
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX1
  MOVI r2,1
  CALL @x1_enc_rm
  MOVI r8,2
  CMP r11,r8
  JMP[EQ] @x1_alu_i32w
  ADD r2,r10,r0
  CALL @x1_emitd
  JMP @x1_endins
x1_alu_i32w:
  ADD r2,r10,r0
  CALL @x1_emitw
  JMP @x1_endins
x1_h_test:
  CALL @x1_sz_of
  ADD r11,r1,r0
  CMP r11,r0
  JMP[EQ] @x1_e_form
  LD r4,r0,#Z1_OPBASE
  LD r5,r0,#Z1_OPBASE+1
  LD r6,r0,#Z1_OPBASE+8
  LD r7,r0,#Z1_OPBASE+9
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_ts_r
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_ts_i
  JMP @x1_e_form
x1_ts_r:
  ADD r10,r5,r0
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x84
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_ts_r_op
  ADDI r1,r1,1
x1_ts_r_op:
  CALL @x1_emitb
  ADD r1,r10,r0
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_ts_i:
  ADD r10,r5,r0
  MOVI r8,1
  CMP r6,r8
  JMP[NE] @x1_ts_i_n
  ADD r1,r7,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[NE] @x1_ts_i_n
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0xA8
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_ts_a_op
  ADDI r1,r1,1
x1_ts_a_op:
  CALL @x1_emitb
  JMP @x1_ts_ie
x1_ts_i_n:
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0xF6
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_ts_n_op
  ADDI r1,r1,1
x1_ts_n_op:
  CALL @x1_emitb
  MOVI r1,0
  MOVI r2,1
  CALL @x1_enc_rm
x1_ts_ie:
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_ts_e8
  MOVI r8,2
  CMP r11,r8
  JMP[EQ] @x1_ts_e16
  ADD r2,r10,r0
  CALL @x1_emitd
  JMP @x1_endins
x1_ts_e8:
  ADD r1,r10,r0
  CALL @x1_emitb
  JMP @x1_endins
x1_ts_e16:
  ADD r2,r10,r0
  CALL @x1_emitw
  JMP @x1_endins
x1_h_group:
  CALL @x1_sz_of
  ADD r11,r1,r0
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0xF6
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_gr_op
  ADDI r1,r1,1
x1_gr_op:
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_h_incdec:
  CALL @x1_sz_of
  ADD r11,r1,r0
  LD r4,r0,#Z1_OPBASE
  LD r5,r0,#Z1_OPBASE+1
  CMP r11,r0
  JMP[EQ] @x1_e_form
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_id_reg
  MOVI r8,3
  CMP r4,r8
  JMP[EQ] @x1_id_mem
  JMP @x1_e_form
x1_id_reg:
  ADD r10,r5,r0
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_id_r8
  ADD r1,r11,r0
  CALL @x1_prefix
  ADD r1,r10,r0
  CALL @x1_rf
  ADDI r1,r1,0x40
  LD r4,r0,#Z1_V_AUX0
  CMP r4,r0
  JMP[EQ] @x1_id_r_op
  ADDI r1,r1,8
x1_id_r_op:
  CALL @x1_emitb
  JMP @x1_endins
x1_id_r8:
  MOVI r1,0xFE
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_id_mem:
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0xFE
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_id_m_op
  ADDI r1,r1,1
x1_id_m_op:
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_h_shift:
  MOVI r2,1
  CALL @x1_sz_op
  ADD r11,r1,r0
  LD r4,r0,#Z1_OPBASE
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_sh_cl
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_sh_imm
  JMP @x1_e_form
x1_sh_cl:
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0xD2
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_sh_c_op
  ADDI r1,r1,1
x1_sh_c_op:
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_sh_imm:
  LD r5,r0,#Z1_OPBASE+1
  ADD r10,r5,r0
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r8,1
  CMP r10,r8
  JMP[EQ] @x1_sh_one
  MOVI r1,0xC0
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_sh_i_op
  ADDI r1,r1,1
x1_sh_i_op:
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  MOVI r2,1
  CALL @x1_enc_rm
  ADD r1,r10,r0
  CALL @x1_emitb
  JMP @x1_endins
x1_sh_one:
  MOVI r1,0xD0
  MOVI r8,1
  CMP r11,r8
  JMP[EQ] @x1_sh_1_op
  ADDI r1,r1,1
x1_sh_1_op:
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_jmp:
  LD r4,r0,#Z1_OPBASE
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_j_rel
  MOVI r1,0xFF
  CALL @x1_emitb
  MOVI r1,4
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_j_rel:
  LD r8,r0,#Z1_OPBASE+1
  MOVI r9,0xEB
  MOVI r10,0xE9
  MOVI r11,5
  CALL @x1_branch
  JMP @x1_endins
x1_m_call:
  LD r4,r0,#Z1_OPBASE
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_c_rel
  MOVI r1,0xFF
  CALL @x1_emitb
  MOVI r1,2
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_c_rel:
  MOVI r1,0xE8
  CALL @x1_emitb
  LD r8,r0,#Z1_OPBASE+1
  LD r7,r0,#Z1_V_BASE
  LD r1,r0,#Z1_V_PC
  ADD r7,r7,r1
  ADDI r7,r7,4
  SUB r2,r8,r7
  CALL @x1_emitd
  JMP @x1_endins
x1_h_jcc:
  LD r4,r0,#Z1_OPBASE
  MOVI r8,2
  CMP r4,r8
  JMP[NE] @x1_e_form
  LD r8,r0,#Z1_OPBASE+1
  LD r9,r0,#Z1_V_AUX0
  ADDI r9,r9,0x70
  LD r10,r0,#Z1_V_AUX0
  ADDI r10,r10,0x80
  MOVI r11,6
  CALL @x1_branch
  JMP @x1_endins
x1_m_loop:
  MOVI r1,0xE2
  CALL @x1_emitb
  LD r8,r0,#Z1_OPBASE+1
  LD r7,r0,#Z1_V_BASE
  LD r1,r0,#Z1_V_PC
  ADD r7,r7,r1
  ADDI r7,r7,1
  SUB r1,r8,r7
  CALL @x1_emitb
  JMP @x1_endins
x1_m_jecxz:
  MOVI r1,0xE3
  CALL @x1_emitb
  LD r8,r0,#Z1_OPBASE+1
  LD r7,r0,#Z1_V_BASE
  LD r1,r0,#Z1_V_PC
  ADD r7,r7,r1
  ADDI r7,r7,1
  SUB r1,r8,r7
  CALL @x1_emitb
  JMP @x1_endins
x1_h_pushpop:
  CALL @x1_sz_of
  ADD r11,r1,r0
  LD r4,r0,#Z1_OPBASE
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_pp_reg
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_pp_imm
  JMP @x1_e_form
x1_pp_reg:
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_rf
  ADD r10,r1,r0
  MOVI r1,0x50
  LD r4,r0,#Z1_V_AUX0
  CMP r4,r0
  JMP[EQ] @x1_pp_op
  ADDI r1,r1,8
x1_pp_op:
  ADD r1,r1,r10
  CALL @x1_emitb
  JMP @x1_endins
x1_pp_imm:
  LD r4,r0,#Z1_V_AUX0
  CMP r4,r0
  JMP[NE] @x1_e_form
  MOVI r1,0x68
  CALL @x1_emitb
  LD r2,r0,#Z1_OPBASE+1
  LD r8,r0,#Z1_V_MODE
  CMP r8,r0
  JMP[EQ] @x1_pp_i16
  CALL @x1_emitd
  JMP @x1_endins
x1_pp_i16:
  CALL @x1_emitw
  JMP @x1_endins
x1_h_lea:
  MOVI r2,1
  CALL @x1_sz_op
  ADD r11,r1,r0
  LD r4,r0,#Z1_OPBASE
  MOVI r8,3
  CMP r4,r8
  JMP[NE] @x1_e_form
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x8D
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_inout:
  LD r4,r0,#Z1_OPBASE
  LD r5,r0,#Z1_OPBASE+1
  LD r6,r0,#Z1_OPBASE+8
  LD r7,r0,#Z1_OPBASE+9
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_io_ii
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_io_r
  JMP @x1_e_form
x1_io_ii:
  MOVI r8,1
  CMP r6,r8
  JMP[NE] @x1_e_form
  ADD r1,r7,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[NE] @x1_e_form
  ADD r1,r7,r0
  SHR r1,r1,4
  MOVI r8,0
  CMP r1,r8
  MOVI r1,0xE4
  MOVI[NE] r1,0xE5
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_emitb
  JMP @x1_endins
x1_io_r:
  ADD r1,r5,r0
  CALL @x1_rf
  MOVI r8,2
  CMP r1,r8
  JMP[NE] @x1_io_out
  ADD r1,r7,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[NE] @x1_e_form
  ADD r1,r7,r0
  SHR r1,r1,4
  MOVI r8,0
  CMP r1,r8
  MOVI r1,0xEC
  MOVI[NE] r1,0xED
  CALL @x1_emitb
  JMP @x1_endins
x1_io_out:
  ADD r1,r5,r0
  CALL @x1_rf
  CMP r1,r0
  JMP[NE] @x1_e_form
  MOVI r8,1
  CMP r6,r8
  JMP[EQ] @x1_io_od
  MOVI r8,2
  CMP r6,r8
  JMP[EQ] @x1_io_oi
  JMP @x1_e_form
x1_io_od:
  ADD r1,r7,r0
  CALL @x1_rf
  MOVI r8,2
  CMP r1,r8
  JMP[NE] @x1_e_form
  ADD r1,r5,r0
  SHR r1,r1,4
  MOVI r8,0
  CMP r1,r8
  MOVI r1,0xEE
  MOVI[NE] r1,0xEF
  CALL @x1_emitb
  JMP @x1_endins
x1_io_oi:
  ADD r1,r5,r0
  SHR r1,r1,4
  MOVI r8,0
  CMP r1,r8
  MOVI r1,0xE6
  MOVI[NE] r1,0xE7
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_emitb
  JMP @x1_endins
x1_m_int:
  MOVI r1,0xCD
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_emitb
  JMP @x1_endins
x1_h_gdt:
  LD r4,r0,#Z1_OPBASE
  MOVI r8,3
  CMP r4,r8
  JMP[NE] @x1_e_form
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x01
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_ljmp:
  MOVI r1,0xEA
  CALL @x1_emitb
  LD r8,r0,#Z1_V_MODE
  CMP r8,r0
  JMP[EQ] @x1_ljmp16
  LD r2,r0,#Z1_OPBASE+9
  CALL @x1_emitd
  JMP @x1_ljmp_sel
x1_ljmp16:
  LD r2,r0,#Z1_OPBASE+9
  CALL @x1_emitw
x1_ljmp_sel:
  LD r2,r0,#Z1_OPBASE+1
  CALL @x1_emitw
  JMP @x1_endins
x1_m_shrd:
  LD r4,r0,#Z1_OPBASE
  MOVI r8,2
  CMP r4,r8
  JMP[NE] @x1_e_form
  MOVI r2,2
  CALL @x1_sz_op
  ADD r11,r1,r0
  CMP r11,r0
  JMP[EQ] @x1_e_form
  ADD r1,r11,r0
  CALL @x1_prefix
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0xAC
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,2
  CALL @x1_enc_rm
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_emitb
  JMP @x1_endins
x1_m_bt:
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0xA3
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_bswap:
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_rf
  ADDI r1,r1,0xC8
  CALL @x1_emitb
  JMP @x1_endins
x1_h_sse3:
  MOVI r1,0xF3
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_h_sse0:
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_h_cvt:
  MOVI r1,0xF3
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_movd:
  LD r4,r0,#Z1_OPBASE+1
  SHR r4,r4,4
  MOVI r8,3
  CMP r4,r8
  JMP[EQ] @x1_md_x
  MOVI r1,0x66
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x6E
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_md_x:
  MOVI r1,0x66
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x7E
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_movql:
  MOVI r1,0xF3
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x7E
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_movqs:
  MOVI r1,0x66
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0xD6
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_h_movq:
  LD r4,r0,#Z1_OPBASE+1
  SHR r4,r4,4
  MOVI r8,3
  CMP r4,r8
  JMP[EQ] @x1_mq_st
  MOVI r1,0xF3
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0x7E
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_mq_st:
  MOVI r1,0x66
  CALL @x1_emitb
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0xD6
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+1
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  JMP @x1_endins
x1_m_imul:
  LD r4,r0,#Z1_V_OPN
  MOVI r8,1
  CMP r4,r8
  JMP[EQ] @x1_h_group
  LD r6,r0,#Z1_OPBASE+8
  MOVI r8,1
  CMP r6,r8
  JMP[NE] @x1_e_form
  LD r4,r0,#Z1_OPBASE
  MOVI r8,2
  CMP r4,r8
  JMP[EQ] @x1_im_imm
  MOVI r1,0x0F
  CALL @x1_emitb
  MOVI r1,0xAF
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_im_imm:
  LD r10,r0,#Z1_OPBASE+1
  ADD r1,r10,r0
  CALL @x1_fits8
  CMP r9,r0
  JMP[EQ] @x1_im_i32
  MOVI r1,0x6B
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  ADD r1,r10,r0
  CALL @x1_emitb
  JMP @x1_endins
x1_im_i32:
  MOVI r1,0x69
  CALL @x1_emitb
  LD r1,r0,#Z1_OPBASE+9
  CALL @x1_rf
  MOVI r2,1
  CALL @x1_enc_rm
  ADD r2,r10,r0
  CALL @x1_emitd
  JMP @x1_endins
x1_h_setcc:
  MOVI r1,0x0F
  CALL @x1_emitb
  LD r1,r0,#Z1_V_AUX0
  ADDI r1,r1,0x90
  CALL @x1_emitb
  MOVI r1,0
  MOVI r2,0
  CALL @x1_enc_rm
  JMP @x1_endins
x1_d_byte:
  ST r15,r14,0
  ADD r14,r14,r13
x1_db_l:
  CALL @x1_expr
  ADD r1,r8,r0
  CALL @x1_emitb
  CALL @x1_nextc
  MOVI r4,44
  CMP r1,r4
  JMP[EQ] @x1_db_l
  CALL @x1_ungetc
  SUB r14,r14,r13
  LD r15,r14,0
  JMP @x1_endins
x1_d_word:
  ST r15,r14,0
  ADD r14,r14,r13
x1_dw_l:
  CALL @x1_expr
  ADD r2,r8,r0
  CALL @x1_emitw
  CALL @x1_nextc
  MOVI r4,44
  CMP r1,r4
  JMP[EQ] @x1_dw_l
  CALL @x1_ungetc
  SUB r14,r14,r13
  LD r15,r14,0
  JMP @x1_endins
x1_d_long:
  ST r15,r14,0
  ADD r14,r14,r13
x1_dl_l:
  CALL @x1_expr
  ADD r2,r8,r0
  CALL @x1_emitd
  CALL @x1_nextc
  MOVI r4,44
  CMP r1,r4
  JMP[EQ] @x1_dl_l
  CALL @x1_ungetc
  SUB r14,r14,r13
  LD r15,r14,0
  JMP @x1_endins
x1_d_str:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @x1_nextc
  MOVI r4,34
  CMP r1,r4
  JMP[NE] @x1_ds_bad
x1_ds_l:
  CALL @x1_getc
  CMP r1,r0
  JMP[EQ] @x1_ds_e
  MOVI r4,34
  CMP r1,r4
  JMP[EQ] @x1_ds_e
  MOVI r4,92
  CMP r1,r4
  JMP[NE] @x1_ds_p
  CALL @x1_getc
  MOVI r4,110
  CMP r1,r4
  MOVI[EQ] r1,10
  MOVI r4,114
  CMP r1,r4
  MOVI[EQ] r1,13
  MOVI r4,116
  CMP r1,r4
  MOVI[EQ] r1,9
  MOVI r4,48
  CMP r1,r4
  MOVI[EQ] r1,0
x1_ds_p:
  CALL @x1_emitb
  JMP @x1_ds_l
x1_ds_bad:
  CALL @x1_bump_err
x1_ds_e:
  SUB r14,r14,r13
  LD r15,r14,0
  JMP @x1_endins
x1_d_equ:
  CALL @x1_nextc
  CALL @x1_rdhash1
  ADD r12,r5,r0
  CALL @x1_expr
  ADD r5,r12,r0
  CALL @x1_define
  JMP @x1_endins
x1_d_org:
  CALL @x1_expr
  ADD r10,r8,r0
  LD r1,r0,#Z1_V_PC
  CMP r10,r1
  JMP[LT] @x1_e_form
x1_org_l:
  LD r1,r0,#Z1_V_PC
  CMP r1,r10
  JMP[EQ] @x1_endins
  MOVI r1,0
  CALL @x1_emitb
  JMP @x1_org_l
x1_d_align:
  CALL @x1_expr
  ADD r10,r8,r0
  CMP r10,r0
  JMP[EQ] @x1_e_form
  LD r1,r0,#Z1_V_PC
  ADD r1,r1,r10
  SUB r1,r1,r13
  ADD r3,r1,r0
  ADD r4,r10,r0
  DIVU r6,r3,r4
  MUL r7,r6,r4
x1_al_l:
  LD r1,r0,#Z1_V_PC
  CMP r1,r7
  JMP[EQ] @x1_endins
  MOVI r1,0
  CALL @x1_emitb
  JMP @x1_al_l
x1_d_base:
  CALL @x1_expr
  ST r8,r0,#Z1_V_BASE
  JMP @x1_endins
x1_d_code16:
  MOVI r4,0
  ST r4,r0,#Z1_V_MODE
  JMP @x1_endins
x1_d_code32:
  MOVI r4,1
  ST r4,r0,#Z1_V_MODE
  JMP @x1_endins
x1_d_code64:
  MOVI r4,2
  ST r4,r0,#Z1_V_MODE
  JMP @x1_endins
x1_m_inc_b:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_incdec
x1_m_inc_w:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_incdec
x1_m_inc_l:
  MOVI r4,4
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_incdec
x1_m_alu_b:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_alu
x1_m_alu_w:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_alu
x1_m_alu_l:
  MOVI r4,4
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_alu
x1_m_test_b:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_test
x1_m_test_w:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_test
x1_m_test_l:
  MOVI r4,4
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_test
x1_m_shift_b:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_shift
x1_m_shift_w:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_shift
x1_m_shift_l:
  MOVI r4,4
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_shift
x1_m_group_b:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_group
x1_m_group_w:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_group
x1_m_group_l:
  MOVI r4,4
  ST r4,r0,#Z1_V_SZ
  JMP @x1_h_group
x1_m_imul_b:
  MOVI r4,1
  ST r4,r0,#Z1_V_SZ
  JMP @x1_m_imul
x1_m_imul_w:
  MOVI r4,2
  ST r4,r0,#Z1_V_SZ
  JMP @x1_m_imul
x1_m_imul_l:
  MOVI r4,4
  ST r4,r0,#Z1_V_SZ
  JMP @x1_m_imul

; ---- x86 tables ----
; nasm1_tables.nas - generated by tools/gen_nasm1_tables.py; djb2 5381, case-folded. Do not edit by hand.
x1_mnem:
.word 193464626,@x1_h_byte1,144   ; NOP
.word 193457997,@x1_h_byte1,244   ; HLT
.word 193468656,@x1_h_byte1,195   ; RET
.word 193452535,@x1_h_byte1,248   ; CLC
.word 193470223,@x1_h_byte1,249   ; STC
.word 193452536,@x1_h_byte1,252   ; CLD
.word 193470224,@x1_h_byte1,253   ; STD
.word 193452541,@x1_h_byte1,250   ; CLI
.word 193470229,@x1_h_byte1,251   ; STI
.word 2088966988,@x1_h_byte1,153   ; CLTD
.word 193463543,@x1_m_mov,0   ; MOV
.word 2089329689,@x1_m_movb,0   ; MOVB
.word 2089329710,@x1_m_movw,0   ; MOVW
.word 2089329699,@x1_m_movl,0   ; MOVL
.word 228403881,@x1_h_movzx,0   ; MOVZX
.word 3242360843,@x1_h_movzx,182   ; MOVZXB
.word 3242360864,@x1_h_movzx,183   ; MOVZXW
.word 228403650,@x1_h_movsx,0   ; MOVSX
.word 3242353220,@x1_h_movsx,190   ; MOVSXB
.word 3242353241,@x1_h_movsx,191   ; MOVSXW
.word 193450094,@x1_h_alu,0   ; ADD
.word 5862598,@x1_h_alu,2049   ; OR
.word 193450424,@x1_h_alu,8196   ; AND
.word 193470255,@x1_h_alu,10245   ; SUB
.word 193475518,@x1_h_alu,12294   ; XOR
.word 193452581,@x1_h_alu,14343   ; CMP
.word 2089570277,@x1_h_test,0   ; TEST
.word 193459135,@x1_h_incdec,0   ; INC
.word 193453393,@x1_h_incdec,1   ; DEC
.word 193464630,@x1_h_group,2   ; NOT
.word 193464287,@x1_h_group,3   ; NEG
.word 193463731,@x1_h_group,4   ; MUL
.word 2089183740,@x1_m_imul,5   ; IMUL
.word 193453544,@x1_h_group,6   ; DIV
.word 2089173553,@x1_h_group,7   ; IDIV
.word 193469836,@x1_h_shift,4   ; SHL
.word 193469605,@x1_h_shift,4   ; SAL
.word 193469842,@x1_h_shift,5   ; SHR
.word 193469611,@x1_h_shift,7   ; SAR
.word 193468978,@x1_h_shift,0   ; ROL
.word 193468984,@x1_h_shift,1   ; ROR
.word 193460204,@x1_m_jmp,0   ; JMP
.word 2088954753,@x1_m_call,0   ; CALL
.word 2089293535,@x1_m_loop,0   ; LOOP
.word 224465993,@x1_m_jecxz,0   ; JECXZ
.word 2089443941,@x1_h_pushpop,0   ; PUSH
.word 193466804,@x1_h_pushpop,1   ; POP
.word 193462103,@x1_h_lea,0   ; LEA
.word 5862396,@x1_m_inout,0   ; IN
.word 193465917,@x1_m_inout,0   ; OUT
.word 193459152,@x1_m_int,0   ; INT
.word 2089284464,@x1_h_gdt,2   ; LGDT
.word 2089286642,@x1_h_gdt,3   ; LIDT
.word 2089288024,@x1_m_ljmp,0   ; LJMP
.word 2089537558,@x1_m_shrd,0   ; SHRD
.word 5862171,@x1_m_bt,0   ; BT
.word 215502754,@x1_m_bswap,0   ; BSWAP
.word 213757684,@x1_h_sse3,88   ; ADDSS
.word 235713013,@x1_h_sse3,92   ; SUBSS
.word 228608377,@x1_h_sse3,89   ; MULSS
.word 217514734,@x1_h_sse3,94   ; DIVSS
.word 3479394613,@x1_h_sse3,81   ; SQRTSS
.word 887125544,@x1_h_sse0,46   ; UCOMISS
.word 241444321,@x1_h_sse0,87   ; XORPS
.word 4143355846,@x1_h_cvt,42   ; CVTSI2SS
.word 3638901402,@x1_h_cvt,44   ; CVTTSS2SI
.word 2089329691,@x1_m_movd,0   ; MOVD
.word 228403572,@x1_m_movql,0   ; MOVQL
.word 228403579,@x1_m_movqs,0   ; MOVQS
.word 2089329704,@x1_h_movq,0   ; MOVQ
.word 3242360127,@x1_h_movzx,182   ; MOVZBL
.word 3242360820,@x1_h_movzx,183   ; MOVZWL
.word 3242352504,@x1_h_movsx,190   ; MOVSBL
.word 3242353197,@x1_h_movsx,191   ; MOVSWL
.word 223586734,@x1_m_imul,0   ; IMUL2
.word 2833639705,@x1_h_rep,171   ; REPSTOSD
.word 2826352117,@x1_h_rep,165   ; REPMOVSD
.word 2089184225,@x1_m_inc_b,0   ; INCB
.word 2088994739,@x1_m_inc_b,1   ; DECB
.word 2088885872,@x1_m_alu_b,0   ; ADDB
.word 193465800,@x1_m_alu_b,2049   ; ORB
.word 2088896762,@x1_m_alu_b,8196   ; ANDB
.word 2089551185,@x1_m_alu_b,10245   ; SUBB
.word 2089724864,@x1_m_alu_b,12294   ; XORB
.word 2088967943,@x1_m_alu_b,14343   ; CMPB
.word 236342471,@x1_m_test_b,0   ; TESTB
.word 2089537358,@x1_m_shift_b,4   ; SHLB
.word 2089529735,@x1_m_shift_b,4   ; SALB
.word 2089537556,@x1_m_shift_b,5   ; SHRB
.word 2089529933,@x1_m_shift_b,7   ; SARB
.word 2089509044,@x1_m_shift_b,0   ; ROLB
.word 2089509242,@x1_m_shift_b,1   ; RORB
.word 2089365560,@x1_m_group_b,2   ; NOTB
.word 2089354241,@x1_m_group_b,3   ; NEGB
.word 2089335893,@x1_m_group_b,4   ; MULB
.word 2088999722,@x1_m_group_b,6   ; DIVB
.word 223250579,@x1_m_group_b,7   ; IDIVB
.word 223586750,@x1_m_imul_b,5   ; IMULB
.word 2089184246,@x1_m_inc_w,0   ; INCW
.word 2088994760,@x1_m_inc_w,1   ; DECW
.word 2088885893,@x1_m_alu_w,0   ; ADDW
.word 193465821,@x1_m_alu_w,2049   ; ORW
.word 2088896783,@x1_m_alu_w,8196   ; ANDW
.word 2089551206,@x1_m_alu_w,10245   ; SUBW
.word 2089724885,@x1_m_alu_w,12294   ; XORW
.word 2088967964,@x1_m_alu_w,14343   ; CMPW
.word 236342492,@x1_m_test_w,0   ; TESTW
.word 2089537379,@x1_m_shift_w,4   ; SHLW
.word 2089529756,@x1_m_shift_w,4   ; SALW
.word 2089537577,@x1_m_shift_w,5   ; SHRW
.word 2089529954,@x1_m_shift_w,7   ; SARW
.word 2089509065,@x1_m_shift_w,0   ; ROLW
.word 2089509263,@x1_m_shift_w,1   ; RORW
.word 2089365581,@x1_m_group_w,2   ; NOTW
.word 2089354262,@x1_m_group_w,3   ; NEGW
.word 2089335914,@x1_m_group_w,4   ; MULW
.word 2088999743,@x1_m_group_w,6   ; DIVW
.word 223250600,@x1_m_group_w,7   ; IDIVW
.word 223586771,@x1_m_imul_w,5   ; IMULW
.word 2089184235,@x1_m_inc_l,0   ; INCL
.word 2088994749,@x1_m_inc_l,1   ; DECL
.word 2088885882,@x1_m_alu_l,0   ; ADDL
.word 193465810,@x1_m_alu_l,2049   ; ORL
.word 2088896772,@x1_m_alu_l,8196   ; ANDL
.word 2089551195,@x1_m_alu_l,10245   ; SUBL
.word 2089724874,@x1_m_alu_l,12294   ; XORL
.word 2088967953,@x1_m_alu_l,14343   ; CMPL
.word 236342481,@x1_m_test_l,0   ; TESTL
.word 2089537368,@x1_m_shift_l,4   ; SHLL
.word 2089529745,@x1_m_shift_l,4   ; SALL
.word 2089537566,@x1_m_shift_l,5   ; SHRL
.word 2089529943,@x1_m_shift_l,7   ; SARL
.word 2089509054,@x1_m_shift_l,0   ; ROLL
.word 2089509252,@x1_m_shift_l,1   ; RORL
.word 2089365570,@x1_m_group_l,2   ; NOTL
.word 2089354251,@x1_m_group_l,3   ; NEGL
.word 2089335903,@x1_m_group_l,4   ; MULL
.word 2088999732,@x1_m_group_l,6   ; DIVL
.word 223250589,@x1_m_group_l,7   ; IDIVL
.word 223586760,@x1_m_imul_l,5   ; IMULL
.word 5862430,@x1_h_jcc,0   ; JO
.word 193460236,@x1_h_jcc,1   ; JNO
.word 5862417,@x1_h_jcc,2   ; JB
.word 5862418,@x1_h_jcc,2   ; JC
.word 193459797,@x1_h_jcc,3   ; JAE
.word 193460224,@x1_h_jcc,3   ; JNC
.word 5862420,@x1_h_jcc,4   ; JE
.word 5862441,@x1_h_jcc,4   ; JZ
.word 193460226,@x1_h_jcc,5   ; JNE
.word 193460247,@x1_h_jcc,5   ; JNZ
.word 193459830,@x1_h_jcc,6   ; JBE
.word 5862416,@x1_h_jcc,7   ; JA
.word 5862434,@x1_h_jcc,8   ; JS
.word 193460240,@x1_h_jcc,9   ; JNS
.word 5862431,@x1_h_jcc,10   ; JP
.word 193460237,@x1_h_jcc,11   ; JNP
.word 5862427,@x1_h_jcc,12   ; JL
.word 193459995,@x1_h_jcc,13   ; JGE
.word 193460160,@x1_h_jcc,14   ; JLE
.word 5862422,@x1_h_jcc,15   ; JG
.word 2089534368,@x1_h_setcc,0   ; SETO
.word 235157454,@x1_h_setcc,1   ; SETNO
.word 2089534355,@x1_h_setcc,2   ; SETB
.word 2089534356,@x1_h_setcc,2   ; SETC
.word 235157015,@x1_h_setcc,3   ; SETAE
.word 235157442,@x1_h_setcc,3   ; SETNC
.word 2089534358,@x1_h_setcc,4   ; SETE
.word 2089534379,@x1_h_setcc,4   ; SETZ
.word 235157444,@x1_h_setcc,5   ; SETNE
.word 235157465,@x1_h_setcc,5   ; SETNZ
.word 235157048,@x1_h_setcc,6   ; SETBE
.word 2089534354,@x1_h_setcc,7   ; SETA
.word 2089534372,@x1_h_setcc,8   ; SETS
.word 235157458,@x1_h_setcc,9   ; SETNS
.word 2089534369,@x1_h_setcc,10   ; SETP
.word 235157455,@x1_h_setcc,11   ; SETNP
.word 2089534365,@x1_h_setcc,12   ; SETL
.word 235157213,@x1_h_setcc,13   ; SETGE
.word 235157378,@x1_h_setcc,14   ; SETLE
.word 2089534360,@x1_h_setcc,15   ; SETG
.word 0,0,0
x1_regs:
.word 193454371,32   ; EAX
.word 193454437,33   ; ECX
.word 193454470,34   ; EDX
.word 193454404,35   ; EBX
.word 193454957,36   ; ESP
.word 193454396,37   ; EBP
.word 193454950,38   ; ESI
.word 193454455,39   ; EDI
.word 5862142,16   ; AX
.word 5862208,17   ; CX
.word 5862241,18   ; DX
.word 5862175,19   ; BX
.word 5862728,20   ; SP
.word 5862167,21   ; BP
.word 5862721,22   ; SI
.word 5862226,23   ; DI
.word 5862130,0   ; AL
.word 5862196,1   ; CL
.word 5862229,2   ; DL
.word 5862163,3   ; BL
.word 5862126,4   ; AH
.word 5862192,5   ; CH
.word 5862225,6   ; DH
.word 5862159,7   ; BH
.word 5862269,80   ; ES
.word 5862203,81   ; CS
.word 5862731,82   ; SS
.word 5862236,83   ; DS
.word 5862302,84   ; FS
.word 5862335,85   ; GS
.word 193452714,64   ; CR0
.word 193452716,66   ; CR2
.word 193452717,67   ; CR3
.word 2089722503,48   ; XMM0
.word 2089722504,49   ; XMM1
.word 2089722505,50   ; XMM2
.word 2089722506,51   ; XMM3
.word 2089722507,52   ; XMM4
.word 2089722508,53   ; XMM5
.word 2089722509,54   ; XMM6
.word 2089722510,55   ; XMM7
.word 0,0
x1_dirs:
.word 2088945209,@x1_d_byte,0   ; .byte
.word 2089688929,@x1_d_word,0   ; .word
.word 2089293493,@x1_d_long,0   ; .long
.word 193470238,@x1_d_str,0   ; .str
.word 193454896,@x1_d_equ,0   ; .equ
.word 193465805,@x1_d_org,0   ; .org
.word 214050224,@x1_d_align,0   ; .align
.word 2088919040,@x1_d_base,0   ; .base
.word 2850335879,@x1_d_code16,0   ; .code16
.word 2850335941,@x1_d_code32,0   ; .code32
.word 2850336042,@x1_d_code64,0   ; .code64
.word 0,0,0
