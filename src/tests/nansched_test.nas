; nansched_test.nas - verification image for src/lib/nansched.nas.
;
; The image is a real nan0s boot: it initialises nanproc + the scheduler,
; installs nsch_svc through nk_install_proc (src/lib/nankernel.nas keeps
; SVC 4..8 for NPAF), creates a root process and enters it with SVC 0.
; The root uses the same kernel for a file open/write/close and for eight
; child processes at priorities 1..3.  Children print, yield, sleep and exit;
; one is killed and waited for.  The final line is SCHED PASS.
;
; Kernel/process memory map (word addresses):
;   0..0x1FFFF  image and process code region (RX)
;   0x2F0000    nankernel kernel stack, 0x2F1000 trap frame, 0x2F2000 hook
;   0x40000     nanproc table (up to 64*96 in this image; library supports 1024)
;   0x58000     scheduler state NS_BASE: queues/links/wait words,
;               per-slot frames at NS_BASE+4192, region tables at NS_BASE+28768
;   0x69000     nanproc variable block
;   0x70000     root process data (accessed through r12=P_DATA)
;   0x7F000     boot stack
;   0x80000     process stacks (0x800 words each)
;   0xA0000..   free
;
; The per-slot frame and region-table arrays live inside the configured
; NS_BASE block so a kernel can move the whole scheduler block with one
; .equ; no array has a private fixed address.
;
; This test is verification only; the scheduler itself is src/lib/nansched.nas
; and is installed by the existing kernel, not a private OS.

.org 0
JMP @nsch_boot
.include "../lib/ncc.nas"
.include "../lib/nankernel.nas"
.include "../lib/nansched.nas"

; overrides (later .equ wins in nmk)
.equ NP_BASE      0x40000
.equ NP_VARS      0x69000
.equ NS_BASE      0x58000

.equ P_DATA       0x70000
.equ BOOTSTACK    0x7F000
.equ P_STACK      0x80000
.equ P_STACK_TOP  0x80400
.equ STACK_A      0x80800
.equ STACK_B      0x81000
.equ STACK_H      0x81800
.equ STACK_L      0x82000
.equ STACK_S      0x82800
.equ STACK_X      0x83000
.equ STACK_K      0x83800
.equ STACK_Y      0x84000
.equ STACK_A_TOP  0x80C00
.equ STACK_B_TOP  0x81400
.equ STACK_H_TOP  0x81C00
.equ STACK_L_TOP  0x82400
.equ STACK_S_TOP  0x82C00
.equ STACK_X_TOP  0x83400
.equ STACK_K_TOP  0x83C00
.equ STACK_Y_TOP  0x84400

.equ PID_A 0x10
.equ PID_B 0x11
.equ PID_H 0x12
.equ PID_L 0x13
.equ PID_S 0x14
.equ PID_X 0x15
.equ PID_K 0x16
.equ PID_Y 0x17
.equ ST_A 0x20
.equ ST_B 0x21
.equ ST_H 0x22
.equ ST_L 0x23
.equ ST_S 0x24
.equ ST_X 0x25
.equ ST_Y 0x26
.equ ST_K 0x27
.equ KILL_RC 0x30
.equ FS_HANDLE 0x31

.equ CODE_BASE    0
.equ CODE_WORDS   0x20000

; ---------------------------------------------------------------------------
; boot: ports are programmed by nsch_init; then install the process hook and
; create the root process.  SVC 0 with no current process starts it.
nsch_boot:
  MOVI r13,1
  LA r14,#BOOTSTACK
  CALL @nsch_init
  LA r1,@ns_svc
  CALL @nk_install_proc
  MOVI r1,0
  LA r2,@desc_root
  CALL @nsch_spawn_desc
  CMP r1,r0
  JMP[EQ] @boot_fail
  SVC 0
  HALT
boot_fail:
  LA r1,@msg_bootfail
  CALL @test_puts
  HALT

; ---------------------------------------------------------------------------
; test_puts: r1 = word address of NUL-terminated bytes.
test_puts:
  ST r15,r14,0
  ADDI r14,r14,17
  SHL r1,r1,2
  ADD r5,r1,r0
