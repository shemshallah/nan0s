; gui_sched_boot.nas - NaN/0S kernel boot with the desktop and NANIX shell
; as scheduled processes.
;
; Layout (word addresses):
;   0x00000  boot trampoline (this file)
;   0x02000  GUI desktop cartridge (unchanged; linked at 8192)
;   0x10000  nankernel + nansched kernel image (this file)
;   0x200000 NS_BASE scheduler block
;   0x220000 nanproc table (1024 slots)
;   0x240000 NP_VARS
;   0x250000 PID 2 shell stack
;   0x2F0000 kernel stack / 0x2F1000 trap frame / 0x2F2000 hook
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

.org 8192
.include "gui_cart.nas"

.org 0x10000
.include "../lib/nankernel.nas"
.include "../lib/nansched.nas"

; Kernel/process map (word addresses).  Later .equ wins in nmk.
.equ NP_BASE      0x220000
.equ NP_VARS      0x240000
.equ NS_BASE      0x200000
.equ NP_MAX_PROCS 1024
.equ NS_BOOTMEM   0x1000000
.equ SHELL_STACK  0x250000
.equ KBOOT_STACK  0x2F0000
.equ KERNEL_MEM   0x1000000
; The GUI's fixed compiler/terminal buffers end below this word; the SVC 2
; heap starts here and runs to the top of the machine's discovered RAM.
.equ HEAP_BASE    0xB00000
.equ MIN_MEM      0x1000000

; ---------------------------------------------------------------------------
; gui_kernel_boot - initialise the kernel, create PID 1 (desktop) and PID 2
; (NANIX shell), then enter the highest-priority ready process.
gui_kernel_boot:
  MOVI r13,1
  LA r14,#KBOOT_STACK
  CALL @nsch_init
  LA r1,@ns_svc
  CALL @nk_install_proc

  ; MEMQ: the kernel publishes the actual word count through CPUID
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

  ; Publish the word count to the desktop shell and to both region tables.
  LA r4,@g_mem_words
  ST r11,r4,0
  LA r4,@gui_desc_desktop
  ADDI r4,r4,6
  ST r11,r4,0
  LA r4,@gui_desc_shell
  ADDI r4,r4,6
  ST r11,r4,0
  ; The boot region table was built before MEMQ; widen it to real RAM.
  LA r4,#NS_BASE
  LA r5,#NS_BOOTTAB
  ADD r4,r4,r5
  ST r11,r4,1

  LA r4,@g_heap_free
  ST r0,r4,0

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

  ; The kernel has no runnable context of its own: SVC 0 with no current
  ; process starts the highest-priority ready process.
  SVC 0
  JMP @gui_boot_fail

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
  .word @gui_shell_proc, #SHELL_STACK, 0, 0, 1
  .word 0, #KERNEL_MEM, 4, 7
