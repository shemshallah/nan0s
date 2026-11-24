; nanproc.nas - NaN/0S process table and lifecycle (raw NaN16).
;
; This is the NaN kernel's process subsystem: allocation of pids, parent/child
; links, state transitions, exit/wait/zombie/reap, per-process heap and region
; bookkeeping, and the stat interface consumed by a guest process viewer.
; Thread scheduling internals (contexts, run queues, preemption) are owned by
; the scheduler stream; this file only maintains the per-process thread list.
;
; Integration point for the S1 loader: np_spawn below is a flat-image stub.
; The kernel-side hook is documented in spec/PROCESS.md §3.2: SVC 9 spawn has
; the loader verify the L4 seal and place the image, SVC 2 region_map maps it,
; and the kernel then calls np_create/np_region_add/np_heap_set/np_thread_add.
; This file emits no SVC opcodes; use SVC/SVCRET/INL mnemonics once nmk has
; them, never a raw SVC opcode word. Nothing outside this file needs to know which
; loader is present.
;
; Config supplied by the including program:
;   NP_BASE        process table base word address (required)
;   NP_VARS        kernel variable block, NP_VAR_WORDS words (required)
;   NP_MAX_PROCS   optional; override after the .include (a later .equ wins)
; The table base and the variable block may be anywhere in word memory:
; every access to NP_BASE/NP_VARS uses LA (MOVI+MOVHI), never a 16-bit
; immediate address. A program overriding NP_MAX_PROCS must reserve
; NP_MAX_PROCS*NP_ENTRY words at NP_BASE; np_init clears exactly that many.
;
; Entry layout revision: the original 64-word entry (words 0..63) is kept
; byte-for-byte. Capacity is extended in the second 32 words of a 96-word
; entry:
;   64..79  region descriptors 4..7
;   80..87  thread ids 8..15
;   88..95  reserved
; Defaults are 64 processes, 8 regions per process, 16 threads per process.
; Growth path: a revision may use a 128-word entry with further extension
; areas at 96..127; the 0..95 meanings above remain stable.
; NP_MAX_PROCS is a build-time array bound; NP_MAX_REGIONS/NP_MAX_THREADS are
; the current entry layout limits (8/16). No dynamic growth in place.
;
; ABI conventions: r0=0, r13=1, r14=software stack (grows up), r15=link.
; Public routines preserve r13 and r14 and clobber r1..r12 unless stated.
; All routines are non-reentrant (kernel runs them under its trap lock).
;
; Process entry (96 words; words 0..63 are the original stable ABI). Word
; offsets are part of the viewer/manager ABI; keep them stable. Region entry
; = 4 words {base, nwords, kind, prot}, as in the S1 region table, followed by
; the per-process thread id list.
;
;   0 pid          1 ppid         2 state        3 exit_status
;   4 heap_base    5 heap_end     6 heap_words   7 heap_used
;   8 threads      9 cpu_steps   10 capabilities 11 name_ptr
;  12 region_count 13 flags      14 first_child  15 next_sibling
;  16 image_base  17 image_words 18 region_words 19 priority
;  20 start_tick  21 exit_tick   22 reserved     23 reserved
;  24..39 regions 0..3 (4 x 4 words)
;  40..47 thread ids 0..7
;  48..63 reserved (original ABI tail)
;  64..79 regions 4..7 (extension)
;  80..87 thread ids 8..15 (extension)
;  88..95 reserved (extension)
;
; State values: 0 free, 1 ready, 2 running, 3 blocked, 4 zombie, 5 dead.
; Flags: bit 0 live (allocated), bit 1 image mapped, bit 2 heap registered.
;
; Region kinds: 1 image, 2 heap, 3 stack, 4 shared, 5 device.
; Protection bits: 1 read, 2 write, 4 execute.
;
; Status returns: 0 ok, 1 bad pid, 2 table full or illegal transition,
; 3 zero length / duplicate / invalid hook, as documented per routine.

.equ NP_MAX_PROCS 64
.equ NP_ENTRY 96
.equ NP_VAR_WORDS 16
.equ NP_MAX_REGIONS 8
.equ NP_MAX_THREADS 16
; Every non-leaf routine reserves a uniform 9-word frame: [old SP] link,
; [old SP+1..8] locals, new SP = old SP+9. A callee's link therefore lands
; above the caller's locals, so nested calls cannot clobber saved arguments.
.equ NP_FRAME 9
.equ NP_FRAME_NEG -9

.equ NP_ST_FREE 0
.equ NP_ST_READY 1
.equ NP_ST_RUNNING 2
.equ NP_ST_BLOCKED 3
.equ NP_ST_ZOMBIE 4
.equ NP_ST_DEAD 5

.equ NP_F_LIVE 1
.equ NP_F_IMAGE 2
.equ NP_F_HEAP 4

.equ NP_K_IMAGE 1
.equ NP_K_HEAP 2
.equ NP_K_STACK 3
.equ NP_K_SHARED 4
.equ NP_K_DEV 5

.equ NP_PROT_R 1
.equ NP_PROT_W 2
.equ NP_PROT_X 4
.equ NP_PROT_RW 3
.equ NP_PROT_RX 5

