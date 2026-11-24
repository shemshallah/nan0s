; ps.nas - NaN/0S guest process viewer (raw NaN16, ISA-neutral).
;
; Runs as a small NaN image or can be linked into the museum/shell image. It
; reads the live process table through the nanproc stat ABI and renders:
;   pid, ppid, state, threads, memory, CPU steps, priority.
; The kill/priority/spawn entries are the manager hooks for the future
; interactive shell. This deterministic demo uses them after the screen so the
; gate can verify the table changes. All logic is guest NaN code; no host C.
;
; Config: NP_BASE/NP_VARS must be set for nanproc (defined below). These are
; standalone-image test conveniences; a museum/shell link must choose them
; from free memory (MEMQ) so they do not overlap code, cartridges, stacks or
; heaps. The viewer itself is relocatable: only the table/vars addresses and
; stack are fixed by the caller.
.equ NP_BASE 0x10000
.equ NP_VARS 0x1F00
.equ V_HOOK 0x1F10
.equ V_T0 0x1F11
.equ V_T1 0x1F12
.equ V_T2 0x1F13
.equ V_T3 0x1F14
.equ V_T4 0x1F15
.equ PS_STAT 0x1F30
.equ STACK 0x7000
.equ HEAP0 0x30000
.equ HEAP1 0x31000
.equ HEAP2 0x33000
.equ HEAP3 0x34000
.equ IMAGE2 0x50000
.equ IMAGE3 0x60000
.equ STACK2 0x3A000
.equ IMAGE4 0x70000

main:
  MOVI r13,1
  MOVI r14,#STACK
  MOVI r1,@s_banner
  CALL @ps_puts
  CALL @np_init

; ---- pid 1: init/root, running, owns a heap ----
  MOVI r1,0
  MOVI r2,@s_init
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  MOVI r1,1
  MOVI r2,#NP_ST_RUNNING
  CALL @np_set_state
  MOVI r1,1
  LA r2,#HEAP0
  MOVI r3,1024
  CALL @np_heap_set
  MOVI r1,1
  MOVI r2,64
  CALL @np_heap_used_set
  MOVI r1,1
  MOVI r2,10
  CALL @np_add_steps
  MOVI r1,1
  MOVI r2,1
  CALL @np_thread_add

; ---- pid 2: shell child, ready, one thread, priority hook ----
  MOVI r1,1
  MOVI r2,@s_sh
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  MOVI r1,2
  LA r2,#HEAP1
  MOVI r3,512
  CALL @np_heap_set
  MOVI r1,2
  MOVI r2,200
  CALL @np_heap_used_set
  MOVI r1,2
  MOVI r2,101
  CALL @np_thread_add
  MOVI r1,2
  MOVI r2,42
  CALL @np_add_steps
  MOVI r1,2
  MOVI r2,3
  CALL @ps_priority
  ST r1,r0,#V_HOOK

; ---- pid 3: tcl child, image+heap+stack, two threads, blocked ----
  MOVI r1,1
  MOVI r2,@s_tcl
  LA r3,#IMAGE2
  MOVI r4,128
  CALL @np_spawn
  MOVI r1,3
  LA r2,#HEAP2
  MOVI r3,2048
  CALL @np_heap_set
  MOVI r1,3
  MOVI r2,700
  CALL @np_heap_used_set
  MOVI r1,3
  LA r2,#STACK2
  MOVI r3,64
  MOVI r4,#NP_K_STACK
  MOVI r5,#NP_PROT_RW
  CALL @np_region_add
  MOVI r1,3
  MOVI r2,201
  CALL @np_thread_add
  MOVI r1,3
  MOVI r2,202
  CALL @np_thread_add
  MOVI r1,3
  MOVI r2,5000
  CALL @np_add_steps
  MOVI r1,3
  MOVI r2,5
  CALL @np_set_priority
  MOVI r1,3
  MOVI r2,#NP_ST_RUNNING
  CALL @np_set_state
  MOVI r1,3
  MOVI r2,#NP_ST_BLOCKED
  CALL @np_set_state

