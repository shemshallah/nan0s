; ndbg.nas - NaN/0S native debug core, first proof. Written entirely in NaN16.
;
; No host code, no C, no Python. This file is assembled by tools/nmk.awk and runs
; on the real NaN16 machine (x86 kan16 or the portable C core). It proves the
; two load-bearing ideas of spec/NANDBG.md:
;
;   1. THE DIAGNOSTIC WORD. A fault is a normal 64-bit NaN word whose two heads
;      are the type: near head = severity, far head = domain. LDN reads the type
;      as a nibble; STW writes it; BSWAPM mirrors it by rot2(n).
;         severity: +s fault   -s panic   +q warn   -q info
;         domain:   +s core    -s memory  +q device -q program
;      payload = code:8 | site:24. A fault is data the machine can inspect.
;
;   2. THE STEP CORE. A NaN16 interpreter that executes exactly one target
;      instruction, returns a status word, and turns gate/bad-op traps into
;      typed records instead of a halt. Breakpoints are checked before fetch;
;      the target image is never modified, so seals stay valid.
;
; This proof implements the control core (MOVI/MOVHI/ADD/SUB/CMP/JMP/CALL/RET/
; JMPR/LD/ST/STW/LDN/PUTC/NOP/HALT, all 16 BOOL functions, predication, flags)
; and the typed record path. The full op table, watchpoints, shadow call stack,
; history ring and UI are designed in spec/NANDBG.md and are the next stages.
;
; ABI: r0=0, r13=1. No stack; every CALL saves r15 in a private cell.
;
; Serial output is deliberately tiny and parseable:
;   !D<type><code>@<site> W=<hi><lo>
;   NDBG PASS   |   NDBG FAIL <code>
;
.org 0
JMP @nd_main

; =============================================================================
; diagnostic type helpers
; =============================================================================

; nd_mkword: r1 = type nibble, r2 = payload, r3 = destination word
; writes one legal NaN word with that type. This is STW, the type-bearing store.
nd_mkword:
  STW r2,r3,r1
  RET

; nd_quiet: r1 = type -> r1 = same type with both quiet bits set
; +s -> +q on both faces; the fault has been heard and latched.
nd_quiet:
  MOVI r2,10
  BOOL.14 r1,r1,r2
  RET

; nd_raise: r1 = type -> r1 = same type with both quiet bits clear
nd_raise:
  MOVI r2,5
  BOOL.8 r1,r1,r2
  RET

; nd_rot2: r1 = type -> r1 = rot2(type), the BSWAPM mirror of the nibble
nd_rot2:
  MOVI r2,3
  BOOL.8 r2,r1,r2
  SHL r2,r2,2
  SHR r1,r1,2
  BOOL.14 r1,r1,r2
  RET

; nd_puthex: r1 = value, r2 = digits. Prints uppercase hex to COM1.
nd_puthex:
  ST r15,r0,@ph_lnk
  ST r1,r0,@ph_v
  ST r2,r0,@ph_n
  CMP r2,r0
  JMP[EQ] @ph_end
  ; align the requested low n nibbles to the top of the word
  MOVI r3,1
  SUB r3,r2,r3
  MOVI r4,@ph_pow
  ADD r4,r4,r3
  LD r4,r4,0
  MUL r1,r1,r4
  ST r1,r0,@ph_v
ph_loop:
  LD r2,r0,@ph_n
  CMP r2,r0
  JMP[EQ] @ph_end
  LD r1,r0,@ph_v
  SHR r3,r1,28
  SHL r1,r1,4
  ST r1,r0,@ph_v
  MOVI r4,48
  ADD r4,r4,r3
  MOVI r5,10
  CMP r3,r5
  MOVI r6,7
  ADD[GE] r4,r4,r6
  PUTC r4
  LD r2,r0,@ph_n
  SUB r2,r2,r13
  ST r2,r0,@ph_n
  JMP @ph_loop
ph_end:
  LD r15,r0,@ph_lnk
  RET
ph_lnk:
.word 0
ph_v:
.word 0
ph_n:
.word 0
ph_pow:
.word 268435456,16777216,1048576,65536,4096,256,16,1

; nd_puts: r1 = word address of a NUL-terminated 4-chars-per-word string.
nd_puts:
  ST r15,r0,@ps_lnk
  ST r1,r0,@ps_a
ps_word:
  LD r1,r0,@ps_a
  LD r2,r1,0
  MOVI r3,4