.equ NP_E_PID 0
.equ NP_E_PPID 1
.equ NP_E_STATE 2
.equ NP_E_STATUS 3
.equ NP_E_HEAP_BASE 4
.equ NP_E_HEAP_END 5
.equ NP_E_HEAP_WORDS 6
.equ NP_E_HEAP_USED 7
.equ NP_E_THREADS 8
.equ NP_E_STEPS 9
.equ NP_E_CAPS 10
.equ NP_E_NAME 11
.equ NP_E_NREG 12
.equ NP_E_FLAGS 13
.equ NP_E_CHILD 14
.equ NP_E_SIB 15
.equ NP_E_IMAGE 16
.equ NP_E_IMAGE_WORDS 17
.equ NP_E_MEM_WORDS 18
.equ NP_E_PRIO 19
.equ NP_E_START_TICK 20
.equ NP_E_EXIT_TICK 21
.equ NP_E_REGIONS 24
.equ NP_E_REGIONS2 64
.equ NP_E_TCB 40
.equ NP_E_TCB2 80
.equ NP_E_SIZE 96

; NP_VARS offsets.
.equ NP_V_NEXT 0
.equ NP_V_LIVE 1
.equ NP_V_RUN 2
.equ NP_V_ZOMB 3
.equ NP_V_MEM 4
.equ NP_V_SPAWN 5
.equ NP_V_REAP 6
.equ NP_V_KILL 7

; stat output block (20 words) filled by np_stat.
.equ NP_S_PID 0
.equ NP_S_PPID 1
.equ NP_S_STATE 2
.equ NP_S_STATUS 3
.equ NP_S_THREADS 4
.equ NP_S_STEPS 5
.equ NP_S_CAPS 6
.equ NP_S_NREG 7
.equ NP_S_MEM_WORDS 8
.equ NP_S_HEAP_BASE 9
.equ NP_S_HEAP_END 10
.equ NP_S_HEAP_USED 11
.equ NP_S_HEAP_WORDS 12
.equ NP_S_CHILDREN 13
.equ NP_S_PRIO 14
.equ NP_S_FLAGS 15
.equ NP_S_IMAGE 16
.equ NP_S_IMAGE_WORDS 17
.equ NP_S_NAME 18
.equ NP_S_START 19

; ---------------------------------------------------------------------------
; np_init -> r1=0. Wipe table and counters; pid numbering starts at 1.
np_init:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  LA r3,#NP_BASE
  MOVI r4,#NP_MAX_PROCS
np_init_t:
  MOVI r5,#NP_ENTRY
np_init_w:
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r5,r5,r13
  CMP r5,r0
  JMP[NE] @np_init_w
  SUB r4,r4,r13
  CMP r4,r0
  JMP[NE] @np_init_t
  LA r3,#NP_VARS
  MOVI r4,#NP_VAR_WORDS
np_init_v:
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r4,r4,r13
  CMP r4,r0
  JMP[NE] @np_init_v
  MOVI r1,1
  LA r3,#NP_VARS
  ST r1,r3,#NP_V_NEXT
  MOVI r1,0
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_lookup r1=pid -> r1=entry ptr or 0. Clobbers r2..r5.
np_lookup:
  CMP r1,r0
  JMP[EQ] @npl_none
  MOVI r3,0
  LA r4,#NP_BASE
npl_loop:
  LD r5,r4,#NP_E_PID
  CMP r5,r1
  JMP[EQ] @npl_found
  MOVI r5,#NP_ENTRY
  ADD r4,r4,r5
  ADD r3,r3,r13
  MOVI r5,#NP_MAX_PROCS
  CMP r3,r5
  JMP[LT] @npl_loop
npl_none:
  MOVI r1,0
  RET
npl_found:
  MOVI r1,0
  ADD r1,r4,r0
  RET

; np_region_slot r1=entry, r2=index 0..7 -> r5=descriptor pointer.
; Words 0..3 live at entry+24; extension 4..7 at entry+64.
np_region_slot:
  MOVI r5,#NP_E_REGIONS
  MOVI r3,4
  CMP r2,r3
  JMP[LT] @nrs_lo
  MOVI r5,#NP_E_REGIONS2
  SUB r3,r2,r3
  SHL r3,r3,2
  ADD r5,r5,r3
  JMP @nrs_done
nrs_lo:
  SHL r3,r2,2
  ADD r5,r5,r3
nrs_done:
  ADD r5,r5,r1
  RET

; np_tcb_slot r1=entry, r2=index 0..15 -> r5=thread-id slot pointer.
; Words 0..7 live at entry+40; extension 8..15 at entry+80.
np_tcb_slot:
  MOVI r5,#NP_E_TCB
  MOVI r3,8
  CMP r2,r3
  JMP[LT] @nts_lo
  MOVI r5,#NP_E_TCB2
  SUB r3,r2,r3
  ADD r5,r5,r3
  JMP @nts_done
nts_lo:
  ADD r5,r5,r2
nts_done:
  ADD r5,r5,r1
  RET

; np_zero_entry r1=entry. Clobbers r2..r4.
np_zero_entry:
  MOVI r2,#NP_ENTRY
nz_loop:
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @nz_loop
  RET

; np_alloc -> r1=new pid or 0. Reserves a free slot, state ready, parent 0.
np_alloc:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  MOVI r2,0
  LA r3,#NP_BASE
npa_loop:
  LD r4,r3,#NP_E_PID
  CMP r4,r0
  JMP[EQ] @npa_free
  MOVI r4,#NP_ENTRY
  ADD r3,r3,r4
  ADD r2,r2,r13
  MOVI r4,#NP_MAX_PROCS
  CMP r2,r4
  JMP[LT] @npa_loop
  MOVI r1,0
  JMP @npa_out