; ---- pid 4: crashed child, zombie awaiting wait/reap ----
  MOVI r1,1
  MOVI r2,@s_crash
  LA r3,#IMAGE3
  MOVI r4,64
  CALL @np_spawn
  MOVI r1,4
  LA r2,#HEAP3
  MOVI r3,256
  CALL @np_heap_set
  MOVI r1,4
  MOVI r2,7
  CALL @np_add_steps
  MOVI r1,4
  MOVI r2,4
  CALL @np_thread_add
  MOVI r1,4
  MOVI r2,3
  CALL @np_exit

  CALL @ps_render

; ---- manager hooks -------------------------------------------------------
  MOVI r1,@s_hook_prio
  CALL @ps_puts
  MOVI r1,2
  CALL @np_lookup
  CALL @ps_nonzero
  LD r2,r1,#NP_E_PRIO
  ST r2,r0,#V_T0
  MOVI r1,2
  MOVI r1,@s_pid
  CALL @ps_puts
  MOVI r1,2
  CALL @ps_dec
  MOVI r1,@s_code
  CALL @ps_puts
  LD r1,r0,#V_HOOK
  CALL @ps_dec
  MOVI r1,@s_prio
  CALL @ps_puts
  LD r1,r0,#V_T0
  CALL @ps_dec
  CALL @ps_nl

  MOVI r1,2
  CALL @ps_kill
  ST r1,r0,#V_HOOK
  MOVI r1,2
  CALL @np_lookup
  CALL @ps_nonzero
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T0
  LD r2,r1,#NP_E_STATUS
  ST r2,r0,#V_T1
  MOVI r1,@s_hook_kill
  CALL @ps_puts
  MOVI r1,@s_pid
  CALL @ps_puts
  MOVI r1,2
  CALL @ps_dec
  MOVI r1,@s_code
  CALL @ps_puts
  LD r1,r0,#V_HOOK
  CALL @ps_dec
  MOVI r1,@s_state
  CALL @ps_puts
  LD r1,r0,#V_T0
  CALL @ps_dec
  MOVI r1,@s_status
  CALL @ps_puts
  LD r1,r0,#V_T1
  CALL @ps_dec
  CALL @ps_nl

  MOVI r1,1
  MOVI r2,@s_job
  LA r3,#IMAGE4
  MOVI r4,16
  CALL @ps_spawn
  ST r1,r0,#V_T0
  MOVI r1,@s_hook_spawn
  CALL @ps_puts
  MOVI r1,@s_pid
  CALL @ps_puts
  LD r1,r0,#V_T0
  CALL @ps_dec
  MOVI r1,@s_ppid
  CALL @ps_puts
  MOVI r1,1
  CALL @ps_dec
  MOVI r1,@s_image
  CALL @ps_puts
  LA r1,#IMAGE4
  CALL @ps_hex
  MOVI r1,@s_words
  CALL @ps_puts
  MOVI r1,16
  CALL @ps_dec
  CALL @ps_nl
  LD r1,r0,#V_T0
  MOVI r2,9
  CALL @np_exit
  LD r1,r0,#V_T0
  CALL @np_reap
  ST r2,r0,#V_T1
  MOVI r1,@s_hook_reap
  CALL @ps_puts
  MOVI r1,@s_pid
  CALL @ps_puts
  LD r1,r0,#V_T0
  CALL @ps_dec
  MOVI r1,@s_status
  CALL @ps_puts
  LD r1,r0,#V_T1
  CALL @ps_dec
  CALL @ps_nl
  MOVI r1,@s_ok
  CALL @ps_puts
  HALT

; ps_render: print the live process table. Uses the stat ABI, not the entry
; layout, so a kernel can move internals without breaking the viewer.
ps_render:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  MOVI r1,@s_head
  CALL @ps_puts
  MOVI r1,0
  ST r1,r0,@ps_slot
  LA r1,#NP_BASE
  ST r1,r0,@ps_ent