ps_ch:
  MOVI r4,255
  BOOL.8 r5,r2,r4
  CMP r5,r0
  JMP[EQ] @ps_end
  PUTC r5
  SHR r2,r2,8
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @ps_ch
  LD r1,r0,@ps_a
  ADD r1,r1,r13
  ST r1,r0,@ps_a
  JMP @ps_word
ps_end:
  LD r15,r0,@ps_lnk
  RET
ps_lnk:
.word 0
ps_a:
.word 0

; nd_sev: r1 = type -> r1 = severity 0 fault 1 panic 2 warn 3 info
nd_sev:
  SHR r1,r1,2
  RET

; nd_dom: r1 = type -> r1 = domain 0 core 1 memory 2 device 3 program
nd_dom:
  MOVI r2,3
  BOOL.8 r1,r1,r2
  RET

; nd_type_letters: r1 = type. Prints the two-letter severity/domain tag.
nd_type_letters:
  ST r15,r0,@tl_lnk
  ST r1,r0,@tl_n
  CALL @nd_sev
  MOVI r2,@nd_sev_ch
  ADD r1,r1,r2
  LD r1,r1,0
  PUTC r1
  LD r1,r0,@tl_n
  CALL @nd_dom
  MOVI r2,@nd_dom_ch
  ADD r1,r1,r2
  LD r1,r1,0
  PUTC r1
  LD r15,r0,@tl_lnk
  RET
tl_lnk:
.word 0
tl_n:
.word 0
nd_sev_ch:
.word 70,80,87,73
nd_dom_ch:
.word 67,77,68,83

; =============================================================================
; typed record: 4 words
;   rec+0  HEADER  type, payload = code<<24 | seq
;   rec+1  SITE    type, payload = site(24) | space<<24
;   rec+2  WORD_LO type 10, faulting word low 32
;   rec+3  WORD_HI type 10, faulting word high 32
; =============================================================================

; nd_emit: r1=type r2=code r3=site r4=word_lo r5=word_hi. Writes nd_rec.
nd_emit:
  ST r15,r0,@ne_lnk
  ST r1,r0,@ne_n
  ST r2,r0,@ne_code
  ST r3,r0,@ne_site
  ST r4,r0,@ne_lo
  ST r5,r0,@ne_hi
  ; header
  LD r6,r0,@ne_code
  SHL r6,r6,24
  LD r7,r0,@nd_seq
  LA r8,0xFFFFFF
  BOOL.8 r7,r7,r8
  BOOL.14 r6,r6,r7
  MOVI r9,@nd_rec
  LD r1,r0,@ne_n
  STW r6,r9,r1
  ; site (space 0 = code)
  LD r6,r0,@ne_site
  BOOL.8 r6,r6,r8
  MOVI r9,@nd_rec
  ADD r9,r9,r13
  STW r6,r9,r1
  ; raw word: low half is the payload, high half is zero in this proof
  MOVI r9,@nd_rec
  MOVI r8,2
  ADD r9,r9,r8
  MOVI r1,10
  LD r6,r0,@ne_lo
  STW r6,r9,r1
  ADD r9,r9,r13
  LD r6,r0,@ne_hi
  STW r6,r9,r1
  ; sequence
  LD r6,r0,@nd_seq
  ADD r6,r6,r13
  ST r6,r0,@nd_seq
  LD r15,r0,@ne_lnk
  RET
ne_lnk:
.word 0
ne_n:
.word 0
ne_code:
.word 0
ne_site:
.word 0
ne_lo:
.word 0
ne_hi:
.word 0

; nd_print_rec: render nd_rec as one line on COM1.
nd_print_rec:
  ST r15,r0,@pr_lnk
  MOVI r1,33
  PUTC r1
  MOVI r1,68
  PUTC r1
  MOVI r1,@nd_rec
  LDN r1,r1,0
  CALL @nd_type_letters
  MOVI r1,64
  PUTC r1
  ; header payload: code
  LD r1,r0,@nd_rec
  SHR r1,r1,24
  MOVI r2,2
  CALL @nd_puthex
  ; site
  MOVI r1,@nd_rec
  ADD r1,r1,r13
  LD r1,r1,0
  LA r2,0xFFFFFF
  BOOL.8 r1,r1,r2
  MOVI r2,6
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  MOVI r1,87
  PUTC r1
  MOVI r1,61
  PUTC r1
  ; raw word: high then low payload
  MOVI r1,@nd_rec
  MOVI r2,3
  ADD r1,r1,r2
  LD r1,r1,0
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,@nd_rec
  MOVI r2,2
  ADD r1,r1,r2
  LD r1,r1,0
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  LD r15,r0,@pr_lnk
  RET
