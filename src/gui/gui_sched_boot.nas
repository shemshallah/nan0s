; gui_sched_boot.nas - NaN/0S kernel boot with the desktop and NANIX shell
; as scheduled processes.
;
; Layout (word addresses; the scheduler block and process table move at
; runtime into the highest usable PMEM range, not these fixed defaults):
;   0x00000  boot trampoline (this file)
;   0x02000  GUI desktop cartridge (unchanged; linked at 8192)
;   0x10000  nankernel + nansched + memmap kernel image (this file)
;   runtime  NS_BASE scheduler block, NP_BASE nanproc table, NP_VARS
;   0x250000 PID 2 shell stack
;   0x2F0000 kernel stack / 0x2F1000 trap frame / 0x2F2000 hook
;   runtime  SVC 2 bump heap, one span per usable PMEM range, ending below
;            NP_VARS
;
; PID 1 is the desktop/window-manager process (entry cart_entry, the same
; stack the cart has always used).  PID 2 is the NANIX command process: the
; Terminal writes a completed line to FNB, sets g_shell_req, and yields;
; PID 2 calls the same raw-NaN fs_dispatch/term_cmd path and writes output
; into the Terminal's virtual console.  No C is involved in the guest.
;
; All code below is raw NaN16.  The C core is only the conformance oracle.

.org 0
LA r1,@gui_kernel_boot
JMPR r1

; nasm0 and n16i live in the free pad below the 64K GUI cart.  Both are
; 16-bit-address code (nasm0 uses MOVI @label for its tables), so the shell at
; 0x80000 reaches them with near CALLs while their internals stay below 0x10000.
.org 0x300
.include "../prog/nasm.nas"
.org 0x18A0
.include "../tools/n16i.nas"

.org 8192
.include "gui_cart.nas"

.org 0x10000
.include "../lib/nankernel.nas"
.include "../lib/nansched.nas"
.include "../lib/nansmp.nas"
.include "../lib/nansched_nansmp.nas"
.include "../lib/n64.nas"
.include "../lib/narena64.nas"
.include "../lib/nten.nas"
.include "../lib/nmat.nas"
.include "../lib/memmap.nas"

; Kernel/process map (word addresses).  Later .equ wins in nmk.
.equ NP_BASE      0x220000
.equ NP_VARS      0x240000
.equ NS_BASE      0x200000
.equ NP_MAX_PROCS 1024
.equ NS_BOOTMEM   0x1000000
.equ SHELL_STACK  0x250000
.equ KBOOT_STACK  0x2F0000
.equ KERNEL_MEM   0x1000000
; Boot SMP policy probe: task arena and nansmp ops table live below the
; compiler/GUI buffers; the probe runs once before the first SVC.
.equ SMPT_CTX     0x2C0000
.equ SMPT_OPS     0x2C0100
.equ SMPT_ARENA   0x2C0200
.equ N64_CTX      0x2D0000
.equ N64_TEN      0x2D0100
.equ N64_BASE     0x2E0000
.equ N64_SIZE     0x1000
; The GUI's fixed compiler/terminal buffers end below this word; the SVC 2
; heap starts here and is clipped to every usable PMEM range above it.
.equ HEAP_BASE    0xB00000
.equ MIN_MEM      0xF00000

; ---------------------------------------------------------------------------
; gui_kernel_boot - initialise the kernel, create PID 1 (desktop) and PID 2
; (NANIX shell), then enter the highest-priority ready process.
gui_kernel_boot:
  MOVI r13,1
  LA r14,#KBOOT_STACK
  ; COM1 cold-boot banner: product boot smoke with no C harness.
  LA r1,@gui_boot_banner
  SHL r1,r1,2
gui_boot_ser:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @gui_boot_ser_done
  PUTC r2
  ADD r1,r1,r13
  JMP @gui_boot_ser
gui_boot_ser_done:

  ; MEMQ first: the kernel publishes the actual word count through CPUID
  ; 0x4E4D00FF, subleaf 1.  Never compile a RAM size into the boot path.
  LA r1,0x4E4D00FF
  MOVI r2,1
  CPUID r3,r1,r2
  CMP r3,r0
  JMP[NE] @gui_mem_have
  LA r3,#MIN_MEM
