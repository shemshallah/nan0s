; nansched.nas - NaN/0S preemptive process scheduler (raw NaN16).
;
; This is the kernel scheduler for the existing nan0s kernel.  It owns the
; process SVCs delegated by src/lib/nankernel.nas through nk_install_proc:
;
;   SVC  0 yield              -> 0 (thread yield in thread mode)
;   SVC  1 exit(code)         -> does not return
;   SVC  2 region_map(words, prot) -> base word of a fresh bump region, or 0
;           prot 0/3 = RW, 5 = RX, 7 = RWX (used for loaded code)
;   SVC  9 spawn(descriptor)  -> pid or 0
;   SVC 10 wait(pid|0|-1)     -> exit status (blocks; pid 0/-1 = any child)
;   SVC 13 thread_create(entry, stack, arg) -> tid or 0
;   SVC 14 thread_join(tid)                 -> exit code or -1
;   SVC 15 thread_exit(code)                -> does not return
;   SVC 16 mutex(op, addr)                  -> 0/1/-1
;   SVC 17 cond(op, addr, mutex)            -> 0/-1
;   SVC 18 tls(index, value)                -> old/-1
;   SVC 19 thread_detach(tid)               -> 0/-1
;   SVC 20 getpid             -> pid
;   SVC 21 getppid            -> ppid
;   SVC 22 kill(pid, sig)     -> 0 / 1 bad pid / 2 already terminating
;   SVC 24 sleep(ticks)       -> 0 after the wake tick
;   SVC 25 setpriority(pid, prio) -> 0/1/2
;   SVC 26 getpriority(pid)       -> prio or -1
;   SVC 27 proc_count()           -> live processes
;   SVC 28 proc_limit()           -> NP_MAX_PROCS
;
; SVC 4..8 stay on nankernel's NPAF file service.  nsch_init installs a small
; kentry wrapper: it routes the appended process/thread calls above and sends
; every other trap (SVC 4..8, process SVCs, timer IRQ) to nankernel's kentry,
; which delegates 0/1/9/10/20..24 back to nsch_svc.  The same kernel therefore
; handles files and processes.
;
; ---------------------------------------------------------------------------
; ABI / configuration
;
; Required kernel configuration (later .equ wins; defaults are the test map):
;   NP_BASE    process table base (nanproc.nas), default 0x40000
;   NP_VARS    nanproc variable block, default 0x69000
;   NS_BASE    scheduler state block, default 0x58000
;
; NS_BASE must hold NS_BYTES words.  The layout below is fixed for
; NS_MAX_PROCS=1024 and NS_NPRIO=32:
;   +0    32 run-queue pairs {head,tail}; entries are slot+1, 0 = empty
;   +64   per-slot next link (slot+1)                    1024 words
;   +1088 per-slot wait pid (0 = any child)              1024 words
;   +2112 per-slot wait kind (0 none,1 sleep,2 wait)     1024 words
;   +3136 per-slot wake tick                             1024 words
;   +4160 current pid
;   +4161 tick counter (timer IRQs)
;   +4162 current slice
;   +4163 quantum in ticks
;   +4164 next slot (scratch)
;   +4165 active trap-frame pointer
;   +4166 started flag
;   +4167 timer-IRQ preemption count
;   +4168 kernel scratch words 0..7
;   +4176 thread-owner pid (0 = no process in thread mode)
;   +4177 thread-owner slot (NS_NONE = none)
;   +4178 blocked sleeper count (fast tick path)
;   +4179 earliest sleeper wake tick (0 when none)
;   +4192 per-slot 24-word trap frames                    1024*24 words
;   +28768 per-slot region tables (8 entries + terminator) 1024*36 words
;   +65632 boot region table (3 entries)                   16 words
;   NS_BYTES = 65648
;
; NP_MAX_PROCS may be lowered.  It must not exceed NS_MAX_PROCS (1024);
; the nanproc table span is NP_MAX_PROCS*96 words.
;
; Thread mode uses nanthr.nas (included below) for one owning process at a
; time.  TCBs live at NS_TCB_BASE (64 TCBs, 56 words each).  All threads of
; the owner share its pid and S1 region table; thread switches are
; cooperative through SVC 0/13..19, and process-level timer preemption still
; saves/restores the current TCB frame.  A second process may take thread
; mode only after the first exits (documented gap; no per-process nanthr
; state duplication).  Thread stacks are caller-provided and must already be
; mapped in the owner's region table; the nanthr arena at NS_TSTACK_BASE is
; configured but not auto-mapped in this cooperative slice.
;
; Process state is the nanproc state word (0 free, 1 ready, 2 running,
; 3 blocked, 4 zombie, 5 dead).  The scheduler keeps nanproc authoritative:
; run-queue membership is only a scheduling hint and every pick rechecks the
; state.  Priorities are 0..NS_NPRIO-1, lower number = higher priority.
;
; Trap frame: exactly the frozen 24-word S1 frame from spec/KERNEL_ABI.md:
; [0..15] r0..r15, [16] pc, [17] flags, [18] addr high, [19] cause,
; [20] syscall, [21] status/return, [22] sp, [23] reserved.  A switch copies
; the live frame from the port-configured kframe into NS_FRAMES[slot] and
; copies the next process's frame back.  Region tables are copied to the S1
; {base,nwords,kind,prot} shape per process and published on port 0x4E04.
;
; Spawn descriptor (word addresses; all regions are {base,nwords,kind,prot}):
;   +0 entry pc        +1 initial sp       +2 priority 0..31
;   +3 name/id         +4 region count 0..8
;   +5 first region, then count*4 words
; The image is not sealed: this module is the flat-image kernel scheduler
; (spec/PROCESS.md section 3.2).  A sealed loader belongs above SVC 9.
;
; Kernel entry contract: nsch_svc(r1=frame) is called with in_kernel=1 and
; owns the final SVCRET.  It never returns through its NaN caller.  Timer
; IRQs arrive with cause=1; SVCs with cause=0.  Faults are a kernel bug and
; halt with "!S".
;
; ABI conventions: r0=0, r13=1, r14=kernel stack, r15=link.  Public calls
; preserve r13/r14; internal routines use a uniform 9-word frame:
; [SP] link, [SP+1..8] locals, new SP = old SP+9.  Callees therefore start
; their own frame at that SP and cannot overlap a caller's eight locals.
; NP_MAX_PROCS may be lowered; it must not exceed NS_MAX_PROCS (1024).
; ---------------------------------------------------------------------------

.equ NP_BASE      0x40000
.equ NP_VARS      0x69000
.equ NS_BASE      0x58000
; Runtime base pointers.  nsch_config writes these; zero means "use the
; compile-time default" so every existing test image still works.
.equ NS_PTR       0x3F010
.equ NSH_MEMWORDS 0x3F013

.include "nanproc.nas"
.include "nanthr.nas"

; Bump heap for SVC 2.  The kernel boot builds the list from the PMEM map
; (src/lib/memmap.nas); tests that do not call SVC 2 can leave it empty.
; The words live above the GUI cart code and below the default nanproc table.
; NSH_NEXT is the next free word and NSH_RIDX the range containing it.  Each
; range is {base,end} in words, exclusive end, ascending, and never overlaps
; a reserved/ACPI/device hole.  A failed allocation leaves both words intact,
; so SVC 2 can roll back a failed region-table append without guessing.
.equ NSH_NEXT 0x3F000
.equ NSH_END  0x3F001
.equ NSH_NR   0x3F002
.equ NSH_RIDX 0x3F003
.equ NSH_RANGES 0x3F040
.equ NSH_MAX_RANGES 64

