; nanthr_test - NaN kernel thread subsystem acceptance program.
; Pure NaN16.  Two threads interleave, a mutex gives exclusion across a
; forced yield inside the critical section, cond wait/signal wakes the right
; waiter, join returns the exit value, TLS is per-thread, a 1000-yield loop
; terminates, the preemption hook is exercised, and 60 create/join cycles
; prove TCB slots are reaped.  The same .nan image is the x86_64 S1 input.
;
; Layout: code/data below 0x2000, main stack 0x3000, TCB arena 0x4000
; (32 slots), thread stacks 0x8000+ (0x4000 words, 256 words per thread).
.org 0
JMP @main
.include "../lib/nanthr.nas"

.equ TV_ORDER   0x2000
.equ TV_ON      0x2010
.equ TV_MUTEX   0x2020
.equ TV_MCOUNT  0x2024
.equ TV_MTMP    0x2025
.equ TV_COND1   0x2030
.equ TV_COND2   0x2032
.equ TV_MUTEX2  0x2038
.equ TV_R1      0x203C
.equ TV_R2      0x203D
.equ TV_W1      0x203E
.equ TV_W2      0x203F
.equ TV_TLSKEY  0x2040
.equ TV_TLSA    0x2041
.equ TV_TLSB    0x2042
.equ TV_MAINTLS 0x2043
.equ TV_YCOUNT  0x2044
.equ TV_T1      0x2045
.equ TV_T2      0x2046
.equ TV_J1      0x2047
.equ TV_J2      0x2048
.equ TV_TICK    0x2049
.equ TV_REUSE   0x204A
.equ TV_RCODE   0x204B
.equ TV_PHASE   0x204C
.equ TV_IL1     0x204D
.equ TV_IL2     0x204E
.equ TV_CJ1     0x204F
.equ TV_CJ2     0x2050
.equ TV_CW2     0x2051
.equ TV_TLSJ1   0x2052
.equ TV_TLSJ2   0x2053
.equ TV_YJ      0x2054
.equ TV_RCODE2  0x2055
.equ TV_FRAMER  0x2056
.equ TV_DET1    0x2057
.equ TV_ATOM    0x2059
.equ TV_A1      0x205A
.equ TV_A2      0x205B
.equ TV_A3      0x205C
.equ TV_DET2    0x2058
.equ TV_FRAME   0x2100

main:
MOVI r13,1
MOVI r14,0x3000
; ---- kernel init: TCB arena, stack arena
MOVI r1,0x4000
MOVI r2,32
MOVI r3,0x8000
MOVI r4,0x4000
MOVI r5,256
CALL @nthr_init
CALL @nthr_mock_install

; ---- 1. two-thread interleave --------------------------------------
MOVI r1,1
ST r1,r0,#TV_PHASE
LA r1,@thr_il_a
MOVI r2,0
MOVI r3,65
CALL @nthr_create
ADD r10,r1,r0
LA r1,@thr_il_b
MOVI r2,0
MOVI r3,66
CALL @nthr_create
ADD r11,r1,r0
ADD r1,r10,r0
CALL @nthr_join
ST r1,r0,#TV_IL1
ADD r1,r11,r0
CALL @nthr_join
ST r1,r0,#TV_IL2

; ---- 2. mutex exclusion --------------------------------------------
MOVI r1,2
ST r1,r0,#TV_PHASE
MOVI r1,#TV_MUTEX
CALL @nthr_mutex_init
LA r1,@thr_mutex
MOVI r2,0
MOVI r3,0
CALL @nthr_create
ADD r10,r1,r0
LA r1,@thr_mutex
MOVI r2,0
MOVI r3,0
CALL @nthr_create
ADD r11,r1,r0
ADD r1,r10,r0
CALL @nthr_join
ADD r1,r11,r0
CALL @nthr_join

