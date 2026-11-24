; ndbg_cart_test.nas - run a real museum cartridge through the step core.
; The harness lives at word 512, the cart at 8192, the core at 40000.
; It installs JMP -> RET vectors at words 1..31 so the cart's V_* calls return
; harmlessly. Baby then runs its plaque loop and reaches KEY; the core returns
; WAIT_KEY instead of blocking, which is the pass condition.
.org 0
JMP @main

.org 512
main:
  MOVI r13,1
  ; vector word = JMP(stub_ret), class 15, for words 1..31
  MOVI r1,0x0A00
  SHL r1,r1,16
  MOVI r2,@stub_ret
  BOOL.14 r1,r1,r2
  MOVI r4,1
  MOVI r5,31
vt_loop:
  MOVI r3,15
  STW r1,r4,r3
  ADD r4,r4,r13
  CMP r4,r5
  JMP[LE] @vt_loop

  CALL @nd_reset
  MOVI r1,40000
  ST r1,r0,@nd_whi
  MOVI r1,8192
  ST r1,r0,@nd_pc
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_brk
  LA r1,1000000
  CALL @nd_run
  LD r2,r0,@nd_status
  MOVI r3,5
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,@s_ok
  CALL @nd_puts
  HALT
fail:
  MOVI r1,@s_bad
  CALL @nd_puts
  HALT

.org 600
stub_ret:
  RET

s_ok:
.str "CART PASS\n"
s_bad:
.str "CART FAIL\n"

.org 8192
.include "../exhibits/baby_cart.nas"

.org 40000
.include "../dbg/core.nas"
.include "../dbg/undo_stub.nas"
.include "../dbg/ndr_stub.nas"
