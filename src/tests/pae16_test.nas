; pae16_test.nas - guest proof for the 16 GB PAE bank window and PMEM v1 map.
;
; CPUID leaf 0x4E4D00FF queries (mask, words, flags, bank switches).  nn=0x1F
; raises the mask to the kernel's power-of-two wrap cap.  The test then:
;   1. validates the PMEM v1 block at word 0x3F800 (magic/version/count/flags,
;      ascending non-overlapping entries inside MEMQ words, kinds 1..5);
;   2. computes the bank count from the exact word count (ceil(words/2^27));
;   3. for every bank, finds a kind-1 PMEM word in that bank, writes a unique
;      class-6 payload at it, and after all banks are written reads every word
;      back (aliasing or a wrong window switch shows as a payload/class error);
;   4. BCOPYs eight words from bank 0 to the highest bank and verifies them.
; Output is line-oriented hex so the outer gate can parse it.
; PASS lines: "PMEM PASS", "BANKS PASS", "PASS".
.include "../lib/memmap_defs.nas"
main:
  MOVI r13,1
  MOVI r11,6
  ; ---- MEMQ: raise to the kernel's maximum wrap mask, then report it ----
  LA r1,0x4E4D001F
  MOVI r2,0
  CPUID r3,r1,r2
  ST r3,r0,@mk
  MOVI r4,77                ; M effective mask
  CALL @ph
  MOVI r2,1
  CPUID r3,r1,r2
  ST r3,r0,@nwd
  MOVI r4,87                ; W exact words
  CALL @ph
  MOVI r2,2
  CPUID r3,r1,r2
  ST r3,r0,@flg
  MOVI r4,70                ; F flags
  CALL @ph
  MOVI r2,3
  CPUID r3,r1,r2
  ST r3,r0,@sw
  MOVI r4,83                ; S bank switches
  CALL @ph
  ; bank count = ceil(words / 2^27)
  LD r3,r0,@nwd
  LA r4,0x7FFFFFF
  ADD r3,r3,r4
  SHR r3,r3,27
  ST r3,r0,@nb
  MOVI r4,66                ; B
  CALL @ph
  MOVI r11,0
  MOVI r12,0
  ; ---- PMEM header ----
  LA r10,#MM_BASE
  LD r3,r10,0
  ST r3,r0,@pmagic
  MOVI r4,80                ; P
  CALL @ph
  LD r3,r10,1
  ST r3,r0,@cnt
  MOVI r4,67                ; C
  CALL @ph
  LD r3,r10,2
  ST r3,r0,@pver
  MOVI r4,86                ; V
  CALL @ph
  LD r3,r10,3
  ST r3,r0,@pflg
  MOVI r4,71                ; G
  CALL @ph
  ; magic, version, count, source flag
  LD r3,r10,0
  LA r4,#MM_MAGIC
  CMP r3,r4
  JMP[NE] @mbad
  LD r3,r10,2
  MOVI r4,#MM_VERSION
  CMP r3,r4
  JMP[NE] @mbad
  LD r3,r10,1
  CMP r3,r0
  JMP[EQ] @mbad
  LA r4,#MM_MAX
  CMP r3,r4
  JMP[GT] @mbad
  LD r3,r10,3
  MOVI r4,3
  BOOL.8 r3,r3,r4           ; flags & (E820|SYNTH)
  CMP r3,r0
  JMP[EQ] @mbad
  ; ---- entry validation and summary ----
  LA r7,#MM_BASE
  ADDI r7,r7,#MM_HDR_WORDS  ; entry 0
  MOVI r10,0                ; i
  MOVI r9,0                 ; prev_end
  MOVI r11,0                ; kinds bitmap
  MOVI r12,0                ; usable words