; ---- 3. cond wait/signal -------------------------------------------
MOVI r1,3
ST r1,r0,#TV_PHASE
MOVI r1,#TV_MUTEX2
CALL @nthr_mutex_init
MOVI r1,#TV_COND1
CALL @nthr_cond_init
MOVI r1,#TV_COND2
CALL @nthr_cond_init
LA r1,@thr_c1
MOVI r2,0
MOVI r3,1
CALL @nthr_create
ST r1,r0,#TV_T1
LA r1,@thr_c2
MOVI r2,0
MOVI r3,2
CALL @nthr_create
ST r1,r0,#TV_T2
; wait until both workers are parked in cond_wait
cond_poll:
LD r1,r0,#TV_R1
CMP r1,r0
JMP[EQ] @cond_poll_y
LD r1,r0,#TV_R2
CMP r1,r0
JMP[EQ] @cond_poll_y
JMP @cond_ready
cond_poll_y:
CALL @nthr_yield
JMP @cond_poll
cond_ready:
; signal C1 only; C2 must stay asleep
MOVI r1,#TV_MUTEX2
CALL @nthr_lock
MOVI r1,#TV_COND1
CALL @nthr_cond_signal
MOVI r1,#TV_MUTEX2
CALL @nthr_unlock
LD r1,r0,#TV_T1
CALL @nthr_join
ST r1,r0,#TV_CJ1
LD r1,r0,#TV_W2
ST r1,r0,#TV_CW2
; now signal C2
MOVI r1,#TV_MUTEX2
CALL @nthr_lock
MOVI r1,#TV_COND2
CALL @nthr_cond_signal
MOVI r1,#TV_MUTEX2
CALL @nthr_unlock
LD r1,r0,#TV_T2
CALL @nthr_join
ST r1,r0,#TV_CJ2
MOVI r1,0
ST r1,r0,#TV_FRAME

; ---- 4. TLS --------------------------------------------------------
MOVI r1,4
ST r1,r0,#TV_PHASE
CALL @nthr_tls_key_create
ST r1,r0,#TV_TLSKEY
LD r1,r0,#TV_TLSKEY
MOVI r2,999
CALL @nthr_tls_set
LA r1,@thr_tls
MOVI r2,0
MOVI r3,7
CALL @nthr_create
ADD r10,r1,r0
LA r1,@thr_tls
MOVI r2,0
MOVI r3,9
CALL @nthr_create
ADD r11,r1,r0
ADD r1,r10,r0
CALL @nthr_join
ST r1,r0,#TV_TLSJ1
ADD r1,r11,r0
CALL @nthr_join
ST r1,r0,#TV_TLSJ2
LD r1,r0,#TV_TLSKEY
CALL @nthr_tls_get
ST r1,r0,#TV_MAINTLS

; ---- 5. yield loop terminates --------------------------------------
MOVI r1,5
ST r1,r0,#TV_PHASE
LA r1,@thr_yieldloop
MOVI r2,0
MOVI r3,0
CALL @nthr_create
CALL @nthr_join
ST r1,r0,#TV_YJ

; ---- 6. preemption hook with no other runnable thread --------------
MOVI r10,8
tick_loop:
CALL @nthr_tick
SUB r10,r10,r13
CMP r10,r0
JMP[NE] @tick_loop
MOVI r1,#TV_FRAME
CALL @nthr_preempt
ST r1,r0,#TV_TICK

; ---- 7. repeated create/join reaps TCB slots -----------------------
MOVI r1,7
ST r1,r0,#TV_PHASE
MOVI r10,0
reuse_loop:
LA r1,@thr_ret5
MOVI r2,0
MOVI r3,0
CALL @nthr_create
CMP r1,r0
JMP[EQ] @fail
CALL @nthr_join
ST r1,r0,#TV_RCODE2
ADD r10,r10,r13
MOVI r11,60
CMP r10,r11
JMP[LT] @reuse_loop
ST r10,r0,#TV_REUSE

; ---- 8. atomics/fence primitives (mock is single-core exact)
MOVI r1,#TV_ATOM
MOVI r2,0
MOVI r3,1
CALL @nthr_atomic_cas
ST r1,r0,#TV_A1
MOVI r1,#TV_ATOM
MOVI r2,0
MOVI r3,2
CALL @nthr_atomic_cas
ST r1,r0,#TV_A2
MOVI r1,#TV_ATOM
MOVI r2,7
CALL @nthr_atomic_exch
MOVI r1,#TV_ATOM
CALL @nthr_atomic_load
ST r1,r0,#TV_A3
CALL @nthr_fence

; ---- 9. detach: join of a detached thread fails, slot still reaped
LA r1,@thr_ret5
MOVI r2,0
MOVI r3,0
CALL @nthr_create
ADD r10,r1,r0
ADD r1,r10,r0
CALL @nthr_detach
ST r1,r0,#TV_DET1
ADD r1,r10,r0
CALL @nthr_join
ST r1,r0,#TV_DET2
CALL @nthr_yield

; ---- 10. S1 trap-frame dispatch entry (svc 0 yield, no peer ready) --
MOVI r2,#TV_FRAME
MOVI r3,24
BFILL r2,r0,r3
ST r0,r2,20
ADD r1,r2,r0
CALL @nthr_syscall_dispatch
ST r1,r0,#TV_FRAMER