.equ NS_MAX_PROCS  1024
.equ NS_NPRIO      32
.equ NS_FRAME      9
.equ NS_FRAME_NEG  -9
.equ NS_QUANTUM_DEFAULT 4
.equ NS_TICK_INTERVAL   16

; S1 control ports (spec/KERNEL_ABI.md section 2).
.equ NS_P_ENTRY    0x4E00
.equ NS_P_FRAME    0x4E01
.equ NS_P_TIMER    0x4E02
.equ NS_P_KSTACK   0x4E03
.equ NS_P_REGIONS  0x4E04
.equ NS_P_LDS      0x4E07

; Kernel-stack/frame words.  These match src/lib/nankernel.nas; the frame
; port is the single frame the S1 saves on every trap.
.equ NS_KFRAME     0x2F1000
.equ NS_KSTACK     0x2F0000
.equ NS_KMEMM      0x4000

; Scheduler state offsets from NS_BASE.
.equ NS_QUEUE      0
.equ NS_LINK       64
.equ NS_WAITPID    1088
.equ NS_WAITK      2112
.equ NS_WAKE       3136
.equ NS_CUR        4160
.equ NS_TICKS      4161
.equ NS_SLICE      4162
.equ NS_QUANTUM    4163
.equ NS_NEXT       4164
.equ NS_FP         4165
.equ NS_STARTED    4166
.equ NS_PREEMPT    4167
.equ NS_TMP0       4168
.equ NS_TMP1       4169
.equ NS_TMP2       4170
.equ NS_TMP3       4171
.equ NS_TMP4       4172
.equ NS_TMP5       4173
.equ NS_TMP6       4174
.equ NS_TMP7       4175
.equ NS_THRPID     4176
.equ NS_THRSLOT    4177
.equ NS_NSLEEP     4178
.equ NS_SMIN       4179
.equ NS_FRAMES     4192
.equ NS_REGT       28768
.equ NS_BOOTTAB    65632
.equ NS_BYTES      65648

; Thread arena (nanthr.nas TCBs and kernel-allocated thread stacks).
.equ NS_TCB_BASE     0xA0000
.equ NS_TCB_COUNT    64
.equ NS_TSTACK_BASE  0xA4000
.equ NS_TSTACK_WORDS 0x4000
.equ NS_TSTACK_SIZE  0x100

; Wait kinds.
.equ NS_WK_NONE    0
.equ NS_WK_SLEEP   1
.equ NS_WK_WAIT    2

; Sentinel for "no slot"/"no thread owner" (slot values are 0..1023).
.equ NS_NONE       0xFFFF

; Boot region table spans.  Guest memory must be at least 0xA0000 words.
; Entry 1 covers the nankernel stack/frame/hook block.
.equ NS_BOOTMEM    0xA0000

; ---------------------------------------------------------------------------
; Public integration ABI for the existing nan0s kernel/boot:
;   ns_init            initialise nanproc + scheduler, program S1 ports
;   ns_svc(frame)      SVC/timer entry, owns SVCRET
;   ns_start(pid|0)    enter the first process, owns SVCRET
;   ns_heap_init       r1=heap base r2=heap end: reset + one usable range
;   ns_heap_reset      empty the usable-range list (no allocation possible)
;   ns_heap_add_range  r1=base r2=end (exclusive), append an ascending range
;   ns_heap_alloc      r1=words -> r1=base or 0; never crosses a range hole
;   ns_heap_free       -> r1=words available from NSH_NEXT to every range end
ns_init:
  JMP @nsch_init
ns_svc:
  JMP @nsch_svc
ns_start:
  JMP @nsch_start
ns_heap_init:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @ns_heap_reset
  LD r1,r14,1
  LD r2,r14,2
  CALL @ns_heap_add_range
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET
ns_heap_reset:
  LA r3,#NSH_NEXT
  ST r0,r3,0
  LA r3,#NSH_END
  ST r0,r3,0
  LA r3,#NSH_NR
  ST r0,r3,0
  LA r3,#NSH_RIDX
  ST r0,r3,0
  RET
; ns_heap_add_range r1=base r2=end (exclusive).  Callers add ranges in
; ascending address order; the boot does so from the PMEM map.  A range that
; ends at/below its base is ignored.  Returns r1=1 stored, 0 list full/bad.
ns_heap_add_range:
  CMP r2,r1
  JMP[LE] @ns_har_bad
  LA r3,#NSH_NR
  LD r4,r3,0
  LA r5,#NSH_MAX_RANGES
  CMP r4,r5
  JMP[GE] @ns_har_bad
  LA r5,#NSH_RANGES
  SHL r6,r4,1
  ADD r6,r6,r5
  ST r1,r6,0
  ST r2,r6,1
  ADD r4,r4,r13
  ST r4,r3,0
  CMP r4,r13
  JMP[NE] @ns_har_ok
  LA r3,#NSH_NEXT
  ST r1,r3,0
  LA r3,#NSH_END
  ST r2,r3,0
ns_har_ok:
  MOVI r1,1
  RET
ns_har_bad:
  MOVI r1,0
  RET
; ns_heap_alloc r1=words -> r1=base or 0.  It tries the current range first,
; then advances to each later range; an allocation larger than the remainder
; of a range is placed at the start of the next range, never across the hole.
; The state words are only written on success.
ns_heap_alloc:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1                 ; words
  LA r3,#NSH_NR
  LD r4,r3,0                  ; count
  ST r4,r14,2
  LA r3,#NSH_RIDX
  LD r5,r3,0                  ; index
  ST r5,r14,3
  LA r3,#NSH_NEXT
  LD r6,r3,0                  ; next
  ST r6,r14,4
  CMP r4,r0
  JMP[EQ] @ns_ha_fail
  LD r7,r14,1
  CMP r7,r0
  JMP[EQ] @ns_ha_fail
ns_ha_loop:
  LD r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @ns_ha_fail
  LA r3,#NSH_RANGES
  SHL r8,r5,1
  ADD r8,r8,r3
  LD r9,r8,0                  ; range base
  LD r10,r8,1                 ; range end
  LD r6,r14,4
  CMP r6,r9
  JMP[GE] @ns_ha_at_base
  ADD r6,r9,r0                ; below this range: start at its base
  ST r6,r14,4
ns_ha_at_base:
  CMP r6,r10
  JMP[GE] @ns_ha_next         ; current pointer already past this range
  SUB r11,r10,r6
  LD r7,r14,1
  CMP r7,r11
  JMP[GT] @ns_ha_next         ; does not fit: skip the hole, try next range
  ADD r7,r6,r7                ; new next
  LA r3,#NSH_NEXT
  ST r7,r3,0
  LA r3,#NSH_RIDX
  ST r5,r3,0
  ADD r1,r6,r0
  JMP @ns_ha_out
ns_ha_next:
  ADD r5,r5,r13
  ST r5,r14,3
  LD r7,r14,1
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @ns_ha_fail
  LA r3,#NSH_RANGES
  SHL r8,r5,1
  ADD r8,r8,r3
  LD r6,r8,0
  ST r6,r14,4
  JMP @ns_ha_loop
ns_ha_fail:
  MOVI r1,0
ns_ha_out:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET
; ns_heap_free -> r1 = words available from NSH_NEXT through every range end.
ns_heap_free:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  MOVI r1,0
  ST r1,r14,1                 ; total
  LA r3,#NSH_NR
  LD r4,r3,0
  ST r4,r14,2                 ; count
  LA r3,#NSH_RIDX
  LD r5,r3,0
  ST r5,r14,3                 ; index
  LA r3,#NSH_NEXT
  LD r6,r3,0
  ST r6,r14,4                 ; next
  CMP r4,r0
  JMP[EQ] @ns_hf_done