npa_free:
  ST r3,r14,1
  MOVI r1,0
  ADD r1,r3,r0
  CALL @np_zero_entry
  LA r12,#NP_VARS
  LD r1,r12,#NP_V_NEXT
  CMP r1,r0
  JMP[NE] @npa_pid
  MOVI r1,1
npa_pid:
  LA r12,#NP_VARS
  ST r1,r12,#NP_V_NEXT
  ADD r2,r1,r13
  LA r12,#NP_VARS
  ST r2,r12,#NP_V_NEXT
  LD r3,r14,1
  ST r1,r3,#NP_E_PID
  MOVI r4,#NP_ST_READY
  ST r4,r3,#NP_E_STATE
  MOVI r4,#NP_F_LIVE
  ST r4,r3,#NP_E_FLAGS
  LA r12,#NP_VARS
  LD r4,r12,#NP_V_LIVE
  ADD r4,r4,r13
  LA r12,#NP_VARS
  ST r4,r12,#NP_V_LIVE
  LD r1,r3,#NP_E_PID
npa_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_link_child r1=parent pid, r2=child pid -> r1=0 ok / 1 bad pid.
; Prepends the child to the parent's child list; child.next_sibling is updated.
np_link_child:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nlc_bad
  ST r1,r14,3
  LD r1,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nlc_bad
  ST r1,r14,4
  LD r3,r14,3
  LD r4,r3,#NP_E_CHILD
  ST r4,r1,#NP_E_SIB
  LD r2,r14,2
  ST r2,r3,#NP_E_CHILD
  MOVI r1,0
  JMP @nlc_out
nlc_bad:
  MOVI r1,1
nlc_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_unlink_child r1=parent pid, r2=child pid -> r1=0 ok / 1 not found.
np_unlink_child:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nuc_bad
  ST r1,r14,3
  LD r1,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nuc_bad
  ST r1,r14,4
  LD r5,r14,3
  LD r6,r5,#NP_E_CHILD
  LD r7,r14,2
  CMP r6,r7
  JMP[EQ] @nuc_head
  ST r6,r14,5
nuc_loop:
  LD r6,r14,5
  CMP r6,r0
  JMP[EQ] @nuc_bad
  ADD r1,r6,r0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nuc_bad
  ST r1,r14,6
  LD r5,r1,#NP_E_SIB
  LD r7,r14,2
  CMP r5,r7
  JMP[EQ] @nuc_found
  ST r5,r14,5
  JMP @nuc_loop
nuc_found:
  LD r1,r14,6
  LD r5,r14,4
  LD r5,r5,#NP_E_SIB
  ST r5,r1,#NP_E_SIB
  LD r5,r14,4
  ST r0,r5,#NP_E_SIB
  MOVI r1,0
  JMP @nuc_out
nuc_head:
  LD r5,r14,3
  LD r6,r14,4
  LD r6,r6,#NP_E_SIB
  ST r6,r5,#NP_E_CHILD
  LD r5,r14,4
  ST r0,r5,#NP_E_SIB
  MOVI r1,0
  JMP @nuc_out
nuc_bad:
  MOVI r1,1
nuc_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_create r1=ppid, r2=name_ptr, r3=image_base, r4=image_words -> r1=pid/0.
; The image is recorded as a read+execute region when image_words > 0.
; Parent 0 means kernel/root. A dead parent is treated as absent.
np_create:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CALL @np_alloc
  CMP r1,r0
  JMP[EQ] @npc_fail
  ST r1,r14,5
  CALL @np_lookup
  ST r1,r14,6
  LD r3,r14,2
  ST r3,r1,#NP_E_NAME
  LD r3,r14,3
  ST r3,r1,#NP_E_IMAGE
  LD r3,r14,4
  ST r3,r1,#NP_E_IMAGE_WORDS
  ; image region first, so a full region table fails cleanly before linking
  CMP r3,r0
  JMP[EQ] @npc_noreg
  LD r1,r14,5
  LD r2,r14,3
  LD r3,r14,4
  MOVI r4,#NP_K_IMAGE
  MOVI r5,#NP_PROT_RX
  CALL @np_region_add
  CMP r1,r0
  JMP[EQ] @npc_noreg
  ; rollback the slot on region-table failure
  LD r1,r14,6
  CALL @np_zero_entry
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_LIVE
  SUB r3,r3,r13
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_LIVE
  MOVI r1,0
  JMP @npc_out
npc_noreg:
  ; mark image mapped when a region was recorded
  LD r3,r14,6
  LD r4,r14,4
  CMP r4,r0
  JMP[EQ] @npc_parent
  LD r4,r3,#NP_E_FLAGS
  MOVI r5,#NP_F_IMAGE
  BOOL.14 r4,r4,r5
  ST r4,r3,#NP_E_FLAGS
npc_parent:
  LD r2,r14,1
  CMP r2,r0
  JMP[EQ] @npc_count
  ADD r1,r2,r0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npc_count
  LD r4,r1,#NP_E_STATE
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[GE] @npc_count
  LD r3,r14,6
  LD r2,r14,1
  ST r2,r3,#NP_E_PPID
  ADD r1,r2,r0
  LD r2,r14,5
  CALL @np_link_child
npc_count:
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_SPAWN
  ADD r3,r3,r13
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_SPAWN
  LD r1,r14,5
  JMP @npc_out
npc_fail:
  MOVI r1,0
npc_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_spawn r1=ppid, r2=path, r3=image_base, r4=image_words -> r1=pid/0.
; This is the guest-facing entry. It currently lands in np_spawn_stub below.
np_spawn:
  JMP @np_spawn_stub