; ---- validate every observable before printing PASS ----------------
LD r1,r0,#TV_ON
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_IL1
MOVI r2,10
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_IL2
MOVI r2,20
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_MCOUNT
MOVI r2,100
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_CJ1
MOVI r2,31
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_CJ2
MOVI r2,32
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_CW2
CMP r1,r0
JMP[NE] @fail
LD r1,r0,#TV_W1
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_W2
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_TLSA
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_TLSB
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_MAINTLS
MOVI r2,999
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_TLSJ1
MOVI r2,41
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_TLSJ2
MOVI r2,42
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_YCOUNT
MOVI r2,1000
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_YJ
MOVI r2,77
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_TICK
CMP r1,r0
JMP[NE] @fail
LD r1,r0,#TV_REUSE
MOVI r2,60
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_RCODE2
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_FRAMER
CMP r1,r0
JMP[NE] @fail
LD r1,r0,#TV_DET1
CMP r1,r0
JMP[NE] @fail
LD r1,r0,#TV_DET2
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_A1
CMP r1,r0
JMP[NE] @fail
LD r1,r0,#TV_A2
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,#TV_A3
MOVI r2,7
CMP r1,r2
JMP[NE] @fail

; ---- report --------------------------------------------------------
LA r1,@s_il
CALL @puts
MOVI r10,0
LD r11,r0,#TV_ON
il_pr:
CMP r10,r11
JMP[GE] @il_pr_done
MOVI r2,#TV_ORDER
ADD r2,r2,r10
LD r1,r2,0
PUTC r1
ADD r10,r10,r13
JMP @il_pr
il_pr_done:
MOVI r1,10
PUTC r1

LA r1,@s_join
CALL @puts
LD r1,r0,#TV_IL1
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_IL2
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_mutex
CALL @puts
LD r1,r0,#TV_MCOUNT
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_cond
CALL @puts
LD r1,r0,#TV_CJ1
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_CJ2
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_CW2
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_W1
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_tls
CALL @puts
LD r1,r0,#TV_TLSA
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_TLSB
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_MAINTLS
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_TLSJ1
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_TLSJ2
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_yield
CALL @puts
LD r1,r0,#TV_YCOUNT
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_YJ
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_tick
CALL @puts
LD r1,r0,#TV_TICK
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_atom
CALL @puts
LD r1,r0,#TV_A1
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_A2
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_A3
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_detach
CALL @puts
LD r1,r0,#TV_DET1
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_DET2
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_frame
CALL @puts
LD r1,r0,#TV_FRAMER
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_reuse
CALL @puts
LD r1,r0,#TV_REUSE
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_RCODE2
CALL @pdec
MOVI r1,10
PUTC r1

LA r1,@s_pass
CALL @puts
HALT

fail:
LA r1,@s_fail
CALL @puts
LD r1,r0,#TV_PHASE
CALL @pdec
MOVI r1,32
PUTC r1
LD r1,r0,#TV_REUSE
CALL @pdec
MOVI r1,10
PUTC r1
HALT

; ---------------------------------------------------------------- threads
thr_il_a:
MOVI r1,65
JMP @thr_il
thr_il_b:
MOVI r1,66
thr_il:
ADD r10,r1,r0
MOVI r11,3
il_loop:
LD r3,r0,#TV_ON
MOVI r4,#TV_ORDER
ADD r4,r4,r3
ST r10,r4,0
ADD r3,r3,r13
ST r3,r0,#TV_ON
CALL @nthr_yield
SUB r11,r11,r13
CMP r11,r0
JMP[NE] @il_loop
MOVI r1,10
MOVI r2,66
CMP r10,r2
JMP[NE] @il_ret
MOVI r1,20
il_ret:
CALL @nthr_exit
HALT

thr_mutex:
MOVI r10,0
mt_loop:
MOVI r1,#TV_MUTEX
CALL @nthr_lock
LD r3,r0,#TV_MCOUNT
ST r3,r0,#TV_MTMP
CALL @nthr_yield
LD r3,r0,#TV_MTMP
ADD r3,r3,r13
ST r3,r0,#TV_MCOUNT
MOVI r1,#TV_MUTEX
CALL @nthr_unlock
CALL @nthr_yield
ADD r10,r10,r13
MOVI r11,50
CMP r10,r11
JMP[LT] @mt_loop
MOVI r1,0
CALL @nthr_exit
HALT