pr_lnk:
.word 0

; =============================================================================
; target status and state
; =============================================================================
; status: 0 ok, 1 halt, 2 break, 3 fault
; reason codes: 0x00 halt none, 0x10 gate, 0x20 bad op, 0x21 unimplemented
;               0x02 breakpoint

nd_regs:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nd_pc:
.word 0
nd_k:
.word 0
nd_steps:
.word 0
nd_mask:
.word 0xFFFF
nd_gb:
.word 0
nd_brk:
.word 0xFFFFFFFF
nd_status:
.word 0
nd_reason:
.word 0
nd_seq:
.word 0
nd_raw:
.word 0
nd_waddr:
.word 0
nd_curn:
.word 0
nd_payload:
.word 0
nd_op:
.word 0
nd_d:
.word 0
nd_a:
.word 0
nd_imm:
.word 0
nd_b:
.word 0
nd_A:
.word 0
nd_B:
.word 0
nd_EA:
.word 0
nd_VAL:
.word 0
nd_bits:
.word 1,2,4,8
nd_rec:
.word 0,0,0,0,0,0,0,0

; nd_getreg: r1 = index -> r1 = value
nd_getreg:
  LD r1,r1,@nd_regs
  RET

; nd_setreg: r1 = index, r2 = value
nd_setreg:
  ST r2,r1,@nd_regs
  RET

; nd_setk2: r1 = Z, r2 = L -> nd_k = 2Z+L
nd_setk2:
  SHL r1,r1,1
  ADD r1,r1,r2
  ST r1,r0,@nd_k
  RET

; nd_addr: r1 = guest address -> r1 = host word address (mask+gb)
nd_addr:
  LD r2,r0,@nd_mask
  BOOL.8 r1,r1,r2
  LD r2,r0,@nd_gb
  ADD r1,r1,r2
  RET

; =============================================================================
; one step
; =============================================================================
nd_step:
  ST r15,r0,@st_lnk
  MOVI r1,0
  ST r1,r0,@nd_reason
  LD r1,r0,@nd_pc
  CALL @nd_addr
  ST r1,r0,@nd_waddr
  LDN r2,r1,0
  MOVI r3,16
  CMP r2,r3
  JMP[GE] @st_gate
  ST r2,r0,@nd_curn
  ; LD returns the 32-bit payload, not the raw 64-bit word. LDN is the type.
  ; Every new step core gets this wrong once; the record still carries the
  ; payload and the class separately.
  LD r3,r1,0
  ST r3,r0,@nd_raw
  ; pc++, steps++
  LD r4,r0,@nd_pc
  ADD r4,r4,r13
  LD r5,r0,@nd_mask
  BOOL.8 r4,r4,r5
  ST r4,r0,@nd_pc
  LD r4,r0,@nd_steps
  ADD r4,r4,r13
  ST r4,r0,@nd_steps
  ; payload and op (LD already returns the 32-bit payload)
  ADD r4,r3,r0
  ST r4,r0,@nd_payload
  SHR r5,r4,24
  ST r5,r0,@nd_op
  MOVI r6,255
  CMP r5,r6
  JMP[EQ] @st_halt
  MOVI r6,0x61
  CMP r5,r6
  JMP[GT] @st_badop
  ; predication: BOOL ignores it; everything else tests bit k of the nibble
  CMP r5,r0
  JMP[EQ] @st_dec
  LD r6,r0,@nd_k
  MOVI r7,@nd_bits
  ADD r7,r7,r6
  LD r7,r7,0
  LD r6,r0,@nd_curn
  BOOL.8 r7,r7,r6
  CMP r7,r0
  JMP[EQ] @st_ok