mv_loop:
  LD r8,r0,@cnt
  CMP r10,r8
  JMP[GE] @mv_done
  SHL r6,r10,2
  ADD r6,r6,r7
  LD r1,r6,#MM_E_BASE
  LD r2,r6,#MM_E_WORDS
  LD r3,r6,#MM_E_KIND
  ; nwords != 0
  CMP r2,r0
  JMP[EQ] @mbad
  ; kind 1..5
  MOVI r4,1
  CMP r3,r4
  JMP[LT] @mbad
  MOVI r4,5
  CMP r3,r4
  JMP[GT] @mbad
  ; base < words and base+nwords <= words
  LD r8,r0,@nwd
  CMP r1,r8
  JMP[GE] @mbad
  ADD r4,r1,r2
  CMP r4,r8
  JMP[GT] @mbad
  ; ascending, non-overlapping
  CMP r1,r9
  JMP[LT] @mbad
  ADD r9,r4,r0
  ; kind bitmap for the gate: bit (1<<kind)
  MOVI r8,1
  CMP r3,r8
  JMP[EQ] @mv_k1
  MOVI r8,2
  CMP r3,r8
  JMP[EQ] @mv_k2
  MOVI r8,3
  CMP r3,r8
  JMP[EQ] @mv_k3
  MOVI r8,4
  CMP r3,r8
  JMP[EQ] @mv_k4
  MOVI r8,32
  JMP @mv_kb
mv_k1:
  MOVI r8,2
  JMP @mv_kb
mv_k2:
  MOVI r8,4
  JMP @mv_kb
mv_k3:
  MOVI r8,8
  JMP @mv_kb
mv_k4:
  MOVI r8,16
mv_kb:
  BOOL.14 r11,r11,r8
  ; usable words = sum(kind==1 nwords)
  CMP r3,r13
  JMP[NE] @mv_next
  ADD r12,r12,r2
mv_next:
  ADD r10,r10,r13
  JMP @mv_loop
mv_done:
  ST r11,r0,@kinds
  ST r12,r0,@usable
  MOVI r4,85                ; U usable words
  ADD r3,r12,r0
  CALL @ph
  MOVI r4,81                ; Q kind bitmap
  ADD r3,r11,r0
  CALL @ph
  LD r8,r0,@mflag
  CMP r8,r0
  JMP[NE] @skip_banks
  ; ---- guest-visible dump of every PMEM entry ----
  MOVI r10,0
md_loop:
  LD r8,r0,@cnt
  CMP r10,r8
  JMP[GE] @md_done
  LA r7,#MM_BASE
  ADDI r7,r7,#MM_HDR_WORDS
  SHL r8,r10,2
  ADD r8,r8,r7
  MOVI r4,101               ; e entry index
  ADD r3,r10,r0
  CALL @ph
  LD r3,r8,#MM_E_BASE
  MOVI r4,97                ; a base_word
  CALL @ph
  LD r3,r8,#MM_E_WORDS
  MOVI r4,110               ; n nwords
  CALL @ph
  LD r3,r8,#MM_E_KIND
  MOVI r4,107               ; k kind
  CALL @ph
  LD r3,r8,#MM_E_FLAGS
  MOVI r4,102               ; f flags
  CALL @ph
  ADD r10,r10,r13
  JMP @md_loop
md_done:
  LD r8,r0,@mflag
  CMP r8,r0
  JMP[NE] @skip_banks
  ; ---- pass 1: pick one kind-1 word per bank and write a unique payload ----
  MOVI r10,0                ; bank
bs1_loop:
  LD r8,r0,@nb
  CMP r10,r8
  JMP[GE] @bs1_done
  SHL r2,r10,27             ; bank_lo
  LA r4,0x8000000
  ADD r3,r2,r4              ; bank_hi
  MOVI r5,0                 ; entry index
  MOVI r1,0                 ; found
  MOVI r6,0                 ; test word
bs1_scan:
  LD r8,r0,@cnt
  CMP r5,r8
  JMP[GE] @bs1_nf
  LA r7,#MM_BASE
  ADDI r7,r7,#MM_HDR_WORDS
  SHL r8,r5,2
  ADD r8,r8,r7
  LD r7,r8,#MM_E_KIND
  CMP r7,r13
  JMP[NE] @bs1_next
  LD r7,r8,#MM_E_BASE
  LD r9,r8,#MM_E_WORDS
  ADD r9,r9,r7              ; end
  CMP r9,r2
  JMP[LE] @bs1_next         ; ends before this bank
  CMP r7,r3
  JMP[GE] @bs1_next         ; starts after this bank
  ADD r6,r7,r0
  LA r8,0x80000             ; stay above the guest image and the PMEM block
  ADD r6,r6,r8
  CMP r6,r2
  JMP[GE] @bs1_c1
  ADD r6,r2,r0