ns_hf_loop:
  LD r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @ns_hf_done
  LA r3,#NSH_RANGES
  SHL r8,r5,1
  ADD r8,r8,r3
  LD r9,r8,0
  LD r10,r8,1
  LD r6,r14,4
  CMP r6,r9
  JMP[GE] @ns_hf_at_base
  ADD r6,r9,r0
ns_hf_at_base:
  CMP r6,r10
  JMP[GE] @ns_hf_next
  SUB r11,r10,r6
  LD r1,r14,1
  ADD r1,r1,r11
  ST r1,r14,1
ns_hf_next:
  ADD r5,r5,r13
  ST r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @ns_hf_done
  LA r3,#NSH_RANGES
  SHL r8,r5,1
  ADD r8,r8,r3
  LD r6,r8,0
  ST r6,r14,4
  JMP @ns_hf_loop
ns_hf_done:
  LD r1,r14,1
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET
ns_config:
  LA r5,#NS_PTR
  ST r1,r5,0
  LA r5,#NP_PTR
  ST r2,r5,0
  LA r5,#NPV_PTR
  ST r3,r5,0
  LA r5,#NSH_MEMWORDS
  ST r4,r5,0
  RET

; ---------------------------------------------------------------------------
; nsch_init - initialise nanproc and the scheduler, then activate the S1 ABI.
; No arguments.  Sets kframe/kstack/timer/regions and writes kentry last so
; the ABI becomes live only after the boot region table is in place.
nsch_init:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  LA r1,#NS_PTR
  LD r1,r1,0
  CMP r1,r0
  JMP[NE] @nsch_ptr_ok
  LA r1,#NS_BASE
  LA r2,#NS_PTR
  ST r1,r2,0
  LA r1,#NP_BASE
  LA r2,#NP_PTR
  ST r1,r2,0
  LA r1,#NP_VARS
  LA r2,#NPV_PTR
  ST r1,r2,0
nsch_ptr_ok:
  CALL @np_init

  ; zero the scheduler block
  LA r3,#NS_PTR
  LD r3,r3,0
  LA r4,#NS_BYTES
nsch_init_z:
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r4,r4,r13
  CMP r4,r0
  JMP[NE] @nsch_init_z

  ; quantum and initial slice
  LA r2,#NS_PTR
  LD r2,r2,0
  MOVI r1,#NS_QUANTUM_DEFAULT
  ST r1,r2,#NS_QUANTUM
  ST r1,r2,#NS_SLICE
  MOVI r1,#NS_NONE
  ST r1,r2,#NS_THRSLOT

  ; boot region table: whole low image/tables/stacks (RWX), then the
  ; nankernel stack/frame/hook block (RWX).  Terminator is the zero word
  ; written by the clear loop.
  LA r3,#NS_PTR
  LD r3,r3,0
  LA r1,#NS_BOOTTAB
  ADD r3,r3,r1
  ST r0,r3,0
  LA r1,#NSH_MEMWORDS
  LD r1,r1,0
  CMP r1,r0
  JMP[NE] @nsch_bootmem
  LA r1,#NS_BOOTMEM
nsch_bootmem:
  ST r1,r3,1
  ST r0,r3,2
  MOVI r1,7
  ST r1,r3,3
  LA r1,#NS_KSTACK
  ST r1,r3,4
  MOVI r1,#NS_KMEMM
  ST r1,r3,5
  ST r0,r3,6
  MOVI r1,7
  ST r1,r3,7

  ; kframe
  MOVI r1,#NS_P_FRAME
  LA r2,#NS_KFRAME
  OUTL r2,r1
  ; kernel stack
  MOVI r1,#NS_P_KSTACK
  LA r2,#NS_KSTACK
  OUTL r2,r1
  ; timer interval (instruction count; S1 reloads it on every IRQ)
  MOVI r1,#NS_P_TIMER
  MOVI r2,#NS_TICK_INTERVAL
  OUTL r2,r1
  ; boot region table
  MOVI r1,#NS_P_REGIONS
  LA r2,#NS_PTR
  LD r2,r2,0
  LA r3,#NS_BOOTTAB
  ADD r2,r2,r3
  OUTL r2,r1
  ; activate the ABI last
  MOVI r1,#NS_P_ENTRY
  LA r2,@nsch_kentry
  OUTL r2,r1

  MOVI r1,0
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_kentry - S1 kernel entry installed by nsch_init.  Appended
; process/thread SVCs are handled here; every other SVC (4..8 and the
; nankernel-delegated process numbers), timer IRQ and inherited path goes to
; nankernel's kentry.
nsch_kentry:
  MOVI r13,1
  MOVI r1,#NS_P_FRAME
  INL r10,r1
  LD r3,r10,19
  CMP r3,r0
  JMP[EQ] @nsch_ke_svc
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @nsch_ke_fwd
  ; Fault while the scheduler owns the trap is a kernel bug.
  MOVI r1,33
  PUTC r1
  MOVI r1,83
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT
nsch_ke_svc:
  LD r3,r10,20
  ; SVC 0 is a thread yield while the current process owns thread mode.
  CMP r3,r0
  JMP[NE] @nsch_ke_13
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r4,r2,#NS_THRPID
  CMP r4,r0
  JMP[EQ] @nsch_ke_fwd
  LD r5,r2,#NS_CUR
  CMP r4,r5
  JMP[NE] @nsch_ke_fwd
  JMP @nsch_ke_thread
nsch_ke_13:
  MOVI r4,2
  CMP r3,r4
  JMP[EQ] @nsch_ke_new
  MOVI r4,13
  CMP r3,r4
  JMP[LT] @nsch_ke_25
  MOVI r4,19
  CMP r3,r4
  JMP[LE] @nsch_ke_thread
nsch_ke_25:
  MOVI r4,25
  CMP r3,r4
  JMP[LT] @nsch_ke_fwd
  MOVI r4,28
  CMP r3,r4
  JMP[LE] @nsch_ke_new
nsch_ke_fwd:
  JMP @kentry
nsch_ke_new:
  ADD r1,r10,r0
  JMP @nsch_svc
nsch_ke_thread:
  ADD r1,r10,r0
  JMP @nsch_thread_svc

; ---------------------------------------------------------------------------
; nsch_svc - kernel SVC/timer entry.  r1 = 24-word trap frame pointer.
; Owns SVCRET; never returns to the caller.
nsch_svc:
  ADD r10,r1,r0
  LA r2,#NS_PTR
  LD r2,r2,0
  ST r10,r2,#NS_FP
  LD r3,r10,19
  CMP r3,r0
  JMP[EQ] @nsch_svc_call
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @nsch_svc_irq
  ; A fault while the scheduler owns the trap is a kernel bug.
  MOVI r1,33
  PUTC r1
  MOVI r1,83
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT

nsch_svc_call:
  LD r3,r10,20
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r4,r2,#NS_CUR
  CMP r4,r0
  JMP[NE] @nsch_dispatch
  ; No process yet: the boot context starts the highest-priority ready one.
  CMP r3,r0
  JMP[NE] @nsch_svc_bad
  MOVI r1,0
  CALL @nsch_start
  JMP @nsch_svc_bad

nsch_dispatch:
  CMP r3,r0
  JMP[EQ] @nsch_svc_yield
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @nsch_svc_exit
  MOVI r4,2
  CMP r3,r4
  JMP[EQ] @nsch_svc_region
  MOVI r4,9
  CMP r3,r4
  JMP[EQ] @nsch_svc_spawn
  MOVI r4,10
  CMP r3,r4
  JMP[EQ] @nsch_svc_wait
  MOVI r4,20
  CMP r3,r4
  JMP[EQ] @nsch_svc_getpid
  MOVI r4,21
  CMP r3,r4
  JMP[EQ] @nsch_svc_getppid
  MOVI r4,22
  CMP r3,r4
  JMP[EQ] @nsch_svc_kill
  MOVI r4,23
  CMP r3,r4
  JMP[EQ] @nsch_svc_bad
  MOVI r4,24
  CMP r3,r4
  JMP[EQ] @nsch_svc_sleep
  MOVI r4,25
  CMP r3,r4
  JMP[EQ] @nsch_svc_setprio
  MOVI r4,26
  CMP r3,r4
  JMP[EQ] @nsch_svc_getprio
  MOVI r4,27
  CMP r3,r4
  JMP[EQ] @nsch_svc_count
  MOVI r4,28
  CMP r3,r4
  JMP[EQ] @nsch_svc_limit