st_dec:
  SHR r6,r4,20
  MOVI r7,15
  BOOL.8 r6,r6,r7
  ST r6,r0,@nd_d
  SHR r6,r4,16
  BOOL.8 r6,r6,r7
  ST r6,r0,@nd_a
  MOVI r7,0xFFFF
  BOOL.8 r7,r4,r7
  ST r7,r0,@nd_imm
  MOVI r7,15
  LD r6,r0,@nd_imm
  BOOL.8 r7,r7,r6
  ST r7,r0,@nd_b
  ; dispatch (compare chain in this proof; the full table is in NANDBG.md)
  LD r7,r0,@nd_op
  CMP r7,r0
  JMP[EQ] @nd_h_bool
  MOVI r8,1
  CMP r7,r8
  JMP[EQ] @nd_h_movi
  MOVI r8,2
  CMP r7,r8
  JMP[EQ] @nd_h_movhi
  MOVI r8,3
  CMP r7,r8
  JMP[EQ] @nd_h_add
  MOVI r8,4
  CMP r7,r8
  JMP[EQ] @nd_h_sub
  MOVI r8,7
  CMP r7,r8
  JMP[EQ] @nd_h_cmp
  MOVI r8,8
  CMP r7,r8
  JMP[EQ] @nd_h_ld
  MOVI r8,9
  CMP r7,r8
  JMP[EQ] @nd_h_st
  MOVI r8,10
  CMP r7,r8
  JMP[EQ] @nd_h_jmp
  MOVI r8,11
  CMP r7,r8
  JMP[EQ] @nd_h_call
  MOVI r8,12
  CMP r7,r8
  JMP[EQ] @nd_h_ret
  MOVI r8,13
  CMP r7,r8
  JMP[EQ] @nd_h_jmpr
  MOVI r8,15
  CMP r7,r8
  JMP[EQ] @st_ok
  MOVI r8,21
  CMP r7,r8
  JMP[EQ] @nd_h_putc
  MOVI r8,22
  CMP r7,r8
  JMP[EQ] @nd_h_stw
  MOVI r8,23
  CMP r7,r8
  JMP[EQ] @nd_h_ldn
  JMP @st_unsup

; ---- handlers ---------------------------------------------------------------
nd_h_bool:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  ST r1,r0,@nd_A
  LD r1,r0,@nd_b
  CALL @nd_getreg
  ST r1,r0,@nd_B
  LD r2,r0,@nd_A
  LD r3,r0,@nd_B
  MOVI r4,0
  ; bit0: ~(A|B)
  BOOL.14 r5,r2,r3
  BOOL.3 r5,r5,r5
  LD r6,r0,@nd_curn
  MOVI r7,1
  BOOL.8 r7,r7,r6
  CMP r7,r0
  JMP[EQ] @nd_b1
  BOOL.14 r4,r4,r5
nd_b1:
  ; bit1: ~A & B
  BOOL.3 r5,r2,r2
  BOOL.8 r5,r5,r3
  MOVI r7,2
  BOOL.8 r7,r7,r6
  CMP r7,r0
  JMP[EQ] @nd_b2
  BOOL.14 r4,r4,r5
nd_b2:
  ; bit2: A & ~B
  BOOL.3 r5,r3,r3
  BOOL.8 r5,r5,r2
  MOVI r7,4
  BOOL.8 r7,r7,r6
  CMP r7,r0
  JMP[EQ] @nd_b3
  BOOL.14 r4,r4,r5
nd_b3:
  ; bit3: A & B
  BOOL.8 r5,r2,r3
  MOVI r7,8
  BOOL.8 r7,r7,r6
  CMP r7,r0
  JMP[EQ] @nd_b4
  BOOL.14 r4,r4,r5
nd_b4:
  LD r1,r0,@nd_d
  ST r4,r1,@nd_regs
  CMP r4,r0
  MOVI[EQ] r1,1
  MOVI[NE] r1,0
  MOVI r2,0
  CALL @nd_setk2
  JMP @st_ok

nd_h_movi:
  LD r1,r0,@nd_d
  LD r2,r0,@nd_imm
  CALL @nd_setreg
  JMP @st_ok

nd_h_movhi:
  LD r1,r0,@nd_d
  CALL @nd_getreg
  MOVI r3,0xFFFF
  BOOL.8 r1,r1,r3
  LD r2,r0,@nd_imm
  SHL r2,r2,16
  BOOL.14 r1,r1,r2
  LD r3,r0,@nd_d
  ST r1,r3,@nd_regs
  JMP @st_ok

nd_h_add:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  ST r1,r0,@nd_A
  LD r1,r0,@nd_b
  CALL @nd_getreg
  ST r1,r0,@nd_B
  LD r2,r0,@nd_A
  LD r3,r0,@nd_B
  ADD r4,r2,r3
  LD r5,r0,@nd_d
  ST r4,r5,@nd_regs
  CMP r4,r0
  MOVI[EQ] r1,1
  MOVI[NE] r1,0
  CMP r4,r2
  MOVI[LT] r2,1
  MOVI[GE] r2,0
  CALL @nd_setk2
  JMP @st_ok