ps_row:
  LD r5,r0,@ps_slot
  MOVI r6,#NP_MAX_PROCS
  CMP r5,r6
  JMP[GE] @ps_table_done
  LD r6,r0,@ps_ent
  LD r7,r6,#NP_E_PID
  CMP r7,r0
  JMP[EQ] @ps_row_next
  ADD r1,r7,r0
  MOVI r2,#PS_STAT
  CALL @np_stat
  LD r1,r0,#PS_STAT+#NP_S_PID
  MOVI r2,4
  CALL @ps_paddec
  MOVI r1,32
  PUTC r1
  LD r1,r0,#PS_STAT+#NP_S_PPID
  MOVI r2,4
  CALL @ps_paddec
  MOVI r1,32
  PUTC r1
  LD r5,r0,#PS_STAT+#NP_S_STATE
  MOVI r6,@ps_state_tab
  ADD r6,r6,r5
  LD r1,r6,0
  CALL @ps_puts
  MOVI r1,32
  PUTC r1
  LD r1,r0,#PS_STAT+#NP_S_THREADS
  MOVI r2,3
  CALL @ps_paddec
  MOVI r1,32
  PUTC r1
  LD r1,r0,#PS_STAT+#NP_S_MEM_WORDS
  MOVI r2,6
  CALL @ps_paddec
  MOVI r1,32
  PUTC r1
  LD r1,r0,#PS_STAT+#NP_S_STEPS
  MOVI r2,7
  CALL @ps_paddec
  MOVI r1,32
  PUTC r1
  LD r1,r0,#PS_STAT+#NP_S_PRIO
  MOVI r2,4
  CALL @ps_paddec
  CALL @ps_nl
ps_row_next:
  LD r6,r0,@ps_ent
  MOVI r7,#NP_ENTRY
  ADD r6,r6,r7
  ST r6,r0,@ps_ent
  LD r5,r0,@ps_slot
  ADD r5,r5,r13
  ST r5,r0,@ps_slot
  JMP @ps_row
ps_table_done:
  CALL @np_counts
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  MOVI r1,@s_live
  CALL @ps_puts
  LD r1,r0,#V_T0
  CALL @ps_dec
  MOVI r1,@s_run
  CALL @ps_puts
  LD r1,r0,#V_T1
  CALL @ps_dec
  MOVI r1,@s_zomb
  CALL @ps_puts
  LD r1,r0,#V_T2
  CALL @ps_dec
  MOVI r1,@s_spawn
  CALL @ps_puts
  LD r1,r0,#V_T3
  CALL @ps_dec
  MOVI r1,@s_reap
  CALL @ps_puts
  LD r1,r0,#V_T4
  CALL @ps_dec
  CALL @ps_nl
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; Manager hooks (placeholders backed by real table operations):
; ps_kill(pid) sends SIGTERM (15); ps_priority(pid,prio) sets the hint;
; ps_spawn(ppid,path,image_base,image_words) uses the flat loader stub.
ps_kill:
  MOVI r2,15
  JMP @np_kill
ps_priority:
  JMP @np_set_priority
ps_spawn:
  JMP @np_spawn

; --- output helpers -------------------------------------------------------
ps_puts:
  MOVI r4,255
ppw:
  LD r2,r1,0
  MOVI r3,4
ppt:
  BOOL.8 r5,r2,r4
  CMP r5,r0
  RET[EQ]
  PUTC r5
  SHR r2,r2,8
  SUB r3,r3,r13
  JMP[NE] @ppt
  ADD r1,r1,r13
  JMP @ppw

ps_hex:
  MOVI r3,8
  MOVI r4,10
  MOVI r7,7
phx:
  SHR r2,r1,28
  SHL r1,r1,4
  MOVI r6,48
  ADD r6,r6,r2
  CMP r2,r4
  ADD[GE] r6,r6,r7
  PUTC r6
  SUB r3,r3,r13
  JMP[NE] @phx
  RET

ps_dec:
  MOVI r2,0
  JMP @ps_paddec

; ps_paddec r1=value r2=field width -> right-justified decimal.
ps_paddec:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r0,@ps_pd_val
  ST r2,r0,@ps_pd_w
  CMP r1,r0
  JMP[NE] @ps_pd_find
  LD r1,r0,@ps_pd_w
  MOVI r2,1
  CMP r1,r2
  JMP[LE] @ps_pd_zero
  SUB r1,r1,r2