gui_mem_have:
  LA r4,#MIN_MEM
  CMP r3,r4
  JMP[LT] @gui_boot_fail
  ADD r11,r3,r0
  LA r4,@g_mem_words
  ST r3,r4,0

  ; PMEM: the highest usable range is the only legal home for the scheduler,
  ; process table and kernel stacks.  mm_top returns the legacy single range
  ; {0, MEMQ_words, RAM} when no map exists, so old images keep working.
  ADD r1,r11,r0
  CALL @mm_top
  ; r1=top base  r2=top end (exclusive)  r3=entry index  r4=map source
  CMP r2,r0
  JMP[EQ] @gui_boot_fail
  CMP r1,r2
  JMP[GE] @gui_boot_fail
  LA r4,@g_top_base
  ST r1,r4,0
  LA r4,@g_top_end
  ST r2,r4,0
  ADD r10,r2,r0                ; top end of the highest usable range

  ; Place the process table and scheduler at that top, below its guard page.
  ; The heap ends below them, so RAM size/holes and kernel placement are not
  ; linked to a fixed address.
  LA r1,#NS_BYTES
  SUB r4,r10,r1
  LA r5,0x1000
  SUB r4,r4,r5                 ; NS_BASE
  LA r1,#NP_MAX_PROCS
  MOVI r2,#NP_ENTRY
  MUL r1,r1,r2
  SUB r5,r4,r1
  LA r1,0x1000
  SUB r5,r5,r1                 ; NP_BASE
  LA r1,#NP_VAR_WORDS
  SUB r6,r5,r1
  LA r1,0x1000
  SUB r6,r6,r1                 ; NP_VARS
  LA r7,#HEAP_BASE
  LA r1,0x10000
  ADD r7,r7,r1
  CMP r6,r7
  JMP[LE] @gui_boot_fail
  LA r1,@g_top_base
  LD r1,r1,0
  CMP r6,r1
  JMP[LE] @gui_boot_fail       ; scheduler block leaves the usable range
  ADD r1,r4,r0
  ADD r2,r5,r0
  ADD r3,r6,r0
  LA r4,@g_mem_words
  LD r4,r4,0
  CALL @ns_config
  CALL @nsch_init
  LA r1,@ns_svc
  CALL @nk_install_proc

  ; nsch_init clobbers r1..r12; reload the published values.
  LA r4,@g_mem_words
  LD r11,r4,0
  LA r4,@gui_desc_desktop
  ADDI r4,r4,6
  ST r11,r4,0
  LA r4,@gui_desc_shell
  ADDI r4,r4,6
  ST r11,r4,0
  LA r4,#NS_PTR
  LD r4,r4,0
  LA r5,#NS_BOOTTAB
  ADD r4,r4,r5
  ST r11,r4,1

  ; Build the SVC 2 bump heap from every usable PMEM range.  Ranges are
  ; clipped to [HEAP_BASE, NPV_PTR-guard), so a reserved/ACPI/device hole
  ; between two RAM ranges is never allocatable and is never crossed.
  CALL @ns_heap_reset
  LA r4,#NPV_PTR
  LD r2,r4,0
  LA r4,0x1000
  SUB r2,r2,r4
  LA r4,@g_heap_end
  ST r2,r4,0
  LA r4,@g_mem_words
  LD r11,r4,0
  LA r4,@g_map_i
  ST r0,r4,0
gui_heap_ranges:
  LA r4,@g_map_i
  LD r1,r4,0
  ADD r2,r11,r0
  CALL @mm_entry
  CMP r5,r0
  JMP[EQ] @gui_heap_done
  MOVI r6,#MM_K_RAM
  CMP r3,r6
  JMP[NE] @gui_heap_next
  ADD r6,r1,r2                 ; range end
  LA r7,#HEAP_BASE
  CMP r1,r7
  JMP[GE] @gui_heap_base_ok
  ADD r1,r7,r0
gui_heap_base_ok:
  LA r7,@g_heap_end
  LD r7,r7,0
  CMP r6,r7
  JMP[LE] @gui_heap_end_ok
  ADD r6,r7,r0
gui_heap_end_ok:
  CMP r6,r1
  JMP[LE] @gui_heap_next
  ADD r2,r6,r0
  CALL @ns_heap_add_range
gui_heap_next:
  LA r4,@g_map_i
  LD r4,r4,0
  ADD r4,r4,r13
  LA r5,@g_map_i
  ST r4,r5,0
  JMP @gui_heap_ranges
gui_heap_done:
  CALL @ns_heap_free
  LA r4,@g_heap_free
  ST r1,r4,0

  MOVI r1,0
  LA r2,@gui_desc_desktop
  CALL @nsch_spawn_desc
  CMP r1,r0
  JMP[EQ] @gui_boot_fail

  MOVI r1,0
  LA r2,@gui_desc_shell
  CALL @nsch_spawn_desc
  CMP r1,r0
  JMP[EQ] @gui_boot_fail
  LA r2,@g_shell_pid
  ST r1,r2,0
  ; Shell startup smoke: proves PID 2 was created before the first SVC 0.
  LA r1,@gui_shell_banner
  SHL r1,r1,2