nsch_svc_bad:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r2,r2,#NS_FP
  LA r1,0xFFFFFFFF
  ST r1,r2,21
  SVCRET

; ---------------------------------------------------------------------------
; SVC 0 - yield: current -> ready tail, pick the highest ready.
nsch_svc_yield:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r0,r10,21
  LD r1,r2,#NS_CUR
  MOVI r2,#NP_ST_READY
  CALL @np_set_state
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  CALL @nsch_slot
  CALL @nsch_enqueue
  JMP @nsch_sched_save_switch

; ---------------------------------------------------------------------------
; SVC 1 - exit(code).
nsch_svc_exit:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r1,r10,1              ; status
  ST r1,r2,#NS_TMP0
  ; np_exit(current, status)
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  LD r2,r2,#NS_TMP0
  CALL @np_exit
  ; drop thread mode if the owner is exiting (all joins must be done first)
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  LD r3,r2,#NS_THRPID
  CMP r1,r3
  JMP[NE] @nsch_exit_nothr
  ST r0,r2,#NS_THRPID
  MOVI r3,#NS_NONE
  ST r3,r2,#NS_THRSLOT
nsch_exit_nothr:
  ; wake parent waiters, then reap the zombie when a parent consumed it
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  LD r2,r2,#NS_TMP0
  CALL @nsch_wake_waiters
  ; an orphan/dead process has no later waiter: reap it now
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_sched_save_switch
  LD r3,r1,#NP_E_STATE
  MOVI r4,#NP_ST_DEAD
  CMP r3,r4
  JMP[NE] @nsch_sched_save_switch
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  CALL @np_reap
  JMP @nsch_sched_save_switch

; ---------------------------------------------------------------------------
; SVC 2 - region_map(words): carve a RW region from the boot-time bump heap,
; append it to the current process's nanproc/S1 region table, return its base.
nsch_svc_region:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r3,r10,1
  ST r3,r14,1
  LA r4,#NSH_NEXT
  LD r4,r4,0
  ST r4,r14,7
  LA r4,#NSH_RIDX
  LD r4,r4,0
  ST r4,r14,8
  CMP r3,r0
  JMP[EQ] @nsch_region_fail
  LD r7,r10,2
  CMP r7,r0
  JMP[EQ] @nsch_region_rw
  MOVI r4,7
  CMP r7,r4
  JMP[LE] @nsch_region_prot
nsch_region_rw:
  MOVI r7,#NP_PROT_RW
nsch_region_prot:
  ST r7,r14,6
  ; The bump heap walks the PMEM usable ranges.  ns_heap_alloc only commits
  ; NSH_NEXT/NSH_RIDX on success, so a failed region-table append restores
  ; the pre-call tuple exactly.
  LD r1,r14,1
  CALL @ns_heap_alloc
  CMP r1,r0
  JMP[EQ] @nsch_region_fail
  ST r1,r14,2
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  ST r1,r14,3
  CALL @nsch_slot
  ST r1,r14,4
  LD r1,r14,3
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_region_fail
  LD r3,r1,#NP_E_NREG
  MOVI r4,8
  CMP r3,r4
  JMP[GE] @nsch_region_fail
  ST r3,r14,5
  LD r1,r14,3
  LD r2,r14,2
  LD r3,r14,1
  MOVI r4,#NP_K_HEAP
  LD r5,r14,6
  CALL @np_region_add
  CMP r1,r0
  JMP[NE] @nsch_region_fail
  LD r1,r14,4
  CALL @nsch_rt_ptr
  LD r3,r14,5
  SHL r3,r3,2
  ADD r2,r1,r3
  LD r3,r14,2
  ST r3,r2,0
  LD r3,r14,1
  ST r3,r2,1
  MOVI r3,#NP_K_HEAP
  ST r3,r2,2
  LD r3,r14,6
  ST r3,r2,3
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r1,r14,2
  ST r1,r10,21
  JMP @nsch_region_out
nsch_region_fail:
  LD r1,r14,7
  LA r2,#NSH_NEXT
  ST r1,r2,0
  LD r1,r14,8
  LA r2,#NSH_RIDX
  ST r1,r2,0
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r0,r10,21
nsch_region_out:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  SVCRET

; ---------------------------------------------------------------------------
; SVC 9 - spawn(descriptor).
nsch_svc_spawn:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r3,r10,1              ; descriptor word address
  LD r1,r2,#NS_CUR         ; ppid = current
  ADD r2,r3,r0
  CALL @nsch_spawn_desc
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r1,r10,21
  SVCRET

; ---------------------------------------------------------------------------
; SVC 10 - wait(pid|0|-1).
nsch_svc_wait:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r3,r10,1              ; wanted pid
  LA r4,0xFFFFFFFF
  CMP r3,r4
  MOVI[EQ] r3,0
  ; np_wait(ppid=current, wanted)
  ST r3,r2,#NS_TMP1
  LD r1,r2,#NS_CUR
  ADD r2,r3,r0
  CALL @np_wait
  CMP r1,r0
  JMP[EQ] @nsch_wait_block
  ; zombie child already available: copy status, then reap
  LA r3,#NS_PTR
  LD r3,r3,0
  ST r1,r3,#NS_TMP0
  ST r2,r3,#NS_TMP2
  ADD r1,r1,r0
  CALL @np_reap
  LA r3,#NS_PTR
  LD r3,r3,0
  LD r10,r3,#NS_FP
  LD r2,r3,#NS_TMP2
  ST r2,r10,21
  SVCRET
nsch_wait_block:
  ; record wait kind and target on the current slot
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  CALL @nsch_slot
  LA r2,#NS_PTR
  LD r2,r2,0
  ST r1,r2,#NS_TMP0
  LD r3,r2,#NS_TMP1        ; wanted
  ADDI r4,r2,#NS_WAITPID
  ADD r4,r4,r1
  ST r3,r4,0
  ADDI r4,r2,#NS_WAITK
  ADD r4,r4,r1
  MOVI r3,#NS_WK_WAIT
  ST r3,r4,0
  ADDI r4,r2,#NS_WAKE
  ADD r4,r4,r1
  ST r0,r4,0
  ; blocked
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  MOVI r2,#NP_ST_BLOCKED
  CALL @np_set_state
  JMP @nsch_sched_save_switch

; ---------------------------------------------------------------------------
; SVC 20/21 - getpid/getppid.
nsch_svc_getpid:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  LD r2,r2,#NS_FP
  ST r1,r2,21
  SVCRET
nsch_svc_getppid:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  CALL @np_lookup
  LD r1,r1,#NP_E_PPID
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r2,r2,#NS_FP
  ST r1,r2,21
  SVCRET