test_puts_l:
  LDB r2,r5,0
  CMP r2,r0
  JMP[EQ] @test_puts_d
  PUTC r2
  ADDI r5,r5,1
  JMP @test_puts_l
test_puts_d:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; test_put_dec: r1 = 0..999, no leading zeroes.
test_put_dec:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  CMP r1,r0
  JMP[NE] @tpd_nonzero
  MOVI r1,48
  PUTC r1
  JMP @tpd_out
tpd_nonzero:
  LD r1,r14,1
  MOVI r2,100
  CMP r1,r2
  JMP[LT] @tpd_tens
  DIVU r3,r1,r2
  ADDI r1,r3,48
  PUTC r1
  LD r1,r14,1
  MOVI r2,100
  DIVU r3,r1,r2
  MOVI r4,100
  MUL r3,r3,r4
  SUB r1,r1,r3
  ST r1,r14,1
tpd_tens:
  LD r1,r14,1
  MOVI r2,10
  DIVU r3,r1,r2
  ADDI r1,r3,48
  PUTC r1
  LD r1,r14,1
  MOVI r2,10
  MODU r3,r1,r2
  ADDI r1,r3,48
  PUTC r1
tpd_out:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; root process: the same kernel handles FS SVCs 4..8 and process SVCs.
root_entry:
  MOVI r13,1
  LA r14,#P_STACK_TOP
  LA r12,#P_DATA
  LA r1,@msg_begin
  CALL @test_puts

  ; SVC 4 open("/sched.txt", write)
  LA r1,@fs_path
  SHL r1,r1,2
  MOVI r2,1
  SVC 4
  CMP r1,r0
  JMP[EQ] @root_fsbad
  ST r1,r12,#FS_HANDLE
  ; SVC 6 write(handle, "FSOK", 4)
  LD r1,r12,#FS_HANDLE
  LA r2,@fs_msg
  SHL r2,r2,2
  MOVI r3,4
  SVC 6
  MOVI r4,4
  CMP r1,r4
  JMP[NE] @root_fsbad
  ; SVC 8 close(handle)
  LD r1,r12,#FS_HANDLE
  SVC 8
  CMP r1,r0
  JMP[NE] @root_fsbad
  LA r1,@msg_fsok
  CALL @test_puts
  JMP @root_spawn
root_fsbad:
  LA r1,@msg_fsbad
  CALL @test_puts

root_spawn:
  LA r1,@desc_a
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_A
  LA r1,@desc_b
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_B
  LA r1,@desc_h
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_H
  LA r1,@desc_l
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_L
  LA r1,@desc_s
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_S
  LA r1,@desc_x
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_X
  LA r1,@desc_k
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_K
  LA r1,@desc_y
  SVC 9
  CMP r1,r0
  JMP[EQ] @root_spawnbad
  ST r1,r12,#PID_Y
  LA r1,@msg_spawn
  CALL @test_puts
  LA r1,@msg_run
  CALL @test_puts

  ; Wait for the seven normal children.  Each wait blocks until the child
  ; exits; the scheduler wakes the parent with the status in r1.
  LD r1,r12,#PID_A
  SVC 10
  ST r1,r12,#ST_A
  LD r1,r12,#PID_B
  SVC 10
  ST r1,r12,#ST_B
  LD r1,r12,#PID_H
  SVC 10
  ST r1,r12,#ST_H
  LD r1,r12,#PID_L
  SVC 10
  ST r1,r12,#ST_L
  LD r1,r12,#PID_S
  SVC 10
  ST r1,r12,#ST_S
  LD r1,r12,#PID_X
  SVC 10
  ST r1,r12,#ST_X
  LD r1,r12,#PID_Y
  SVC 10
  ST r1,r12,#ST_Y

  ; kill the yielding victim, then wait for 128+15 = 143
  LD r1,r12,#PID_K
  MOVI r2,15
  SVC 22
  ST r1,r12,#KILL_RC
  LD r1,r12,#PID_K
  SVC 10
  ST r1,r12,#ST_K

  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_A
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_B
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_H
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_L
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_S
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_X
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_Y
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_kill
  CALL @test_puts
  LD r1,r12,#KILL_RC
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_w
  CALL @test_puts
  LD r1,r12,#ST_K
  CALL @test_put_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_pass
  CALL @test_puts
  MOVI r1,0
  SVC 1
  HALT