thr_c1:
MOVI r1,#TV_MUTEX2
CALL @nthr_lock
MOVI r2,1
ST r2,r0,#TV_R1
MOVI r1,#TV_COND1
MOVI r2,#TV_MUTEX2
CALL @nthr_cond_wait
MOVI r2,1
ST r2,r0,#TV_W1
MOVI r1,#TV_MUTEX2
CALL @nthr_unlock
MOVI r1,31
CALL @nthr_exit
HALT

thr_c2:
MOVI r1,#TV_MUTEX2
CALL @nthr_lock
MOVI r2,1
ST r2,r0,#TV_R2
MOVI r1,#TV_COND2
MOVI r2,#TV_MUTEX2
CALL @nthr_cond_wait
MOVI r2,1
ST r2,r0,#TV_W2
MOVI r1,#TV_MUTEX2
CALL @nthr_unlock
MOVI r1,32
CALL @nthr_exit
HALT

thr_tls:
ADD r10,r1,r0
LD r1,r0,#TV_TLSKEY
MOVI r2,100
MUL r2,r10,r2
ADD r2,r2,r13
ADD r11,r2,r0
CALL @nthr_tls_set
MOVI r12,4
tls_loop:
CALL @nthr_yield
SUB r12,r12,r13
CMP r12,r0
JMP[NE] @tls_loop
LD r1,r0,#TV_TLSKEY
CALL @nthr_tls_get
CMP r1,r11
JMP[NE] @tls_bad
MOVI r2,1
MOVI r3,7
CMP r10,r3
JMP[NE] @tls_b
ST r2,r0,#TV_TLSA
JMP @tls_exit
tls_b:
ST r2,r0,#TV_TLSB
tls_exit:
MOVI r1,41
MOVI r2,9
CMP r10,r2
JMP[NE] @tls_ret
MOVI r1,42
tls_ret:
CALL @nthr_exit
HALT
tls_bad:
MOVI r1,99
CALL @nthr_exit
HALT

thr_yieldloop:
MOVI r10,0
yl_loop:
CALL @nthr_yield
ADD r10,r10,r13
MOVI r11,1000
CMP r10,r11
JMP[LT] @yl_loop
ST r10,r0,#TV_YCOUNT
MOVI r1,77
CALL @nthr_exit
HALT

thr_ret5:
MOVI r1,5
CALL @nthr_exit
HALT

; ---------------------------------------------------------------- output
; r1 = word address of a NUL-terminated 4-chars/word string
puts:
MOVI r4,255
pw:
LD r2,r1,0
MOVI r3,4
pt1:
BOOL.8 r5,r2,r4
CMP r5,r0
RET[EQ]
PUTC r5
SHR r2,r2,8
SUB r3,r3,r13
JMP[NE] @pt1
ADD r1,r1,r13
JMP @pw

; r1 = value -> decimal, no leading zeros
pdec:
ST r15,r14,0
ADD r14,r14,r13
CMPS r1,r0
JMP[GE] @pd_pos
MOVI r5,45
PUTC r5
SUB r1,r0,r1
pd_pos:
LA r2,@pdec_buf
MOVI r3,10
MOVI r4,5
pd_loop:
MOD r5,r1,r3
ST r5,r2,0
DIV r1,r1,r3
ADD r2,r2,r13
SUB r4,r4,r13
CMP r4,r0
JMP[NE] @pd_loop
MOVI r6,1
pd_print:
SUB r2,r2,r13
LD r5,r2,0
CMP r6,r0
JMP[EQ] @pd_emit
CMP r5,r0
JMP[EQ] @pd_skip
pd_emit:
MOVI r6,0
ADDI r5,r5,48
PUTC r5
pd_skip:
LA r7,@pdec_buf
CMP r2,r7
JMP[NE] @pd_print
CMP r6,r0
JMP[EQ] @pd_done
MOVI r1,48
PUTC r1
pd_done:
SUB r14,r14,r13
LD r15,r14,0
RET

pdec_buf:
.word 0,0,0,0,0
s_il:
.str "IL "
s_join:
.str "JOIN "
s_mutex:
.str "MUTEX "
s_cond:
.str "COND "
s_tls:
.str "TLS "
s_yield:
.str "YIELD "
s_tick:
.str "TICK "
s_atom:
.str "ATOM "
s_detach:
.str "DETACH "
s_frame:
.str "FRAME "
s_reuse:
.str "REUSE "
s_pass:
.str "THREADS PASS\n"
s_fail:
.str "THREADS FAIL\n"