; ---------------------------------------------------------------------------
; SVC 25 - setpriority(pid, prio 0..31).
nsch_svc_setprio:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r3,r10,1
  LD r4,r10,2
  MOVI r5,#NS_NPRIO
  CMP r4,r5
  JMP[GE] @nsch_setprio_range
  ST r3,r2,#NS_TMP0
  ADD r1,r3,r0
  ADD r2,r4,r0
  CALL @np_set_priority
  LA r2,#NS_PTR
  LD r2,r2,0
  ST r1,r2,#NS_TMP2
  CMP r1,r0
  JMP[NE] @nsch_setprio_fin
  ; A ready target must move to its new run level.
  LD r1,r2,#NS_TMP0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_setprio_ok
  LD r3,r1,#NP_E_STATE
  MOVI r4,#NP_ST_READY
  CMP r3,r4
  JMP[NE] @nsch_setprio_ok
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_TMP0
  CALL @nsch_remove_pid
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_TMP0
  CALL @nsch_slot
  CALL @nsch_enqueue
nsch_setprio_ok:
  MOVI r1,0
  JMP @nsch_setprio_fin
nsch_setprio_range:
  MOVI r1,2
nsch_setprio_fin:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r1,r10,21
  SVCRET

; ---------------------------------------------------------------------------
; SVC 26 - getpriority(pid) -> prio or -1.
nsch_svc_getprio:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r1,r10,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_getprio_bad
  LD r1,r1,#NP_E_PRIO
  JMP @nsch_getprio_fin
nsch_getprio_bad:
  LA r1,0xFFFFFFFF
nsch_getprio_fin:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r1,r10,21
  SVCRET

; ---------------------------------------------------------------------------
; SVC 27 - proc_count() -> live processes; SVC 28 - proc_limit().
nsch_svc_count:
  CALL @np_counts
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r1,r10,21
  SVCRET
nsch_svc_limit:
  MOVI r1,#NP_MAX_PROCS
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r1,r10,21
  SVCRET

; ---------------------------------------------------------------------------
; SVC 22 - kill(pid, sig).
nsch_svc_kill:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r1,r10,1
  LD r2,r10,2
  CALL @nsch_kill
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  ST r1,r10,21
  SVCRET

; ---------------------------------------------------------------------------
; SVC 24 - sleep(ticks).
nsch_svc_sleep:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LD r1,r10,1
  CMP r1,r0
  JMP[NE] @nsch_sleep_go
  ST r0,r10,21
  SVCRET
nsch_sleep_go:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_TICKS
  ADD r3,r3,r1
  ST r3,r2,#NS_TMP1        ; wake tick
  LD r1,r2,#NS_CUR
  CALL @nsch_slot
  LA r2,#NS_PTR
  LD r2,r2,0
  ST r1,r2,#NS_TMP0
  LD r3,r2,#NS_TMP1
  ADDI r4,r2,#NS_WAKE
  ADD r4,r4,r1
  ST r3,r4,0
  ADDI r4,r2,#NS_WAITK
  ADD r4,r4,r1
  MOVI r3,#NS_WK_SLEEP
  ST r3,r4,0
  ADDI r4,r2,#NS_WAITPID
  ADD r4,r4,r1
  ST r0,r4,0
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r3,r4,#NS_NSLEEP
  CMP r3,r0
  JMP[NE] @nsch_sleep_have
  LD r3,r4,#NS_TMP1
  ST r3,r4,#NS_SMIN
  JMP @nsch_sleep_inc
nsch_sleep_have:
  LD r5,r4,#NS_TMP1
  LD r3,r4,#NS_SMIN
  CMP r5,r3
  JMP[GE] @nsch_sleep_inc
  ST r5,r4,#NS_SMIN
nsch_sleep_inc:
  LD r3,r4,#NS_NSLEEP
  ADD r3,r3,r13
  ST r3,r4,#NS_NSLEEP
  LD r1,r2,#NS_CUR
  MOVI r2,#NP_ST_BLOCKED
  CALL @np_set_state
  JMP @nsch_sched_save_switch

; ---------------------------------------------------------------------------
; IRQ - tick, wake sleepers, preempt when the slice expires.
nsch_svc_irq:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_CUR
  CMP r3,r0
  JMP[EQ] @nsch_irq_ret     ; boot context before the first process
  CALL @nsch_tick
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_SLICE
  CMP r3,r0
  JMP[NE] @nsch_irq_ret
  CALL @nsch_preempt_current
  JMP @nsch_sched_save_switch
nsch_irq_ret:
  SVCRET

; ---------------------------------------------------------------------------
; nsch_start - enter the first process.  r1 = pid, or 0 to pick the highest
; ready process.  Called from the boot SVC 0 path or by a kernel boot stub.
; Owns SVCRET.
nsch_start:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nsch_start_pick
  CALL @nsch_slot
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_start_dead
  ; remove it from its ready queue if it is queued, then activate
  CALL @nsch_remove_slot
  LD r1,r14,1
  CALL @nsch_slot
  JMP @nsch_activate_slot
nsch_start_pick:
  CALL @nsch_pick
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_start_dead
  JMP @nsch_activate_slot
nsch_start_dead:
  MOVI r1,33
  PUTC r1
  MOVI r1,83
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT

; ---------------------------------------------------------------------------
; nsch_sched_save_switch - save the live kframe into the current slot and
; switch to the next ready process.  Never returns.
nsch_sched_save_switch:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  CMP r1,r0
  JMP[EQ] @nsch_ss_pick
  CALL @nsch_slot
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_ss_pick
  ST r1,r14,1
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_THRSLOT
  LD r4,r14,1
  CMP r3,r4
  JMP[NE] @nsch_ss_norm
  ; Thread owner: save the live kframe in nanthr's current TCB.
  MOVI r1,#NS_P_FRAME
  INL r2,r1
  LA r3,@nthr_globals
  LD r4,r3,#NT_G_CUR
  MOVI r5,24
  BCOPY r4,r2,r5
  JMP @nsch_ss_pick
nsch_ss_norm:
  LD r1,r14,1
  CALL @nsch_frame_ptr
  ADD r4,r1,r0
  MOVI r1,#NS_P_FRAME
  INL r2,r1
  MOVI r3,24
  BCOPY r4,r2,r3
nsch_ss_pick:
  CALL @nsch_pick
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_ss_dead
  JMP @nsch_activate_slot
nsch_ss_dead:
  HALT

; ---------------------------------------------------------------------------
; nsch_activate_slot - make slot r1 current and SVCRET into its frame.
nsch_activate_slot:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  ; entry pointer
  MOVI r2,#NP_ENTRY
  MUL r2,r1,r2
  LA r3,#NP_PTR
  LD r3,r3,0
  ADD r3,r3,r2
  ST r3,r14,2
  LD r1,r3,#NP_E_PID
  ST r1,r14,3
  ; ready (or blocked wake) -> running
  MOVI r2,#NP_ST_RUNNING
  CALL @np_set_state
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r14,3
  ST r1,r2,#NS_CUR
  ; frame -> kframe (current TCB frame in thread mode)
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_THRSLOT
  LD r4,r14,1
  CMP r3,r4
  JMP[NE] @nsch_act_norm
  LA r3,@nthr_globals
  LD r3,r3,#NT_G_CUR
  ST r3,r14,4
  JMP @nsch_act_copy
nsch_act_norm:
  LD r1,r14,1
  CALL @nsch_frame_ptr
  ST r1,r14,4
nsch_act_copy:
  LD r4,r14,4
  MOVI r1,#NS_P_FRAME
  INL r2,r1
  MOVI r3,24
  BCOPY r2,r4,r3
  ; region table -> port
  LD r1,r14,1
  CALL @nsch_rt_ptr
  MOVI r2,#NS_P_REGIONS
  OUTL r1,r2
  ; fresh quantum
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_QUANTUM
  ST r3,r2,#NS_SLICE
  SVCRET