bs1_c1:
  CMP r6,r9
  JMP[LT] @bs1_c2
  ADD r6,r9,r0
  SUB r6,r6,r13
bs1_c2:
  CMP r6,r3
  JMP[LT] @bs1_ok
  ADD r6,r3,r0
  SUB r6,r6,r13
bs1_ok:
  MOVI r1,1
  JMP @bs1_found
bs1_next:
  ADD r5,r5,r13
  JMP @bs1_scan
bs1_found:
bs1_nf:
  LA r7,@tf
  ADD r7,r7,r10
  ST r1,r7,0
  LA r7,@tw
  ADD r7,r7,r10
  ST r6,r7,0
  LA r7,0x01010101
  MUL r8,r10,r7
  ADDI r8,r8,0x1234
  LA r7,@tp
  ADD r7,r7,r10
  ST r8,r7,0
  CMP r1,r0
  JMP[EQ] @bs1_skipw
  MOVI r9,6
  STW r8,r6,r9
bs1_skipw:
  ADD r10,r10,r13
  JMP @bs1_loop
bs1_done:
  ; ---- pass 2: read every bank back ----
  MOVI r10,0
bs2_loop:
  LD r8,r0,@nb
  CMP r10,r8
  JMP[GE] @bs2_done
  LA r7,@tf
  ADD r7,r7,r10
  LD r1,r7,0
  CMP r1,r0
  JMP[EQ] @bs2_none
  LA r7,@tw
  ADD r7,r7,r10
  LD r1,r7,0
  LA r7,@tp
  ADD r7,r7,r10
  LD r2,r7,0
  MOVI r4,75                ; K
  ADD r3,r10,r0
  CALL @ph
  LDN r9,r1,0
  MOVI r4,6
  CMP r9,r4
  JMP[NE] @bs2_fail
  LD r9,r1,0
  CMP r9,r2
  JMP[NE] @bs2_fail
  MOVI r5,80                ; P
  PUTC r5
  JMP @bs2_nl
bs2_fail:
  MOVI r5,70                ; F
  PUTC r5
  MOVI r9,1
  ST r9,r0,@bbad
bs2_nl:
  MOVI r5,10
  PUTC r5
  JMP @bs2_next
bs2_none:
  MOVI r4,75
  ADD r3,r10,r0
  CALL @ph
  MOVI r5,45                ; -
  PUTC r5
  MOVI r5,10
  PUTC r5
bs2_next:
  ADD r10,r10,r13
  JMP @bs2_loop
bs2_done:
  ; ---- bank 0 last word (PD1[0], the direct 1 GiB boundary) ----
  LA r1,0x7FFFFFF
  MOVI r2,0x5A5A
  MOVI r3,6
  STW r2,r1,r3
  LDN r4,r1,0
  CMP r4,r3
  JMP[NE] @lw_fail
  LD r4,r1,0
  CMP r4,r2
  JMP[NE] @lw_fail
  MOVI r5,76                ; L
  PUTC r5
  MOVI r5,80                ; P
  PUTC r5
  JMP @lw_nl
lw_fail:
  MOVI r5,76
  PUTC r5
  MOVI r5,70
  PUTC r5
  MOVI r9,1
  ST r9,r0,@bbad
lw_nl:
  MOVI r5,10
  PUTC r5
  ; ---- cross-bank BCOPY: bank 0 -> highest bank ----
  LD r8,r0,@nb
  MOVI r9,2
  CMP r8,r9
  JMP[LT] @bc_skip
  LA r7,@tf
  LD r9,r7,0
  CMP r9,r0
  JMP[EQ] @bc_skip
  LD r8,r0,@nb
  SUB r8,r8,r13
  ADD r7,r7,r8
  LD r9,r7,0
  CMP r9,r0
  JMP[EQ] @bc_skip
  LA r7,@tw
  LD r1,r7,0                ; src word
  LD r8,r0,@nb
  SUB r8,r8,r13
  ADD r7,r7,r8
  LD r2,r7,0                ; dst word
  MOVI r10,0