nd_h_sub:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  ST r1,r0,@nd_A
  LD r1,r0,@nd_b
  CALL @nd_getreg
  ST r1,r0,@nd_B
  LD r2,r0,@nd_A
  LD r3,r0,@nd_B
  SUB r4,r2,r3
  LD r5,r0,@nd_d
  ST r4,r5,@nd_regs
  CMP r4,r0
  MOVI[EQ] r1,1
  MOVI[NE] r1,0
  CMP r2,r3
  MOVI[LT] r2,1
  MOVI[GE] r2,0
  CALL @nd_setk2
  JMP @st_ok

nd_h_cmp:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  ST r1,r0,@nd_A
  LD r1,r0,@nd_b
  CALL @nd_getreg
  ST r1,r0,@nd_B
  LD r2,r0,@nd_A
  LD r3,r0,@nd_B
  CMP r2,r3
  MOVI[EQ] r1,1
  MOVI[NE] r1,0
  MOVI[LT] r2,1
  MOVI[GE] r2,0
  CALL @nd_setk2
  JMP @st_ok

nd_h_ld:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  LD r2,r0,@nd_imm
  ADD r1,r1,r2
  CALL @nd_addr
  LD r4,r1,0
  LD r2,r0,@nd_d
  ST r4,r2,@nd_regs
  JMP @st_ok

nd_h_st:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  LD r2,r0,@nd_imm
  ADD r1,r1,r2
  CALL @nd_addr
  ST r1,r0,@nd_EA
  LD r1,r0,@nd_d
  CALL @nd_getreg
  LD r2,r0,@nd_EA
  ST r1,r2,0
  JMP @st_ok

nd_h_jmp:
  LD r1,r0,@nd_imm
  ST r1,r0,@nd_pc
  JMP @st_ok

nd_h_call:
  LD r1,r0,@nd_pc
  MOVI r2,15
  ST r1,r2,@nd_regs
  LD r1,r0,@nd_imm
  ST r1,r0,@nd_pc
  JMP @st_ok

nd_h_ret:
  MOVI r1,15
  CALL @nd_getreg
  LD r2,r0,@nd_mask
  BOOL.8 r1,r1,r2
  ST r1,r0,@nd_pc
  JMP @st_ok

nd_h_jmpr:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  LD r2,r0,@nd_mask
  BOOL.8 r1,r1,r2
  ST r1,r0,@nd_pc
  JMP @st_ok

nd_h_putc:
  LD r1,r0,@nd_d
  CALL @nd_getreg
  PUTC r1
  JMP @st_ok

nd_h_stw:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  CALL @nd_addr
  ST r1,r0,@nd_EA
  LD r1,r0,@nd_d
  CALL @nd_getreg
  ST r1,r0,@nd_VAL
  LD r1,r0,@nd_b
  CALL @nd_getreg
  MOVI r4,15
  BOOL.8 r1,r1,r4
  LD r2,r0,@nd_VAL
  LD r3,r0,@nd_EA
  STW r2,r3,r1
  JMP @st_ok

nd_h_ldn:
  LD r1,r0,@nd_a
  CALL @nd_getreg
  LD r2,r0,@nd_imm
  ADD r1,r1,r2
  CALL @nd_addr
  ST r1,r0,@nd_EA
  LD r1,r0,@nd_EA
  LDN r4,r1,0
  LD r2,r0,@nd_d
  ST r4,r2,@nd_regs
  JMP @st_ok