; np_spawn_stub - MOCKED flat-image loader. image_base/image_words are mapped
; directly; no seal is verified and no storage is read. It emits no SVC and
; must not encode a raw SVC opcode word. Real integration is at the S1 syscall
; dispatch (spec/PROCESS.md §3.2):
;   SVC 9 spawn(path, argv, env)  -> loader verifies the L4 seal, returns pid
;   SVC 2 region_map(id, base, words, kind) -> memory region mapping
; then the kernel calls np_create/np_region_add/np_heap_set/np_thread_add as
; shown there. Use the named SVC/SVCRET/INL mnemonics when nmk exposes them.
; The stub keeps the deterministic nanproc gate runnable before S1 storage and
; the sealed-image loader exist; the gate output names it.
np_spawn_stub:
  JMP @np_create

; np_exit r1=pid, r2=status -> r1=0 ok / 1 bad pid or already terminating.
; Live processes become zombies for a live parent. Orphans become dead and
; their own live children are reparented to init (pid 1) when init is live.
np_exit:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npx_bad
  ST r1,r14,3
  LD r4,r1,#NP_E_STATE
  CMP r4,r0
  JMP[EQ] @npx_bad
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[GE] @npx_bad
  LD r2,r14,2
  ST r2,r1,#NP_E_STATUS
  ; find init unless this process itself is init
  LD r4,r14,1
  MOVI r5,1
  CMP r4,r5
  JMP[EQ] @npx_noinit
  MOVI r1,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npx_noinit
  LD r4,r1,#NP_E_STATE
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[LT] @npx_haveinit
npx_noinit:
  MOVI r1,0
npx_haveinit:
  ST r1,r14,7
  ; walk and reparent the children before clearing the parent's list
  LD r3,r14,3
  LD r4,r3,#NP_E_CHILD
  ST r4,r14,4
npx_child:
  LD r4,r14,4
  CMP r4,r0
  JMP[EQ] @npx_children_done
  ADD r1,r4,r0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npx_children_done
  ST r1,r14,6
  LD r5,r1,#NP_E_SIB
  ST r5,r14,5
  LD r5,r14,7
  CMP r5,r0
  JMP[EQ] @npx_orphan
  ; reparent to init (prepend there)
  MOVI r5,1
  ST r5,r1,#NP_E_PPID
  MOVI r1,1
  LD r2,r14,4
  CALL @np_link_child
  JMP @npx_next
npx_orphan:
  LD r1,r14,6
  LD r5,r1,#NP_E_STATE
  MOVI r6,#NP_ST_ZOMBIE
  CMP r5,r6
  JMP[NE] @npx_orphan_pp
  MOVI r5,#NP_ST_DEAD
  ST r5,r1,#NP_E_STATE
  LA r12,#NP_VARS
  LD r5,r12,#NP_V_ZOMB
  SUB r5,r5,r13
  LA r12,#NP_VARS
  ST r5,r12,#NP_V_ZOMB
npx_orphan_pp:
  ST r0,r1,#NP_E_PPID
  ST r0,r1,#NP_E_SIB
npx_next:
  LD r4,r14,5
  ST r4,r14,4
  JMP @npx_child
npx_children_done:
  LD r3,r14,3
  ST r0,r3,#NP_E_CHILD
  ; zombie only when a live parent remains, otherwise dead
  LD r4,r3,#NP_E_PPID
  CMP r4,r0
  JMP[EQ] @npx_dead
  ADD r1,r4,r0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npx_dead
  LD r5,r1,#NP_E_STATE
  MOVI r6,#NP_ST_ZOMBIE
  CMP r5,r6
  JMP[GE] @npx_dead
  LD r1,r14,1
  MOVI r2,#NP_ST_ZOMBIE
  CALL @np_set_state
  JMP @npx_ok
npx_dead:
  LD r1,r14,1
  MOVI r2,#NP_ST_DEAD
  CALL @np_set_state
npx_ok:
  MOVI r1,0
  JMP @npx_out
npx_bad:
  MOVI r1,1
npx_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_wait r1=ppid, r2=wanted pid (0 = any) -> r1=zombie child pid or 0,
; r2=exit status. Does not reap; the kernel calls np_reap after copying status.
np_wait:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npw_none
  LD r3,r1,#NP_E_STATE
  MOVI r4,#NP_ST_ZOMBIE
  CMP r3,r4
  JMP[GE] @npw_none
  LD r5,r1,#NP_E_CHILD
  ST r5,r14,3
npw_loop:
  LD r5,r14,3
  CMP r5,r0
  JMP[EQ] @npw_none
  ADD r1,r5,r0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npw_none
  ST r1,r14,4
  LD r6,r1,#NP_E_SIB
  ST r6,r14,5
  LD r6,r14,2
  CMP r6,r0
  JMP[EQ] @npw_check
  LD r6,r14,3
  LD r7,r14,2
  CMP r6,r7
  JMP[NE] @npw_next
npw_check:
  LD r5,r14,4
  LD r6,r5,#NP_E_STATE
  MOVI r7,#NP_ST_ZOMBIE
  CMP r6,r7
  JMP[NE] @npw_next
  LD r1,r14,3
  LD r2,r5,#NP_E_STATUS
  JMP @npw_out
npw_next:
  LD r5,r14,5
  ST r5,r14,3
  JMP @npw_loop
npw_none:
  MOVI r1,0
  MOVI r2,0