; ---------------------------------------------------------------------------
; nsch_preempt_current - running -> ready tail.
nsch_preempt_current:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_PREEMPT
  ADD r3,r3,r13
  ST r3,r2,#NS_PREEMPT
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  MOVI r2,#NP_ST_READY
  CALL @np_set_state
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  CALL @nsch_slot
  CALL @nsch_enqueue
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_tick - one timer IRQ.  Increments ticks, wakes sleepers and decrements
; the current slice.
nsch_tick:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_TICKS
  ADD r3,r3,r13
  ST r3,r2,#NS_TICKS
  CALL @nsch_wake_sleepers
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_SLICE
  SUB r3,r3,r13
  ST r3,r2,#NS_SLICE
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_wake_sleepers - blocked sleepers whose wake tick has arrived become
; ready.  A woken process with a higher priority than the current one forces
; the slice to zero so the IRQ path switches immediately.
nsch_wake_sleepers:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_NSLEEP
  CMP r3,r0
  JMP[EQ] @nsch_ws_ret
  LD r3,r2,#NS_SMIN
  LD r4,r2,#NS_TICKS
  CMP r4,r3
  JMP[LT] @nsch_ws_ret
  ; current priority (0xFFFF if none)
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r2,#NS_CUR
  MOVI r3,#NS_NONE
  ST r3,r14,2
  CMP r1,r0
  JMP[EQ] @nsch_ws_scan
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_ws_scan
  LD r3,r1,#NP_E_PRIO
  ST r3,r14,2
nsch_ws_scan:
  MOVI r1,0
  ST r1,r14,1
  LA r4,0xFFFFFFFF
  ST r4,r14,4
nsch_ws_loop:
  LD r1,r14,1
  MOVI r2,#NP_MAX_PROCS
  CMP r1,r2
  JMP[GE] @nsch_ws_done
  ; entry = NP_BASE + slot*96
  MOVI r2,#NP_ENTRY
  MUL r2,r1,r2
  LA r3,#NP_PTR
  LD r3,r3,0
  ADD r3,r3,r2
  ST r3,r14,3
  LD r4,r3,#NP_E_PID
  CMP r4,r0
  JMP[EQ] @nsch_ws_next
  LD r5,r3,#NP_E_STATE
  MOVI r6,#NP_ST_BLOCKED
  CMP r5,r6
  JMP[NE] @nsch_ws_next
  ; wait kind must be sleep
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_WAITK
  ADD r6,r6,r1
  LD r5,r6,0
  MOVI r7,#NS_WK_SLEEP
  CMP r5,r7
  JMP[NE] @nsch_ws_next
  ; wake tick
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_WAKE
  ADD r6,r6,r1
  LD r5,r6,0
  LA r6,#NS_PTR
  LD r6,r6,0
  LD r7,r6,#NS_TICKS
  CMP r7,r5
  JMP[LT] @nsch_ws_notdue
  ; ready
  LD r1,r3,#NP_E_PID
  MOVI r2,#NP_ST_READY
  CALL @np_set_state
  LD r1,r14,1
  CALL @nsch_enqueue
  ; clear wait kind and count the sleeper out
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_WAITK
  LD r1,r14,1
  ADD r6,r6,r1
  ST r0,r6,0
  LA r6,#NS_PTR
  LD r6,r6,0
  LD r7,r6,#NS_NSLEEP
  SUB r7,r7,r13
  ST r7,r6,#NS_NSLEEP
  ; higher priority than current forces a switch
  LD r3,r14,3
  LD r4,r3,#NP_E_PRIO
  LD r5,r14,2
  MOVI r6,#NS_NONE
  CMP r5,r6
  JMP[EQ] @nsch_ws_next
  CMP r4,r5
  JMP[GE] @nsch_ws_next
  LA r6,#NS_PTR
  LD r6,r6,0
  ST r0,r6,#NS_SLICE
nsch_ws_next:
  LD r1,r14,1
  ADD r1,r1,r13
  ST r1,r14,1
  JMP @nsch_ws_loop
nsch_ws_notdue:
  LD r6,r14,4
  CMP r5,r6
  JMP[GE] @nsch_ws_next
  ST r5,r14,4
  JMP @nsch_ws_next
nsch_ws_done:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_NSLEEP
  CMP r3,r0
  JMP[NE] @nsch_ws_setmin
  ST r0,r2,#NS_SMIN
  JMP @nsch_ws_end
nsch_ws_setmin:
  LD r3,r14,4
  ST r3,r2,#NS_SMIN
nsch_ws_end:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET
nsch_ws_ret:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_wake_waiters - r1=child pid, r2=status.  Wake the parent blocked in
; wait for this child (or for any child) and inject the status into its
; saved frame.  Reap the zombie when a waiter consumed it.
nsch_wake_waiters:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ; child -> ppid
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_ww_done
  LD r3,r1,#NP_E_PPID
  CMP r3,r0
  JMP[EQ] @nsch_ww_done
  ST r3,r14,3
  ; parent must be blocked in wait
  ADD r1,r3,r0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_ww_done
  ST r1,r14,4
  LD r3,r1,#NP_E_STATE
  MOVI r4,#NP_ST_BLOCKED
  CMP r3,r4
  JMP[NE] @nsch_ww_done
  ; parent slot and wait record
  LD r1,r14,3
  CALL @nsch_slot
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_ww_done
  ST r1,r14,5
  LA r2,#NS_PTR
  LD r2,r2,0
  ADDI r2,r2,#NS_WAITK
  ADD r2,r2,r1
  LD r3,r2,0
  MOVI r4,#NS_WK_WAIT
  CMP r3,r4
  JMP[NE] @nsch_ww_done
  LA r2,#NS_PTR
  LD r2,r2,0
  ADDI r2,r2,#NS_WAITPID
  ADD r2,r2,r1
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @nsch_ww_match
  LD r4,r14,1
  CMP r3,r4
  JMP[NE] @nsch_ww_done
nsch_ww_match:
  ; wake parent
  LD r1,r14,3
  MOVI r2,#NP_ST_READY
  CALL @np_set_state
  LD r1,r14,5
  CALL @nsch_enqueue
  LD r1,r14,5
  CALL @nsch_frame_ptr
  LD r2,r14,2
  ST r2,r1,21
  ST r2,r1,1
  LD r2,r14,1
  ST r2,r1,2
  ; clear wait record
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_WAITK
  LD r1,r14,5
  ADD r6,r6,r1
  ST r0,r6,0
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_WAITPID
  ADD r6,r6,r1
  ST r0,r6,0
  ; waiter consumed the zombie
  LD r1,r14,1
  CALL @np_reap
nsch_ww_done:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_kill - r1=pid, r2=sig -> r1=0/1/2.  Removes a ready victim from the
; run queues and wakes waiters (status 128+sig from np_kill).
nsch_kill:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ; self?
  LA r3,#NS_PTR
  LD r3,r3,0
  LD r3,r3,#NS_CUR
  LD r4,r14,1
  CMP r3,r4
  JMP[EQ] @nsch_kill_self
  LD r1,r14,1
  LD r2,r14,2
  CALL @np_kill
  ST r1,r14,3
  CMP r1,r0
  JMP[NE] @nsch_kill_out
  ; unlink from any run queue and clear wait metadata
  LD r1,r14,1
  CALL @nsch_remove_pid
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r1,r14,1
  CALL @nsch_slot
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_kill_out
  ST r1,r14,4
  LA r2,#NS_PTR
  LD r2,r2,0
  ADDI r2,r2,#NS_WAITK
  ADD r2,r2,r1
  LD r3,r2,0
  MOVI r4,#NS_WK_SLEEP
  CMP r3,r4
  JMP[NE] @nsch_kill_notsleep
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r3,r4,#NS_NSLEEP
  SUB r3,r3,r13
  ST r3,r4,#NS_NSLEEP