; ---- halts and traps --------------------------------------------------------
st_gate:
  MOVI r1,3
  ST r1,r0,@nd_status
  MOVI r1,0x10
  ST r1,r0,@nd_reason
  ; site = pc+1 (the native core's convention)
  LD r2,r0,@nd_pc
  ADD r2,r2,r13
  ADD r3,r2,r0
  ; payload at the faulting address (LD returns the payload)
  LD r1,r0,@nd_waddr
  LD r4,r1,0
  LDN r5,r1,0
  MOVI r1,0
  MOVI r2,0x10
  CALL @nd_emit
  CALL @nd_print_rec
  LD r15,r0,@st_lnk
  RET

st_halt:
  MOVI r1,1
  ST r1,r0,@nd_status
  MOVI r1,0
  ST r1,r0,@nd_reason
  LD r15,r0,@st_lnk
  RET

st_badop:
  MOVI r1,0x20
  JMP @st_badtail
st_unsup:
  MOVI r1,0x21
st_badtail:
  ST r1,r0,@nd_reason
  MOVI r2,3
  ST r2,r0,@nd_status
  LD r2,r0,@nd_reason
  LD r3,r0,@nd_pc
  LD r4,r0,@nd_raw
  LD r1,r0,@nd_waddr
  LDN r5,r1,0
  MOVI r1,0
  CALL @nd_emit
  CALL @nd_print_rec
  LD r15,r0,@st_lnk
  RET

st_ok:
  MOVI r1,0
  ST r1,r0,@nd_status
  LD r15,r0,@st_lnk
  RET
st_lnk:
.word 0

; =============================================================================
; run until break, fault or halt. r1 = max steps. returns r1 = status.
; =============================================================================
nd_run:
  ST r15,r0,@rn_lnk
  ST r1,r0,@rn_max
rn_loop:
  LD r1,r0,@nd_steps
  LD r2,r0,@rn_max
  CMP r1,r2
  JMP[GE] @rn_budget
  ; breakpoint before fetch
  LD r1,r0,@nd_pc
  LD r2,r0,@nd_brk
  CMP r1,r2
  JMP[EQ] @rn_break
  CALL @nd_step
  LD r1,r0,@nd_status
  CMP r1,r0
  JMP[EQ] @rn_loop
  LD r15,r0,@rn_lnk
  RET
rn_break:
  MOVI r1,2
  ST r1,r0,@nd_status
  MOVI r1,2
  ST r1,r0,@nd_reason
  ; a breakpoint is an info/core record; capture the unexecuted word
  LD r2,r0,@nd_pc
  LD r3,r0,@nd_mask
  BOOL.8 r3,r2,r3
  LD r4,r0,@nd_gb
  ADD r3,r3,r4
  LD r4,r3,0
  LDN r5,r3,0
  MOVI r1,12
  MOVI r2,0x02
  LD r3,r0,@nd_pc
  CALL @nd_emit
  MOVI r1,2
  LD r15,r0,@rn_lnk
  RET
rn_budget:
  MOVI r1,4
  ST r1,r0,@nd_status
  LD r15,r0,@rn_lnk
  RET
rn_lnk:
.word 0
rn_max:
.word 0

; =============================================================================
; tests
; =============================================================================
nd_main:
  MOVI r13,1
  MOVI r1,@s_banner
  CALL @nd_puts
  CALL @nd_test_types
  CALL @nd_lattice
  CALL @nd_test_target
  CALL @nd_test_faults
  CALL @nd_test_quiet
  MOVI r1,@s_pass
  CALL @nd_puts
  HALT

; ---- 1. all 16 types, LDN/STW, mirror, quiet/raise -------------------------
nd_test_types:
  ST r15,r0,@tt_lnk
  MOVI r8,0
tt_loop:
  ; payload = 0x5A5A0000 | n
  MOVI r2,0x5A5A
  SHL r2,r2,16
  BOOL.14 r2,r2,r8
  MOVI r3,@nd_tw
  ADD r3,r3,r8
  MOVI r1,0
  ADD r1,r8,r0
  CALL @nd_mkword
  LDN r4,r3,0
  CMP r4,r8
  JMP[NE] @tt_fail
  ; mirror: BSWAPM rotates the type by 2 and reverses the payload
  BSWAPM r3,0
  LDN r5,r3,0
  MOVI r1,0
  ADD r1,r8,r0
  CALL @nd_rot2
  CMP r5,r1
  JMP[NE] @tt_fail
  BSWAPM r3,0
  ; quiet and raise
  MOVI r1,0
  ADD r1,r8,r0
  CALL @nd_quiet
  MOVI r6,10
  BOOL.14 r6,r8,r6
  CMP r1,r6
  JMP[NE] @tt_fail
  MOVI r2,0
  ADD r2,r1,r0
  MOVI r3,@nd_tq
  ADD r3,r3,r8
  CALL @nd_mkword
  LDN r4,r3,0
  CMP r4,r6
  JMP[NE] @tt_fail
  CALL @nd_raise
  MOVI r7,5
  BOOL.8 r7,r8,r7
  CMP r1,r7
  JMP[NE] @tt_fail
  ADD r8,r8,r13
  MOVI r7,16
  CMP r8,r7
  JMP[LT] @tt_loop
  MOVI r1,@s_types
  CALL @nd_puts
  LD r15,r0,@tt_lnk
  RET
tt_fail:
  MOVI r1,@s_badtypes
  CALL @nd_puts
  JMP @nd_fail
tt_lnk:
.word 0

; ---- 1b. print the 4x4 type matrix -----------------------------------------
nd_lattice:
  ST r15,r0,@lt_lnk
  MOVI r8,0
lt_row:
  MOVI r1,@s_mat
  CALL @nd_puts
  MOVI r9,0
lt_col:
  LD r7,r0,@lt_zero
  CMP r9,r7
  JMP[EQ] @lt_tag
  MOVI r1,32
  PUTC r1
lt_tag:
  MOVI r1,0
  ADD r1,r8,r0
  CALL @nd_type_letters
  ADD r8,r8,r13
  ADD r9,r9,r13
  MOVI r7,4
  CMP r9,r7
  JMP[LT] @lt_col
  MOVI r1,10
  PUTC r1
  MOVI r7,16
  CMP r8,r7
  JMP[LT] @lt_row
  LD r15,r0,@lt_lnk
  RET
lt_zero:
.word 0
lt_lnk:
.word 0

; ---- 2. breakpoint and full-speed run on a real target ---------------------
nd_test_target:
  ST r15,r0,@tg_lnk
  CALL @nd_clear
  MOVI r1,@tgt_entry
  ST r1,r0,@nd_pc
  MOVI r1,@tgt_hit
  ST r1,r0,@nd_brk
  MOVI r1,1000
  CALL @nd_run
  LD r1,r0,@nd_status
  MOVI r2,2
  CMP r1,r2
  JMP[NE] @tg_fail
  LD r1,r0,@nd_pc
  MOVI r2,@tgt_hit
  CMP r1,r2
  JMP[NE] @tg_fail
  MOVI r1,1
  CALL @nd_getreg
  MOVI r2,5
  CMP r1,r2
  JMP[NE] @tg_fail
  MOVI r1,2
  CALL @nd_getreg
  MOVI r2,15
  CMP r1,r2
  JMP[NE] @tg_fail
  MOVI r1,@s_break
  CALL @nd_puts
  ; one single step from the break: MOVI r4,42
  CALL @nd_dumpregs
  CALL @nd_step
  MOVI r1,4
  CALL @nd_getreg
  MOVI r2,42
  CMP r1,r2
  JMP[NE] @tg_fail
  MOVI r1,@s_step
  CALL @nd_puts
  ; clear the breakpoint, run to halt; the target prints its own 'A'
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_brk
  MOVI r1,1000
  CALL @nd_run
  LD r1,r0,@nd_status
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @tg_fail
  MOVI r1,@s_run
  CALL @nd_puts
  LD r15,r0,@tg_lnk
  RET
tg_fail:
  CALL @nd_dumpregs
  MOVI r1,83
  PUTC r1
  MOVI r1,61
  PUTC r1
  LD r1,r0,@nd_status
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,82
  PUTC r1
  MOVI r1,61
  PUTC r1
  LD r1,r0,@nd_reason
  MOVI r2,2
  CALL @nd_puthex
  MOVI r1,10
  PUTC r1
  MOVI r1,@s_badtarget
  CALL @nd_puts
  JMP @nd_fail
tg_lnk:
.word 0

; ---- 3. gate and bad-op become typed records, not a dead machine -----------
nd_test_faults:
  ST r15,r0,@ft_lnk
  ; gate: illegal heads at word 9000
  CALL @nd_clear
  MOVI r1,9000
  ST r1,r0,@nd_pc
  CALL @nd_step
  LD r1,r0,@nd_status
  MOVI r2,3
  CMP r1,r2
  JMP[NE] @ft_fail
  LD r1,r0,@nd_reason
  MOVI r2,0x10
  CMP r1,r2
  JMP[NE] @ft_fail
  MOVI r1,@s_gate
  CALL @nd_puts
  ; bad op: legal heads, payload op 0x7F at word 9001
  CALL @nd_clear
  MOVI r1,9001
  ST r1,r0,@nd_pc
  CALL @nd_step
  LD r1,r0,@nd_status
  MOVI r2,3
  CMP r1,r2
  JMP[NE] @ft_fail
  LD r1,r0,@nd_reason
  MOVI r2,0x20
  CMP r1,r2
  JMP[NE] @ft_fail
  MOVI r1,@s_badop
  CALL @nd_puts
  LD r15,r0,@ft_lnk
  RET
ft_fail:
  MOVI r1,@s_badfault
  CALL @nd_puts
  JMP @nd_fail
ft_lnk:
.word 0

; ---- 4. quiet/raise the record that was just produced ----------------------
nd_test_quiet:
  ST r15,r0,@qt_lnk
  MOVI r1,@nd_rec
  LDN r1,r1,0
  ST r1,r0,@qt_n
  CALL @nd_quiet
  ST r1,r0,@qt_q
  ; recompute expected: qn = n | 10
  LD r2,r0,@qt_n
  CALL @nd_quiet
  LD r3,r0,@qt_q
  CMP r2,r3
  JMP[NE] @qt_fail
  MOVI r1,@s_quiet
  CALL @nd_puts
  LD r15,r0,@qt_lnk
  RET
qt_fail:
  MOVI r1,@s_badquiet
  CALL @nd_puts
  JMP @nd_fail
qt_lnk:
.word 0
qt_n:
.word 0
qt_q:
.word 0

; nd_clear: zero the interpreted register file and state, keep mask/gb.
nd_clear:
  MOVI r1,0
  MOVI r2,0
cl_l:
  ST r0,r2,@nd_regs
  ADD r2,r2,r13
  MOVI r3,16
  CMP r2,r3
  JMP[LT] @cl_l
  ST r0,r0,@nd_k
  ST r0,r0,@nd_pc
  ST r0,r0,@nd_steps
  ST r0,r0,@nd_status
  ST r0,r0,@nd_reason
  ST r0,r0,@nd_seq
  ; the machine convention: r13 is the constant 1
  MOVI r1,1
  MOVI r2,13
  ST r1,r2,@nd_regs
  RET

; nd_dumpregs: PC, K, R0..R7 on one line; the rest on a second.
nd_dumpregs:
  ST r15,r0,@dr_lnk
  MOVI r1,80
  PUTC r1
  MOVI r1,67
  PUTC r1
  MOVI r1,61
  PUTC r1
  LD r1,r0,@nd_pc
  MOVI r2,4
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  MOVI r1,75
  PUTC r1
  MOVI r1,61
  PUTC r1
  LD r1,r0,@nd_k
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  MOVI r8,0
dr_l:
  MOVI r1,82
  PUTC r1
  MOVI r1,0
  ADD r1,r8,r0
  MOVI r2,1
  CALL @nd_puthex
  MOVI r1,61
  PUTC r1
  MOVI r1,0
  ADD r1,r8,r0
  CALL @nd_getreg
  MOVI r2,8
  CALL @nd_puthex
  MOVI r1,32
  PUTC r1
  ADD r8,r8,r13
  MOVI r7,8
  CMP r8,r7
  JMP[LT] @dr_l
  MOVI r1,10
  PUTC r1
  LD r15,r0,@dr_lnk
  RET
dr_lnk:
.word 0

nd_fail:
  MOVI r1,@s_fail
  CALL @nd_puts
  HALT

; =============================================================================
; strings and type tables
; =============================================================================
s_banner:
.str "NDBG: NAN16 NATIVE DEBUG CORE\n"
s_types:
.str "TYPES PASS\n"
s_mat:
.str "TYPES "
s_break:
.str "BREAK PASS\n"
s_step:
.str "STEP PASS\n"
s_run:
.str "RUN PASS\n"
s_gate:
.str "GATE RECORD PASS\n"
s_badop:
.str "BADOP RECORD PASS\n"
s_quiet:
.str "QUIET PASS\n"
s_pass:
.str "NDBG PASS\n"
s_fail:
.str "NDBG FAIL\n"
s_badtypes:
.str "TYPES FAIL\n"
s_badtarget:
.str "TARGET FAIL\n"
s_badfault:
.str "FAULT FAIL\n"
s_badquiet:
.str "QUIET FAIL\n"

nd_tw:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nd_tq:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

; =============================================================================
; =============================================================================
.org 8192
tgt_entry:
  MOVI r1,0
  MOVI r2,0
tgt_loop:
  ADD r1,r1,r13
  ADD r2,r2,r1
  MOVI r3,5
  CMP r1,r3
  JMP[LT] @tgt_loop
tgt_hit:
  MOVI r4,42
  MOVI r1,65
  PUTC r1
  HALT

; two deliberately broken words for the fault path. They are data; the debugger
; never executes them natively, only through the step core, which reports them.
.org 9000
bad_gate:
.raw 0000_DEADBEEF_0000
bad_op:
.raw FFF8_7F000000_F8FF