ps_pd_zp:
  MOVI r2,32
  PUTC r2
  SUB r1,r1,r13
  CMP r1,r0
  JMP[GT] @ps_pd_zp
ps_pd_zero:
  MOVI r2,48
  PUTC r2
  JMP @ps_pd_out
ps_pd_find:
  MOVI r3,0
ps_pd_fl:
  MOVI r4,@ps_pw
  ADD r4,r4,r3
  LD r4,r4,0
  LD r1,r0,@ps_pd_val
  CMP r1,r4
  JMP[GE] @ps_pd_found
  ADD r3,r3,r13
  JMP @ps_pd_fl
ps_pd_found:
  ST r3,r0,@ps_pd_idx
  MOVI r5,10
  SUB r5,r5,r3
  LD r1,r0,@ps_pd_w
  CMP r1,r5
  JMP[LE] @ps_pd_digits
  SUB r1,r1,r5
ps_pd_pad:
  MOVI r2,32
  PUTC r2
  SUB r1,r1,r13
  CMP r1,r0
  JMP[GT] @ps_pd_pad
ps_pd_digits:
  LD r1,r0,@ps_pd_val
  LD r3,r0,@ps_pd_idx
ps_pd_dl:
  MOVI r4,@ps_pw
  ADD r4,r4,r3
  LD r4,r4,0
  MOVI r5,0
ps_pd_sub:
  CMP r1,r4
  JMP[LT] @ps_pd_dig
  SUB r1,r1,r4
  ADD r5,r5,r13
  JMP @ps_pd_sub
ps_pd_dig:
  MOVI r6,48
  ADD r5,r5,r6
  PUTC r5
  ADD r3,r3,r13
  MOVI r6,10
  CMP r3,r6
  JMP[LT] @ps_pd_dl
ps_pd_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

ps_nl:
  MOVI r1,10
  PUTC r1
  RET

; assertion helper for the demo setup: must not silently render a bad table
ps_nonzero:
  CMP r1,r0
  RET[NE]
  MOVI r1,@s_bad
  CALL @ps_puts
  HALT

; --- data ---------------------------------------------------------------
ps_slot:
.word 0
ps_ent:
.word 0
ps_pd_val:
.word 0
ps_pd_idx:
.word 0
ps_pd_w:
.word 0
ps_pw:
.word 1000000000
.word 100000000
.word 10000000
.word 1000000
.word 100000
.word 10000
.word 1000
.word 100
.word 10
.word 1

s_banner:
.str "NaN/0S PROCESS VIEWER\n"
s_head:
.str " PID PPID STATE  THR    MEM    CPU PRIO\n"
s_live:
.str "LIVE "
s_run:
.str "  RUN "
s_zomb:
.str "  ZOMBIE "
s_spawn:
.str "  SPAWN "
s_reap:
.str "  REAP "
s_init:
.str "init"
s_sh:
.str "sh"
s_tcl:
.str "tcl"
s_crash:
.str "crash"
s_job:
.str "job"
s_hook_prio:
.str "HOOK priority"
s_hook_kill:
.str "HOOK kill"
s_hook_spawn:
.str "HOOK spawn-stub"
s_hook_reap:
.str "HOOK reap"
s_pid:
.str " pid="
s_ppid:
.str " ppid="
s_code:
.str " code="
s_prio:
.str " prio="
s_state:
.str " state="
s_status:
.str " status="
s_image:
.str " image="
s_words:
.str " words="
s_ok:
.str "VIEWER OK\n"
s_bad:
.str "VIEWER BAD TABLE\n"

; state names are fixed 6-character fields, indexed by state value
ps_state_tab:
.word @ps_st_free
.word @ps_st_ready
.word @ps_st_run
.word @ps_st_block
.word @ps_st_zombie
.word @ps_st_dead
ps_st_free:
.str "FREE  "
ps_st_ready:
.str "READY "
ps_st_run:
.str "RUN   "
ps_st_block:
.str "BLOCK "
ps_st_zombie:
.str "ZOMBIE"
ps_st_dead:
.str "DEAD  "

.include "../lib/nanproc.nas"