nsch_kill_notsleep:
  ST r0,r2,0
  LA r2,#NS_PTR
  LD r2,r2,0
  ADDI r2,r2,#NS_WAKE
  ADD r2,r2,r1
  ST r0,r2,0
  ; status from the table
  LD r1,r14,1
  CALL @np_lookup
  LD r2,r1,#NP_E_STATUS
  ST r2,r14,5
  LD r1,r14,1
  LD r2,r14,5
  CALL @nsch_wake_waiters
nsch_kill_out:
  LD r1,r14,3
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET
nsch_kill_self:
  LD r2,r14,2
  MOVI r3,128
  ADD r2,r2,r3
  ST r2,r14,5
  ADD r1,r4,r0
  CALL @np_exit
  LD r1,r14,1
  LD r2,r14,5
  CALL @nsch_wake_waiters
  JMP @nsch_sched_save_switch

; ---------------------------------------------------------------------------
; Cooperative thread mode (nanthr.nas).  One owning process per boot may use
; threads; every thread shares the owner pid and S1 region table.  The first
; thread SVC seeds nanthr's main TCB with the live kframe, so SVC 0 yields
; between threads once a worker exists.
nsch_thread_svc:
  ADD r10,r1,r0
  LD r3,r10,20
  LA r2,#NS_PTR
  LD r2,r2,0
  ST r3,r2,#NS_TMP0
  LD r4,r2,#NS_THRPID
  CMP r4,r0
  JMP[NE] @nsch_ts_have
  ADD r1,r10,r0
  CALL @nsch_thread_boot
nsch_ts_have:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r4,r2,#NS_THRPID
  LD r5,r2,#NS_CUR
  CMP r4,r5
  JMP[NE] @nsch_ts_bad
  ; thread_exit: drop the exiting tid from the nanproc thread list
  LD r3,r2,#NS_TMP0
  MOVI r4,15
  CMP r3,r4
  JMP[NE] @nsch_ts_disp
  CALL @nthr_self
  ADD r2,r1,r0
  LA r3,#NS_PTR
  LD r3,r3,0
  LD r1,r3,#NS_CUR
  CALL @np_thread_remove
nsch_ts_disp:
  MOVI r1,#NS_P_FRAME
  INL r10,r1
  ADD r1,r10,r0
  CALL @nthr_syscall_dispatch
  ; thread_create: the tid is in the restored r1/frame[1]
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_TMP0
  MOVI r4,13
  CMP r3,r4
  JMP[NE] @nsch_ts_ret
  MOVI r1,#NS_P_FRAME
  INL r10,r1
  LD r1,r10,1
  CMP r1,r0
  JMP[EQ] @nsch_ts_ret
  ADD r2,r1,r0
  LA r3,#NS_PTR
  LD r3,r3,0
  LD r1,r3,#NS_CUR
  CALL @np_thread_add
nsch_ts_ret:
  SVCRET
nsch_ts_bad:
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r10,r2,#NS_FP
  LA r1,0xFFFFFFFF
  ST r1,r10,21
  SVCRET

; nsch_thread_boot - r1=frame.  Configure nanthr and seed its main TCB.
nsch_thread_boot:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  LA r1,#NS_TCB_BASE
  MOVI r2,#NS_TCB_COUNT
  LA r3,#NS_TSTACK_BASE
  MOVI r4,#NS_TSTACK_WORDS
  MOVI r5,#NS_TSTACK_SIZE
  CALL @nthr_init
  ; main TCB frame = live kframe
  LA r2,@nthr_globals
  LD r2,r2,#NT_G_CUR
  LD r1,r14,1
  MOVI r3,24
  BCOPY r2,r1,r3
  ; owner pid/slot
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_CUR
  ST r3,r2,#NS_THRPID
  ADD r1,r3,r0
  CALL @nsch_slot
  LA r2,#NS_PTR
  LD r2,r2,0
  ST r1,r2,#NS_THRSLOT
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_spawn_desc - r1=ppid, r2=descriptor -> r1=pid or 0.
nsch_spawn_desc:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r2,0
  ST r3,r14,3
  LD r3,r2,1
  ST r3,r14,4
  LD r3,r2,2
  ST r3,r14,5
  LD r3,r2,3
  ST r3,r14,6
  LD r3,r2,4
  MOVI r4,8
  CMP r3,r4
  JMP[LE] @nsch_sd_nreg
  MOVI r3,8
nsch_sd_nreg:
  LA r4,#NS_PTR
  LD r4,r4,0
  ST r3,r4,#NS_TMP3
  LD r3,r14,5
  MOVI r4,#NS_NPRIO
  CMP r3,r4
  JMP[LT] @nsch_sd_prio
  MOVI r3,#NS_NPRIO-1
  ST r3,r14,5
nsch_sd_prio:
  LD r1,r14,1
  LD r2,r14,6
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  CMP r1,r0
  JMP[EQ] @nsch_sd_fail
  LA r4,#NS_PTR
  LD r4,r4,0
  ST r1,r4,#NS_TMP0
  CALL @nsch_slot
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_sd_rollback
  LA r4,#NS_PTR
  LD r4,r4,0
  ST r1,r4,#NS_TMP1
  CALL @nsch_rt_ptr
  LA r4,#NS_PTR
  LD r4,r4,0
  ST r1,r4,#NS_TMP4
  MOVI r3,36
nsch_sd_rtz:
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nsch_sd_rtz
  LA r4,#NS_PTR
  LD r4,r4,0
  ST r0,r4,#NS_TMP2
nsch_sd_loop:
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r3,r4,#NS_TMP2
  LD r5,r4,#NS_TMP3
  CMP r3,r5
  JMP[GE] @nsch_sd_regions
  LD r2,r14,2
  MOVI r5,4
  MUL r5,r3,r5
  ADDI r2,r2,5
  ADD r2,r2,r5
  LD r6,r2,0
  ST r6,r14,7
  LD r6,r2,1
  ST r6,r14,8
  LD r6,r2,2
  LA r4,#NS_PTR
  LD r4,r4,0
  ST r6,r4,#NS_TMP5
  LD r6,r2,3
  LA r4,#NS_PTR
  LD r4,r4,0
  ST r6,r4,#NS_TMP6
  ; mirror into the per-slot S1 table before the nanproc call
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r2,r4,#NS_TMP4
  LD r3,r4,#NS_TMP2
  MOVI r5,4
  MUL r3,r3,r5
  ADD r2,r2,r3
  LD r6,r14,7
  ST r6,r2,0
  LD r6,r14,8
  ST r6,r2,1
  LD r6,r4,#NS_TMP5
  ST r6,r2,2
  LD r6,r4,#NS_TMP6
  ST r6,r2,3
  ; np_region_add(pid, base, words, kind, prot)
  LA r6,#NS_PTR
  LD r6,r6,0
  LD r1,r6,#NS_TMP0
  LD r2,r14,7
  LD r3,r14,8
  LD r4,r6,#NS_TMP5
  LD r5,r6,#NS_TMP6
  CALL @np_region_add
  CMP r1,r0
  JMP[NE] @nsch_sd_rollback
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r3,r4,#NS_TMP2
  ADD r3,r3,r13
  ST r3,r4,#NS_TMP2
  JMP @nsch_sd_loop
nsch_sd_regions:
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP0
  LD r2,r14,5
  CALL @np_set_priority
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP0
  MOVI r2,1
  CALL @np_thread_add
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP0
  CALL @np_lookup
  LA r2,#NS_PTR
  LD r2,r2,0
  LD r3,r2,#NS_TICKS
  ST r3,r1,#NP_E_START_TICK
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP1
  LD r2,r14,3
  LD r3,r14,4
  CALL @nsch_init_frame
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP1
  CALL @nsch_enqueue
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP0
  JMP @nsch_sd_out
