; block.nas - NaN-native straight-line/block translator driver.
; xt_block_x86: r1=source NaN word ptr r2=max words r3=output byte ptr
;              r4=next pc if the block falls through
;              -> r1=emitted bytes (0 on unsupported op)
;
; Decodes real NaN16 words: payload via LD, predicate nibble via LDN.
; Supported: MOVI MOVHI ADD SUB ADDI SHL SHR SAR CMP CMPS LD ST LDB STB,
; JMP/JMPR/RET as block terminators.  Non-branch instructions must be
; ALWAYS or NEVER predicated.  JMP[cond] is fully predicated: the emitted
; x86 tests the guest FLAGM mask and selects target or fallthrough with
; cmov, then returns to the interpreter.
;
; ABI: r0=0, r13=1, r14=translation stack, r15=link.
.include "x86.nas"

xt_block_x86:
  ST r15,r0,@xt_retaddr
  ST r1,r0,@xt_src
  ST r2,r0,@xt_n
  ST r3,r0,@xt_out
  ST r3,r0,@xt_start
  ST r4,r0,@xt_next
  MOVI r11,0
  ST r11,r0,@xt_endflag
xt_loop:
  LD r2,r0,@xt_n
  CMP r2,r0
  JMP[EQ] @xt_end
  LD r1,r0,@xt_src
  LD r5,r1,0
  LDN r6,r1,0
  SHR r7,r5,24
  SHR r8,r5,20
  MOVI r11,15
  BOOL.8 r8,r8,r11
  SHR r9,r5,16
  BOOL.8 r9,r9,r11
  MOVI r11,0xFFFF
  BOOL.8 r10,r5,r11
  MOVI r11,15
  BOOL.8 r12,r10,r11
  ; terminators first
  MOVI r11,0x0A
  CMP r7,r11
  JMP[EQ] @xt_jmp
  MOVI r11,0x0D
  CMP r7,r11
  JMP[EQ] @xt_jmpr
  MOVI r11,0x0C
  CMP r7,r11
  JMP[EQ] @xt_retop
  ; non-branch predicate: ALWAYS or NEVER only
  MOVI r11,15
  CMP r6,r11
  JMP[EQ] @xt_plain
  CMP r6,r0
  JMP[EQ] @xt_adv
  JMP @xt_fail
xt_plain:
  MOVI r11,1
  CMP r7,r11
  JMP[EQ] @xt_movi
  MOVI r11,2
  CMP r7,r11
  JMP[EQ] @xt_movhi
  MOVI r11,3
  CMP r7,r11
  JMP[EQ] @xt_add
  MOVI r11,4
  CMP r7,r11
  JMP[EQ] @xt_sub
  MOVI r11,5
  CMP r7,r11
  JMP[EQ] @xt_shl
  MOVI r11,6
  CMP r7,r11
  JMP[EQ] @xt_shr
  MOVI r11,0x27
  CMP r7,r11
  JMP[EQ] @xt_sar
  MOVI r11,7
  CMP r7,r11
  JMP[EQ] @xt_cmp
  MOVI r11,0x28
  CMP r7,r11
  JMP[EQ] @xt_cmps
  MOVI r11,8
  CMP r7,r11
  JMP[EQ] @xt_ld
  MOVI r11,9
  CMP r7,r11
  JMP[EQ] @xt_st
  MOVI r11,0x29
  CMP r7,r11
  JMP[EQ] @xt_addi
  MOVI r11,0x2A
  CMP r7,r11
  JMP[EQ] @xt_ldb
  MOVI r11,0x2B
  CMP r7,r11
  JMP[EQ] @xt_stb
  JMP @xt_fail

xt_movi:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r7,r10,r0
  CALL @x86_movi_mem
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_movhi:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r7,r10,r0
  CALL @x86_movhi
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_add:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x86_add
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_sub:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r8,r12,r0
  CALL @x86_sub
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_shl:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_shl
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_shr:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_shr
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_sar:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_sar
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_cmp:
  LD r1,r0,@xt_out
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x92
  CALL @x86_cmp
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_cmps:
  LD r1,r0,@xt_out
  ADD r6,r9,r0
  ADD r8,r12,r0
  MOVI r9,0x9C
  CALL @x86_cmp
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_ld:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_ld
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_st:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_st
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_addi:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_addi
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_ldb:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_ldb
  ST r1,r0,@xt_out
  JMP @xt_adv
xt_stb:
  LD r1,r0,@xt_out
  ADD r5,r8,r0
  ADD r6,r9,r0
  ADD r7,r10,r0
  CALL @x86_stb
  ST r1,r0,@xt_out
  JMP @xt_adv

; ---- terminators ---------------------------------------------------------
xt_jmp:
  MOVI r11,15
  CMP r6,r11
  JMP[EQ] @xt_jmp_u
  CMP r6,r0
  JMP[EQ] @xt_adv
  LD r1,r0,@xt_out
  ADD r7,r10,r0
  LD r8,r0,@xt_src
  ADDI r8,r8,1
  ADD r9,r6,r0
  CALL @x86_jmp_cond
  ST r1,r0,@xt_out
  JMP @xt_ended
xt_jmp_u:
  LD r1,r0,@xt_out
  ADD r7,r10,r0
  CALL @x86_jmp
  ST r1,r0,@xt_out
  JMP @xt_ended

xt_jmpr:
  MOVI r11,15
  CMP r6,r11
  JMP[EQ] @xt_jmpr_u
  CMP r6,r0
  JMP[EQ] @xt_adv
  JMP @xt_fail
xt_jmpr_u:
  LD r1,r0,@xt_out
  ADD r6,r9,r0
  CALL @x86_jmpr
  ST r1,r0,@xt_out
  JMP @xt_ended

xt_retop:
  MOVI r11,15
  CMP r6,r11
  JMP[EQ] @xt_ret_u
  CMP r6,r0
  JMP[EQ] @xt_adv
  JMP @xt_fail
xt_ret_u:
  LD r1,r0,@xt_out
  CALL @x86_ret
  ST r1,r0,@xt_out

xt_ended:
  MOVI r11,1
  ST r11,r0,@xt_endflag

xt_adv:
  LD r1,r0,@xt_src
  ADDI r1,r1,1
  ST r1,r0,@xt_src
  LD r2,r0,@xt_n
  SUB r2,r2,r13
  ST r2,r0,@xt_n
  LD r11,r0,@xt_endflag
  CMP r11,r0
  JMP[NE] @xt_end
  JMP @xt_loop

xt_end:
  LD r11,r0,@xt_endflag
  CMP r11,r0
  JMP[NE] @xt_done
  LD r1,r0,@xt_out
  LD r7,r0,@xt_next
  CALL @x86_jmp
  ST r1,r0,@xt_out
xt_done:
  LD r1,r0,@xt_out
  LD r2,r0,@xt_start
  SUB r1,r1,r2
  LD r15,r0,@xt_retaddr
  RET
xt_fail:
  MOVI r1,0
  LD r15,r0,@xt_retaddr
  RET

xt_retaddr:
  .word 0
xt_src:
  .word 0
xt_n:
  .word 0
xt_out:
  .word 0
xt_start:
  .word 0
xt_next:
  .word 0
xt_endflag:
  .word 0