npw_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_reap r1=pid -> r1=0 ok / 1 bad pid / 2 not zombie-or-dead, r2=exit status.
; Unlinks from the parent list, releases regions/heap accounting and frees the
; slot. Reaped pids are not reused (the pid counter is monotonic).
np_reap:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npr_bad
  ST r1,r14,2
  LD r4,r1,#NP_E_STATE
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[EQ] @npr_okstate
  MOVI r5,#NP_ST_DEAD
  CMP r4,r5
  JMP[EQ] @npr_okstate
  MOVI r1,2
  JMP @npr_out
npr_okstate:
  ST r4,r14,3
  LD r5,r1,#NP_E_STATUS
  ST r5,r14,4
  LD r5,r1,#NP_E_MEM_WORDS
  ST r5,r14,5
  LD r5,r1,#NP_E_PPID
  CMP r5,r0
  JMP[EQ] @npr_unlinked
  ADD r1,r5,r0
  LD r2,r14,1
  CALL @np_unlink_child
npr_unlinked:
  ; global region words
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_MEM
  LD r4,r14,5
  CMP r3,r4
  JMP[GE] @npr_memok
  MOVI r3,0
  JMP @npr_memstore
npr_memok:
  SUB r3,r3,r4
npr_memstore:
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_MEM
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_LIVE
  SUB r3,r3,r13
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_LIVE
  LD r3,r14,3
  MOVI r4,#NP_ST_ZOMBIE
  CMP r3,r4
  JMP[NE] @npr_clear
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_ZOMB
  SUB r3,r3,r13
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_ZOMB
npr_clear:
  LD r1,r14,2
  CALL @np_zero_entry
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_REAP
  ADD r3,r3,r13
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_REAP
  MOVI r1,0
  LD r2,r14,4
  JMP @npr_out
npr_bad:
  MOVI r1,1
  MOVI r2,0
npr_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_kill r1=pid, r2=signal -> r1=0 ok / 1 bad pid / 2 already terminating.
; Exit status is 128+signal, the forbidden-by-POSIX shell convention that
; keeps signal deaths distinguishable in a status-only table.
np_kill:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npk_bad
  LD r3,r1,#NP_E_STATE
  MOVI r4,#NP_ST_ZOMBIE
  CMP r3,r4
  JMP[GE] @npk_term
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_KILL
  ADD r3,r3,r13
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_KILL
  LD r2,r14,2
  MOVI r4,128
  ADD r2,r2,r4
  LD r1,r14,1
  CALL @np_exit
  JMP @npk_out
npk_bad:
  MOVI r1,1
  JMP @npk_out
npk_term:
  MOVI r1,2
npk_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_set_state r1=pid, r2=new state -> r1=0 ok / 1 bad pid / 2 illegal.
; Legal: free->ready; ready->running|zombie|dead; running->ready|blocked|
; zombie|dead; blocked->ready|zombie|dead; zombie->dead; dead->free.
np_set_state:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nps_badpid
  ST r1,r14,3
  LD r3,r1,#NP_E_STATE
  LD r4,r14,2
  CMP r3,r4
  JMP[EQ] @nps_ok
  CMP r3,r0
  JMP[NE] @nps_ready
  MOVI r5,#NP_ST_READY
  CMP r4,r5
  JMP[EQ] @nps_commit
  JMP @nps_illegal
nps_ready:
  MOVI r5,#NP_ST_READY
  CMP r3,r5
  JMP[NE] @nps_running
  MOVI r5,#NP_ST_RUNNING
  CMP r4,r5
  JMP[EQ] @nps_commit
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[EQ] @nps_commit
  MOVI r5,#NP_ST_DEAD
  CMP r4,r5
  JMP[EQ] @nps_commit
  JMP @nps_illegal
nps_running:
  MOVI r5,#NP_ST_RUNNING
  CMP r3,r5
  JMP[NE] @nps_blocked
  MOVI r5,#NP_ST_READY
  CMP r4,r5
  JMP[EQ] @nps_commit
  MOVI r5,#NP_ST_BLOCKED
  CMP r4,r5
  JMP[EQ] @nps_commit
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[EQ] @nps_commit
  MOVI r5,#NP_ST_DEAD
  CMP r4,r5
  JMP[EQ] @nps_commit
  JMP @nps_illegal
nps_blocked:
  MOVI r5,#NP_ST_BLOCKED
  CMP r3,r5
  JMP[NE] @nps_zombie
  MOVI r5,#NP_ST_READY
  CMP r4,r5
  JMP[EQ] @nps_commit
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[EQ] @nps_commit
  MOVI r5,#NP_ST_DEAD
  CMP r4,r5
  JMP[EQ] @nps_commit
  JMP @nps_illegal
nps_zombie:
  MOVI r5,#NP_ST_ZOMBIE
  CMP r3,r5
  JMP[NE] @nps_dead
  MOVI r5,#NP_ST_DEAD
  CMP r4,r5
  JMP[EQ] @nps_commit
  JMP @nps_illegal
nps_dead:
  MOVI r5,#NP_ST_DEAD
  CMP r3,r5
  JMP[NE] @nps_illegal
  CMP r4,r0
  JMP[EQ] @nps_commit
  JMP @nps_illegal
nps_commit:
  ; adjust running/zombie counters only when the state actually changes
  MOVI r5,#NP_ST_RUNNING
  CMP r3,r5
  JMP[NE] @nps_notoldrun
  LA r12,#NP_VARS
  LD r5,r12,#NP_V_RUN
  SUB r5,r5,r13
  LA r12,#NP_VARS
  ST r5,r12,#NP_V_RUN