root_spawnbad:
  LA r1,@msg_spawnbad
  CALL @test_puts
  MOVI r1,1
  SVC 1
  HALT

; ---------------------------------------------------------------------------
; child entries.  Each sets r13/r14 from its region table; code is shared RX.
cp_a:
  MOVI r13,1
  LA r14,#STACK_A_TOP
  MOVI r7,65
  MOVI r6,3
cp_a_l:
  PUTC r7
  SVC 0
  SUB r6,r6,r13
  CMP r6,r0
  JMP[NE] @cp_a_l
  MOVI r1,10
  SVC 1
  HALT

cp_b:
  MOVI r13,1
  LA r14,#STACK_B_TOP
  MOVI r7,66
  MOVI r6,3
cp_b_l:
  PUTC r7
  SVC 0
  SUB r6,r6,r13
  CMP r6,r0
  JMP[NE] @cp_b_l
  MOVI r1,20
  SVC 1
  HALT

cp_h:
  MOVI r13,1
  LA r14,#STACK_H_TOP
  MOVI r1,72
  PUTC r1
  MOVI r1,2
  SVC 24
  MOVI r1,104
  PUTC r1
  MOVI r1,30
  SVC 1
  HALT

cp_l:
  MOVI r13,1
  LA r14,#STACK_L_TOP
  MOVI r1,76
  PUTC r1
  MOVI r1,40
  SVC 1
  HALT

cp_s:
  MOVI r13,1
  LA r14,#STACK_S_TOP
  MOVI r1,83
  PUTC r1
  MOVI r1,3
  SVC 24
  MOVI r1,115
  PUTC r1
  MOVI r1,50
  SVC 1
  HALT

cp_x:
  MOVI r13,1
  LA r14,#STACK_X_TOP
  MOVI r1,88
  PUTC r1
  MOVI r1,60
  SVC 1
  HALT

cp_k:
  MOVI r13,1
  LA r14,#STACK_K_TOP
  MOVI r1,75
  PUTC r1
cp_k_l:
  SVC 0
  JMP @cp_k_l

cp_y:
  MOVI r13,1
  LA r14,#STACK_Y_TOP
  MOVI r1,89
  PUTC r1
  MOVI r1,70
  SVC 1
  HALT

; ---------------------------------------------------------------------------
; spawn descriptors: entry, sp, priority, name, nregions, {base,words,kind,prot}
desc_root:
.word @root_entry,#P_STACK_TOP,0,1,3
.word #CODE_BASE,#CODE_WORDS,0,5
.word #P_DATA,0x400,0,3
.word #P_STACK,0x800,0,3
desc_a:
.word @cp_a,#STACK_A_TOP,3,101,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_A,0x800,0,3
desc_b:
.word @cp_b,#STACK_B_TOP,3,102,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_B,0x800,0,3
desc_h:
.word @cp_h,#STACK_H_TOP,1,103,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_H,0x800,0,3
desc_l:
.word @cp_l,#STACK_L_TOP,2,104,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_L,0x800,0,3
desc_s:
.word @cp_s,#STACK_S_TOP,2,105,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_S,0x800,0,3
desc_x:
.word @cp_x,#STACK_X_TOP,2,106,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_X,0x800,0,3
desc_k:
.word @cp_k,#STACK_K_TOP,3,107,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_K,0x800,0,3
desc_y:
.word @cp_y,#STACK_Y_TOP,3,108,2
.word #CODE_BASE,#CODE_WORDS,0,5
.word #STACK_Y,0x800,0,3

; ---------------------------------------------------------------------------
msg_begin:
.str "SCHED BEGIN\n"
msg_fsok:
.str "FS OK\n"
msg_fsbad:
.str "FS BAD\n"
msg_spawn:
.str "SPAWN 8\n"
msg_spawnbad:
.str "SPAWN BAD\n"
msg_run:
.str "RUN "
msg_w:
.str "W "
msg_kill:
.str "KILL "
msg_pass:
.str "SCHED PASS\n"
msg_bootfail:
.str "BOOT FAIL\n"
fs_path:
.str "/sched.txt"
fs_msg:
.str "FSOK"