gui_shell_ser:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @gui_shell_ser_done
  PUTC r2
  ADD r1,r1,r13
  JMP @gui_shell_ser
gui_shell_ser_done:

  ; Bind the F2 per-CPU policy to the real nansmp ops and prove it can
  ; place a task on CPU 0.  On -smp 1 this is a single-CPU run; on -smp 2/4
  ; the core has already started the APs and the probe sees the full map.
  CALL @n64_probe
  CALL @smp_probe

  ; The kernel has no runnable context of its own: SVC 0 with no current
  ; process starts the highest-priority ready process.
  SVC 0
  JMP @gui_boot_fail

gui_boot_banner:
  .str "NaN/0S BOOT\n"
gui_shell_banner:
  .str "NANIX SHELL READY\n"
gui_boot_fail:
  MOVI r1,33
  PUTC r1
  MOVI r1,75
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT

; ---------------------------------------------------------------------------
; gui_shell_proc - PID 2.  Wait for a completed command line from the
; Terminal, execute it in the shared NANIX code, then wake the desktop.
gui_shell_proc:
  MOVI r13,1
  LA r14,#SHELL_STACK
gui_shell_loop:
  LA r2,@g_shell_req
  LD r1,r2,0
  CMP r1,r0
  JMP[EQ] @gui_shell_idle
  ST r0,r2,0
  CALL @fs_dispatch
  CMP r1,r0
  JMP[NE] @gui_shell_done
  ; Full-line dispatcher did not claim it: preserve the Terminal's
  ; single-letter commands (h, c, v, ...) by reading the first byte of FNB.
  LA r1,#FNB
  LDB r4,r1,0
  MOVI r5,65
  CMP r4,r5
  JMP[LT] @gui_shell_lc
  MOVI r5,90
  CMP r4,r5
  JMP[GT] @gui_shell_lc
  MOVI r5,32
  ADD r4,r4,r5
gui_shell_lc:
  LD r1,r0,@tk_id
  CALL @term_cmd
gui_shell_done:
  LA r2,@g_shell_done
  MOVI r1,1
  ST r1,r2,0
gui_shell_idle:
  SVC 0
  JMP @gui_shell_loop

; Spawn descriptors: {entry, sp, priority, name, nregions, regions...}.
; One RWX shared region covers the flat image; both processes share the
; Terminal buffers, window table and filesystem exactly as the single
; guest did, but with independent trap frames and stacks.
gui_desc_desktop:
  .word @cart_entry, 0x59000, 0, 0, 1
  .word 0, #KERNEL_MEM, 4, 7
gui_desc_shell:
  .word @nx_main, #SHELL_STACK, 0, 0, 1
  .word 0, #KERNEL_MEM, 4, 7

; Boot scratch/evidence published for gates and for the `mem` command.
g_top_base:
  .word 0
g_top_end:
  .word 0
g_heap_end:
  .word 0
g_map_i:
  .word 0
g_ncpu:
  .word 0
g_apmap:
  .word 0
g_smp_ok:
  .word 0
g_n64_ok:
  .word 0
g_n64_ptr:
  .word 0

; ---------------------------------------------------------------------------
; smp_probe - native multicore policy binding at boot.
; Reads the CPU count (0x4E0F) and AP bitmap (0x4E0E), initialises the F2
; scheduler with that many CPUs, binds the production nansmp ops table, and
; runs one add/push/pop on CPU 0.  g_smp_ok records the result.  With more
; than one CPU the kernel prints "SMP <ncpu> AP <bitmap-hex>" before the GUI.
smp_probe:
  ST r15,r14,0
  ADDI r14,r14,9
  MOVI r1,0x4E0F
  INL r2,r1
  LA r3,@g_ncpu
  ST r2,r3,0
  MOVI r1,0x4E0E
  INL r2,r1
  LA r3,@g_apmap
  ST r2,r3,0
  LA r1,#SMPT_CTX
  LA r2,@g_ncpu
  LD r2,r2,0
  LA r3,#SMPT_ARENA
  MOVI r4,16
  MOVI r5,4
  LA r6,#SMPT_OPS
  CALL @nsched_init
  CMP r1,r0
  JMP[NE] @smp_probe_bad
  LA r1,#SMPT_CTX
  CALL @nsched_bind_nansmp
  CMP r1,r0
  JMP[NE] @smp_probe_bad
  LA r1,#SMPT_CTX
  MOVI r2,0
  MOVI r3,0
  MOVI r4,1
  MOVI r5,5
  MOVI r6,0
  CALL @nsched_task_add
  CMP r1,r0
  JMP[NE] @smp_probe_bad
  LA r1,#SMPT_CTX
  MOVI r2,0
  MOVI r3,0
  CALL @nsched_push
  CMP r1,r0
  JMP[NE] @smp_probe_bad
  LA r1,#SMPT_CTX
  MOVI r2,0
  CALL @nsched_pop
  CMP r1,r0
  JMP[NE] @smp_probe_bad
  MOVI r1,1
  LA r2,@g_smp_ok
  ST r1,r2,0
  JMP @smp_probe_print