nps_notoldrun:
  MOVI r5,#NP_ST_RUNNING
  CMP r4,r5
  JMP[NE] @nps_notnewrun
  LA r12,#NP_VARS
  LD r5,r12,#NP_V_RUN
  ADD r5,r5,r13
  LA r12,#NP_VARS
  ST r5,r12,#NP_V_RUN
nps_notnewrun:
  MOVI r5,#NP_ST_ZOMBIE
  CMP r3,r5
  JMP[NE] @nps_notoldz
  LA r12,#NP_VARS
  LD r5,r12,#NP_V_ZOMB
  SUB r5,r5,r13
  LA r12,#NP_VARS
  ST r5,r12,#NP_V_ZOMB
nps_notoldz:
  MOVI r5,#NP_ST_ZOMBIE
  CMP r4,r5
  JMP[NE] @nps_store
  LA r12,#NP_VARS
  LD r5,r12,#NP_V_ZOMB
  ADD r5,r5,r13
  LA r12,#NP_VARS
  ST r5,r12,#NP_V_ZOMB
nps_store:
  LD r1,r14,3
  LD r4,r14,2
  ST r4,r1,#NP_E_STATE
nps_ok:
  MOVI r1,0
  JMP @nps_out
nps_badpid:
  MOVI r1,1
  JMP @nps_out
nps_illegal:
  MOVI r1,2
nps_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_region_add r1=pid, r2=base, r3=nwords, r4=kind, r5=prot
;   -> r1=0 ok / 1 bad pid / 2 region table full / 3 zero length.
; The per-process region table is the S1 table shape: {base,nwords,kind,prot}.
np_region_add:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nra_badpid
  ST r1,r14,6
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @nra_zero
  LD r4,r1,#NP_E_NREG
  MOVI r5,#NP_MAX_REGIONS
  CMP r4,r5
  JMP[GE] @nra_full
  ADD r2,r4,r0
  CALL @np_region_slot
  LD r2,r14,2
  ST r2,r5,0
  LD r2,r14,3
  ST r2,r5,1
  LD r2,r14,4
  ST r2,r5,2
  LD r2,r14,5
  ST r2,r5,3
  ADD r4,r4,r13
  LD r1,r14,6
  ST r4,r1,#NP_E_NREG
  LD r2,r14,3
  LD r3,r1,#NP_E_MEM_WORDS
  ADD r3,r3,r2
  ST r3,r1,#NP_E_MEM_WORDS
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_MEM
  ADD r3,r3,r2
  LA r12,#NP_VARS
  ST r3,r12,#NP_V_MEM
  MOVI r1,0
  JMP @nra_out
nra_badpid:
  MOVI r1,1
  JMP @nra_out
nra_full:
  MOVI r1,2
  JMP @nra_out
nra_zero:
  MOVI r1,3
nra_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_region_get r1=pid, r2=index -> r1=base r2=nwords r3=kind r4=prot
; r5=found (1) or 0 with the other outputs zero.
np_region_get:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nrg_none
  LD r4,r1,#NP_E_NREG
  LD r3,r14,2
  CMP r3,r4
  JMP[GE] @nrg_none
  ADD r2,r3,r0
  CALL @np_region_slot
  LD r1,r5,0
  LD r2,r5,1
  LD r3,r5,2
  LD r4,r5,3
  MOVI r5,1
  JMP @nrg_out
nrg_none:
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  MOVI r5,0
nrg_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_region_clear r1=pid -> r1=0 ok / 1 bad pid. Zeroes all descriptors and
; the heap bookkeeping, and subtracts the region words from the global count.
np_region_clear:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nrc_bad
  ST r1,r14,2
  LD r3,r1,#NP_E_MEM_WORDS
  LA r12,#NP_VARS
  LD r4,r12,#NP_V_MEM
  CMP r4,r3
  JMP[GE] @nrc_sub
  MOVI r4,0
  JMP @nrc_store
nrc_sub:
  SUB r4,r4,r3
nrc_store:
  LA r12,#NP_VARS
  ST r4,r12,#NP_V_MEM
  LD r1,r14,2
  ST r0,r1,#NP_E_NREG
  ST r0,r1,#NP_E_MEM_WORDS
  ST r0,r1,#NP_E_HEAP_BASE
  ST r0,r1,#NP_E_HEAP_END
  ST r0,r1,#NP_E_HEAP_WORDS
  ST r0,r1,#NP_E_HEAP_USED
  LD r3,r1,#NP_E_FLAGS
  MOVI r4,#NP_F_HEAP
  BOOL.5 r3,r3,r4
  MOVI r4,#NP_F_IMAGE
  BOOL.5 r3,r3,r4
  ST r3,r1,#NP_E_FLAGS
  MOVI r5,#NP_E_REGIONS
  ADD r5,r5,r1
  MOVI r6,4
  SHL r6,r6,2
nrc_zero_lo:
  ST r0,r5,0
  ADD r5,r5,r13
  SUB r6,r6,r13
  CMP r6,r0
  JMP[NE] @nrc_zero_lo
  LD r1,r14,2
  MOVI r5,#NP_E_REGIONS2
  ADD r5,r5,r1
  MOVI r6,4
  SHL r6,r6,2
nrc_zero_hi:
  ST r0,r5,0
  ADD r5,r5,r13
  SUB r6,r6,r13
  CMP r6,r0
  JMP[NE] @nrc_zero_hi
  MOVI r1,0
  JMP @nrc_out