nsch_sd_rollback:
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP0
  CALL @np_region_clear
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP0
  LA r2,0xFFFFFFFF
  CALL @np_exit
  LA r4,#NS_PTR
  LD r4,r4,0
  LD r1,r4,#NS_TMP0
  CALL @np_reap
nsch_sd_fail:
  MOVI r1,0
nsch_sd_out:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_init_frame - r1=slot, r2=entry, r3=sp.  Zero the 24-word frame and
; set r13=1, sp, pc.
nsch_init_frame:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @nsch_frame_ptr
  ADD r6,r1,r0
  MOVI r4,24
  ADD r5,r6,r0
nsch_if_z:
  ST r0,r5,0
  ADD r5,r5,r13
  SUB r4,r4,r13
  CMP r4,r0
  JMP[NE] @nsch_if_z
  MOVI r4,1
  ST r4,r6,13
  LD r4,r14,3
  ST r4,r6,14
  ST r4,r6,22
  LD r4,r14,2
  ST r4,r6,16
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_pick - pop the highest-priority ready slot -> r1=slot or NS_NONE.
nsch_pick:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  MOVI r2,0
  ST r2,r14,1
nsch_pick_loop:
  LD r1,r14,1
  CALL @nsch_dequeue_head
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[NE] @nsch_pick_out
  LD r2,r14,1
  ADD r2,r2,r13
  ST r2,r14,1
  MOVI r3,#NS_NPRIO
  CMP r2,r3
  JMP[LT] @nsch_pick_loop
  MOVI r1,#NS_NONE
nsch_pick_out:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsch_enqueue - append slot r1 to its priority queue.
nsch_enqueue:
  ; leaf
  MOVI r2,#NP_ENTRY
  MUL r3,r1,r2
  LA r2,#NP_PTR
  LD r2,r2,0
  ADD r3,r2,r3
  LD r4,r3,#NP_E_PRIO
  MOVI r5,#NS_NPRIO
  CMP r4,r5
  JMP[LT] @nsch_eq_prio
  MOVI r4,#NS_NPRIO-1
nsch_eq_prio:
  LA r5,#NS_PTR
  LD r5,r5,0
  ADDI r5,r5,#NS_QUEUE
  SHL r4,r4,1
  ADD r5,r5,r4              ; queue pair
  ; link[slot] = 0
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_LINK
  ADD r6,r6,r1
  ST r0,r6,0
  ADD r7,r1,r13             ; encoded slot
  LD r8,r5,1                ; tail
  CMP r8,r0
  JMP[EQ] @nsch_eq_empty
  ; link[tail-1] = enc
  SUB r8,r8,r13
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_LINK
  ADD r6,r6,r8
  ST r7,r6,0
  ST r7,r5,1
  RET
nsch_eq_empty:
  ST r7,r5,0
  ST r7,r5,1
  RET

; ---------------------------------------------------------------------------
; nsch_dequeue_head - r1=priority level -> r1=slot or NS_NONE.
nsch_dequeue_head:
  ; leaf
  LA r2,#NS_PTR
  LD r2,r2,0
  ADDI r2,r2,#NS_QUEUE
  SHL r3,r1,1
  ADD r2,r2,r3
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @nsch_dq_none
  SUB r4,r3,r13             ; slot
  LA r5,#NS_PTR
  LD r5,r5,0
  ADDI r5,r5,#NS_LINK
  ADD r5,r5,r4
  LD r6,r5,0                ; next enc
  ST r6,r2,0
  CMP r6,r0
  JMP[NE] @nsch_dq_have
  ST r0,r2,1
nsch_dq_have:
  ST r0,r5,0
  ADD r1,r4,r0
  RET
nsch_dq_none:
  MOVI r1,#NS_NONE
  RET

; ---------------------------------------------------------------------------
; nsch_remove_pid r1=pid; nsch_remove_slot r1=slot.  Unlink from any level.
nsch_remove_pid:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  CALL @nsch_slot
  MOVI r2,#NS_NONE
  CMP r1,r2
  JMP[EQ] @nsch_rp_out
  CALL @nsch_remove_slot
nsch_rp_out:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

nsch_remove_slot:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  ADD r2,r1,r13
  ST r2,r14,2              ; encoded target
  MOVI r2,0
  ST r2,r14,3              ; level
nsch_rs_level:
  LA r3,#NS_PTR
  LD r3,r3,0
  ADDI r3,r3,#NS_QUEUE
  LD r4,r14,3
  SHL r4,r4,1
  ADD r3,r3,r4
  LD r4,r3,0
  CMP r4,r0
  JMP[EQ] @nsch_rs_next
  LD r5,r14,2
  CMP r4,r5
  JMP[EQ] @nsch_rs_head
  ST r4,r14,4              ; previous encoded
nsch_rs_prev:
  LD r4,r14,4
  SUB r5,r4,r13
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_LINK
  ADD r6,r6,r5
  LD r5,r6,0
  CMP r5,r0
  JMP[EQ] @nsch_rs_next
  LD r7,r14,2
  CMP r5,r7
  JMP[EQ] @nsch_rs_mid
  ST r5,r14,4
  JMP @nsch_rs_prev
nsch_rs_mid:
  ; link[prev] = link[slot]
  LD r4,r14,4
  SUB r4,r4,r13
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_LINK
  ADD r6,r6,r4
  LD r5,r14,1
  LA r7,#NS_PTR
  LD r7,r7,0
  ADDI r7,r7,#NS_LINK
  ADD r7,r7,r5
  LD r8,r7,0
  ST r8,r6,0
  ; tail fix
  LD r8,r3,1
  LD r9,r14,2
  CMP r8,r9
  JMP[NE] @nsch_rs_clear
  LD r8,r14,4
  ST r8,r3,1
  JMP @nsch_rs_clear
nsch_rs_head:
  LD r5,r14,1
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_LINK
  ADD r6,r6,r5
  LD r5,r6,0
  ST r5,r3,0
  CMP r5,r0
  JMP[NE] @nsch_rs_clear
  ST r0,r3,1
nsch_rs_clear:
  LD r5,r14,1
  LA r6,#NS_PTR
  LD r6,r6,0
  ADDI r6,r6,#NS_LINK
  ADD r6,r6,r5
  ST r0,r6,0
  JMP @nsch_rs_done
nsch_rs_next:
  LD r4,r14,3
  ADD r4,r4,r13
  ST r4,r14,3
  MOVI r5,#NS_NPRIO
  CMP r4,r5
  JMP[LT] @nsch_rs_level
nsch_rs_done:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Address helpers.
; nsch_slot r1=pid -> r1=slot or NS_NONE.
nsch_slot:
  ST r15,r14,0
  ADDI r14,r14,#NS_FRAME
  ST r1,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsch_slot_bad
  LA r2,#NP_PTR
  LD r2,r2,0
  SUB r1,r1,r2
  MOVI r2,#NP_ENTRY
  DIVU r1,r1,r2
  JMP @nsch_slot_out
nsch_slot_bad:
  MOVI r1,#NS_NONE
nsch_slot_out:
  ADDI r14,r14,#NS_FRAME_NEG
  LD r15,r14,0
  RET

; nsch_frame_ptr r1=slot -> r1=word address.
nsch_frame_ptr:
  MOVI r2,24
  MUL r2,r1,r2
  LA r1,#NS_PTR
  LD r1,r1,0
  ADDI r1,r1,#NS_FRAMES
  ADD r1,r1,r2
  RET

; nsch_rt_ptr r1=slot -> r1=word address.
nsch_rt_ptr:
  MOVI r2,36
  MUL r2,r1,r2
  LA r1,#NS_PTR
  LD r1,r1,0
  ADDI r1,r1,#NS_REGT
  ADD r1,r1,r2
  RET