smp_probe_bad:
  MOVI r1,0
  LA r2,@g_smp_ok
  ST r1,r2,0
smp_probe_print:
  LA r1,@g_smp_ok
  LD r1,r1,0
  CMP r1,r0
  JMP[EQ] @smp_probe_out
  LA r1,@g_ncpu
  LD r1,r1,0
  MOVI r2,1
  CMP r1,r2
  JMP[LE] @smp_probe_out
  MOVI r1,83
  PUTC r1
  MOVI r1,77
  PUTC r1
  MOVI r1,80
  PUTC r1
  MOVI r1,32
  PUTC r1
  LA r1,@g_ncpu
  LD r1,r1,0
  ADDI r1,r1,48
  PUTC r1
  MOVI r1,32
  PUTC r1
  MOVI r1,65
  PUTC r1
  MOVI r1,80
  PUTC r1
  MOVI r1,32
  PUTC r1
  LA r1,@g_apmap
  LD r1,r1,0
  MOVI r2,10
  CMP r1,r2
  JMP[LT] @smp_probe_hex
  ADDI r1,r1,7
smp_probe_hex:
  ADDI r1,r1,48
  PUTC r1
  MOVI r1,10
  PUTC r1
smp_probe_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; n64_probe - 64-bit product ABI self-test.
; Allocates from an narena64 with (lo,hi) pointers, builds an nten descriptor,
; checks a 64-bit tensor pointer, and runs an nmat DP4B dot.  Success prints
; "N64 OK" before the shell starts; failure prints "N64 BAD".
n64_probe:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#N64_CTX
  LA r2,#N64_BASE
  MOVI r3,0
  LA r4,#N64_SIZE
  MOVI r5,0
  CALL @nar64_init
  LA r1,#N64_CTX
  MOVI r2,64
  MOVI r3,0
  MOVI r4,8
  CALL @nar64_alloc
  CMP r1,r0
  JMP[EQ] @n64_bad
  CMP r2,r0
  JMP[NE] @n64_bad
  LA r3,@g_n64_ptr
  ST r1,r3,0
  LA r1,#N64_TEN
  LA r2,@g_n64_ptr
  LD r2,r2,0
  MOVI r3,0
  MOVI r4,4
  MOVI r5,4
  MOVI r6,4
  MOVI r7,0
  MOVI r8,1
  MOVI r9,0
  CALL @nten_init
  LA r1,#N64_TEN
  MOVI r2,1
  MOVI r3,2
  CALL @nten_ptr
  LA r4,@g_n64_ptr
  LD r4,r4,0
  ADDI r4,r4,6
  CMP r1,r4
  JMP[NE] @n64_bad
  CMP r2,r0
  JMP[NE] @n64_bad
  LA r10,@g_n64_ptr
  LD r10,r10,0
  LA r11,0x04030201
  ST r11,r10,0
  LA r11,0x01010101
  ST r11,r10,4
  MOVI r11,0
  ST r11,r10,1
  ST r11,r10,5
  ADD r1,r10,r0
  ADDI r2,r10,4
  MOVI r3,2
  CALL @nmat_dot
  MOVI r4,10
  CMP r1,r4
  JMP[NE] @n64_bad
  MOVI r1,1
  LA r2,@g_n64_ok
  ST r1,r2,0
  LA r1,@n64_ok_msg
  CALL @n64_puts
  JMP @n64_probe_out
n64_bad:
  LA r1,@n64_bad_msg
  CALL @n64_puts
n64_probe_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET
n64_puts:
  SHL r1,r1,2
n64_puts_l:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @n64_puts_d
  PUTC r2
  ADD r1,r1,r13
  JMP @n64_puts_l
n64_puts_d:
  RET
n64_ok_msg:
  .str "N64 OK\n"
n64_bad_msg:
  .str "N64 BAD\n"

; ---------------------------------------------------------------------------
; NANIX POSIX shell (PID 2).  Separate image region so command growth cannot
; consume the 64K GUI cart.  Loaded at word 0x80000 (byte 4 MiB), below the
; GUI compiler buffers and shell stack, outside the cart slot.
.org 0x80000
.include "../nix/nixsh.nas"