nrc_bad:
  MOVI r1,1
nrc_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_heap_set r1=pid, r2=base, r3=words -> r1=0 ok / 1 bad pid /
; 2 region table full / 3 heap already registered. words=0 clears the heap.
; Registers the heap as a read+write region (kind heap) automatically; the
; caller gets base/size from MEMQ or the kernel buddy allocator.
np_heap_set:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nhs_bad
  ST r1,r14,4
  LD r3,r1,#NP_E_FLAGS
  MOVI r4,#NP_F_HEAP
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[NE] @nhs_dupe
  LD r3,r14,3
  CMP r3,r0
  JMP[NE] @nhs_add
  ; empty heap: no region
  LD r1,r14,4
  ST r0,r1,#NP_E_HEAP_BASE
  ST r0,r1,#NP_E_HEAP_END
  ST r0,r1,#NP_E_HEAP_WORDS
  ST r0,r1,#NP_E_HEAP_USED
  MOVI r1,0
  JMP @nhs_out
nhs_add:
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,3
  MOVI r4,#NP_K_HEAP
  MOVI r5,#NP_PROT_RW
  CALL @np_region_add
  CMP r1,r0
  JMP[NE] @nhs_out
  LD r1,r14,4
  LD r2,r14,2
  ST r2,r1,#NP_E_HEAP_BASE
  LD r3,r14,3
  ADD r4,r2,r3
  ST r4,r1,#NP_E_HEAP_END
  ST r3,r1,#NP_E_HEAP_WORDS
  ST r0,r1,#NP_E_HEAP_USED
  LD r3,r1,#NP_E_FLAGS
  MOVI r4,#NP_F_HEAP
  BOOL.14 r3,r3,r4
  ST r3,r1,#NP_E_FLAGS
  MOVI r1,0
  JMP @nhs_out
nhs_bad:
  MOVI r1,1
  JMP @nhs_out
nhs_dupe:
  MOVI r1,3
nhs_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_heap_used_set r1=pid, r2=used words -> r1=0 ok / 1 bad pid / 2 over heap.
; Hook for the nalloc rover report after each malloc/free.
np_heap_used_set:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nhu_bad
  LD r3,r1,#NP_E_HEAP_WORDS
  LD r4,r14,2
  CMP r4,r3
  JMP[GT] @nhu_over
  ST r4,r1,#NP_E_HEAP_USED
  MOVI r1,0
  JMP @nhu_out
nhu_bad:
  MOVI r1,1
  JMP @nhu_out
nhu_over:
  MOVI r1,2
nhu_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_mem_stats r1=pid -> r1=heap_used r2=heap_words r3=region_words
; r4=region_count r5=heap_headroom. Bad pid returns zeros.
np_mem_stats:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nms_zero
  LD r2,r1,#NP_E_HEAP_USED
  LD r3,r1,#NP_E_HEAP_WORDS
  LD r4,r1,#NP_E_MEM_WORDS
  LD r5,r1,#NP_E_NREG
  MOVI r6,0
  ADD r6,r6,r3
  SUB r6,r6,r2
  CMP r6,r0
  JMP[GE] @nms_out
  MOVI r6,0
  JMP @nms_out
nms_zero:
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  MOVI r5,0
  MOVI r6,0
nms_out:
  MOVI r1,0
  ADD r1,r2,r0
  MOVI r2,0
  ADD r2,r3,r0
  MOVI r3,0
  ADD r3,r4,r0
  MOVI r4,0
  ADD r4,r5,r0
  ADD r5,r6,r0
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_add_steps r1=pid, r2=delta -> r1=0 ok / 1 bad pid.
np_add_steps:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r2,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nas_bad
  LD r3,r1,#NP_E_STEPS
  LD r4,r14,1
  ADD r3,r3,r4
  ST r3,r1,#NP_E_STEPS
  MOVI r1,0
  JMP @nas_out
nas_bad:
  MOVI r1,1
nas_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_set_steps r1=pid, r2=value -> r1=0 ok / 1 bad pid.
np_set_steps:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r2,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nst_bad
  LD r3,r14,1
  ST r3,r1,#NP_E_STEPS
  MOVI r1,0
  JMP @nst_out
nst_bad:
  MOVI r1,1
nst_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_thread_add r1=pid, r2=tid -> 0 ok / 1 bad pid / 2 full / 3 duplicate.
; Bookkeeping only; the scheduler owns the thread context itself.
np_thread_add:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @nta_dupe
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nta_bad
  ST r1,r14,3
  MOVI r6,0
nta_loop:
  LD r1,r14,3
  ADD r2,r6,r0
  CALL @np_tcb_slot
  LD r7,r5,0
  CMP r7,r0
  JMP[EQ] @nta_free
  LD r7,r14,2
  LD r8,r5,0
  CMP r8,r7
  JMP[EQ] @nta_dupe
  ADD r6,r6,r13
  MOVI r7,#NP_MAX_THREADS
  CMP r6,r7
  JMP[LT] @nta_loop
  MOVI r1,2
  JMP @nta_out
nta_free:
  LD r7,r14,2
  ST r7,r5,0
  LD r1,r14,3
  LD r7,r1,#NP_E_THREADS
  ADD r7,r7,r13
  ST r7,r1,#NP_E_THREADS
  MOVI r1,0
  JMP @nta_out
nta_bad:
  MOVI r1,1
  JMP @nta_out