bc_w:
  LA r7,0xA000
  ADD r7,r7,r10
  ADD r6,r1,r10
  MOVI r9,6
  STW r7,r6,r9
  ADD r10,r10,r13
  MOVI r9,8
  CMP r10,r9
  JMP[LT] @bc_w
  MOVI r4,8
  BCOPY r2,r1,r4
  MOVI r10,0
bc_v:
  ADD r6,r2,r10
  LDN r9,r6,0
  MOVI r8,6
  CMP r9,r8
  JMP[NE] @bc_fail
  LD r9,r6,0
  LA r7,0xA000
  ADD r7,r7,r10
  CMP r9,r7
  JMP[NE] @bc_fail
  ADD r10,r10,r13
  MOVI r9,8
  CMP r10,r9
  JMP[LT] @bc_v
  MOVI r5,68                ; D
  PUTC r5
  MOVI r5,80                ; P
  PUTC r5
  JMP @bc_nl
bc_fail:
  MOVI r5,68
  PUTC r5
  MOVI r5,70
  PUTC r5
  MOVI r9,1
  ST r9,r0,@bbad
bc_nl:
  MOVI r5,10
  PUTC r5
  JMP @bc_done
bc_skip:
  MOVI r5,68
  PUTC r5
  MOVI r5,45
  PUTC r5
  MOVI r5,10
  PUTC r5
bc_done:
skip_banks:
  ; ---- verdict ----
  LD r8,r0,@mflag
  CMP r8,r0
  JMP[NE] @pm_fail
  MOVI r5,80
  PUTC r5
  MOVI r5,77
  PUTC r5
  MOVI r5,69
  PUTC r5
  MOVI r5,77
  PUTC r5
  MOVI r5,32
  PUTC r5
  MOVI r5,80
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,10
  PUTC r5
  JMP @pm_ok
pm_fail:
  MOVI r5,80
  PUTC r5
  MOVI r5,77
  PUTC r5
  MOVI r5,69
  PUTC r5
  MOVI r5,77
  PUTC r5
  MOVI r5,32
  PUTC r5
  MOVI r5,70
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,73
  PUTC r5
  MOVI r5,76
  PUTC r5
  MOVI r5,10
  PUTC r5
pm_ok:
  LD r8,r0,@bbad
  CMP r8,r0
  JMP[NE] @bk_fail
  MOVI r5,66
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,78
  PUTC r5
  MOVI r5,75
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,32
  PUTC r5
  MOVI r5,80
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,10
  PUTC r5
  JMP @bk_ok
bk_fail:
  MOVI r5,66
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,78
  PUTC r5
  MOVI r5,75
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,32
  PUTC r5
  MOVI r5,70
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,73
  PUTC r5
  MOVI r5,76
  PUTC r5
  MOVI r5,10
  PUTC r5
bk_ok:
  LD r8,r0,@mflag
  LD r9,r0,@bbad
  BOOL.14 r8,r8,r9
  CMP r8,r0
  JMP[NE] @all_fail
  MOVI r5,80
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,83
  PUTC r5
  MOVI r5,10
  PUTC r5
  HALT
all_fail:
  MOVI r5,70
  PUTC r5
  MOVI r5,65
  PUTC r5
  MOVI r5,73
  PUTC r5
  MOVI r5,76
  PUTC r5
  MOVI r5,10
  PUTC r5
  HALT
mbad:
  MOVI r9,1
  ST r9,r0,@mflag
  JMP @mv_done
; print r4 as a char, then r3 as 8 hex digits and newline
ph:
  PUTC r4
  MOVI r9,8
ph1:
  SHR r5,r3,28
  SHL r3,r3,4
  MOVI r6,10
  CMP r5,r6
  MOVI r7,48
  MOVI[GE] r7,55
  ADD r7,r7,r5
  PUTC r7
  SUB r9,r9,r13
  CMP r9,r0
  JMP[NE] @ph1
  MOVI r7,10
  PUTC r7
  RET
mk:
  .word 0
nwd:
  .word 0
flg:
  .word 0
sw:
  .word 0
cnt:
  .word 0
pver:
  .word 0
pmagic:
  .word 0
pflg:
  .word 0
nb:
  .word 0
mflag:
  .word 0
bbad:
  .word 0
kinds:
  .word 0
usable:
  .word 0
tw:
  .word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tp:
  .word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tf:
  .word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