nta_dupe:
  MOVI r1,3
nta_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_thread_remove r1=pid, r2=tid -> 0 ok / 1 bad pid / 2 not found.
np_thread_remove:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @ntr_bad
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @ntr_bad
  ST r1,r14,3
  MOVI r6,0
ntr_loop:
  LD r1,r14,3
  ADD r2,r6,r0
  CALL @np_tcb_slot
  LD r7,r5,0
  LD r8,r14,2
  CMP r7,r8
  JMP[EQ] @ntr_found
  ADD r6,r6,r13
  MOVI r7,#NP_MAX_THREADS
  CMP r6,r7
  JMP[LT] @ntr_loop
  MOVI r1,2
  JMP @ntr_out
ntr_found:
  ST r0,r5,0
  LD r1,r14,3
  LD r7,r1,#NP_E_THREADS
  CMP r7,r0
  JMP[EQ] @ntr_ok
  SUB r7,r7,r13
  ST r7,r1,#NP_E_THREADS
ntr_ok:
  MOVI r1,0
  JMP @ntr_out
ntr_bad:
  MOVI r1,1
ntr_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_set_priority r1=pid, r2=priority 0..255 -> 0 ok / 1 bad pid / 2 out of range.
np_set_priority:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r2,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @nsp_bad
  LD r3,r14,1
  MOVI r4,255
  CMP r3,r4
  JMP[GT] @nsp_range
  ST r3,r1,#NP_E_PRIO
  MOVI r1,0
  JMP @nsp_out
nsp_bad:
  MOVI r1,1
  JMP @nsp_out
nsp_range:
  MOVI r1,2
nsp_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_child_count r1=pid -> r1=number of live entries in the child list.
np_child_count:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @ncc_zero
  LD r3,r1,#NP_E_CHILD
  ST r3,r14,2
  MOVI r3,0
  ST r3,r14,3
ncc_loop:
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @ncc_done
  ADD r1,r3,r0
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @ncc_done
  LD r4,r1,#NP_E_SIB
  ST r4,r14,2
  LD r4,r14,3
  ADD r4,r4,r13
  ST r4,r14,3
  JMP @ncc_loop
ncc_done:
  LD r1,r14,3
  JMP @ncc_out
ncc_zero:
  MOVI r1,0
ncc_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

; np_counts -> r1=live r2=running r3=zombies r4=spawns r5=reaps.
np_counts:
  LA r12,#NP_VARS
  LD r1,r12,#NP_V_LIVE
  LA r12,#NP_VARS
  LD r2,r12,#NP_V_RUN
  LA r12,#NP_VARS
  LD r3,r12,#NP_V_ZOMB
  LA r12,#NP_VARS
  LD r4,r12,#NP_V_SPAWN
  LA r12,#NP_VARS
  LD r5,r12,#NP_V_REAP
  RET

; np_stat r1=pid, r2=out (20 words; NP_S_* layout) -> r1=0 ok / 1 bad pid.
; This is the viewer/manager stat ABI; the entry layout stays kernel-private.
np_stat:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CALL @np_lookup
  CMP r1,r0
  JMP[EQ] @npst_bad
  ST r1,r14,3
  LD r1,r14,1
  CALL @np_child_count
  ST r1,r14,4
  LD r1,r14,3
  LD r5,r14,2
  LD r2,r1,#NP_E_PID
  ST r2,r5,#NP_S_PID
  LD r2,r1,#NP_E_PPID
  ST r2,r5,#NP_S_PPID
  LD r2,r1,#NP_E_STATE
  ST r2,r5,#NP_S_STATE
  LD r2,r1,#NP_E_STATUS
  ST r2,r5,#NP_S_STATUS
  LD r2,r1,#NP_E_THREADS
  ST r2,r5,#NP_S_THREADS
  LD r2,r1,#NP_E_STEPS
  ST r2,r5,#NP_S_STEPS
  LD r2,r1,#NP_E_CAPS
  ST r2,r5,#NP_S_CAPS
  LD r2,r1,#NP_E_NREG
  ST r2,r5,#NP_S_NREG
  LD r2,r1,#NP_E_MEM_WORDS
  ST r2,r5,#NP_S_MEM_WORDS
  LD r2,r1,#NP_E_HEAP_BASE
  ST r2,r5,#NP_S_HEAP_BASE
  LD r2,r1,#NP_E_HEAP_END
  ST r2,r5,#NP_S_HEAP_END
  LD r2,r1,#NP_E_HEAP_USED
  ST r2,r5,#NP_S_HEAP_USED
  LD r2,r1,#NP_E_HEAP_WORDS
  ST r2,r5,#NP_S_HEAP_WORDS
  LD r2,r14,4
  ST r2,r5,#NP_S_CHILDREN
  LD r2,r1,#NP_E_PRIO
  ST r2,r5,#NP_S_PRIO
  LD r2,r1,#NP_E_FLAGS
  ST r2,r5,#NP_S_FLAGS
  LD r2,r1,#NP_E_IMAGE
  ST r2,r5,#NP_S_IMAGE
  LD r2,r1,#NP_E_IMAGE_WORDS
  ST r2,r5,#NP_S_IMAGE_WORDS
  LD r2,r1,#NP_E_NAME
  ST r2,r5,#NP_S_NAME
  LD r2,r1,#NP_E_START_TICK
  ST r2,r5,#NP_S_START
  MOVI r1,0
  JMP @npst_out
npst_bad:
  MOVI r1,1
npst_out:
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET
